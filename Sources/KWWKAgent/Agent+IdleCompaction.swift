import Foundation
import KWWKAI

extension Agent {
    /// Restart the idle countdown. The agent calls this itself whenever it
    /// becomes idle; hosts call it for activity the agent cannot see (typing,
    /// navigating a dialog) so a session in active use is never compacted
    /// under the user. Cheap enough to call per keystroke. No-op while
    /// `idleCompact` is nil.
    public func noteIdleActivity() {
        guard let options = idleCompact, options.delay.isFinite else { return }
        idleCompactionTimer.arm(after: max(0, options.delay)) { [weak self] in
            await self?.runScheduledIdleCompaction()
        }
    }

    /// Timer entry point. Ending the compaction's own maintenance window
    /// re-arms the countdown, so a failed summary would otherwise be retried
    /// (and billed) every `delay` for as long as the session sits untouched.
    /// One attempt per transcript revision is enough.
    private func runScheduledIdleCompaction() async {
        let revision = state.snapshotModelContext().revision
        guard idleCompactionTimer.lastAttemptedRevision != revision else { return }
        guard await compactIfIdle() != nil else { return }
        idleCompactionTimer.lastAttemptedRevision = state.snapshotModelContext().revision
    }

    /// Run one idle compaction now if every idle condition holds, without
    /// waiting for the delay. Returns nil when skipped — idle compaction is
    /// off, the context is below the threshold, work is queued or running, or
    /// the host vetoed it — and the compaction outcome otherwise.
    @discardableResult
    public func compactIfIdle() async -> AgentContextCompactionOutcome? {
        guard let options = idleCompact,
              !state.isStreaming,
              !hasQueuedMessages(),
              isAboveIdleThreshold(options) else { return nil }

        let autoCompact = autoCompact
        let backgroundManager = autoCompact?.backgroundManager
        // Waiting on a background task is not idle: its completion is about to
        // continue this conversation and should find the context it left.
        if let backgroundManager, let sessionId, !sessionId.isEmpty,
           !(await backgroundManager.activeTaskIds(sessionId: sessionId)).isEmpty {
            return nil
        }
        if let canCompact = options.canCompact, !(await canCompact()) { return nil }

        let outcome: AgentContextCompactionOutcome?
        do {
            outcome = try await withMaintenance { [self] cancellation in
                // The awaits above may have let a run append or a prompt queue.
                guard !hasQueuedMessages(), isAboveIdleThreshold(options) else {
                    return nil as AgentContextCompactionOutcome?
                }
                let snapshot = state.snapshotModelContext()
                await emitIdleCompaction(.compactStart(
                    messagesCount: snapshot.context.messages.count,
                    usage: AgentContextCompactor.currentUsage(
                        context: snapshot.context,
                        model: snapshot.model
                    )
                ), cancellation: cancellation)
                let outcome = await AgentContextCompactor.compactAgent(
                    agent: self,
                    backgroundManager: backgroundManager,
                    sessionId: sessionId,
                    config: autoCompact?.config ?? .init(),
                    // Maintenance ownership is the authoritative busy guard.
                    ignoreStreaming: true,
                    cancellation: cancellation
                )
                // Listeners persist and render the replacement here, still
                // under maintenance ownership, before any queued turn appends.
                await emitIdleCompaction(.compactEnd(outcome: outcome), cancellation: cancellation)
                return outcome
            }
        } catch {
            // A run or another maintenance owner won the race; not idle.
            return nil
        }
        // Prompts steered in while maintenance was held have no idle waiter.
        resumeQueuedWork()
        return outcome
    }

    private func isAboveIdleThreshold(_ options: AgentIdleCompactOptions) -> Bool {
        let snapshot = state.snapshotModelContext()
        guard snapshot.context.messages.count >= agentCompactMinMessages else { return false }
        return options.threshold.isReached(by: AgentContextCompactor.currentUsage(
            context: snapshot.context,
            model: snapshot.model
        ))
    }
}

/// One re-armable deadline. `arm` only moves the deadline while a timer task
/// is already sleeping, so per-keystroke activity costs a lock, not a Task.
/// The action runs at most once per arm, after the deadline has passed with
/// no further `arm` or `cancel`.
final class IdleCompactionTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: TimeInterval?
    private var action: (@Sendable () async -> Void)?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var _lastAttemptedRevision: UInt64?

    /// Transcript revision left behind by the last scheduled attempt.
    var lastAttemptedRevision: UInt64? {
        get { lock.withLock { _lastAttemptedRevision } }
        set { lock.withLock { _lastAttemptedRevision = newValue } }
    }

    func arm(after delay: TimeInterval, action: @escaping @Sendable () async -> Void) {
        lock.withLock {
            deadline = ProcessInfo.processInfo.systemUptime + delay
            self.action = action
            guard task == nil else { return }
            generation &+= 1
            let generation = generation
            task = Task { [weak self] in await self?.run(generation) }
        }
    }

    func cancel() {
        lock.withLock {
            deadline = nil
            action = nil
            generation &+= 1
            task?.cancel()
            task = nil
        }
    }

    var isArmed: Bool { lock.withLock { deadline != nil } }

    private enum Step {
        case stop
        case sleep(TimeInterval)
        case fire(@Sendable () async -> Void)
    }

    private func run(_ generation: UInt64) async {
        while true {
            let step: Step = lock.withLock {
                guard self.generation == generation, let deadline, let action else { return .stop }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { return .sleep(remaining) }
                // Release the slot before firing so activity during the
                // (long) action arms a fresh countdown instead of being lost.
                self.deadline = nil
                self.action = nil
                self.task = nil
                return .fire(action)
            }
            switch step {
            case .stop:
                return
            case .sleep(let seconds):
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            case .fire(let action):
                await action()
                return
            }
        }
    }
}
