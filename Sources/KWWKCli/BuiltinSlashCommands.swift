import Foundation
import KWWKAI
import KWWKAgent

/// Register the V1 set of builtin slash commands on `registry`. Keep these
/// focused on things a user actually needs mid-session; heavier flows
/// (login, config persistence) live on the `kwwk` binary instead.
@MainActor
func registerBuiltinSlashCommands(_ registry: SlashCommandRegistry) {
    registry.register(SlashCommand(
        name: "model",
        description: "Pick a model for this session",
        handler: handleModelCommand
    ))
    registry.register(SlashCommand(
        name: "compact",
        description: "Summarize the transcript to reclaim context",
        handler: handleCompactCommand
    ))
    registry.register(SlashCommand(
        name: "shake",
        description: "Trim heavy tool output from context (no LLM)",
        handler: handleShakeCommand
    ))
    registry.register(SlashCommand(
        name: "queue",
        description: "Show or clear the steering-message queue",
        handler: handleQueueCommand
    ))
    registry.register(SlashCommand(
        name: "thinking",
        description: "Show / set thinking level (off|minimal|low|medium|high|xhigh) or display (show|hide)",
        handler: handleThinkingCommand
    ))
    registry.register(SlashCommand(
        name: "verbose",
        description: "Toggle verbose provider/internal diagnostics",
        handler: handleVerboseCommand
    ))
    registry.register(SlashCommand(
        name: "context",
        description: "Show the context-window usage breakdown",
        handler: handleContextCommand
    ))
    registry.register(SlashCommand(
        name: "init",
        description: "Explore the repo and generate an AGENTS.md",
        handler: handleInitCommand
    ))
    registry.register(SlashCommand(
        name: "tools",
        description: "List the tools available to the agent",
        handler: handleToolsCommand
    ))
    registry.register(SlashCommand(
        name: "hotkeys",
        description: "Show the TUI keyboard shortcuts",
        aliases: ["keys"],
        handler: handleHotkeysCommand
    ))
    registry.register(SlashCommand(
        name: "copy",
        description: "Copy the last assistant reply to the clipboard",
        handler: handleCopyCommand
    ))
    registry.register(SlashCommand(
        name: "dump",
        description: "Copy the full transcript to the clipboard",
        handler: handleDumpCommand
    ))
    registry.register(SlashCommand(
        name: "rename",
        description: "Set a title for the current session",
        handler: handleRenameCommand
    ))
    registry.register(SlashCommand(
        name: "help",
        description: "List available slash commands",
        handler: { ctx, _ in
            var lines = [Style.dimmed("  available slash commands:")]
            for cmd in registry.all {
                var line = "    /\(cmd.name) — \(cmd.description)"
                if !cmd.aliases.isEmpty {
                    let aliasList = cmd.aliases.map { "/\($0)" }.joined(separator: ", ")
                    line += " (alias: \(aliasList))"
                }
                lines.append(Style.dimmed(line))
            }
            ctx.notifyBlock(lines)
        }
    ))
}

/// `/model` — opens a modal with every model the currently-authenticated
/// provider supports. Selection updates `agent.state.model` for the next
/// LLM request; the swap is session-scoped (restart = back to default).
///
/// Cross-provider switching (Codex → Anthropic or vice versa) needs a
/// second provider registered on APIRegistry at startup, which is out of
/// scope for V1.
@MainActor
private func handleModelCommand(_ ctx: SlashContext, _ args: String) async {
    let current = ctx.agent.state.model
    let agentProvider = current.provider
    let catalogKey = catalogProviderKey(forAgentProvider: agentProvider)

    let available = ModelsCatalog.models(for: catalogKey)
        .sorted { $0.id < $1.id }

    if available.isEmpty {
        ctx.notify(Style.error("  /model: no catalog entries for provider '\(agentProvider)'"))
        return
    }

    let modal = ModelSelectorModal(
        title: "Select a model  (provider: \(agentProvider))",
        models: available,
        currentModelId: current.id,
        onSelect: { [agent = ctx.agent, notifyBlock = ctx.notifyBlock, modal = ctx.modal] picked in
            let rebuilt = adoptFields(from: current, into: picked)
            agent.state.model = rebuilt
            modal.close()
            if picked.id == current.id {
                notifyBlock([Style.dimmed("  /model: already on \(picked.id)")])
            } else {
                notifyBlock([Style.dimmed("  /model: switched \(current.id) → \(picked.id)")])
            }
        },
        onCancel: { [modal = ctx.modal, notifyBlock = ctx.notifyBlock] in
            modal.close()
            notifyBlock([Style.dimmed("  /model: cancelled")])
        }
    )
    ctx.modal.open(modal)
}

