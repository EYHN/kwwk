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
    private let agentProvider: @MainActor @Sendable () -> Agent
    let modal: ModalHost
    let backgroundManager: BackgroundTaskManager
    private let sessionIdProvider: @MainActor @Sendable () -> String
    var agent: Agent { agentProvider() }
    var sessionId: String { sessionIdProvider() }
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
    /// Persist a user-set session title to the live session file. Backed by
    /// the SessionRecorder in the TUI; a no-op in headless/test contexts.
    let setSessionTitle: @MainActor (_ title: String) async -> Void
    /// Providers logged in this session — read by `/model` to list + route
    /// across accounts, mutated by `/login` / `/logout`. Empty in headless /
    /// test contexts that don't wire it up.
    let sessionProviders: SessionProviders
    /// Mutable resolver map the agent delegates to; `/login` installs a
    /// newly-authenticated provider's resolver here. Nil in headless/tests.
    let authResolvers: SessionAuthResolvers?
    /// Launch-time `--context-1m` flag. `/login` forwards it into
    /// `registerStoredProviderLive` so a provider added mid-session (including
    /// the first login of a logged-out session) still opts into the Anthropic
    /// 1M-context beta. False in headless/test contexts that don't wire it up.
    let context1m: Bool
    /// Suspend the coding TUI (release raw stdin + terminal modes), run
    /// `body` with the terminal in cooked state (for a full-screen sub-flow
    /// like the `/login` OAuth handoff), then restore the TUI and repaint.
    /// A no-op passthrough in headless / test contexts.
    let withSuspendedTUI: @MainActor (_ body: @escaping @MainActor () async -> Void) async -> Void
    /// Mark the TUI busy for the duration of a manual `/compact`: shows the
    /// compacting spinner and makes the Enter handler treat the round-trip as
    /// busy, so a prompt submitted mid-compact queues (steers) instead of
    /// starting a turn that the compactor would clobber when it overwrites
    /// `agent.state.messages`. A no-op in headless / test contexts.
    let setCompacting: @MainActor (_ active: Bool) -> Void

    init(
        agent: Agent,
        modal: ModalHost,
        backgroundManager: BackgroundTaskManager,
        sessionId: String,
        notifyBlock: @MainActor @escaping ([String]) -> Void,
        commitScrollback: @MainActor @escaping ((Int) -> [String]) -> Void,
        refreshTranscript: @MainActor @escaping () -> Void,
        recordCompaction: @MainActor @escaping (_ messagesCompacted: Int) async -> Void = { _ in },
        setSessionTitle: @MainActor @escaping (_ title: String) async -> Void = { _ in },
        sessionProviders: SessionProviders = SessionProviders(),
        authResolvers: SessionAuthResolvers? = nil,
        context1m: Bool = false,
        withSuspendedTUI: @MainActor @escaping (_ body: @escaping @MainActor () async -> Void) async -> Void = { body in await body() },
        setCompacting: @MainActor @escaping (_ active: Bool) -> Void = { _ in }
    ) {
        self.agentProvider = { agent }
        self.modal = modal
        self.backgroundManager = backgroundManager
        self.sessionIdProvider = { sessionId }
        self.notifyBlock = notifyBlock
        self.commitScrollback = commitScrollback
        self.refreshTranscript = refreshTranscript
        self.recordCompaction = recordCompaction
        self.setSessionTitle = setSessionTitle
        self.sessionProviders = sessionProviders
        self.authResolvers = authResolvers
        self.context1m = context1m
        self.withSuspendedTUI = withSuspendedTUI
        self.setCompacting = setCompacting
    }

    /// Runtime-backed variant used by the interactive TUI, whose `/new` and
    /// `/resume` commands replace the complete session-scoped Agent.
    init(
        agentProvider: @MainActor @escaping @Sendable () -> Agent,
        modal: ModalHost,
        backgroundManager: BackgroundTaskManager,
        sessionIdProvider: @MainActor @escaping @Sendable () -> String,
        notifyBlock: @MainActor @escaping ([String]) -> Void,
        commitScrollback: @MainActor @escaping ((Int) -> [String]) -> Void,
        refreshTranscript: @MainActor @escaping () -> Void,
        recordCompaction: @MainActor @escaping (_ messagesCompacted: Int) async -> Void = { _ in },
        setSessionTitle: @MainActor @escaping (_ title: String) async -> Void = { _ in },
        sessionProviders: SessionProviders = SessionProviders(),
        authResolvers: SessionAuthResolvers? = nil,
        context1m: Bool = false,
        withSuspendedTUI: @MainActor @escaping (_ body: @escaping @MainActor () async -> Void) async -> Void = { body in await body() },
        setCompacting: @MainActor @escaping (_ active: Bool) -> Void = { _ in }
    ) {
        self.agentProvider = agentProvider
        self.modal = modal
        self.backgroundManager = backgroundManager
        self.sessionIdProvider = sessionIdProvider
        self.notifyBlock = notifyBlock
        self.commitScrollback = commitScrollback
        self.refreshTranscript = refreshTranscript
        self.recordCompaction = recordCompaction
        self.setSessionTitle = setSessionTitle
        self.sessionProviders = sessionProviders
        self.authResolvers = authResolvers
        self.context1m = context1m
        self.withSuspendedTUI = withSuspendedTUI
        self.setCompacting = setCompacting
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
    /// Optional alternate names the command also answers to in the popup /
    /// completion (e.g. `clear` for `/new`). Not registered as separate
    /// dispatch keys — purely a matcher affordance.
    let aliases: [String]
    let handler: SlashHandler

    init(name: String, description: String, aliases: [String] = [], handler: @escaping SlashHandler) {
        self.name = name
        self.description = description
        self.aliases = aliases
        self.handler = handler
    }
}

