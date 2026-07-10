import Foundation
import KWWKAI

// MARK: - Attachment bookkeeping

/// Tracks one `attachBackgroundManager` attachment so `abortAndKillBackgroundTasks`
/// can find and drain every active manager. Held strongly — we want the
/// Manager to stick around as long as an attachment exists.
final class BackgroundAttachment: @unchecked Sendable {
    let manager: BackgroundTaskManager
    let sessionId: String?
    let bridgeId: UUID
    let deliveryConsumer: BackgroundTaskDeliveryConsumer

    init(
        manager: BackgroundTaskManager,
        sessionId: String?,
        bridgeId: UUID,
        deliveryConsumer: BackgroundTaskDeliveryConsumer
    ) {
        self.manager = manager
        self.sessionId = sessionId
        self.bridgeId = bridgeId
        self.deliveryConsumer = deliveryConsumer
    }
}

/// Bridges a `BackgroundTaskManager` to an `Agent`: receives notifications and
/// injects them through the Agent's internal runtime-aside queue, kicking off
/// a fresh run when the Agent is idle.
///
/// Delivery strategy:
///   - Enqueue the notification as runtime context, separate from the user's
///     editable steering queue. A running loop picks it up at the next turn
///     boundary automatically.
///   - If the Agent is not currently streaming when the notification arrives,
///     kick off `agent.continue()`. If the Agent just started a run in the
///     meantime, `continue()` throws `alreadyRunning` and we swallow — the
///     runtime aside is safe in its queue and will be drained next turn.
///   - After `agentEnd`, wait for the Agent to truly finalize (post
///     `runLifecycle` teardown), then if the queue still has anything in it,
///     fire `continue()` once more. This handles the narrow race where a
///     notification arrives during final teardown.
final class BackgroundAgentBridge: @unchecked Sendable {
    let id: UUID
    weak var agent: Agent?
    let sessionId: String?

    init(agent: Agent, sessionId: String?) {
        self.id = UUID()
        self.agent = agent
        self.sessionId = sessionId
    }

    func onDeliveryAvailable() {
        guard let agent else { return }
        // Always install an idle waiter. This also covers the teardown sliver
        // after Agent.continue drained an empty mailbox but before it publishes
        // idle; a state-only `if !isStreaming` check would miss that wake.
        let ref = agent
        Task { [weak ref] in
            await ref?.waitForIdle()
            guard let ref, ref.hasQueuedMessages() else { return }
            try? await ref.continue()
        }
    }

    func onAgentEvent(_ event: AgentEvent) async {
        guard case .agentEnd = event else { return }
        let ref = agent
        Task { [weak ref] in
            await ref?.waitForIdle()
            guard let ref else { return }
            if ref.hasQueuedMessages() {
                try? await ref.continue()
            }
        }
    }
}

// MARK: - Agent extensions

extension Agent {
    /// Attach a `BackgroundTaskManager`. Notifications from the manager are
    /// injected into this agent as internal runtime asides (drained at a turn
    /// boundary; fresh `continue()` when idle).
    ///
    /// Passing a `sessionId` scopes both notification delivery AND the
    /// `abortAndKillBackgroundTasks` sweep: only tasks spawned with the same
    /// sessionId are killed.
    ///
    /// Returns an async unsubscribe handle. Safe to call multiple times with
    /// different managers.
    public func attachBackgroundManager(
        _ manager: BackgroundTaskManager,
        sessionId: String? = nil,
        deliveryConsumer explicitConsumer: BackgroundTaskDeliveryConsumer? = nil
    ) async -> @Sendable () async -> Void {
        // An explicit mailbox is reusable only when its scope exactly matches
        // the attachment. Accepting a broader/narrower consumer here would let
        // `drainRuntimeMessages()` bypass the attachment's session boundary.
        let scopedExplicitConsumer = explicitConsumer?.sessionId == sessionId
            ? explicitConsumer
            : nil
        let deliveryConsumer = scopedExplicitConsumer
            ?? state.tools.lazy.compactMap { tool -> BackgroundTaskDeliveryConsumer? in
                guard tool.backgroundTaskManager === manager else { return nil }
                return tool.backgroundDeliveryConsumer
            }.first(where: { $0.sessionId == sessionId })
            ?? BackgroundTaskDeliveryConsumer(sessionId: sessionId)
        let bridge = BackgroundAgentBridge(agent: self, sessionId: sessionId)
        let attachment = BackgroundAttachment(
            manager: manager,
            sessionId: sessionId,
            bridgeId: bridge.id,
            deliveryConsumer: deliveryConsumer
        )
        appendAttachment(attachment)

        // Agent event subscription for the post-agentEnd safety drain.
        let eventUnsubscribe = subscribe { event, _ in
            await bridge.onAgentEvent(event)
        }

        let unregisterDelivery = await manager.registerAgentDelivery(
            deliveryConsumer,
            wakeHandler: { [weak bridge] in
                bridge?.onDeliveryAvailable()
            },
            notificationHandler: { [weak self] notification in
                guard (sessionId == nil || notification.sessionId == sessionId),
                      let event = backgroundSubagentLifecycleEvent(notification),
                      let self,
                      self.recordBackgroundSubagent(event) else {
                    return
                }
                await self.emitExternalRuntimeEvent(.subagent(event))
            }
        )

        return { [weak self] in
            eventUnsubscribe()
            await unregisterDelivery()
            deliveryConsumer.releaseAllWatches()
            self?.removeAttachment(bridgeId: bridge.id)
        }
    }

