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
    /// Tail of the serialized append chain. Each flush enqueues its write after
    /// the previous one so concurrent events can't reorder the on-disk JSONL.
    private var appendChain: Task<Void, Never>?

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

    /// Ensure the session file exists with a header. Call once before the
    /// first run when starting a fresh session.
    public func ensureCreated() async {
        _ = try? await store.create(id: sessionId, cwd: cwd, model: model, provider: provider)
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
                await self.noteCompactionStart(usage)
            case .compactEnd(let outcome):
                if case .compacted(let messagesCompacted, _) = outcome {
                    await self.recordCompaction(
                        messages: agent.state.messages,
                        messagesCompacted: messagesCompacted
                    )
                }
            default:
                break
            }
        }
    }

    /// Append any transcript messages not yet on disk.
    public func flush(messages: [Message]) async {
        // Extract the new tail AND enqueue its append under a single lock so the
        // slice order and the write order are decided together. The append task
        // awaits the previous one, guaranteeing FIFO on-disk ordering even when
        // `messageEnd`/`turnEnd` fire concurrently.
        let work: Task<Void, Never>? = lock.withLock {
            guard messages.count > persistedCount else { return nil }
            // Redact hidden goal continuations before writing: replace each with
            // a marker-only stand-in that keeps goal state (the objective) off
            // disk while preserving the `user` role, so the persisted transcript
            // stays valid user→assistant alternation for `/resume`. We map (not
            // filter) so we never orphan the assistant reply that followed.
            let tail = messages[persistedCount...].map(redactedForPersistence)
            persistedCount = messages.count
            let previous = appendChain
            let store = self.store
            let sessionId = self.sessionId
            let cwd = self.cwd
            let model = self.model
            let provider = self.provider
            let next = Task<Void, Never> {
                await previous?.value
                try? await store.append(
                    id: sessionId,
                    cwd: cwd,
                    messages: tail,
                    model: model,
                    provider: provider
                )
            }
            appendChain = next
            return next
        }
        await work?.value
    }

    /// Record that the live context has been replaced by a compacted
    /// projection. This appends a compaction marker after any queued message
    /// writes and resets the baseline so the next post-compaction message is
    /// persisted immediately.
    public func recordCompaction(
        messages replacementMessages: [Message],
        messagesCompacted: Int,
        tokensBefore: Int? = nil,
        contextWindow: Int? = nil
    ) async {
        let work: Task<Void, Never> = lock.withLock {
            let usage = pendingCompactionUsage
            pendingCompactionUsage = nil
            persistedCount = replacementMessages.count
            // Apply the same redaction to the compacted projection so goal
            // internals don't leak in through the compaction path either.
            let redactedReplacement = replacementMessages.map(redactedForPersistence)

            let previous = appendChain
            let store = self.store
            let sessionId = self.sessionId
            let cwd = self.cwd
            let model = self.model
            let provider = self.provider
            let next = Task<Void, Never> {
                await previous?.value
                try? await store.appendCompaction(
                    id: sessionId,
                    cwd: cwd,
                    replacementMessages: redactedReplacement,
                    messagesCompacted: messagesCompacted,
                    tokensBefore: tokensBefore ?? usage?.tokens,
                    contextWindow: contextWindow ?? usage?.window,
                    model: model,
                    provider: provider
                )
            }
            appendChain = next
            return next
        }
        await work.value
    }

    private func noteCompactionStart(_ usage: AgentContextUsage) async {
        lock.withLock {
            pendingCompactionUsage = usage
        }
    }

    /// Persist a user-set session title (append-only `meta` entry). Chained
    /// after any queued message writes so it can't reorder ahead of the
    /// transcript. Backs `/rename`.
    public func recordTitle(_ title: String) async {
        let work: Task<Void, Never> = lock.withLock {
            let previous = appendChain
            let store = self.store
            let sessionId = self.sessionId
            let cwd = self.cwd
            let next = Task<Void, Never> {
                await previous?.value
                _ = try? await store.setTitle(id: sessionId, cwd: cwd, title: title)
            }
            appendChain = next
            return next
        }
        await work.value
    }
}