/// The matcher's view of a slash command — name plus the optional fields it
/// ranks against. Decoupled from `SlashCommand` so both the popup
/// (`CodingFrame`) and the sync completion path can share one ranker without
/// dragging the (non-Equatable) handler closure along.
struct SlashCommandInfo: Equatable, Sendable {
    let name: String
    let description: String
    let aliases: [String]

    init(name: String, description: String = "", aliases: [String] = []) {
        self.name = name
        self.description = description
        self.aliases = aliases
    }
}

struct SlashCompletion: Equatable {
    let suffix: String
    let completedInput: String
}

// MARK: - Fuzzy matcher (ported from omp's autocomplete.ts fuzzyMatch/fuzzyScore)

/// True when every character of `query` appears in `target` in order (a
/// subsequence test). `"cpt"` matches `"compact"`. Both args must already be
/// lowercased by the caller.
func slashFuzzyMatch(_ query: String, _ target: String) -> Bool {
    if query.isEmpty { return true }
    if query.count > target.count { return false }
    var qi = query.startIndex
    for ch in target {
        if ch == query[qi] {
            qi = query.index(after: qi)
            if qi == query.endIndex { return true }
        }
    }
    return qi == query.endIndex
}

/// Score a fuzzy match, higher = tighter. Mirrors omp: exact (100) >
/// starts-with (80) > contains (60) > subsequence (40 minus a per-gap
/// penalty). Returns 0 for a non-match. Both args must be lowercased.
func slashFuzzyScore(_ query: String, _ target: String) -> Int {
    if query.isEmpty { return 1 }
    if target == query { return 100 }
    if target.hasPrefix(query) { return 80 }
    if target.contains(query) { return 60 }

    var qi = query.startIndex
    var gaps = 0
    var lastMatchIdx = -1
    var ti = 0
    for ch in target {
        if qi != query.endIndex && ch == query[qi] {
            if lastMatchIdx >= 0 && ti - lastMatchIdx > 1 { gaps += 1 }
            lastMatchIdx = ti
            qi = query.index(after: qi)
        }
        ti += 1
    }
    if qi != query.endIndex { return 0 }
    return max(1, 40 - gaps * 5)
}

