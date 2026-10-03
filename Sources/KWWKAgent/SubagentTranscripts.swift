import Foundation
import KWWKAI

/// Subagent transcripts on disk.
///
/// A subagent's conversation otherwise lives only in memory (the history
/// store behind `agent_history`), so once its parent process exits nothing
/// shows what the child ran. With a transcript store configured, every child
/// session gets its own append-only JSONL file in the same format as a parent
/// session, written as the child works.
///
/// The files sit in a `subagents/` directory beside the parent sessions, so
/// they never appear in the parent store's `list()` or compete with a
/// parent's `--continue`. A file is a log of every run of one child: a
/// resumed child appends its new messages after the earlier run's, including
/// any tail the resume dropped (an errored turn, unanswered calls). It is a
/// record of what happened, not a session to resume from.
public extension SessionStore {
    /// Name of the directory, beside the parent session files, that holds
    /// subagent transcripts.
    static let subagentTranscriptDirectoryName = "subagents"

    /// The store for transcripts of subagents launched by sessions in this
    /// store, or nil when this store does not persist.
    nonisolated var subagentTranscripts: SessionStore? {
        guard isPersistent else { return nil }
        return SessionStore(
            directory: directory.appendingPathComponent(
                Self.subagentTranscriptDirectoryName,
                isDirectory: true
            )
        )
    }
}

/// The file id for a child session. Child ids join their parts with `:`
/// (`<parent>:subagent:<type>:<uuid>`), which session files reject, so every
/// character a session id cannot carry becomes `.`.
public func subagentTranscriptSessionId(_ childSessionId: String) -> String {
    let mapped = String(childSessionId.map { character -> Character in
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
            ? character
            : "."
    })
    let trimmed = mapped.drop { !($0.isLetter || $0.isNumber) }
    let id = String(trimmed.reversed().drop { !($0.isLetter || $0.isNumber) }.reversed())
    return id.isEmpty ? "subagent" : id
}

/// Records one child run into its transcript file.
struct SubagentTranscriptRecording {
    private let recorder: SessionRecorder
    private let unsubscribe: Unsubscribe

    /// Starts recording `child`. A first run creates the file and titles it
    /// with the agent id, type, and description; a resumed run appends after
    /// the messages it was resumed with, which the earlier run already wrote.
    static func start(
        store: SessionStore,
        childSessionId: String,
        cwd: String,
        model: Model,
        launch: SubagentLaunchInfo,
        subagentType: String,
        resumeMessages: [Message]?,
        child: Agent
    ) async -> SubagentTranscriptRecording {
        let recorder = SessionRecorder(
            store: store,
            sessionId: subagentTranscriptSessionId(childSessionId),
            cwd: cwd,
            model: model.id,
            provider: model.provider,
            persistedCount: resumeMessages?.count ?? 0
        )
        if resumeMessages == nil {
            await recorder.ensureCreated()
            await recorder.recordTitle("\(launch.agentId) (\(subagentType)): \(launch.description)")
        }
        return SubagentTranscriptRecording(
            recorder: recorder,
            unsubscribe: recorder.attach(to: child)
        )
    }

    /// Writes whatever the child added since the last event and stops
    /// listening. Persistence failures never fail the child's run; the
    /// recorder keeps them in `lastPersistenceError`.
    func finish(messages: [Message]) async {
        await recorder.flush(messages: messages)
        unsubscribe()
    }
}