    /// Abort the current run AND kill every active (queued or running) task in
    /// every attached `BackgroundTaskManager`, scoped to the same sessionId
    /// the manager was attached with. Normal `abort()` leaves them running.
    public func abortAndKillBackgroundTasks() async {
        abort()
        let attachments = backgroundAttachments()
        for attachment in attachments {
            if let sessionId = attachment.sessionId {
                // Teardown cancellation is not model input. Close silently so
                // terminal kill notifications cannot wake this idle Agent.
                await attachment.manager.closeSession(sessionId: sessionId)
            } else {
                await attachment.manager.killAll(sessionId: nil)
            }
        }
    }

    /// Terminal background-subagent work observed across model runs for this
    /// Agent instance. Foreground work remains available on each
    /// `AgentRunSummary`; this aggregate closes the observability gap for work
    /// that completes after the spawning run has ended.
    public func backgroundSubagentRuns() -> [SubagentRunSummary] {
        backgroundAttachmentList.backgroundSubagentRuns()
    }

    // MARK: - Private storage wiring

    fileprivate func appendAttachment(_ attachment: BackgroundAttachment) {
        backgroundAttachmentList.append(attachment)
    }

    fileprivate func removeAttachment(bridgeId: UUID) {
        backgroundAttachmentList.remove(bridgeId: bridgeId)
    }

    fileprivate func backgroundAttachments() -> [BackgroundAttachment] {
        backgroundAttachmentList.list()
    }

    fileprivate func recordBackgroundSubagent(_ event: SubagentLifecycleEvent) -> Bool {
        backgroundAttachmentList.record(event)
    }
}

private func backgroundSubagentLifecycleEvent(
    _ notification: BackgroundTaskNotification
) -> SubagentLifecycleEvent? {
    guard notification.kind == "agent", !notification.stalled,
          let outcome = notification.outcome,
          case .object(let details) = outcome.details ?? .null,
          case .string(let subagentType) = details["subagent_type"] ?? .null,
          case .string(let childSessionId) = details["child_session_id"] ?? .null else {
        return nil
    }
    let completed = notification.status == .completed && outcome.success
    return SubagentLifecycleEvent(
        kind: completed ? .completed : .failed,
        subagentType: subagentType,
        childSessionId: childSessionId,
        description: notification.description,
        model: jsonString(details["model"]),
        stopReason: jsonString(details["stop_reason"]).flatMap(StopReason.init(rawValue:)),
        usage: jsonUsage(details["usage"]),
        turns: jsonInt(details["turns"]),
        cost: jsonCost(details["cost"]),
        durationMs: jsonInt(details["duration_ms"]) ?? notification.durationMs,
        backgroundTaskId: notification.taskId,
        outputFile: notification.outputFile,
        message: outcome.summary,
        errorMessage: outcome.errorMessage ?? jsonString(details["error_message"])
    )
}

private func jsonString(_ value: JSONValue?) -> String? {
    guard case .string(let string) = value ?? .null else { return nil }
    return string
}

private func jsonInt(_ value: JSONValue?) -> Int? {
    switch value ?? .null {
    case .int(let int): return int
    case .double(let double): return Int(double)
    default: return nil
    }
}

private func jsonDouble(_ value: JSONValue?) -> Double {
    switch value ?? .null {
    case .double(let double): return double
    case .int(let int): return Double(int)
    default: return 0
    }
}

private func jsonUsage(_ value: JSONValue?) -> Usage? {
    guard case .object(let object) = value ?? .null else { return nil }
    return Usage(
        input: jsonInt(object["input"]) ?? 0,
        output: jsonInt(object["output"]) ?? 0,
        cacheRead: jsonInt(object["cache_read"]) ?? 0,
        cacheWrite: jsonInt(object["cache_write"]) ?? 0,
        totalTokens: jsonInt(object["total_tokens"]) ?? 0
    )
}

private func jsonCost(_ value: JSONValue?) -> Cost? {
    guard case .object(let object) = value ?? .null else { return nil }
    return Cost(
        input: jsonDouble(object["input"]),
        output: jsonDouble(object["output"]),
        cacheRead: jsonDouble(object["cache_read"]),
        cacheWrite: jsonDouble(object["cache_write"]),
        total: jsonDouble(object["total"])
    )
}

final class AgentBackgroundAttachmentList: @unchecked Sendable {
    private let lock = NSLock()
    private var attachments: [BackgroundAttachment] = []
    private var terminalSubagents: [String: SubagentRunSummary] = [:]
    private var terminalOrder: [String] = []

    func append(_ attachment: BackgroundAttachment) {
        lock.withLock {
            attachments.append(attachment)
        }
    }

    func remove(bridgeId: UUID) {
        lock.withLock {
            attachments.removeAll { $0.bridgeId == bridgeId }
        }
    }

    func list() -> [BackgroundAttachment] {
        lock.withLock { attachments }
    }

    func record(_ event: SubagentLifecycleEvent) -> Bool {
        guard let taskId = event.backgroundTaskId,
              event.kind == .completed || event.kind == .failed else { return false }
        return lock.withLock {
            guard terminalSubagents[taskId] == nil else { return false }
            terminalOrder.append(taskId)
            terminalSubagents[taskId] = SubagentRunSummary(
                subagentType: event.subagentType,
                childSessionId: event.childSessionId,
                description: event.description,
                status: event.kind == .completed ? .completed : .failed,
                model: event.model,
                stopReason: event.stopReason,
                usage: event.usage,
                turns: event.turns,
                cost: event.cost,
                durationMs: event.durationMs,
                backgroundTaskId: taskId,
                outputFile: event.outputFile,
                errorMessage: event.errorMessage
            )
            return true
        }
    }

    func backgroundSubagentRuns() -> [SubagentRunSummary] {
        lock.withLock { terminalOrder.compactMap { terminalSubagents[$0] } }
    }
}