/// The single shared ranker. `query` is the text after the leading `/` (no
/// slash). Scores each command's name, aliases, and (at half weight) its
/// description, keeping any candidate that scores > 0; ties preserve the
/// input order so callers that pass commands pre-sorted by name get a stable,
/// predictable top match. An empty query returns every command unchanged so
/// the bare-`/` popup lists the full catalog in registry order.
///
/// Both `CodingFrame`'s popup and `slashCompletion` funnel through this so the
/// highlighted row, the Tab completion, and the inline ghost suffix can never
/// disagree on which command a partial query resolves to.
func rankSlashCommands(query: String, commands: [SlashCommandInfo]) -> [SlashCommandInfo] {
    let lower = query.lowercased()
    if lower.isEmpty { return commands }

    var scored: [(cmd: SlashCommandInfo, score: Int, index: Int)] = []
    for (index, cmd) in commands.enumerated() {
        let lowerName = cmd.name.lowercased()
        var best = slashFuzzyMatch(lower, lowerName) ? slashFuzzyScore(lower, lowerName) : 0
        for alias in cmd.aliases {
            let lowerAlias = alias.lowercased()
            if slashFuzzyMatch(lower, lowerAlias) {
                best = max(best, slashFuzzyScore(lower, lowerAlias))
            }
        }
        let lowerDesc = cmd.description.lowercased()
        if !lowerDesc.isEmpty && slashFuzzyMatch(lower, lowerDesc) {
            best = max(best, slashFuzzyScore(lower, lowerDesc) / 2)
        }
        if best > 0 { scored.append((cmd, best, index)) }
    }
    scored.sort { a, b in
        a.score != b.score ? a.score > b.score : a.index < b.index
    }
    return scored.map(\.cmd)
}

/// Lookup table for slash commands. Single-threaded: all registration and
/// dispatch happens on the MainActor.
@MainActor
final class SlashCommandRegistry {
    private var commands: [String: SlashCommand] = [:]

    func register(_ command: SlashCommand) {
        commands[command.name] = command
    }

    /// Resolve by primary name first, then fall back to any command that
    /// lists `name` as an alias — so `/clear` dispatches `/new`. Aliases are
    /// matcher-only (never registered as separate dispatch keys), so a single
    /// pass over the small command set is fine.
    func find(_ name: String) -> SlashCommand? {
        if let direct = commands[name] { return direct }
        return commands.values.first { $0.aliases.contains(name) }
    }

    var all: [SlashCommand] {
        Array(commands.values).sorted { $0.name < $1.name }
    }
}

@MainActor
func slashCompletion(for input: String, registry: SlashCommandRegistry) -> SlashCompletion? {
    slashCompletion(
        for: input,
        commands: registry.all.map {
            SlashCommandInfo(name: $0.name, description: $0.description, aliases: $0.aliases)
        }
    )
}

/// Names-only convenience: ranks by name alone. Kept for call sites (and
/// tests) that only have a flat command list.
func slashCompletion(for input: String, commandNames: [String]) -> SlashCompletion? {
    slashCompletion(for: input, commands: commandNames.map { SlashCommandInfo(name: $0) })
}

func slashCompletion(for input: String, commands: [SlashCommandInfo]) -> SlashCompletion? {
    guard input.hasPrefix("/") else { return nil }
    let body = String(input.dropFirst())
    guard !body.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) else {
        return nil
    }

    // Share the popup's ranker so the ghost/Tab target is always the popup's
    // top row.
    let ranked = rankSlashCommands(query: body, commands: commands)
    guard let match = ranked.first?.name else { return nil }
    if match == body {
        return input.hasSuffix(" ") ? nil : SlashCompletion(suffix: "", completedInput: "/\(match) ")
    }

    // The inline ghost suffix only reads correctly when the typed body is a
    // literal prefix of the match; for looser fuzzy hits (e.g. `/cpt` →
    // `/compact`) we still complete on Tab via `completedInput`, but suppress
    // the appended ghost since there's no contiguous tail to show.
    let suffix = match.lowercased().hasPrefix(body.lowercased())
        ? String(match.dropFirst(body.count))
        : ""
    return SlashCompletion(suffix: suffix, completedInput: "/\(match) ")
}
