import Foundation
import KWWKAI

/// How a coding-agent run should pick up a previously-persisted session.
///
/// Backs the `--resume` / `--continue` / `--session <id>` CLI flags. The
/// default `.none` means "start fresh" — behavior is unchanged when no flag
/// is passed.
public enum SessionResume: Sendable, Hashable {
    /// Start a brand-new session.
    case none
    /// Resume the most-recently-active session whose `cwd` matches the run's
    /// working directory. Falls back to a fresh session if none exist.
    case latestForCwd
    /// Resume a specific session by id.
    case id(String)
}

/// Result of resolving a `SessionResume` against a `SessionStore`: the
/// session id to use plus any transcript to seed the agent with. When nothing
/// matched (`.none`, or `.latestForCwd` with no prior session), `messages` is
/// empty and `persistedCount` is zero so the recorder starts appending from
/// scratch.
public struct ResolvedResume: Sendable {
    public var sessionId: String
    public var messages: [Message]
    public var model: String?
    public var thinkingLevel: String?
    /// Number of transcript messages already on disk for this session.
    public var persistedCount: Int
    /// True when an existing session was loaded (vs. a fresh id minted).
    public var resumed: Bool

    public init(
        sessionId: String,
        messages: [Message] = [],
        model: String? = nil,
        thinkingLevel: String? = nil,
        persistedCount: Int = 0,
        resumed: Bool = false
    ) {
        self.sessionId = sessionId
        self.messages = messages
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.persistedCount = persistedCount
        self.resumed = resumed
    }
}

extension SessionStore {
    /// Resolve a `SessionResume` for `cwd`, loading the stored transcript when
    /// a matching session exists. A fresh `UUID` id is minted otherwise. Never
    /// throws — an unreadable/missing target degrades to a fresh session.
    public func resolveResume(
        _ resume: SessionResume,
        cwd: String,
        freshId: String = UUID().uuidString
    ) async -> ResolvedResume {
        switch resume {
        case .none:
            return ResolvedResume(sessionId: freshId)

        case .latestForCwd:
            guard let info = latestForCwd(cwd),
                  let loaded = try? load(id: info.id) else {
                return ResolvedResume(sessionId: freshId)
            }
            return ResolvedResume(
                sessionId: loaded.header.id,
                messages: loaded.messages,
                model: loaded.model,
                thinkingLevel: loaded.thinkingLevel,
                persistedCount: loaded.messages.count,
                resumed: true
            )

        case .id(let id):
            guard SessionStore.isValidSessionId(id) else {
                return ResolvedResume(sessionId: freshId)
            }
            do {
                let loaded = try load(id: id)
                return ResolvedResume(
                    sessionId: loaded.header.id,
                    messages: loaded.messages,
                    model: loaded.model,
                    thinkingLevel: loaded.thinkingLevel,
                    persistedCount: loaded.messages.count,
                    resumed: true
                )
            } catch SessionStoreError.notFound {
                // Unknown id — create a new session under that id so the
                // caller's intent (a stable, named session) is honored.
                return ResolvedResume(sessionId: id)
            } catch {
                return ResolvedResume(sessionId: freshId)
            }
        }
    }
}