/// Map an in-session agent `Model.provider` to the key used in
/// `ModelsCatalog.byProvider`. They're mostly identical except for Codex:
/// the chatgpt.com variant registers as `chatgpt-codex` on the agent side,
/// while the catalog lists its models under `openai-codex`.
/// Internal (not private) so regression tests can pin the mapping.
func catalogProviderKey(forAgentProvider provider: String) -> String {
    switch provider {
    case "chatgpt-codex": return "openai-codex"
    default: return provider
    }
}

/// Merge routing info from the current live session onto `picked`. Two
/// regimes:
///
///   - **Same provider** (`current.provider == picked.provider`): the
///     catalog entry already carries the correct wire api, baseUrl, and
///     headers — e.g. Copilot models vary per-model across
///     openai-completions / anthropic-messages / openai-responses, and
///     we registered all three variants at login. Just take `picked`
///     as-is.
///   - **Variant-routed provider** (Codex): catalog lists models under
///     `openai-codex` but we registered the live provider under the
///     variant key `chatgpt-codex`. Carry `current`'s routing across so
///     the first request after a switch doesn't hit the canonical
///     endpoint we never registered a token for. Also preserves the
///     Codex-specific `maxTokens == 0` sentinel (do not emit
///     `max_output_tokens`).
///
/// Internal (not private) so regression tests can pin the sentinel logic.
func adoptFields(from current: Model, into picked: Model) -> Model {
    if current.provider == picked.provider {
        // Same provider — adopt picked's identity, wire (api), and
        // capabilities, but keep the session's `baseUrl`. The session
        // baseUrl carries two things the catalog doesn't:
        //   - Enterprise / Business Copilot's proxy host (refreshed
        //     from the session token's `endpoints.api` claim)
        //   - A user-supplied custom host for `openai-compatible` or
        //     `anthropic-api-key` / `openai-api-key` logins
        // The catalog entry's `baseUrl` is the canonical upstream
        // (`https://api.openai.com/v1`, etc.), which can round-trip
        // into double-`/v1` when our providers append their own
        // suffix. Holding the session value is both correct and
        // defensive.
        return Model(
            id: picked.id,
            name: picked.name,
            api: picked.api,
            provider: picked.provider,
            baseUrl: current.baseUrl,
            reasoning: picked.reasoning,
            input: picked.input,
            cost: picked.cost,
            contextWindow: picked.contextWindow,
            maxTokens: picked.maxTokens,
            headers: picked.headers
        )
    }
    let resolvedMaxTokens = current.maxTokens == 0 ? 0 : picked.maxTokens
    return Model(
        id: picked.id,
        name: picked.name,
        api: current.api,
        provider: current.provider,
        baseUrl: current.baseUrl,
        reasoning: picked.reasoning,
        input: picked.input,
        cost: picked.cost,
        contextWindow: picked.contextWindow,
        maxTokens: resolvedMaxTokens,
        headers: current.headers
    )
}

// MARK: - /verbose

/// `/verbose` toggles verbose provider/internal diagnostics for subsequent
/// requests. `/verbose on|off|status` sets or reads the mode explicitly.
@MainActor
private func handleVerboseCommand(_ ctx: SlashContext, _ args: String) async {
    let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let previous = ctx.agent.state.verboseEnabled

    let next: Bool?
    switch trimmed {
    case "", "toggle":
        next = !previous
    case "on", "enable", "enabled", "true", "yes":
        next = true
    case "off", "disable", "disabled", "false", "no":
        next = false
    case "status":
        next = nil
    default:
        ctx.notify(Style.error("  /verbose: unknown arg '\(args)'. Try /verbose, /verbose on, /verbose off, or /verbose status"))
        return
    }

    if let next {
        ctx.agent.state.verboseEnabled = next
        if next == previous {
            ctx.notify(Style.dimmed("  /verbose: already \(next ? "on" : "off")"))
        } else {
            ctx.notify(Style.dimmed("  /verbose: \(previous ? "on" : "off") → \(next ? "on" : "off")"))
        }
    } else {
        ctx.notify(Style.dimmed("  /verbose: \(previous ? "on" : "off")"))
    }
}

