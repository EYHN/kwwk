import Foundation
import KWWKAI

/// Bridges a live `Agent` to a `SessionStore`: subscribes to the agent's
/// event stream and appends newly-produced transcript messages to the
/// session's JSONL log as they land, so a crashed or aborted run still
/// leaves a resumable transcript on disk.
///
/// The recorder is *additive* and non-invasive — attach it to any agent and
/// detach when done. It persists on every message-bearing event
/// (`messageEnd`, `turnEnd`, `agentEnd`) by diffing the agent's current
/// transcript against the count already written, then appending only the new
/// tail. That keeps writes append-only even when the loop produces several
/// messages between events. Compaction is persisted as its own append-only
/// marker and resets the live-message baseline to the compacted context.
public final class SessionRecorder: @unchecked Sendable {
    private struct PendingCompaction: Sendable {
        let replacementMessages: [Message]
        let messagesCompacted: Int
        let firstKeptMessageIndex: Int?
        let tokensBefore: Int?
        let contextWindow: Int?
        let reason: SessionStore.CompactionReason
    }

    private enum PersistenceOperation: Sendable {
        case ensureCreated
        case messages([Message])
        case compaction(PendingCompaction)
        case title(String)
    }

    private let store: SessionStore
    private let sessionId: String
    private let cwd: String
    private let model: String?
    private let provider: String?

    private let lock = NSLock()
    /// Number of transcript messages already flushed to disk.
    private var persistedCount: Int
    /// Usage snapshot from the latest compactStart, consumed by compactEnd.
    private var pendingCompactionUsage: AgentContextUsage?
    /// Failed operations remain queued so a later recorder event can retry
    /// them before any newer write reaches disk.
    private var pendingOperations: [PersistenceOperation] = []
    /// Protects the first queued operation from snapshot coalescing while its
    /// async store call is in flight.
    private var isPersistingFirstOperation = false
    private var _lastPersistenceError: String?
    /// Tail of the serialized append chain. Each flush enqueues its write after
    /// the previous one so concurrent events can't reorder the on-disk JSONL.
    private var appendChain: Task<Void, Never>?

    /// Most recent persistence failure. The failed operation remains queued;
    /// this value clears once a later retry succeeds.
    public var lastPersistenceError: String? {
        lock.withLock { _lastPersistenceError }
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
        self.persistedCount = persistedCount
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
    /// persisted immediately.
    public func recordCompaction(
        messages replacementMessages: [Message],
        messagesCompacted: Int,
        firstKeptMessageIndex: Int? = nil,
        tokensBefore: Int? = nil,
        contextWindow: Int? = nil,
        reason: SessionStore.CompactionReason
    ) async {
        await enqueue(.compaction(PendingCompaction(
            replacementMessages: replacementMessages.map(redactedForPersistence),
            messagesCompacted: messagesCompacted,
            firstKeptMessageIndex: reason == .compact
                ? (firstKeptMessageIndex ?? messagesCompacted)
                : firstKeptMessageIndex,
            tokensBefore: tokensBefore,
            contextWindow: contextWindow,
            reason: reason
        )))
    }

    private func noteCompactionStart(_ usage: AgentContextUsage) {
        lock.withLock {
            pendingCompactionUsage = usage
        }
    }

    private func takePendingCompactionUsage() -> AgentContextUsage? {
        lock.withLock {
            defer { pendingCompactionUsage = nil }
            return pendingCompactionUsage
        }
    }

    /// Persist a user-set session title (append-only `meta` entry). Chained
    /// after any queued message writes so it can't reorder ahead of the
    /// transcript. Backs `/rename`.
    public func recordTitle(_ title: String) async {
        await enqueue(.title(title))
    }

    private func enqueue(_ operation: PersistenceOperation) async {
        let work: Task<Void, Never> = lock.withLock {
            enqueueCoalescingMessageSnapshots(operation)
            let previous = appendChain
            let next = Task<Void, Never> { [weak self] in
                await previous?.value
                await self?.drainPendingOperations()
            }
            appendChain = next
            return next
        }
        await work.value
    }

    private func drainPendingOperations() async {
        while let operation = lock.withLock({ () -> PersistenceOperation? in
            guard let first = pendingOperations.first else { return nil }
            isPersistingFirstOperation = true
            return first
        }) {
            do {
                try await persist(operation)
                lock.withLock {
                    pendingOperations.removeFirst()
                    isPersistingFirstOperation = false
                    _lastPersistenceError = nil
                }
            } catch {
                lock.withLock {
                    isPersistingFirstOperation = false
                    _lastPersistenceError = String(describing: error)
                }
                return
            }
        }
    }

    private func enqueueCoalescingMessageSnapshots(_ operation: PersistenceOperation) {
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
                model: model,
                provider: provider
            )
            lock.withLock {
                persistedCount = compaction.replacementMessages.count
            }

        case .title(let title):
            try await store.setTitle(id: sessionId, cwd: cwd, title: title)
        }
    }

    private func persist(messages: [Message]) async throws {
        while true {
            let nextIndex = lock.withLock { persistedCount }
            guard nextIndex < messages.count else { return }

            try await store.append(
                id: sessionId,
                cwd: cwd,
                message: redactedForPersistence(messages[nextIndex]),
                model: model,
                provider: provider
            )
            lock.withLock {
                // Operations are drained serially, so a successful single-line
                // append advances the durable baseline exactly once. A later
                // retry resumes after any lines that already reached disk.
                persistedCount = nextIndex + 1
            }
        }
    }
}
