import Foundation
import KWWKAgent

/// Parsed result of whatever the user typed at the prompt. Leading `/` →
/// treated as a slash-command invocation; anything else → an LLM prompt.
enum SlashInput: Equatable {
    case command(name: String, args: String)
    case prompt(text: String)

    /// Split on the first run of whitespace. Leading/trailing whitespace is
    /// trimmed off the command name; args are kept verbatim so a command
    /// can do its own parsing (quoted strings, subcommands, etc.).
    static func parse(_ raw: String) -> SlashInput {
        let trimmedLeading = raw.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmedLeading.hasPrefix("/") else {
            return .prompt(text: raw)
        }
        let body = trimmedLeading.dropFirst()
        let parts = body.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard let first = parts.first, !first.isEmpty else {
            // Bare "/" or "/   " — treat as prompt so the user's accidental
            // slash isn't silently swallowed.
            return .prompt(text: raw)
        }
        let name = String(first)
        let args = parts.count > 1 ? String(parts[1]) : ""
        return .command(name: name, args: args)
    }
}

/// Ambient context a slash-command handler receives: the live Agent (for
/// reading/updating model, messages, etc.), the modal host (to open
/// selectors), the background-task manager + sessionId (so commands like
/// /compact can preserve running-task context), and a hook to append a
/// dimmed line to the transcript so the command can surface its result
/// to the user.
@MainActor
final class SlashContext {
    let agent: Agent
    let modal: ModalHost
    let backgroundManager: BackgroundTaskManager
    let sessionId: String
    /// Append one semantic block of dimmed notification text to the
    /// transcript. All lines in the array are committed together with a
    /// single leading blank row (the "every scrollback block opens with
    /// a blank, never closes with one" rule) — so a multi-line
    /// notification stays visually grouped instead of stacking blanks
    /// between every line. Single-line notifications can use the
    /// `notify(_:String)` convenience overload below.
    let notifyBlock: @MainActor ([String]) -> Void
    /// Emit lines into the TUI's commit buffer so they flow into the
    /// terminal's native scrollback as permanent records. Use when the
    /// command produced a durable outcome worth keeping in history
    /// (e.g. a `/compact` boundary). The closure takes the terminal's
    /// current width so callers can render width-aware rules/banners
    /// without needing to plumb the terminal itself.
    let commitScrollback: @MainActor (_ render: (_ width: Int) -> [String]) -> Void
    /// Recompute the streaming transcript and request a repaint. Used by
    /// commands that change a rendering-affecting piece of agent state
    /// (e.g. `/thinking show|hide`) without emitting an AgentEvent the
    /// listener would otherwise observe.
    let refreshTranscript: @MainActor () -> Void
    /// Persist a successful manual compaction. Automatic compaction uses
    /// AgentEvent subscriptions; slash commands need an explicit hook.
    let recordCompaction: @MainActor (_ messagesCompacted: Int) async -> Void

    init(
        agent: Agent,
        modal: ModalHost,
        backgroundManager: BackgroundTaskManager,
        sessionId: String,
        notifyBlock: @MainActor @escaping ([String]) -> Void,
        commitScrollback: @MainActor @escaping ((Int) -> [String]) -> Void,
        refreshTranscript: @MainActor @escaping () -> Void,
        recordCompaction: @MainActor @escaping (_ messagesCompacted: Int) async -> Void = { _ in }
    ) {
        self.agent = agent
        self.modal = modal
        self.backgroundManager = backgroundManager
        self.sessionId = sessionId
        self.notifyBlock = notifyBlock
        self.commitScrollback = commitScrollback
        self.refreshTranscript = refreshTranscript
        self.recordCompaction = recordCompaction
    }

    /// Single-line convenience: one-off status messages (`/model switched
    /// A → B`) stay ergonomic. Internally treated as a one-line block so
    /// the leading-blank rule still applies.
    @MainActor
    func notify(_ line: String) {
        notifyBlock([line])
    }
}

/// Handler signature. Handlers are allowed to suspend — opening a modal
/// mutates state synchronously and returns; awaiting user input happens via
/// the modal's callbacks, not by blocking the handler.
typealias SlashHandler = @MainActor (SlashContext, String) async -> Void

struct SlashCommand: Sendable {
    let name: String
    let description: String
    let handler: SlashHandler
}

/// Lookup table for slash commands. Single-threaded: all registration and
/// dispatch happens on the MainActor.
@MainActor
final class SlashCommandRegistry {
    private var commands: [String: SlashCommand] = [:]

    func register(_ command: SlashCommand) {
        commands[command.name] = command
    }

    func find(_ name: String) -> SlashCommand? {
        commands[name]
    }

    var all: [SlashCommand] {
        Array(commands.values).sorted { $0.name < $1.name }
    }
}
