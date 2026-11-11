import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// Bridges a live `Agent` to a `SessionStore`: subscribes to the agent's
/// event stream and appends newly-produced transcript messages to the
/// session's JSONL log as they land, so a crashed or aborted run still
/// leaves a resumable transcript on disk.
///
/// Event recording is additive — attach the recorder to any agent and detach
/// when done. It persists on every message-bearing event
/// (`messageEnd`, `turnEnd`, `agentEnd`) by diffing the agent's current
/// transcript against the count already written, then appending only the new
/// tail. That keeps ordinary writes append-only even when the loop produces
/// several messages between events. Compaction is persisted as its own marker
/// and resets the live-message baseline to the compacted context. Explicit
/// `/shake` rewrites share the same serialized persistence queue, so a rewrite
/// can never overtake a pending message or compaction write.
public final class SessionRecorder: Sendable {
    private struct PendingCompaction: Sendable {
        let replacementMessages: [Message]
        let messagesCompacted: Int
        let firstKeptMessageIndex: Int?
        let tokensBefore: Int?
        let contextWindow: Int?
        let reason: SessionStore.CompactionReason
        let usage: Usage?
    }

    private enum TranscriptRewrite: Sendable {
        case shakeToolOutputs(keepingUnder: Int)
        case removeImages

        func apply(to messages: [Message]) -> SessionStore.MessageRewrite {
            switch self {
            case .shakeToolOutputs(let limit):
                let rewrite = AgentContextCompactor.shakeToolOutputs(
                    messages,
                    keepingUnder: limit
                )
                return SessionStore.MessageRewrite(
                    messages: rewrite.messages,
                    changedCount: rewrite.elidedCount
                )
            case .removeImages:
                let rewrite = AgentContextCompactor.removingImages(from: messages)
                return SessionStore.MessageRewrite(
                    messages: rewrite.messages,
                    changedCount: rewrite.removedCount
                )
            }
        }
    }

    private final class RewriteResult: Sendable {
        private enum State {
            case pending
            case succeeded(Int)
            case failed
        }

        private let state = NIOLockedValueBox(State.pending)

        var value: Int? {
            state.withLockedValue { state in
                guard case .succeeded(let value) = state else { return nil }
                return value
            }
        }

        func resolve(_ value: Int) {
            state.withLockedValue { $0 = .succeeded(value) }
        }

        func fail() {
            state.withLockedValue { $0 = .failed }
        }
    }

    private struct PendingRewrite: Sendable {
        let rewrite: TranscriptRewrite
        let result: RewriteResult
    }

    private enum PersistenceOperation: Sendable {
        case ensureCreated
        case messages([Message])
        case compaction(PendingCompaction)
        case rewrite(PendingRewrite)
        case title(String)
    }

    private let store: SessionStore
    private let sessionId: String
    private let cwd: String
    private let model: String?
    private let provider: String?

    private struct State {
        /// Number of transcript messages already flushed to disk.
        var persistedCount: Int
        /// Usage snapshot from the latest compactStart, consumed by compactEnd.
        var pendingCompactionUsage: AgentContextUsage?
        /// Summary-request usage of compactions not yet written to disk. A
        /// failed compaction still bills its requests, so its usage rides on
        /// the next compaction marker instead of being dropped.
        var unrecordedSummaryUsage: Usage?
        /// Failed append/compaction/meta operations remain queued so a later
        /// recorder event can retry them before any newer write reaches disk.
        /// Explicit rewrites queued behind a failure are cancelled as one-shot
        /// transactions because their callers keep the live transcript unchanged.
        var pendingOperations: [PersistenceOperation] = []
        /// Protects the first queued operation from snapshot coalescing while its
        /// async store call is in flight.
        var isPersistingFirstOperation = false
        var lastPersistenceError: String?
        /// Tail of the serialized persistence chain. Each operation waits for the
        /// previous one so appends, compactions, metadata, and rewrites stay ordered.
        var persistenceChain: Task<Void, Never>?

        mutating func enqueueCoalescingMessageSnapshots(_ operation: PersistenceOperation) {
            guard case .messages = operation,
                  let lastIndex = pendingOperations.indices.last,
                  case .messages = pendingOperations[lastIndex],
                  !isPersistingFirstOperation || lastIndex > pendingOperations.startIndex else {
                pendingOperations.append(operation)
                return
            }
            // A newer full snapshot subsumes the older one because persistence
            // resumes from `persistedCount`. Keep at most one waiting snapshot
            // behind an in-flight write, avoiding O(events × transcript size)
            // memory growth during a prolonged I/O failure.
            pendingOperations[lastIndex] = operation
        }
    }

    private let state: NIOLockedValueBox<State>