// MARK: - /thinking

/// `/thinking` (no args) — show current level.
/// `/thinking off|minimal|low|medium|high|xhigh` — set it.
///
/// Extended thinking is auto-enabled at `.medium` on startup for
/// reasoning-capable models so users see `[thinking]` blocks without
/// flipping a switch. This command is the escape hatch: turn it off for
/// latency, crank to `.high` on thorny problems. No catalog-capability
/// check — providers that don't understand the level silently ignore it,
/// so the worst case is a no-op.
@MainActor
private func handleThinkingCommand(_ ctx: SlashContext, _ args: String) async {
    let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty {
        let level = ctx.agent.state.thinkingLevel
        let display = ctx.agent.state.thinkingDisplay
        let model = ctx.agent.state.model
        var lines = [Style.dimmed("  /thinking: level=\(level.rawValue)  display=\(display.rawValue)")]
        if level != .off && !model.reasoning {
            lines.append(Style.dimmed("    (current model \(model.id) is non-reasoning — level stored but won't be sent until `/model` switch)"))
        }
        lines.append(Style.dimmed("    level: off, minimal, low, medium, high, xhigh"))
        lines.append(Style.dimmed("    display: show, hide"))
        ctx.notifyBlock(lines)
        return
    }
    if let display = parseThinkingDisplay(trimmed) {
        let previous = ctx.agent.state.thinkingDisplay
        ctx.agent.state.thinkingDisplay = display
        if previous == display {
            ctx.notify(Style.dimmed("  /thinking: display already \(display.rawValue)"))
        } else {
            ctx.notify(Style.dimmed("  /thinking: display \(previous.rawValue) → \(display.rawValue)"))
            ctx.refreshTranscript()
        }
        return
    }
    guard let level = parseThinkingLevel(trimmed) else {
        ctx.notify(Style.error("  /thinking: unknown arg '\(args)'. Levels: off|minimal|low|medium|high|xhigh. Display: show|hide"))
        return
    }
    let previous = ctx.agent.state.thinkingLevel
    ctx.agent.state.thinkingLevel = level
    let model = ctx.agent.state.model
    var lines: [String] = []
    if previous == level {
        lines.append(Style.dimmed("  /thinking: already \(level.rawValue)"))
    } else {
        lines.append(Style.dimmed("  /thinking: \(previous.rawValue) → \(level.rawValue)"))
    }
    if level != .off && !model.reasoning {
        lines.append(Style.dimmed("    (current model \(model.id) is non-reasoning — level saved; will apply after `/model` to a reasoning-capable one)"))
    }
    ctx.notifyBlock(lines)
}

private func parseThinkingLevel(_ s: String) -> ThinkingLevel? {
    switch s {
    case "off": return .off
    case "minimal": return .minimal
    case "low": return .low
    case "medium", "med": return .medium
    case "high": return .high
    case "xhigh", "x-high", "max": return .xhigh
    default: return nil
    }
}

private func parseThinkingDisplay(_ s: String) -> ThinkingDisplay? {
    switch s {
    case "show", "expand", "expanded", "full": return .expanded
    case "hide", "collapse", "collapsed", "brief": return .collapsed
    default: return nil
    }
}

// MARK: - /queue

/// `/queue` (no args) — list any steering messages waiting to be injected
/// at the next turn boundary. Use `/queue clear` (or `/queue cancel`) to
/// drop them. Queued messages are created implicitly when the user hits
/// Enter while the agent is streaming or auto-compacting.
@MainActor
private func handleQueueCommand(_ ctx: SlashContext, _ args: String) async {
    let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch trimmed {
    case "clear", "cancel", "drop":
        let dropped = ctx.agent.queuedSteeringCount()
        if dropped == 0 {
            ctx.notify(Style.dimmed("  /queue: nothing queued"))
            return
        }
        ctx.agent.clearSteeringQueue()
        ctx.notify(Style.prompt("  /queue: cleared \(dropped) queued \(dropped == 1 ? "message" : "messages")"))
    case "":
        let messages = ctx.agent.queuedSteeringMessages()
        if messages.isEmpty {
            ctx.notify(Style.dimmed("  /queue: nothing queued"))
            return
        }
        var lines = [Style.dimmed("  /queue: \(messages.count) waiting for the next turn boundary")]
        for (i, msg) in messages.enumerated() {
            let body = previewQueuedMessage(msg)
            lines.append(Style.dimmed("    \(i + 1). \(body)"))
        }
        lines.append(Style.dimmed("    (use /queue clear to drop them)"))
        ctx.notifyBlock(lines)
    default:
        ctx.notify(Style.error("  /queue: unknown arg '\(args)'. Try /queue or /queue clear"))
    }
}

