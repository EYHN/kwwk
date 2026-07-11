import Foundation
import KWWKAI

/// Marker for runners which are registered before their execution capacity is
/// available. The runner is responsible for calling `beginRunning` immediately
/// before real work starts.
protocol CapacityQueuedBackgroundTaskRunner: BackgroundTaskRunner {
    var startsQueued: Bool { get }
}

/// Process-scoped manager for background tasks. Owns task registry + the
/// pending-notification queue + an optional stall watchdog. Runners plug in
/// via `BackgroundTaskRunner`; the Manager itself is kind-agnostic.
///
/// Typical flow:
///
///   let manager = BackgroundTaskManager()
///   let (taskId, outputFile) = await manager.spawn(
///       runner: BashBackgroundRunner(command: "npm install", environment: env),
///       sessionId: "sess-1"
///   )
///   // … later, the agent receives a runtime aside when the task completes.
///
/// Cross-cutting guarantees:
///   - Task IDs are unique within a Manager instance.
///   - Each task gets a distinct `outputFile` under `outputDir`.
///   - Exactly one terminal notification is enqueued per task (completion or
///     kill — whichever fires first wins; the other is suppressed). A stall
///     notification is a non-terminal heads-up: it may precede the terminal
///     one, so a stuck-then-finished task yields a stall AND a completion.
///   - Listeners are invoked sequentially in subscription order on the
///     Manager's isolation context.
public actor BackgroundTaskManager {
    // MARK: - Public types

    public struct ListenerHandle: Sendable {
        let id: UUID
        public let unsubscribe: @Sendable () async -> Void
    }

    // MARK: - State

    private struct Entry {
        var spec: BackgroundTaskSpec
        var sessionId: String?
        var status: BackgroundTaskStatus
        var startedAt: Date
        var runningAt: Date?
        var completedAt: Date?
        var outputFile: URL
        var ownsOutputFile: Bool
        var cancellation: CancellationHandle
        var outcome: BackgroundTaskOutcome?
        var notified: Bool
        /// When the task was adopted via `adopt`, its external `waitForCompletion`
        /// is tracked here so `kill` can cancel it.
        var adoptionTask: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        /// Set when the hard deadline has elapsed and cooperative cancellation
        /// has begun. A runner that reports during the grace period still gets
        /// the canonical timeout outcome; the deadline, not callback timing,
        /// determines the terminal result.
        var hardTimeoutTriggered: Bool
        /// Byte offset of the runner-owned terminal section. It is located once
        /// when the task settles, then reused by every snapshot/notification so
        /// payload text containing `[final]` or `[error]` cannot move the preview.
        var terminalOutputOffset: Int?
    }

    /// A spawn captures the current lifecycle generation before resolving the
    /// SDK-supplied `spec` off actor. `closeSession` advances the generation;
    /// a late result from the old generation is registered as silently killed
    /// and never handed to its runner. A later spawn with the same session id
    /// captures the new generation and starts a fresh lifecycle normally.
    private struct SpawnEpoch: Sendable {
        let sessionId: String?
        let generation: UInt64
    }

    private struct Listener: @unchecked Sendable {
        let id: UUID
        let handler: @Sendable (BackgroundTaskNotification) async -> Void
    }

    private var tasks: [String: Entry] = [:]
    private var pendingNotifications: [BackgroundTaskNotification] = []
    private var listeners: [Listener] = []
    /// Model-facing delivery is separate from the public listener broadcast.
    /// Each attached Agent owns a distinct mailbox so one Agent polling a task
    /// can never suppress another Agent or an SDK observer.
    private var deliveryConsumers: [UUID: BackgroundTaskDeliveryConsumer] = [:]
    private var sessionGenerations: [String: UInt64] = [:]

    /// FIFO of notifications still to be delivered to `listeners`. The
    /// actor drains this serially so a steering-style listener (e.g. the
    /// Agent bridge) sees a `stalled` event before a subsequent
    /// `completed` for the same task. An earlier revision used
    /// `Task { for listener in listeners { await listener(notif) } }`
    /// per notification — any suspension in a listener could let later
    /// notifications overtake, which made completion/stall ordering
    /// non-deterministic under load.
    private var deliveryQueue: [BackgroundTaskNotification] = []
    private var deliveryTask: Task<Void, Never>?
    private var deliveringTaskId: String?

    public let outputDir: URL
    /// Time allowed for a runner to react to hard-timeout cancellation before
    /// the manager forces a terminal failure. This only controls registry
    /// settlement; stopping external resources remains the runner's job.
    public let hardTimeoutGraceSeconds: Double
    /// Automatic terminal registry/artifact retention. Active tasks and model
    /// delivery mailboxes/leases are never pruned.
    public let terminalRetentionLimit: Int
    public let terminalRetentionSeconds: Int

    // Tunables (exposed for tests; clamp reasonable defaults)
    public var stallCheckIntervalSeconds: UInt64 = 5
    public var stallThresholdSeconds: Double = 45
    public var tailBytes: Int = 4096

    // MARK: - Init

    public init(
        outputDir: URL? = nil,
        hardTimeoutGraceSeconds: Double = 2,
        terminalRetentionLimit: Int = 256,
        terminalRetentionSeconds: Int = 86_400
    ) {
        self.hardTimeoutGraceSeconds = hardTimeoutGraceSeconds.isFinite
            ? max(0, hardTimeoutGraceSeconds)
            : 2
        self.terminalRetentionLimit = max(1, terminalRetentionLimit)
        self.terminalRetentionSeconds = max(60, terminalRetentionSeconds)
        if let dir = outputDir {
            self.outputDir = dir
        } else {
            // Per-manager private scratch directory under the system temp dir.
            // Foreground adopt path reuses this directory too (see
            // `allocateForegroundOutputFile` in BashTool.swift), so both bg
            // spawns and fg-flipped commands land here.
            self.outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("kwwk-bg-\(UUID().uuidString)", isDirectory: true)
        }
    }

    // MARK: - Spawn / adopt

    /// Start a new background task. Returns the allocated task id and output
    /// file path. The task starts executing immediately; the caller does not
    /// wait for completion.
    public nonisolated func spawn(
        runner: BackgroundTaskRunner,
        sessionId: String? = nil
    ) async -> (taskId: String, outputFile: URL) {
        let epoch = await captureSpawnEpoch(sessionId: sessionId)
        // `spec` is SDK-supplied code too: a computed getter can block just as
        // easily as `run`. Resolve it off-actor before entering registry state.
        let spec = await withCheckedContinuation {
            (continuation: CheckedContinuation<BackgroundTaskSpec, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runner.spec)
            }
        }
        return await spawnResolved(
            runner: runner,
            spec: spec,
            sessionId: sessionId,
            epoch: epoch
        )
    }

    private func captureSpawnEpoch(sessionId: String?) -> SpawnEpoch {
        SpawnEpoch(
            sessionId: sessionId,
            generation: sessionId.flatMap { sessionGenerations[$0] } ?? 0
        )
    }

    private func spawnResolved(
        runner: BackgroundTaskRunner,
        spec: BackgroundTaskSpec,
        sessionId: String?,
        epoch: SpawnEpoch
    ) -> (taskId: String, outputFile: URL) {
        pruneTerminalTasksIfNeeded()
        let startsQueued = (runner as? any CapacityQueuedBackgroundTaskRunner)?
            .startsQueued ?? false
        let (taskId, outputFile) = allocateTask(
            spec: spec,
            sessionId: sessionId,
            initialStatus: startsQueued ? .queued : .running
        )
        let cancellation = tasks[taskId]!.cancellation
        if spawnEpochIsStale(epoch) {
            settleLateSpawn(taskId: taskId)
            DispatchQueue.global(qos: .utility).async {
                runner.cancelBeforeLaunch(reason: "session-closed-before-launch")
            }
            return (taskId, outputFile)
        }
        if !startsQueued {
            scheduleHardTimeout(taskId: taskId, seconds: spec.hardTimeoutSeconds)
            if spec.kind != "agent" { launchWatchdog(taskId: taskId) }
        }

        // Hand off to the runner. Runner drives `onDone`.
        let onDone: @Sendable (BackgroundTaskOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            Task { await self.complete(taskId: taskId, outcome: outcome) }
        }
        // `BackgroundTaskRunner.run` is a synchronous launch hook supplied by
        // SDK clients. Invoke it outside actor isolation so a buggy runner that
        // blocks before returning cannot freeze kill/snapshot/timeout/task APIs.
        DispatchQueue.global(qos: .utility).async {
            runner.run(
                taskId: taskId,
                outputFile: outputFile,
                cancellation: cancellation,
                onDone: onDone
            )
        }
        return (taskId, outputFile)
    }

    private func spawnEpochIsStale(_ epoch: SpawnEpoch) -> Bool {
        guard let sessionId = epoch.sessionId else { return false }
        return sessionGenerations[sessionId, default: 0] != epoch.generation
    }

    private func settleLateSpawn(taskId: String) {
        guard var entry = tasks[taskId], entry.status.isActive else { return }
        let outcome = BackgroundTaskOutcome(
            success: false,
            summary: "session closed before launch",
            details: terminalDetails(
                for: entry,
                adding: [
                    "failure_kind": .string("killed"),
                    "reason": .string("session_closed_before_launch"),
                ]
            )
        )
        entry.status = .killed
        entry.completedAt = Date()
        entry.outcome = outcome
        entry.notified = true
        tasks[taskId] = entry
        entry.cancellation.cancel(reason: "session-closed-before-launch")
        pruneTerminalTasksIfNeeded()
    }

    /// Transition a capacity-queued task to active execution. Returns false if
    /// the task was cancelled or otherwise settled while waiting.
    func beginRunning(taskId: String) -> Bool {
        guard var entry = tasks[taskId] else { return false }
        if entry.status == .running { return true }
        guard entry.status == .queued else { return false }
        entry.status = .running
        entry.runningAt = Date()
        tasks[taskId] = entry
        scheduleHardTimeout(taskId: taskId, seconds: entry.spec.hardTimeoutSeconds)
        if entry.spec.kind != "agent" { launchWatchdog(taskId: taskId) }
        return true
    }

    /// Register an already-running task whose completion is awaited via the
    /// provided closure. Used by foreground-flip-to-background: the process
    /// is already streaming output into the file; we just need to track it
    /// and emit a notification when it ends.
    ///
    /// The Manager does NOT start anything. It trusts the caller that the
    /// work is underway (with `outputFile` being written into by someone
    /// else) and simply awaits `waitForCompletion`.
    public func adopt(
        spec: BackgroundTaskSpec,
        outputFile: URL? = nil,
        sessionId: String? = nil,
        waitForCompletion: @escaping @Sendable (CancellationHandle) async -> BackgroundTaskOutcome
    ) -> (taskId: String, outputFile: URL) {
        pruneTerminalTasksIfNeeded()
        let (taskId, file) = allocateTask(
            spec: spec,
            sessionId: sessionId,
            presetOutputFile: outputFile
        )
        let cancellation = tasks[taskId]!.cancellation
        scheduleHardTimeout(taskId: taskId, seconds: spec.hardTimeoutSeconds)
        if spec.kind != "agent" { launchWatchdog(taskId: taskId) }

        let adoptionTask = Task.detached { [weak self] in
            let outcome = await waitForCompletion(cancellation)
            await self?.complete(taskId: taskId, outcome: outcome)
        }
        tasks[taskId]?.adoptionTask = adoptionTask
        return (taskId, file)
    }

    // MARK: - Kill / query / drain

    /// Cancel a running task. No-op if already terminal.
    public func kill(_ taskId: String) throws {
        try kill(taskId, deliverNotification: true)
    }

    private func kill(_ taskId: String, deliverNotification: Bool) throws {
        guard var entry = tasks[taskId] else {
            throw BackgroundTaskError.notFound(taskId)
        }
        if !entry.status.isActive { return }
        let outcome = BackgroundTaskOutcome(
            success: false,
            summary: "killed",
            details: terminalDetails(
                for: entry,
                adding: [
                    "failure_kind": .string("killed"),
                    "reason": .string("cancelled"),
                ]
            ),
            errorMessage: nil
        )
        entry.status = .killed
        entry.completedAt = Date()
        entry.outcome = outcome
        tasks[taskId] = entry
        entry.cancellation.cancel(reason: "killed")
        entry.adoptionTask?.cancel()
        entry.watchdog?.cancel()
        entry.timeoutTask?.cancel()

        // Fire a killed notification so the model knows, unless the runner
        // already enqueued one (via complete()).
        if !entry.notified, deliverNotification {
            enqueueNotification(
                taskId: taskId,
                status: .killed,
                outcome: outcome,
                stalled: false
            )
            tasks[taskId]?.notified = true
        } else if !deliverNotification {
            tasks[taskId]?.notified = true
        }
        pruneTerminalTasksIfNeeded()
    }

    /// Validate an entire cancellation set, then apply it without actor
    /// reentrancy. This gives `task cancel` all-or-none mutation semantics with
    /// respect to invalid ids and user cancellation observed before this call.
    func killAtomically(
        _ taskIds: [String],
        sessionId: String? = nil
    ) throws -> BackgroundTaskCancellationBatch {
        var seen: Set<String> = []
        let uniqueIds = taskIds.filter { seen.insert($0).inserted }
        for id in uniqueIds {
            guard let entry = tasks[id],
                  sessionId == nil || entry.sessionId == sessionId else {
                throw BackgroundTaskError.notFound(id)
            }
        }
        let cancelledIds = uniqueIds.filter { tasks[$0]?.status.isActive == true }
        for id in cancelledIds {
            try kill(id)
        }
        return BackgroundTaskCancellationBatch(
            cancelledIds: cancelledIds,
            snapshots: uniqueIds.compactMap { id in
                tasks[id].map { snapshot(id: id, entry: $0) }
            }
        )
    }

    /// Kill every running task that matches the given session (pass `nil` to
    /// kill all tasks this manager is tracking regardless of session).
    public func killAll(sessionId: String?) {
        let ids = tasks.filter { _, entry in
            entry.status.isActive && (sessionId == nil || entry.sessionId == sessionId)
        }.map(\.key)
        for id in ids { try? kill(id) }
    }

    /// Close a logical session owned by a higher-level runtime.
    ///
    /// This is intentionally generic: the manager does not know whether the
    /// session belongs to a CLI run, a subagent, a test harness, or another
    /// caller. Closing a session cancels any still-running tasks in that
    /// session and discards queued notifications for that session, because
    /// the owner is going away and can no longer consume them.
    public func closeSession(sessionId: String) {
        sessionGenerations[sessionId, default: 0] &+= 1
        let taskIds = Set(tasks.compactMap { id, entry in
            entry.sessionId == sessionId ? id : nil
        })
        for id in taskIds where tasks[id]?.status.isActive == true {
            try? kill(id, deliverNotification: false)
        }
        pendingNotifications.removeAll { $0.sessionId == sessionId }
        deliveryQueue.removeAll { $0.sessionId == sessionId }
        for consumer in deliveryConsumers.values {
            consumer.discard(taskIds: taskIds)
        }
    }

    /// Snapshot of one task (running or terminal).
    public func get(
        _ taskId: String,
        includeOutputTail: Bool = true
    ) -> BackgroundTaskSnapshot? {
        tasks[taskId].map {
            snapshot(id: taskId, entry: $0, includeTail: includeOutputTail)
        }
    }

    /// Active ids without output-file reads. Used by poll-all so status checks
    /// stay cheap even when many tasks have large logs.
    public func activeTaskIds(sessionId: String? = nil) -> [String] {
        tasks.filter { _, entry in
            entry.status.isActive && (sessionId == nil || entry.sessionId == sessionId)
        }
        .sorted { $0.value.startedAt < $1.value.startedAt }
        .map(\.key)
    }

    /// All tasks known to the Manager, optionally filtered by session, most
    /// recent first.
    public func list(sessionId: String? = nil) -> [BackgroundTaskSnapshot] {
        tasks
            .filter { sessionId == nil || $0.value.sessionId == sessionId }
            .map { snapshot(id: $0.key, entry: $0.value) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Return a bounded page without eagerly loading every task's output tail.
    /// By default terminal history is limited to recent results while queued
    /// and running tasks are always retained in the page source.
    public func listPage(
        sessionId: String? = nil,
        includeAllTerminal: Bool = false,
        recentTerminalSeconds: Int = 600,
        offset: Int = 0,
        limit: Int = 20
    ) -> BackgroundTaskListPage {
        let cutoff = Date().addingTimeInterval(-Double(max(0, recentTerminalSeconds)))
        let matching = tasks
            .filter { _, entry in
                guard sessionId == nil || entry.sessionId == sessionId else { return false }
                return entry.status.isActive
                    || includeAllTerminal
                    || (entry.completedAt ?? .distantPast) >= cutoff
            }
            .sorted { lhs, rhs in lhs.value.startedAt > rhs.value.startedAt }
        let safeOffset = min(max(0, offset), matching.count)
        let safeLimit = max(1, min(limit, 50))
        let end = min(matching.count, safeOffset + safeLimit)
        let page = matching[safeOffset..<end].map {
            snapshot(
                id: $0.key,
                entry: $0.value,
                includeTail: true,
                maxTailBytes: 512
            )
        }
        return BackgroundTaskListPage(
            tasks: page,
            total: matching.count,
            offset: safeOffset,
            nextOffset: end < matching.count ? end : nil
        )
    }

    /// Read one bounded byte range from a manager-owned output artifact. The
    /// session check makes this safe for workspace-only agents without granting
    /// arbitrary `/tmp` file access through the general Read tool.
    public func readOutput(
        taskId: String,
        sessionId: String? = nil,
        offset: Int = 0,
        limit: Int = 8_192
    ) throws -> BackgroundTaskOutputChunk {
        guard let entry = tasks[taskId],
              sessionId == nil || entry.sessionId == sessionId else {
            throw BackgroundTaskError.notFound(taskId)
        }
        let total = max(0, Int(fileSize(entry.outputFile)))
        let safeOffset = min(max(0, offset), total)
        let safeLimit = max(1, min(limit, 32_768))
        let remaining = total - safeOffset
        let desiredCount = min(safeLimit, remaining)
        let page = utf8SafeOutputPage(
            entry.outputFile,
            offset: safeOffset,
            desiredCount: desiredCount,
            remaining: remaining
        )
        let data = page.data
        let next = safeOffset + data.count
        return BackgroundTaskOutputChunk(
            taskId: taskId,
            offset: safeOffset,
            nextOffset: next,
            totalBytes: total,
            text: page.text,
            encoding: page.encoding,
            bytesBase64: data.base64EncodedString(),
            eof: next >= total
        )
    }

    /// Return the tail of the task's output file (at most `tailBytes` bytes).
    public func readOutputTail(_ taskId: String) -> String {
        guard let entry = tasks[taskId] else { return "" }
        return readTail(entry.outputFile, maxBytes: tailBytes)
    }

    /// Drain completion/stall notifications queued since the last drain.
    public func drainNotifications(sessionId: String? = nil) -> [BackgroundTaskNotification] {
        var matched: [BackgroundTaskNotification] = []
        var remaining: [BackgroundTaskNotification] = []
        for n in pendingNotifications {
            if sessionId == nil || n.sessionId == sessionId {
                matched.append(n)
            } else {
                remaining.append(n)
            }
        }
        pendingNotifications = remaining
        return matched
    }

    public func hasNotifications(sessionId: String? = nil) -> Bool {
        pendingNotifications.contains { sessionId == nil || $0.sessionId == sessionId }
    }

    /// Atomically validate visibility and snapshot a set of tasks. Delivery
    /// ownership lives in the calling Agent's consumer mailbox, not here: the
    /// manager continues broadcasting every terminal event to public listeners.
    public func snapshots(
        taskIds: [String],
        sessionId: String? = nil,
        includeOutputTails: Bool = true
    ) throws -> [BackgroundTaskSnapshot] {
        let uniqueIds = Array(Set(taskIds))
        for id in uniqueIds {
            guard let entry = tasks[id],
                  sessionId == nil || entry.sessionId == sessionId else {
                throw BackgroundTaskError.notFound(id)
            }
        }

        return uniqueIds.compactMap { id in
            tasks[id].map {
                snapshot(id: id, entry: $0, includeTail: includeOutputTails)
            }
        }
    }

    /// Summary of currently-running tasks for the session. Intended to be
    /// called by a future context-compaction flow and appended to the
    /// compacted user/assistant summary — not injected into the system
    /// prompt. Returns an empty string when no tasks are running.
    public func runningTasksSummary(sessionId: String? = nil) -> String {
        let now = Date()
        let running = tasks
            .filter { _, entry in
                entry.status.isActive && (sessionId == nil || entry.sessionId == sessionId)
            }
            .sorted { $0.value.startedAt < $1.value.startedAt }
        if running.isEmpty { return "" }
        var out = "Currently running background tasks:\n"
        for (id, entry) in running {
            let ageSec = Int(now.timeIntervalSince(entry.startedAt))
            let label = entry.spec.description ?? entry.spec.label
            let state = entry.status == .queued ? "queued for capacity" : "running"
            out += "- [\(id)] \(label) (kind=\(entry.spec.kind), \(state) ~\(ageSec)s, output=\(entry.outputFile.path))\n"
        }
        return out
    }

    /// Remove terminal tasks whose `completedAt` is older than the cutoff,
    /// preserving artifacts still held by listener delivery or a model mailbox /
    /// explicit poll lease.
    public func cleanup(olderThanSeconds: Int) {
        let cutoff = Date().addingTimeInterval(-Double(olderThanSeconds))
        let queuedForListener = Set(deliveryQueue.map(\.taskId))
        let stale = tasks.filter { _, entry in
            entry.status.isTerminal && (entry.completedAt ?? .distantPast) < cutoff
        }.compactMap { id, _ in
            terminalTaskIsHeld(id, queuedForListener: queuedForListener) ? nil : id
        }
        for id in stale { removeTerminalTask(id) }
    }

    private func pruneTerminalTasksIfNeeded() {
        let terminal = tasks.filter { $0.value.status.isTerminal }.sorted {
            ($0.value.completedAt ?? .distantPast) > ($1.value.completedAt ?? .distantPast)
        }
        guard !terminal.isEmpty else { return }
        let retainedByCount = Set(terminal.prefix(terminalRetentionLimit).map(\.key))
        let cutoff = Date().addingTimeInterval(-Double(terminalRetentionSeconds))
        let queuedForListener = Set(deliveryQueue.map(\.taskId))

        let removable = terminal.compactMap { id, entry -> String? in
            let expired = (entry.completedAt ?? .distantPast) < cutoff
            let overLimit = !retainedByCount.contains(id)
            guard expired || overLimit else { return nil }
            guard !terminalTaskIsHeld(id, queuedForListener: queuedForListener) else { return nil }
            return id
        }
        for id in removable { removeTerminalTask(id) }
    }

    private func terminalTaskIsHeld(
        _ id: String,
        queuedForListener: Set<String>
    ) -> Bool {
        deliveringTaskId == id
            || queuedForListener.contains(id)
            || deliveryConsumers.values.contains { $0.isHolding(taskId: id) }
    }

    private func removeTerminalTask(_ id: String) {
        guard let entry = tasks[id], entry.status.isTerminal else { return }
        entry.adoptionTask?.cancel()
        entry.watchdog?.cancel()
        entry.timeoutTask?.cancel()
        if entry.ownsOutputFile {
            try? FileManager.default.removeItem(at: entry.outputFile)
        }
        tasks.removeValue(forKey: id)
        pendingNotifications.removeAll { $0.taskId == id }
        deliveryQueue.removeAll { $0.taskId == id }
        let taskIds: Set<String> = [id]
        for consumer in deliveryConsumers.values {
            consumer.discard(taskIds: taskIds)
        }
    }

    // MARK: - Subscriber pattern

    /// Subscribe to notification events. The handler fires once per
    /// enqueued notification (completion or stall). Call the returned
    /// unsubscribe closure to detach.
    public func onNotification(
        _ handler: @escaping @Sendable (BackgroundTaskNotification) async -> Void
    ) -> ListenerHandle {
        let id = UUID()
        listeners.append(Listener(id: id, handler: handler))
        let unsubscribe: @Sendable () async -> Void = { [weak self] in
            await self?.removeListener(id)
        }
        return ListenerHandle(id: id, unsubscribe: unsubscribe)
    }

    /// Register one Agent's model-facing mailbox. Public notification listeners
    /// remain independent and always receive the broadcast.
    public func registerDeliveryConsumer(
        _ consumer: BackgroundTaskDeliveryConsumer
    ) -> @Sendable () async -> Void {
        deliveryConsumers[consumer.id] = consumer
        return { [weak self, weak consumer] in
            guard let consumer else { return }
            await self?.removeDeliveryConsumer(consumer.id)
        }
    }

    /// Atomically install all of an Agent attachment's notification paths.
    ///
    /// Keeping the consumer registration, wake handler, and lifecycle listener
    /// in one actor-isolated operation removes the attach-time gap where a task
    /// could finish after the wake handler was set but before the consumer was
    /// registered (or between the consumer and lifecycle registrations).
    func registerAgentDelivery(
        _ consumer: BackgroundTaskDeliveryConsumer,
        wakeHandler: @escaping @Sendable () -> Void,
        notificationHandler: @escaping @Sendable (BackgroundTaskNotification) async -> Void
    ) -> @Sendable () async -> Void {
        let listenerId = UUID()
        deliveryConsumers[consumer.id] = consumer
        listeners.append(Listener(id: listenerId, handler: notificationHandler))
        consumer.setWakeHandler(wakeHandler)

        return { [weak self, weak consumer] in
            guard let consumer else { return }
            consumer.setWakeHandler(nil)
            await self?.removeAgentDelivery(
                consumerId: consumer.id,
                listenerId: listenerId
            )
        }
    }

    private func removeAgentDelivery(consumerId: UUID, listenerId: UUID) {
        deliveryConsumers.removeValue(forKey: consumerId)
        listeners.removeAll { $0.id == listenerId }
    }

    private func removeDeliveryConsumer(_ id: UUID) {
        deliveryConsumers.removeValue(forKey: id)
    }

    private func removeListener(_ id: UUID) {
        listeners.removeAll { $0.id == id }
    }

    // MARK: - Private: allocation + completion

    private func allocateTask(
        spec: BackgroundTaskSpec,
        sessionId: String?,
        presetOutputFile: URL? = nil,
        initialStatus: BackgroundTaskStatus = .running
    ) -> (String, URL) {
        try? FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var taskId: String
        repeat {
            taskId = "bg_\(Self.randHex(n: 8))"
        } while tasks[taskId] != nil
        let file: URL
        if let preset = presetOutputFile {
            file = preset
        } else {
            file = outputDir.appendingPathComponent("\(taskId).log")
            FileManager.default.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        tasks[taskId] = Entry(
            spec: spec,
            sessionId: sessionId,
            status: initialStatus,
            startedAt: Date(),
            runningAt: initialStatus == .running ? Date() : nil,
            completedAt: nil,
            outputFile: file,
            ownsOutputFile: presetOutputFile == nil,
            cancellation: CancellationHandle(),
            outcome: nil,
            notified: false,
            adoptionTask: nil,
            watchdog: nil,
            timeoutTask: nil,
            hardTimeoutTriggered: false,
            terminalOutputOffset: nil
        )
        return (taskId, file)
    }

    private func complete(taskId: String, outcome: BackgroundTaskOutcome) {
        guard var entry = tasks[taskId] else { return }
        // Terminal state is first-writer-wins. A killed or force-timed-out task
        // must not be resurrected, nor have its canonical outcome overwritten,
        // by a runner that calls onDone late.
        guard entry.status.isActive else { return }
        let deadlineElapsed = entry.status == .running
            && entry.spec.hardTimeoutSeconds > 0
            && Date().timeIntervalSince(entry.runningAt ?? entry.startedAt)
                >= Double(entry.spec.hardTimeoutSeconds)
        let terminalOutcome = (entry.hardTimeoutTriggered || deadlineElapsed)
            ? hardTimeoutOutcome(for: entry)
            : outcome
        entry.completedAt = Date()
        entry.outcome = terminalOutcome
        entry.status = terminalOutcome.success ? .completed : .failed
        entry.watchdog?.cancel()
        entry.timeoutTask?.cancel()
        if entry.spec.kind == "agent" {
            entry.terminalOutputOffset = locateTerminalOutputOffset(entry.outputFile)
        }
        tasks[taskId] = entry

        if !entry.notified {
            enqueueNotification(
                taskId: taskId,
                status: entry.status,
                outcome: terminalOutcome,
                stalled: false
            )
            tasks[taskId]?.notified = true
        }
        pruneTerminalTasksIfNeeded()
    }

    private func enqueueNotification(
        taskId: String,
        status: BackgroundTaskStatus,
        outcome: BackgroundTaskOutcome?,
        stalled: Bool
    ) {
        guard let entry = tasks[taskId] else { return }
        let notification = makeNotification(
            taskId: taskId,
            entry: entry,
            status: status,
            outcome: outcome,
            stalled: stalled
        )
        for consumer in deliveryConsumers.values where consumer.accepts(notification) {
            consumer.enqueue(notification)
        }
        pendingNotifications.append(notification)
        deliveryQueue.append(notification)
        kickDeliveryLoop()
    }

    private func makeNotification(
        taskId: String,
        entry: Entry,
        status: BackgroundTaskStatus,
        outcome: BackgroundTaskOutcome?,
        stalled: Bool
    ) -> BackgroundTaskNotification {
        let preview = outputPreview(
            entry.outputFile,
            maxBytes: tailBytes,
            terminalOffset: entry.status.isTerminal ? entry.terminalOutputOffset : nil
        )
        let durationMs = Int((entry.completedAt ?? Date()).timeIntervalSince(entry.startedAt) * 1000)
        return BackgroundTaskNotification(
            taskId: taskId,
            sessionId: entry.sessionId,
            kind: entry.spec.kind,
            label: entry.spec.label,
            description: entry.spec.description,
            status: status,
            outcome: outcome,
            outputTail: preview.text,
            outputTruncated: preview.truncated,
            outputFile: entry.outputFile.path,
            durationMs: durationMs,
            stalled: stalled
        )
    }

    /// Start the serial delivery loop if it isn't already running. The
    /// loop runs on the actor, so it's implicitly single-threaded; we
    /// only need to guard against spawning a second one while the first
    /// is still draining.
    private func kickDeliveryLoop() {
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            await self?.drainDeliveryQueue()
        }
    }

    private func drainDeliveryQueue() async {
        while !deliveryQueue.isEmpty {
            let next = deliveryQueue.removeFirst()
            deliveringTaskId = next.taskId
            // Snapshot per-item so a listener added/removed during the
            // await doesn't retroactively apply to an already-queued
            // notification.
            let snapshot = listeners
            for listener in snapshot {
                await listener.handler(next)
            }
            deliveringTaskId = nil
        }
        deliveryTask = nil
    }

    // MARK: - Hard timeout

    private func scheduleHardTimeout(taskId: String, seconds: Int) {
        guard seconds > 0 else { return }
        let graceSeconds = hardTimeoutGraceSeconds
        let task = Task.detached { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            } catch {
                return
            }
            guard await self?.beginHardTimeout(taskId: taskId) == true else { return }

            if graceSeconds > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(graceSeconds * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
            await self?.forceHardTimeout(taskId: taskId)
        }
        tasks[taskId]?.timeoutTask = task
    }

    private func beginHardTimeout(taskId: String) -> Bool {
        guard var entry = tasks[taskId], entry.status == .running else { return false }
        entry.hardTimeoutTriggered = true
        tasks[taskId] = entry
        entry.cancellation.cancel(reason: "hard-timeout")
        entry.adoptionTask?.cancel()
        return true
    }

    private func forceHardTimeout(taskId: String) {
        guard let entry = tasks[taskId],
              entry.status == .running,
              entry.hardTimeoutTriggered else { return }
        complete(taskId: taskId, outcome: hardTimeoutOutcome(for: entry))
    }

    private func hardTimeoutOutcome(for entry: Entry) -> BackgroundTaskOutcome {
        let seconds = entry.spec.hardTimeoutSeconds
        return BackgroundTaskOutcome(
            success: false,
            summary: "timed out",
            details: terminalDetails(
                for: entry,
                adding: [
                    "failure_kind": .string("timeout"),
                    "reason": .string("hard_timeout"),
                    "timeout_seconds": .int(seconds),
                ]
            ),
            errorMessage: "Background task exceeded hard timeout of \(seconds) seconds"
        )
    }

    private func terminalDetails(
        for entry: Entry,
        adding values: [String: JSONValue]
    ) -> JSONValue {
        var merged: [String: JSONValue]
        if case .object(let metadata) = entry.spec.metadata ?? .null {
            merged = metadata
        } else {
            merged = [:]
        }
        for (key, value) in values { merged[key] = value }
        return .object(merged)
    }

    // MARK: - Stall watchdog

    private static let promptPatterns: [NSRegularExpression] = {
        let raws = [
            "\\(y/n\\)",
            "\\[y/n\\]",
            "\\(yes/no\\)",
            "password\\s*:",
            "passphrase\\s*:",
            "(Do you|Would you|Shall I|Are you sure|Ready to)\\b.*\\?\\s*$",
            "Press\\s+(any key|Enter|return)",
            "Continue\\?",
            "Overwrite\\?",
            "Proceed\\?",
        ]
        return raws.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func looksLikePrompt(_ tail: String) -> Bool {
        let trimmed = tail.trimmingCharacters(in: .whitespaces)
        let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? ""
        let range = NSRange(lastLine.startIndex..., in: lastLine)
        return promptPatterns.contains { regex in
            regex.firstMatch(in: lastLine, options: [], range: range) != nil
        }
    }

    private func launchWatchdog(taskId: String) {
        let interval = stallCheckIntervalSeconds
        let threshold = stallThresholdSeconds
        let task = Task.detached { [weak self] in
            var lastSize: Int64 = 0
            var lastGrowth = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard let self else { return }
                let done = await self.stallTick(
                    taskId: taskId,
                    lastSize: &lastSize,
                    lastGrowth: &lastGrowth,
                    thresholdSeconds: threshold
                )
                if done { return }
            }
        }
        tasks[taskId]?.watchdog = task
    }

    private func stallTick(
        taskId: String,
        lastSize: inout Int64,
        lastGrowth: inout Date,
        thresholdSeconds: Double
    ) -> Bool {
        guard let entry = tasks[taskId] else { return true }
        if entry.status != .running { return true }
        if entry.notified { return true }

        let size = fileSize(entry.outputFile)
        if size > lastSize {
            lastSize = size
            lastGrowth = Date()
            return false
        }
        let age = Date().timeIntervalSince(lastGrowth)
        if age < thresholdSeconds { return false }

        let tail = readTail(entry.outputFile, maxBytes: min(1024, tailBytes))
        if !Self.looksLikePrompt(tail) {
            // Reset so we don't re-tail every tick.
            lastGrowth = Date()
            return false
        }
        enqueueNotification(
            taskId: taskId,
            status: .running,
            outcome: nil,
            stalled: true
        )
        // A stall is a heads-up, not a terminal event: deliberately do NOT set
        // `notified`, so the eventual completion/kill notification still fires.
        // Returning true ends the watchdog, so exactly one stall is emitted.
        return true
    }

    // MARK: - File helpers

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    private func readTail(_ url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size == 0 { return "" }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(size - start)) ?? Data()
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private func readBytes(_ url: URL, offset: Int, count: Int) -> Data {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return Data()
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return Data()
        }
    }

    private func utf8SafeOutputPage(
        _ url: URL,
        offset: Int,
        desiredCount: Int,
        remaining: Int
    ) -> (
        data: Data,
        text: String,
        encoding: BackgroundTaskOutputChunk.Encoding
    ) {
        guard desiredCount > 0 else { return (Data(), "", .utf8) }

        // UTF-8 scalars are at most four bytes. Read a three-byte lookahead so
        // even `limit: 1` can return one complete emoji instead of making no
        // progress. We otherwise prefer the largest valid prefix at or below the
        // requested limit, preserving the caller's byte-budget expectation.
        let candidateCount = min(remaining, desiredCount + 3)
        let candidate = readBytes(url, offset: offset, count: candidateCount)
        let requestedEnd = min(desiredCount, candidate.count)

        if requestedEnd > 0 {
            for count in stride(from: requestedEnd, through: 1, by: -1) {
                let bytes = Data(candidate.prefix(count))
                if let text = String(data: bytes, encoding: .utf8) {
                    return (bytes, text, .utf8)
                }
            }
        }

        if candidate.count > requestedEnd {
            for count in (requestedEnd + 1)...candidate.count {
                let bytes = Data(candidate.prefix(count))
                if let text = String(data: bytes, encoding: .utf8) {
                    return (bytes, text, .utf8)
                }
            }
        }

        // Invalid UTF-8 or an explicitly unaligned byte offset cannot be made
        // lossless as a Swift String. Return the exact requested bytes as base64;
        // callers can reconstruct the artifact page-for-page without U+FFFD.
        let bytes = Data(candidate.prefix(requestedEnd))
        let base64 = bytes.base64EncodedString()
        return (bytes, base64, .base64)
    }

    /// Locate the first runner-owned terminal section at a line boundary. The
    /// result is cached on the task entry, so later previews never re-interpret
    /// marker-looking text inside the final payload. Scanning is chunked to keep
    /// memory bounded for large child logs.
    private func locateTerminalOutputOffset(_ url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let patterns = [
            Data("[final]\n".utf8),
            Data("[incomplete]\n".utf8),
            Data("[error]\n".utf8),
        ]
        let carryCount = patterns.map(\.count).max() ?? 0
        var carry = Data()
        var consumed = 0

        while let chunk = try? handle.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            var combined = Data()
            combined.reserveCapacity(carry.count + chunk.count)
            combined.append(carry)
            combined.append(chunk)
            let baseOffset = consumed - carry.count
            var earliest: Int?

            for pattern in patterns {
                var lowerBound = combined.startIndex
                while lowerBound < combined.endIndex,
                      let range = combined.range(
                          of: pattern,
                          options: [],
                          in: lowerBound..<combined.endIndex
                      ) {
                    let localOffset = combined.distance(
                        from: combined.startIndex,
                        to: range.lowerBound
                    )
                    let absoluteOffset = baseOffset + localOffset
                    let beginsLine: Bool
                    if absoluteOffset == 0 {
                        beginsLine = true
                    } else if range.lowerBound > combined.startIndex {
                        beginsLine = combined[combined.index(before: range.lowerBound)] == 0x0A
                    } else {
                        // A marker beginning at carry index zero was wholly
                        // inspected in the preceding iteration.
                        beginsLine = false
                    }
                    if beginsLine {
                        earliest = min(earliest ?? absoluteOffset, absoluteOffset)
                        break
                    }
                    lowerBound = combined.index(after: range.lowerBound)
                }
            }
            if let earliest { return earliest }

            consumed += chunk.count
            carry = Data(combined.suffix(carryCount))
        }
        return nil
    }

    private func outputPreview(
        _ url: URL,
        maxBytes: Int,
        terminalOffset: Int?
    ) -> (text: String, truncated: Bool) {
        let total = max(0, Int(fileSize(url)))
        guard total > 0 else { return ("", false) }
        let limit = max(1, maxBytes)

        if let terminalOffset,
           terminalOffset >= 0,
           terminalOffset < total {
            let available = total - terminalOffset
            let data = readBytes(
                url,
                offset: terminalOffset,
                count: min(limit, available)
            )
            return (
                String(decoding: data, as: UTF8.self),
                available > data.count
            )
        }

        let count = min(total, limit)
        let data = readBytes(url, offset: total - count, count: count)
        return (String(decoding: data, as: UTF8.self), total > data.count)
    }

    private func snapshot(
        id: String,
        entry: Entry,
        includeTail: Bool = true,
        maxTailBytes: Int? = nil
    ) -> BackgroundTaskSnapshot {
        let preview = includeTail
            ? outputPreview(
                entry.outputFile,
                maxBytes: maxTailBytes ?? tailBytes,
                terminalOffset: entry.status.isTerminal ? entry.terminalOutputOffset : nil
            )
            : (text: "", truncated: false)
        return BackgroundTaskSnapshot(
            id: id,
            sessionId: entry.sessionId,
            spec: entry.spec,
            status: entry.status,
            startedAt: entry.startedAt,
            runningAt: entry.runningAt,
            completedAt: entry.completedAt,
            outputFile: entry.outputFile.path,
            outputTail: preview.text,
            outputSizeBytes: max(0, Int(fileSize(entry.outputFile))),
            outputTailTruncated: preview.truncated,
            outcome: entry.outcome
        )
    }

    static func randHex(n: Int) -> String {
        var out = ""
        for _ in 0..<n {
            let byte = UInt8.random(in: 0..<16)
            out += String(byte, radix: 16)
        }
        return out
    }
}