    /// Most recent persistence failure. Failed append-style operations remain
    /// queued; explicit rewrites are cancelled so they cannot run after their
    /// callers kept the live transcript unchanged.
    public var lastPersistenceError: String? {
        state.withLockedValue { $0.lastPersistenceError }
    }

    /// - Parameters:
    ///   - persistedCount: messages already on disk (non-zero when resuming an
    ///     existing session). New messages beyond this index are appended.
    public init(
        store: SessionStore,
        sessionId: String,
        cwd: String,
        model: String? = nil,
        provider: String? = nil,
        persistedCount: Int = 0
    ) {
        self.store = store
        self.sessionId = sessionId
        self.cwd = cwd
        self.model = model
        self.provider = provider
        self.state = NIOLockedValueBox(State(persistedCount: persistedCount))
    }

    /// Ensure the session file exists with a header, creating it only when it
    /// does not already exist. Safe to call after resuming — it never truncates
    /// an existing transcript, so a resumed session's history is preserved even
    /// if a caller forgets the `resumed` guard.
    public func ensureCreated() async {
        await enqueue(.ensureCreated)
    }

    /// Subscribe to `agent` and persist its transcript as it grows. Returns an
    /// unsubscribe handle.
    @discardableResult
    public func attach(to agent: Agent) -> Unsubscribe {
        agent.subscribe { [weak self, weak agent] event, _ in
            guard let self, let agent else { return }
            switch event {
            case .messageEnd, .turnEnd, .agentEnd:
                await self.flush(messages: agent.state.messages)
            case .compactStart(_, let usage):
                self.noteCompactionStart(usage)
            case .compactEnd(let outcome):
                // A usage snapshot belongs to exactly one terminal compactEnd,
                // successful or not. Always consume it so a later manual
                // compact cannot inherit telemetry from a failed automatic one.
                let usage = self.takePendingCompactionUsage()
                self.noteSummaryUsage(agent.takeCompactionUsage())
                if case .compacted(let messagesCompacted, _) = outcome {
                    await self.recordCompaction(
                        messages: agent.state.messages,
                        messagesCompacted: messagesCompacted,
                        tokensBefore: usage?.tokens,
                        contextWindow: usage?.window,
                        reason: .compact
                    )
                }
            default:
                break
            }
        }
    }

    /// Append any transcript messages not yet on disk.
    public func flush(messages: [Message]) async {
        // Keep a full snapshot for retry. The durable baseline is read only
        // while this operation reaches the head of the FIFO, after every
        // earlier append or compaction has settled. Redact only the individual
        // line that is actually appended; eagerly mapping the full transcript
        // on every messageEnd/turnEnd/agentEnd makes a session quadratic.
        await enqueue(.messages(messages))
    }

    /// Record that the live context has been replaced by a compacted
    /// projection. This appends a compaction marker after any queued message
    /// writes and resets the baseline so the next post-compaction message is
    /// persisted immediately. `summaryUsage` is what the summary requests
    /// cost (usually `agent.takeCompactionUsage()`); usage carried from
    /// earlier failed compactions is added to it.
    public func recordCompaction(
        messages replacementMessages: [Message],
        messagesCompacted: Int,
        firstKeptMessageIndex: Int? = nil,
        tokensBefore: Int? = nil,
        contextWindow: Int? = nil,
        reason: SessionStore.CompactionReason,
        summaryUsage: Usage? = nil
    ) async {
        await enqueue(.compaction(PendingCompaction(
            replacementMessages: replacementMessages.map(redactedForPersistence),
            messagesCompacted: messagesCompacted,
            firstKeptMessageIndex: reason == .compact
                ? (firstKeptMessageIndex ?? messagesCompacted)
                : firstKeptMessageIndex,
            tokensBefore: tokensBefore,
            contextWindow: contextWindow,
            reason: reason,
            usage: combinedSummaryUsage(summaryUsage)
        )))
    }

    private func noteSummaryUsage(_ usage: Usage?) {
        guard let usage else { return }
        state.withLockedValue {
            $0.unrecordedSummaryUsage = ($0.unrecordedSummaryUsage ?? Usage()).adding(usage)
        }
    }

    /// `usage` plus any summary usage still waiting for a marker.
    private func combinedSummaryUsage(_ usage: Usage?) -> Usage? {
        let carried: Usage? = state.withLockedValue { state in
            defer { state.unrecordedSummaryUsage = nil }
            return state.unrecordedSummaryUsage
        }
        switch (carried, usage) {
        case (nil, let usage): return usage
        case (let carried, nil): return carried
        case (let carried?, let usage?): return carried.adding(usage)
        }
    }

