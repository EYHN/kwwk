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
    /// Backs `--continue`.
    case latestForCwd
    /// Interactively pick any session across all projects. Backs `--resume`.
    /// The agent layer cannot run a TUI, so `resolveResume` degrades this to a
    /// fresh session; the CLI layer resolves the user's pick to `.id(...)`
    /// before calling `resolveResume`.
    case pickInteractive
    /// Resume a specific session by id.
    case id(String)
}

/// Result of resolving a `SessionResume` against a `SessionStore`: the
/// session id to use plus any context to seed the agent with. When nothing
/// matched (`.none`, or `.latestForCwd` with no prior session), `messages` is
/// empty and `persistedCount` is zero so the recorder starts appending from
/// scratch.
public struct ResolvedResume: Sendable {
    public var sessionId: String
    public var messages: [Message]
    /// Visual-recap transcript (`LoadedSession.displayMessages`): the full
    /// on-screen history, truncated by rewinds but not by context compaction.
    public var displayMessages: [Message]
    public var model: String?
    public var thinkingLevel: String?
    /// Number of projected context messages already represented on disk for
    /// this session.
    public var persistedCount: Int
    /// True when an existing session was loaded (vs. a fresh id minted).
    public var resumed: Bool

    public init(
        sessionId: String,
        messages: [Message] = [],
        displayMessages: [Message]? = nil,
        model: String? = nil,
        thinkingLevel: String? = nil,
        persistedCount: Int = 0,
        resumed: Bool = false
    ) {
        self.sessionId = sessionId
        self.messages = messages
        self.displayMessages = displayMessages ?? messages
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.persistedCount = persistedCount
        self.resumed = resumed
    }
}

extension SessionStore {
    /// Resolve a `SessionResume` for `cwd`, loading the stored transcript when
    /// a matching session exists. A fresh `UUID` id is minted for `.none` /
    /// `.pickInteractive` / a `.latestForCwd` with no prior session. An
    /// explicit `.id(...)` whose format is invalid throws
    /// `SessionStoreError.invalidId` rather than silently substituting a random
    /// session — a caller asking for a named session should hear about a typo,
    /// not scatter transcripts across UUID files.
    public func resolveResume(
        _ resume: SessionResume,
        cwd: String,
        freshId: String = UUID().uuidString
    ) async throws -> ResolvedResume {
        switch resume {
        case .none:
            return ResolvedResume(sessionId: freshId)

        case .pickInteractive:
            // No UI at this layer: degrade to a fresh session. Interactive
            // callers resolve the user's pick to `.id(...)` before getting here.
            return ResolvedResume(sessionId: freshId)

        case .latestForCwd:
            guard let info = latestForCwd(cwd),
                  let loaded = try? load(id: info.id) else {
                return ResolvedResume(sessionId: freshId)
            }
            return ResolvedResume(
                sessionId: loaded.header.id,
                messages: loaded.messages,
                displayMessages: loaded.displayMessages,
                model: loaded.model,
                thinkingLevel: loaded.thinkingLevel,
                persistedCount: loaded.persistedContextCount,
                resumed: true
            )

        case .id(let id):
            guard SessionStore.isValidSessionId(id) else {
                throw SessionStoreError.invalidId(id)
            }
            do {
                let loaded = try load(id: id)
                return ResolvedResume(
                    sessionId: loaded.header.id,
                    messages: loaded.messages,
                    displayMessages: loaded.displayMessages,
                    model: loaded.model,
                    thinkingLevel: loaded.thinkingLevel,
                    persistedCount: loaded.persistedContextCount,
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
