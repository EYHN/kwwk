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
/// selectors), and a hook to append a dimmed line to the transcript so the
/// command can surface its result to the user.
@MainActor
final class SlashContext {
    let agent: Agent
    let modal: ModalHost
    let notify: @MainActor (String) -> Void

    init(
        agent: Agent,
        modal: ModalHost,
        notify: @MainActor @escaping (String) -> Void
    ) {
        self.agent = agent
        self.modal = modal
        self.notify = notify
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
