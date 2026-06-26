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

    init(manager: BackgroundTaskManager, sessionId: String?, bridgeId: UUID) {
        self.manager = manager
        self.sessionId = sessionId
        self.bridgeId = bridgeId
    }
}

/// Bridges a `BackgroundTaskManager` to an `Agent`: receives notifications and
/// injects them into the Agent's steering queue, kicking off a fresh run when
/// the Agent is idle.
///
/// Delivery strategy:
///   - Always enqueue the notification as a `user` steering message. A
///     running loop picks it up at the next turn boundary automatically via
///     `getSteeringMessages` — no new path needed.
///   - If the Agent is not currently streaming when the notification arrives,
///     kick off `agent.continue()`. If the Agent just started a run in the
///     meantime, `continue()` throws `alreadyRunning` and we swallow — the
///     steered message is safe in the queue and will be drained next turn.
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

    func onNotification(_ notif: BackgroundTaskNotification) async {
        guard let agent else { return }
        let text = notif.messageText()
        let msg = UserMessage(content: [.text(TextContent(text: text))])
        agent.steer(.user(msg))

        if !agent.state.isStreaming {
            // Race-safe: if someone else starts a run in the microsecond
            // between the check and `continue()`, we'll get `alreadyRunning`
            // and quietly give up — the message is already in the queue.
            let ref = agent
            Task { [weak ref] in
                try? await ref?.continue()
            }
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
    /// injected into this agent as user messages (steered mid-turn; fresh
    /// `continue()` when idle).
    ///
    /// Passing a `sessionId` scopes both notification delivery AND the
    /// `abortAndKillBackgroundTasks` sweep: only tasks spawned with the same
    /// sessionId are killed.
    ///
    /// Returns an async unsubscribe handle. Safe to call multiple times with
    /// different managers.
    public func attachBackgroundManager(
        _ manager: BackgroundTaskManager,
        sessionId: String? = nil
    ) async -> @Sendable () async -> Void {
        let bridge = BackgroundAgentBridge(agent: self, sessionId: sessionId)
        let attachment = BackgroundAttachment(
            manager: manager,
            sessionId: sessionId,
            bridgeId: bridge.id
        )
        appendAttachment(attachment)

        // Agent event subscription for the post-agentEnd safety drain.
        let eventUnsubscribe = subscribe { event, _ in
            await bridge.onAgentEvent(event)
        }

        // Manager notification subscription.
        let listenerHandle = await manager.onNotification { notif in
            // Only consume notifications scoped to this bridge's sessionId.
            // Notifications from tasks spawned without a sessionId pass when
            // the attachment is also session-less.
            if sessionId == nil || notif.sessionId == sessionId {
                await bridge.onNotification(notif)
            }
        }

        return { [weak self] in
            eventUnsubscribe()
            await listenerHandle.unsubscribe()
            self?.removeAttachment(bridgeId: bridge.id)
        }
    }

    /// Abort the current run AND kill every running task in every attached
    /// `BackgroundTaskManager` (scoped to the same sessionId the manager was
    /// attached with). Normal `abort()` leaves background tasks running.
    public func abortAndKillBackgroundTasks() async {
        abort()
        let attachments = backgroundAttachments()
        for attachment in attachments {
            await attachment.manager.killAll(sessionId: attachment.sessionId)
        }
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
}

final class AgentBackgroundAttachmentList: @unchecked Sendable {
    private let lock = NSLock()
    private var attachments: [BackgroundAttachment] = []

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
}
