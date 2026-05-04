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
        name: "help",
        description: "List available slash commands",
        handler: { ctx, _ in
            var lines = [Style.dimmed("  available slash commands:")]
            for cmd in registry.all {
                lines.append(Style.dimmed("    /\(cmd.name) — \(cmd.description)"))
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