    private func noteCompactionStart(_ usage: AgentContextUsage) {
        state.withLockedValue {
            $0.pendingCompactionUsage = usage
        }
    }

    private func takePendingCompactionUsage() -> AgentContextUsage? {
        state.withLockedValue { state in
            defer { state.pendingCompactionUsage = nil }
            return state.pendingCompactionUsage
        }
    }

    /// Persist a user-set session title (append-only `meta` entry). Chained
    /// after any queued message writes so it can't reorder ahead of the
    /// transcript. Backs `/rename`.
    public func recordTitle(_ title: String) async {
        await enqueue(.title(title))
    }

    /// Permanently elide oversized tool output in every persisted transcript
    /// entry. The rewrite is ordered with ordinary recorder writes.
    public func rewriteShakenToolOutputs(
        keepingUnder limit: Int = AgentContextCompactor.shakeToolOutputCharacterLimit
    ) async -> Int? {
        await rewriteTranscript(.shakeToolOutputs(keepingUnder: limit))
    }

    /// Permanently remove image blocks from every persisted transcript entry.
    /// The rewrite is ordered with ordinary recorder writes.
    public func rewriteRemovingImages() async -> Int? {
        await rewriteTranscript(.removeImages)
    }

    private func rewriteTranscript(_ rewrite: TranscriptRewrite) async -> Int? {
        let result = RewriteResult()
        await enqueue(.rewrite(PendingRewrite(rewrite: rewrite, result: result)))
        return result.value
    }

    private func enqueue(_ operation: PersistenceOperation) async {
        let work: Task<Void, Never> = state.withLockedValue { state in
            state.enqueueCoalescingMessageSnapshots(operation)
            let previous = state.persistenceChain
            let next = Task<Void, Never> { [weak self] in
                await previous?.value
                await self?.drainPendingOperations()
            }
            state.persistenceChain = next
            return next
        }
        await work.value
    }

    private func drainPendingOperations() async {
        while let operation = state.withLockedValue({ state -> PersistenceOperation? in
            guard let first = state.pendingOperations.first else { return nil }
            state.isPersistingFirstOperation = true
            return first
        }) {
            do {
                try await persist(operation)
                state.withLockedValue { state in
                    state.pendingOperations.removeFirst()
                    state.isPersistingFirstOperation = false
                    state.lastPersistenceError = nil
                }
            } catch {
                let cancelledRewrites = state.withLockedValue { state -> [RewriteResult] in
                    var results: [RewriteResult] = []
                    state.pendingOperations.removeAll { pendingOperation in
                        guard case .rewrite(let pending) = pendingOperation else {
                            return false
                        }
                        results.append(pending.result)
                        return true
                    }
                    state.isPersistingFirstOperation = false
                    state.lastPersistenceError = error.displayDescription
                    return results
                }
                cancelledRewrites.forEach { $0.fail() }
                return
            }
        }
    }

    private func persist(_ operation: PersistenceOperation) async throws {
        switch operation {
        case .ensureCreated:
            try await store.createIfMissing(
                id: sessionId,
                cwd: cwd,
                model: model,
                provider: provider
            )

        case .messages(let messages):
            try await persist(messages: messages)

        case .compaction(let compaction):
            try await store.appendCompaction(
                id: sessionId,
                cwd: cwd,
                replacementMessages: compaction.replacementMessages,
                messagesCompacted: compaction.messagesCompacted,
                firstKeptMessageIndex: compaction.firstKeptMessageIndex,
                tokensBefore: compaction.tokensBefore,
                contextWindow: compaction.contextWindow,
                reason: compaction.reason,
                usage: compaction.usage,
                model: model,
                provider: provider
            )
            state.withLockedValue {
                $0.persistedCount = compaction.replacementMessages.count
            }

        case .rewrite(let pending):
            let rewrite = pending.rewrite
            let changedCount = try await store.rewriteMessages(id: sessionId) { messages in
                rewrite.apply(to: messages)
            }
            pending.result.resolve(changedCount)

        case .title(let title):
            try await store.setTitle(id: sessionId, cwd: cwd, title: title)
        }
    }

    private func persist(messages: [Message]) async throws {
        while true {
            let nextIndex = state.withLockedValue { $0.persistedCount }
            guard nextIndex < messages.count else { return }

            try await store.append(
                id: sessionId,
                cwd: cwd,
                message: redactedForPersistence(messages[nextIndex]),
                model: model,
                provider: provider
            )
            state.withLockedValue {
                // Operations are drained serially, so a successful single-line
                // append advances the durable baseline exactly once. A later
                // retry resumes after any lines that already reached disk.
                $0.persistedCount = nextIndex + 1
            }
        }
    }
}