struct BackgroundTaskCancellationBatch: Sendable {
    let cancelledIds: [String]
    let snapshots: [BackgroundTaskSnapshot]
}

/// One Agent's model-facing background-result mailbox.
///
/// `BackgroundTaskManager` still broadcasts every notification to its public
/// listeners. This mailbox only coordinates the choice between two delivery
/// paths for one Agent: automatic runtime aside, or an explicitly retained
/// `task` tool result. A poll temporarily watches task ids; terminal notices are
/// held until the paired tool result is committed, and are restored if that
/// result is rewound (notably Cursor inline-exec retry/abort).
public final class BackgroundTaskDeliveryConsumer: @unchecked Sendable {
    let id = UUID()
    public let sessionId: String?

    private let lock = NSLock()
    private var pending: [BackgroundTaskNotification] = []
    private var deferredTerminal: [String: BackgroundTaskNotification] = [:]
    private var watchCounts: [String: Int] = [:]
    private var deliveredTerminalTaskIds: Set<String> = []
    private var wakeHandler: (@Sendable () -> Void)?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }

    func accepts(_ notification: BackgroundTaskNotification) -> Bool {
        sessionId == nil || notification.sessionId == sessionId
    }

    func setWakeHandler(_ handler: (@Sendable () -> Void)?) {
        let shouldWake = lock.withLock { () -> Bool in
            wakeHandler = handler
            return handler != nil && !pending.isEmpty
        }
        if shouldWake { handler?() }
    }

    func enqueue(_ notification: BackgroundTaskNotification) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            if isTerminal(notification), (watchCounts[notification.taskId] ?? 0) > 0 {
                deferredTerminal[notification.taskId] = notification
                return nil
            }
            pending.append(notification)
            return wakeHandler
        }
        handler?()
    }

    /// Begin an explicit-delivery transaction. Any terminal notice still in
    /// this mailbox is atomically retracted before the caller re-reads task
    /// state, closing completion-vs-poll races at the Agent boundary.
    func beginWatching(taskIds: [String]) -> Set<String> {
        let ids = Set(taskIds)
        return lock.withLock {
            for id in ids { watchCounts[id, default: 0] += 1 }

            var retained: [BackgroundTaskNotification] = []
            retained.reserveCapacity(pending.count)
            for notification in pending {
                if ids.contains(notification.taskId), isTerminal(notification) {
                    deferredTerminal[notification.taskId] = notification
                } else {
                    retained.append(notification)
                }
            }
            pending = retained
            return ids.intersection(deliveredTerminalTaskIds)
        }
    }

    /// Stop watching and return a lease for terminal results represented by the
    /// tool output. Running tasks immediately resume normal automatic delivery.
    func finishWatching(
        taskIds: [String],
        terminalTaskIds: Set<String>
    ) -> AgentToolRetentionLease? {
        let ids = Set(taskIds)
        var heldTerminalIds: Set<String> = []
        var handler: (@Sendable () -> Void)?

        lock.withLock {
            heldTerminalIds = terminalTaskIds.subtracting(deliveredTerminalTaskIds)
            for id in ids {
                let remaining = max(0, (watchCounts[id] ?? 0) - 1)
                if remaining == 0 {
                    watchCounts.removeValue(forKey: id)
                } else {
                    watchCounts[id] = remaining
                }

                // If the final manager snapshot missed a completion that raced
                // immediately after it, this task is not represented by the
                // tool result. Put its deferred notification back.
                if !heldTerminalIds.contains(id), remaining == 0,
                   let notification = deferredTerminal.removeValue(forKey: id) {
                    pending.append(notification)
                    handler = wakeHandler
                }
            }
        }
        handler?()

        guard !heldTerminalIds.isEmpty else { return nil }
        let leaseTaskIds = heldTerminalIds
        return AgentToolRetentionLease(
            onCommit: { [weak self] in self?.commit(taskIds: leaseTaskIds) },
            onRollback: { [weak self] in self?.rollback(taskIds: leaseTaskIds) }
        )
    }

    func drainMessages() -> [Message] {
        let notifications = lock.withLock { () -> [BackgroundTaskNotification] in
            let drained = pending
            pending.removeAll()
            for notification in drained where isTerminal(notification) {
                deliveredTerminalTaskIds.insert(notification.taskId)
            }
            return drained
        }
        return notifications.map { notification in
            .user(UserMessage(
                content: [.text(TextContent(text: notification.messageText()))],
                source: .runtime
            ))
        }
    }

    func hasPendingMessages() -> Bool {
        lock.withLock { !pending.isEmpty }
    }

    /// True while deleting the manager artifact could invalidate an automatic
    /// aside or explicit poll lease which has not settled yet.
    func isHolding(taskId: String) -> Bool {
        lock.withLock {
            pending.contains { $0.taskId == taskId }
                || deferredTerminal[taskId] != nil
                || (watchCounts[taskId] ?? 0) > 0
        }
    }

    func clearPendingMessages() {
        lock.withLock { pending.removeAll() }
    }

    /// Detaching an Agent must not leave terminal notices permanently held by
    /// an abandoned poll. Restore everything to the mailbox; a later reattach
    /// of the same consumer can deliver it, while public listeners were never
    /// affected in the first place.
    func releaseAllWatches() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            watchCounts.removeAll()
            guard !deferredTerminal.isEmpty else { return nil }
            pending.append(contentsOf: deferredTerminal.values)
            deferredTerminal.removeAll()
            return wakeHandler
        }
        handler?()
    }

    private func commit(taskIds: Set<String>) {
        lock.withLock {
            // A terminal poll result supersedes every older notice for the
            // represented task, including a stall warning that may have been
            // queued just before completion.
            pending.removeAll { taskIds.contains($0.taskId) }
            for id in taskIds {
                deferredTerminal.removeValue(forKey: id)
                deliveredTerminalTaskIds.insert(id)
            }
        }
    }

    private func rollback(taskIds: Set<String>) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            var restored = false
            for id in taskIds where (watchCounts[id] ?? 0) == 0 {
                if let notification = deferredTerminal.removeValue(forKey: id) {
                    pending.append(notification)
                    restored = true
                }
            }
            return restored ? wakeHandler : nil
        }
        handler?()
    }

    /// Purge all mailbox bookkeeping for tasks removed from the manager.
    /// Cleanup is an explicit destructive boundary, so an outstanding lease
    /// for one of these ids must not resurrect its obsolete notification.
    func discard(taskIds: Set<String>) {
        lock.withLock {
            pending.removeAll { taskIds.contains($0.taskId) }
            for id in taskIds {
                deferredTerminal.removeValue(forKey: id)
                watchCounts.removeValue(forKey: id)
                deliveredTerminalTaskIds.remove(id)
            }
        }
    }

    private func isTerminal(_ notification: BackgroundTaskNotification) -> Bool {
        !notification.stalled && notification.status.isTerminal
    }
}

public enum BackgroundTaskError: Error, Equatable, LocalizedError {
    case notFound(String)
    case alreadyTerminal(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "background task \(id) not found"
        case .alreadyTerminal(let id): return "background task \(id) is already in a terminal state"
        }
    }
}