/// One-line preview of a queued message for the `/queue` listing.
/// Truncates long bodies and flattens multi-line text so the listing
/// stays tidy.
private func previewQueuedMessage(_ msg: Message, max: Int = 80) -> String {
    let raw: String = {
        switch msg {
        case .user(let u):
            return u.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: " ")
        default:
            return "(\(msg.role.rawValue) message)"
        }
    }()
    let flat = raw.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
}

// MARK: - /compact

/// `/compact` — thin wrapper around `performCompact` (see CompactRunner.swift)
/// that surfaces each outcome as a dimmed transcript notification. The
/// automatic path uses the same KWWKAgent compactor directly from `Agent`.
@MainActor
private func handleCompactCommand(_ ctx: SlashContext, _ args: String) async {
    let outcome = await performCompact(
        agent: ctx.agent,
        backgroundManager: ctx.backgroundManager,
        sessionId: ctx.sessionId
    )

    switch outcome {
    case .refusedAgentBusy:
        ctx.notify(Style.error("  /compact: agent is busy; stop it first (Esc)"))
    case .refusedTooFewMessages(let count):
        ctx.notify(Style.dimmed("  /compact: only \(count) message(s); nothing to compact"))
    case .compacted(let n, let hasLedger):
        // Show a compact record + durable boundary so the user can
        // scroll up later and see where the compact happened.
        await ctx.recordCompaction(n)
        ctx.notify(Style.dimmed("  /compact: summarizing \(n) messages…"))
        ctx.commitScrollback { width in
            renderCompactBoundary(
                messagesCompacted: n,
                hasRunningTasksLedger: hasLedger,
                width: width
            )
        }
    case .failed(let msg):
        ctx.notify(Style.error("  /compact: \(msg)"))
    }
}

// MARK: - /context

/// `/context` — a full breakdown of context-window usage. The one-line
/// header hint (`42% ctx`) only nudges; this command shows the window size,
/// tokens used with a visual bar, and the auto-compact threshold so the user
/// can decide whether to `/compact` before continuing.
@MainActor
private func handleContextCommand(_ ctx: SlashContext, _ args: String) async {
    let usage = AgentContextCompactor.currentUsage(
        messages: ctx.agent.state.messages,
        model: ctx.agent.state.model
    )
    guard usage.window > 0 else {
        ctx.notify(Style.dimmed("  /context: usage unavailable (no context window for \(ctx.agent.state.model.id))"))
        return
    }
    let pct = Int((usage.ratio * 100).rounded(.down))
    var lines = [
        Style.dimmed("  /context: \(usage.window) token window"),
        Style.dimmed("    " + renderContextBar(fraction: usage.ratio)),
        Style.dimmed("    \(usage.tokens) tokens used · \(pct)%"),
    ]
    if let threshold = ctx.agent.autoCompact?.threshold, threshold > 0 {
        let thresholdPct = Int((threshold * 100).rounded(.down))
        let headroom = max(0, Int(Double(usage.window) * threshold) - usage.tokens)
        lines.append(Style.dimmed("    auto-compact at \(thresholdPct)% · ~\(headroom) tokens of headroom"))
    }
    ctx.notifyBlock(lines)
}

// MARK: - /shake

