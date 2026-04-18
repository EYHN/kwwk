import Foundation
import KWWKAI

/// Process-scoped manager for background tasks. Owns task registry + the
/// pending-notification queue + an optional stall watchdog. Runners plug in
/// via `BackgroundTaskRunner`; the Manager itself is kind-agnostic.
///
/// Typical flow:
///
///   let manager = BackgroundTaskManager()
///   let (taskId, outputFile) = await manager.spawn(
///       runner: BashBackgroundRunner(command: "npm install"),
///       sessionId: "sess-1"
///   )
///   // … later, agent receives a `<task-notification>` user message when
///   // the task completes.
///
/// Cross-cutting guarantees:
///   - Task IDs are unique within a Manager instance.
///   - Each task gets a distinct `outputFile` under `outputDir`.
///   - Exactly one notification is enqueued per task (either completion or
///     stall — whichever fires first wins; the other is suppressed).
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
        var completedAt: Date?
        var outputFile: URL
        var cancellation: CancellationHandle
        var outcome: BackgroundTaskOutcome?
        var notified: Bool
        /// When the task was adopted via `adopt`, its external `waitForCompletion`
        /// is tracked here so `kill` can cancel it.
        var adoptionTask: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private struct Listener: @unchecked Sendable {
        let id: UUID
        let handler: @Sendable (BackgroundTaskNotification) async -> Void
    }

    private var tasks: [String: Entry] = [:]
    private var pendingNotifications: [BackgroundTaskNotification] = []
    private var listeners: [Listener] = []

    public let outputDir: URL

    // Tunables (exposed for tests; clamp reasonable defaults)
    public var stallCheckIntervalSeconds: UInt64 = 5
    public var stallThresholdSeconds: Double = 45
    public var tailBytes: Int = 4096

    // MARK: - Init

    public init(outputDir: URL? = nil) {
        if let dir = outputDir {
            self.outputDir = dir
        } else {
            // `/tmp/kwwk-bg-<pid>`. Rationale:
            //   - `/tmp` so these per-session scratch files don't end up in
            //     the user's home backup / iCloud sync.
            //   - `-<pid>` so concurrent `kwwk` processes don't interleave
            //     output files in the same directory (would race on
            //     `fg_<uuid>.log` allocation and make `list(taskId:)`
            //     ambiguous across sessions).
            //   - Foreground adopt path reuses this directory too
            //     (see `allocateForegroundOutputFile` in BashTool.swift),
            //     so both bg spawns and fg-flipped commands land here.
            let pid = ProcessInfo.processInfo.processIdentifier
            self.outputDir = URL(
                fileURLWithPath: "/tmp/kwwk-bg-\(pid)",
                isDirectory: true
            )
        }
    }

    // MARK: - Spawn / adopt

    /// Start a new background task. Returns the allocated task id and output
    /// file path. The task starts executing immediately; the caller does not
    /// wait for completion.
    public func spawn(
        runner: BackgroundTaskRunner,
        sessionId: String? = nil
    ) -> (taskId: String, outputFile: URL) {
        let spec = runner.spec
        let (taskId, outputFile) = allocateTask(spec: spec, sessionId: sessionId)
        let cancellation = tasks[taskId]!.cancellation
        scheduleHardTimeout(taskId: taskId, seconds: spec.hardTimeoutSeconds)
        launchWatchdog(taskId: taskId)

        // Hand off to the runner. Runner drives `onDone`.
        let onDone: @Sendable (BackgroundTaskOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            Task { await self.complete(taskId: taskId, outcome: outcome) }
        }
        runner.run(
            taskId: taskId,
            outputFile: outputFile,
            cancellation: cancellation,
            onDone: onDone
        )
        return (taskId, outputFile)
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
        let (taskId, file) = allocateTask(
            spec: spec,
            sessionId: sessionId,
            presetOutputFile: outputFile
        )
        let cancellation = tasks[taskId]!.cancellation
        scheduleHardTimeout(taskId: taskId, seconds: spec.hardTimeoutSeconds)
        launchWatchdog(taskId: taskId)

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
        guard var entry = tasks[taskId] else {
            throw BackgroundTaskError.notFound(taskId)
        }
        if entry.status != .running { return }
        entry.status = .killed
        entry.completedAt = Date()
        tasks[taskId] = entry
        entry.cancellation.cancel(reason: "killed")
        entry.watchdog?.cancel()
        entry.timeoutTask?.cancel()

        // Fire a killed notification so the model knows, unless the runner
        // already enqueued one (via complete()).
        if !entry.notified {
            let outcome = BackgroundTaskOutcome(
                success: false,
                summary: "killed",
                details: nil,
                errorMessage: nil
            )
            enqueueNotification(
                taskId: taskId,
                status: .killed,
                outcome: outcome,
                stalled: false
            )
            tasks[taskId]?.notified = true
        }
    }

    /// Kill every running task that matches the given session (pass `nil` to
    /// kill all tasks this manager is tracking regardless of session).
    public func killAll(sessionId: String?) {
        let ids = tasks.filter { _, entry in
            entry.status == .running && (sessionId == nil || entry.sessionId == sessionId)
        }.map(\.key)
        for id in ids { try? kill(id) }
    }

    /// Snapshot of one task (running or terminal).
    public func get(_ taskId: String) -> BackgroundTaskSnapshot? {
        tasks[taskId].map { snapshot(id: taskId, entry: $0) }
    }

    /// All tasks known to the Manager, optionally filtered by session, most
    /// recent first.
    public func list(sessionId: String? = nil) -> [BackgroundTaskSnapshot] {
        tasks
            .filter { sessionId == nil || $0.value.sessionId == sessionId }
            .map { snapshot(id: $0.key, entry: $0.value) }
            .sorted { $0.startedAt > $1.startedAt }
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

    /// Summary of currently-running tasks for the session. Intended to be
    /// called by a future context-compaction flow and appended to the
    /// compacted user/assistant summary — not injected into the system
    /// prompt. Returns an empty string when no tasks are running.
    public func runningTasksSummary(sessionId: String? = nil) -> String {
        let now = Date()
        let running = tasks
            .filter { _, entry in
                entry.status == .running && (sessionId == nil || entry.sessionId == sessionId)
            }
            .sorted { $0.value.startedAt < $1.value.startedAt }
        if running.isEmpty { return "" }
        var out = "Currently running background tasks:\n"
        for (id, entry) in running {
            let ageSec = Int(now.timeIntervalSince(entry.startedAt))
            let label = entry.spec.description ?? entry.spec.label
            out += "- [\(id)] \(label) (kind=\(entry.spec.kind), running ~\(ageSec)s, output=\(entry.outputFile.path))\n"
        }
        return out
    }

    /// Remove terminal tasks whose `completedAt` is older than the cutoff.
    public func cleanup(olderThanSeconds: Int) {
        let cutoff = Date().addingTimeInterval(-Double(olderThanSeconds))
        let stale = tasks.filter { _, entry in
            entry.status != .running && (entry.completedAt ?? .distantPast) < cutoff
        }.map(\.key)
        for id in stale {
            tasks[id]?.adoptionTask?.cancel()
            tasks[id]?.watchdog?.cancel()
            tasks[id]?.timeoutTask?.cancel()
            tasks.removeValue(forKey: id)
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

    private func removeListener(_ id: UUID) {
        listeners.removeAll { $0.id == id }
    }

    // MARK: - Private: allocation + completion

    private func allocateTask(
        spec: BackgroundTaskSpec,
        sessionId: String?,
        presetOutputFile: URL? = nil
    ) -> (String, URL) {
        try? FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
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
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        tasks[taskId] = Entry(
            spec: spec,
            sessionId: sessionId,
            status: .running,
            startedAt: Date(),
            completedAt: nil,
            outputFile: file,
            cancellation: CancellationHandle(),
            outcome: nil,
            notified: false,
            adoptionTask: nil,
            watchdog: nil,
            timeoutTask: nil
        )
        return (taskId, file)
    }

    private func complete(taskId: String, outcome: BackgroundTaskOutcome) {
        guard var entry = tasks[taskId] else { return }
        // If the task was killed, absorb the outcome but keep the killed
        // status — the kill already fired (or will fire) its own notification.
        if entry.status == .killed {
            entry.outcome = outcome
            entry.completedAt = Date()
            entry.watchdog?.cancel()
            entry.timeoutTask?.cancel()
            tasks[taskId] = entry
            return
        }
        entry.completedAt = Date()
        entry.outcome = outcome
        entry.status = outcome.success ? .completed : .failed
        entry.watchdog?.cancel()
        entry.timeoutTask?.cancel()
        tasks[taskId] = entry

        if !entry.notified {
            enqueueNotification(
                taskId: taskId,
                status: entry.status,
                outcome: outcome,
                stalled: false
            )
            tasks[taskId]?.notified = true
        }
    }

    private func enqueueNotification(
        taskId: String,
        status: BackgroundTaskStatus,
        outcome: BackgroundTaskOutcome?,
        stalled: Bool
    ) {
        guard let entry = tasks[taskId] else { return }
        let tail = readTail(entry.outputFile, maxBytes: tailBytes)
        let durationMs = Int((entry.completedAt ?? Date()).timeIntervalSince(entry.startedAt) * 1000)
        let notification = BackgroundTaskNotification(
            taskId: taskId,
            sessionId: entry.sessionId,
            kind: entry.spec.kind,
            label: entry.spec.label,
            description: entry.spec.description,
            status: status,
            outcome: outcome,
            outputTail: tail,
            outputFile: entry.outputFile.path,
            durationMs: durationMs,
            stalled: stalled
        )
        pendingNotifications.append(notification)
        let snapshotListeners = listeners
        Task { [notification] in
            for listener in snapshotListeners {
                await listener.handler(notification)
            }
        }
    }

    // MARK: - Hard timeout

    private func scheduleHardTimeout(taskId: String, seconds: Int) {
        guard seconds > 0 else { return }
        let task = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            await self?.onHardTimeout(taskId: taskId)
        }
        tasks[taskId]?.timeoutTask = task
    }

    private func onHardTimeout(taskId: String) {
        guard let entry = tasks[taskId], entry.status == .running else { return }
        entry.cancellation.cancel(reason: "hard-timeout")
        // Runner is expected to call onDone shortly after cancellation. If it
        // doesn't, the task stays in `running` — callers can still `kill`.
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
        tasks[taskId]?.notified = true
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

    private func snapshot(id: String, entry: Entry) -> BackgroundTaskSnapshot {
        BackgroundTaskSnapshot(
            id: id,
            sessionId: entry.sessionId,
            spec: entry.spec,
            status: entry.status,
            startedAt: entry.startedAt,
            completedAt: entry.completedAt,
            outputFile: entry.outputFile.path,
            outputTail: readTail(entry.outputFile, maxBytes: tailBytes),
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