/// `/shake` — a non-LLM context trim. Unlike `/compact` (which spends a
/// model round-trip to summarize the transcript), `/shake` just walks the
/// live conversation and collapses oversized tool-result output into a short
/// placeholder, reclaiming context window with no LLM call. Idempotent:
/// re-running skips results already collapsed.
///
/// LIMITATION: this trims the IN-MEMORY transcript only — it is not
/// re-persisted to the session file, so a later `/resume` reloads the
/// original tool output. That's acceptable for a "reclaim live context"
/// tool; the saving lands on the next request's prompt, not on disk.
///
/// The before→after token figures come from `currentUsage`, which reflects
/// the most recent *recorded* request, so the window number only moves on the
/// next turn after the trimmed messages are actually sent. The reclaimed-chars
/// line is the immediate, concrete win.
@MainActor
private func handleShakeCommand(_ ctx: SlashContext, _ args: String) async {
    let before = AgentContextCompactor.currentUsage(
        messages: ctx.agent.state.messages,
        model: ctx.agent.state.model
    )
    let beforeChars = toolResultTextChars(ctx.agent.state.messages)

    let result = AgentContextCompactor.shakeToolOutputs(ctx.agent.state.messages)
    if result.elidedCount == 0 {
        ctx.notify(Style.dimmed("  /shake: nothing to trim"))
        return
    }

    ctx.agent.state.messages = result.messages
    ctx.refreshTranscript()

    let after = AgentContextCompactor.currentUsage(
        messages: ctx.agent.state.messages,
        model: ctx.agent.state.model
    )
    let afterChars = toolResultTextChars(result.messages)
    let reclaimed = max(0, beforeChars - afterChars)

    let n = result.elidedCount
    var lines = [
        Style.dimmed("  /shake: elided \(n) heavy tool \(n == 1 ? "result" : "results") (no LLM)"),
        Style.dimmed("    reclaimed ~\(reclaimed) chars of tool output"),
    ]
    if before.window > 0 {
        lines.append(Style.dimmed("    context: \(before.tokens) → \(after.tokens) tokens of \(before.window) (refreshes next turn)"))
    }
    lines.append(Style.dimmed("    (in-memory only — /resume reloads the original output)"))
    ctx.notifyBlock(lines)
}

/// Total character count of every `.text` block across all tool-result
/// messages — the bulk `/shake` reclaims. Used to report a concrete savings.
private func toolResultTextChars(_ messages: [Message]) -> Int {
    messages.reduce(0) { total, message in
        guard case .toolResult(let result) = message else { return total }
        return total + result.content.reduce(0) { sub, block in
            if case .text(let text) = block { return sub + text.text.count }
            return sub
        }
    }
}

// MARK: - /init

/// Canned prompt body for `/init`. Ported from omp's `prompts/agents/init.md`,
/// trimmed to kwwk's toolset: the explorer fan-out goes through the `agent`
/// tool's `explore` subagents instead of omp's `task`/`explore` naming.
private let initPromptBody = """
Generate an AGENTS.md for this repository. Launch several `explore` subagents \
in parallel (via the `agent` tool) to scan different areas — core source, \
tests, build/config, and scripts/docs — then synthesize their findings into a \
single file written to the project root as AGENTS.md.

Structure the document with Markdown headings:
- Project Overview: what the project is for.
- Architecture & Data Flow: high-level structure, key modules, how data moves.
- Key Directories: the main source directories and their purpose.
- Development Commands: build, test, lint, and run commands.
- Code Conventions & Common Patterns: formatting, naming, error handling, \
async patterns, state management.
- Important Files: entry points, config files, key modules.
- Testing & QA: test frameworks, how to run them, coverage expectations.

Requirements:
- Title the document "Repository Guidelines".
- Be concise and practical; focus on what an AI assistant needs to help with \
this codebase.
- Include concrete commands and file paths where helpful.
- Call out architecture and code patterns explicitly.
- Omit information that is obvious from the code structure.

After your analysis, write the result to AGENTS.md at the project root.
"""

/// `/init` — kick off a repo-exploration turn that writes an AGENTS.md. kwwk
/// already injects AGENTS.md / CLAUDE.md into the system prompt, so generating
/// the file improves every later session. Submits the canned prompt on the
/// same fire-and-forget path custom slash commands use.
@MainActor
private func handleInitCommand(_ ctx: SlashContext, _ args: String) async {
    let agent = ctx.agent
    ctx.notify(Style.dimmed("  /init: exploring the repo to generate AGENTS.md…"))
    Task.detached {
        try? await agent.prompt(initPromptBody)
    }
}

// MARK: - /tools

/// `/tools` — list the tools the agent can call this session. Read-only;
/// pairs with `/hotkeys` for in-session discoverability.
@MainActor
private func handleToolsCommand(_ ctx: SlashContext, _ args: String) async {
    let tools = ctx.agent.state.tools.sorted { $0.name < $1.name }
    guard !tools.isEmpty else {
        ctx.notify(Style.dimmed("  /tools: no tools registered for this session"))
        return
    }
    var lines = [Style.dimmed("  /tools: \(tools.count) available")]
    for tool in tools {
        let summary = toolSummaryLine(tool.description)
        if summary.isEmpty {
            lines.append(Style.dimmed("    \(tool.name)"))
        } else {
            lines.append(Style.dimmed("    \(tool.name) — \(summary)"))
        }
    }
    ctx.notifyBlock(lines)
}

/// First non-empty line of a tool description, clipped so the listing stays
/// one row per tool.
private func toolSummaryLine(_ description: String, max: Int = 72) -> String {
    let first = description
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    return first.count <= max ? first : String(first.prefix(max)) + "…"
}

// MARK: - /hotkeys

/// `/hotkeys` — a static reference for the TUI's keyboard bindings. The
/// redesign added keys (slash popup, Alt+↑ dequeue) with no in-session way to
/// learn them; this surfaces them. Read-only.
@MainActor
private func handleHotkeysCommand(_ ctx: SlashContext, _ args: String) async {
    let rows: [(String, String)] = [
        ("Enter", "submit prompt / run highlighted slash command"),
        ("Tab", "complete the slash command under the cursor"),
        ("↑ / ↓", "recall prompt history · move in popups"),
        ("Alt/Option+↑", "pop a queued prompt back into the input to edit"),
        ("Esc", "stop the agent (and close an open popup/modal)"),
        ("Ctrl+L", "repaint the screen"),
        ("Ctrl+C", "exit"),
        ("Ctrl+D", "exit when the input is empty"),
    ]
    var lines = [Style.dimmed("  /hotkeys:")]
    let pad = rows.map { $0.0.count }.max() ?? 0
    for (key, desc) in rows {
        let padded = key.padding(toLength: pad, withPad: " ", startingAt: 0)
        lines.append(Style.dimmed("    \(padded)  \(desc)"))
    }
    ctx.notifyBlock(lines)
}

// MARK: - /copy, /dump

/// `/copy` — put the last assistant reply on the clipboard (plain text, ANSI
/// stripped). Defers omp's interactive selector; the no-arg default covers the
/// common case.
@MainActor
private func handleCopyCommand(_ ctx: SlashContext, _ args: String) async {
    guard let text = lastAssistantText(ctx.agent.state.messages), !text.isEmpty else {
        ctx.notify(Style.dimmed("  /copy: no assistant message to copy yet"))
        return
    }
    let outcome = ClipboardWriter.copy(text)
    ctx.notify(Style.dimmed("  /copy: copied last reply (\(text.count) chars)\(clipboardVia(outcome))"))
}

/// `/dump` — put the whole transcript on the clipboard as plain text.
@MainActor
private func handleDumpCommand(_ ctx: SlashContext, _ args: String) async {
    let rendered = TranscriptSnapshot.render(ctx.agent.state.messages, width: 100)
    let plain = rendered.map { ANSI.stripEscapes($0) }.joined(separator: "\n")
    let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        ctx.notify(Style.dimmed("  /dump: transcript is empty"))
        return
    }
    let outcome = ClipboardWriter.copy(trimmed)
    ctx.notify(Style.dimmed("  /dump: copied transcript (\(trimmed.count) chars)\(clipboardVia(outcome))"))
}

/// Trailing " · via OSC 52" note when the write didn't go through the native
/// pasteboard, so a user on a remote box knows the escape was emitted.
private func clipboardVia(_ outcome: ClipboardWriter.Outcome) -> String {
    outcome == .osc52 ? " · via OSC 52" : ""
}

/// Plain text of the most recent assistant message (its text blocks joined).
/// Internal (not private) so tests can pin exactly what `/copy` selects.
func lastAssistantText(_ messages: [Message]) -> String? {
    for message in messages.reversed() {
        if case .assistant(let a) = message {
            let text = a.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: "\n")
            return text
        }
    }
    return nil
}

// MARK: - /rename

/// `/rename <title>` — set a human-friendly title for the current session.
/// The title is persisted as an append-only `meta` entry and surfaces in the
/// `/resume` picker. `/rename` with no argument reports the requirement.
@MainActor
private func handleRenameCommand(_ ctx: SlashContext, _ args: String) async {
    let title = args.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
        ctx.notify(Style.error("  /rename: usage: /rename <title>"))
        return
    }
    await ctx.setSessionTitle(title)
    ctx.notify(Style.dimmed("  /rename: session titled “\(title)”"))
}
