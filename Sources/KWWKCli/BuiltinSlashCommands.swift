import Foundation
import KWWKAI
import KWWKAgent

/// Register the V1 set of builtin slash commands on `registry`. Keep these
/// focused on things a user actually needs mid-session — including `/login`,
/// which is the only way to add a provider (there is no standalone login
/// subcommand).
@MainActor
func registerBuiltinSlashCommands(_ registry: SlashCommandRegistry) {
    registry.register(SlashCommand(
        name: "model",
        description: "Pick a model for this session (across all logged-in providers)",
        handler: handleModelCommand
    ))
    registry.register(SlashCommand(
        name: "login",
        description: "Log in to another provider (kept alongside existing logins)",
        handler: handleLoginCommand
    ))
    registry.register(SlashCommand(
        name: "logout",
        description: "Show logged-in providers / remove one",
        handler: handleLogoutCommand
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

/// `/model` — opens a modal listing every model across **all** providers
/// logged in this session (grouped by provider), and switches to the picked
/// one. The pick is routed through the target provider's session template
/// (`adoptFields`) so its wire api / provider scope / baseUrl / headers are
/// correct, then stored on `agent.state.model` for the next request. The swap
/// is session-scoped (restart = back to the launch default).
@MainActor
private func handleModelCommand(_ ctx: SlashContext, _ args: String) async {
    let current = ctx.agent.state.model
    let slots = ctx.sessionProviders.slots

    // Logged-out session (sentinel model, no slots): the fallback below would
    // list nothing useful — point at /login instead. The extra
    // `current.provider.isEmpty` clause keeps the headless/test fallback
    // below alive: a REAL model with no session slots (isLoggedOut, but not
    // the sentinel) still gets its own provider's catalog listed.
    if ctx.sessionProviders.isLoggedOut && current.provider.isEmpty {
        ctx.notify(Style.dimmed("  /model: no provider configured — /login to sign in"))
        return
    }

    // Build a flat, provider-grouped list of routed models. Each entry carries
    // a model already stamped with its provider's routing (via `adoptFields`),
    // so selection is a straight assignment.
    var models: [Model] = []
    var groups: [String] = []
    var currentIndex: Int?

    let slotList: [ProviderSlot] = slots.isEmpty
        // No session slots (e.g. a test/headless path): fall back to the
        // active provider's own catalog so `/model` still works.
        ? [ProviderSlot(
            storeId: current.provider,
            catalogProvider: catalogProviderKey(forAgentProvider: current.provider),
            displayName: current.provider,
            template: current)]
        : slots

    for slot in slotList {
        let catalog = ModelsCatalog.models(for: slot.catalogProvider)
            .sorted { $0.id < $1.id }
        // Providers whose active model isn't catalogued (custom openai-compatible
        // endpoints) still get their template as a selectable row.
        let base = catalog.isEmpty ? [slot.template] : catalog
        for m in base {
            let routed = adoptFields(from: slot.template, into: m)
            if routed.provider == current.provider && routed.id == current.id {
                currentIndex = models.count
            }
            models.append(routed)
            groups.append(slot.displayName)
        }
    }

    if models.isEmpty {
        ctx.notify(Style.error("  /model: no models available for the logged-in providers"))
        return
    }

    let multi = slotList.count > 1
    let title = multi ? "Select a model  (\(slotList.count) providers)" : "Select a model"
    let modal = ModelSelectorModal(
        title: title,
        models: models,
        currentModelId: current.id,
        groupLabels: multi ? groups : nil,
        currentIndex: currentIndex,
        onSelect: { [agent = ctx.agent, notifyBlock = ctx.notifyBlock, modal = ctx.modal] picked in
            let previous = agent.state.model
            agent.state.model = picked
            modal.close()
            let switchedProvider = picked.provider != previous.provider
            if picked.id == previous.id && !switchedProvider {
                notifyBlock([Style.dimmed("  /model: already on \(picked.id)")])
            } else if switchedProvider {
                notifyBlock([Style.dimmed("  /model: switched to \(picked.id) · \(ProviderAttribution.getProviderDisplayName(picked.provider))")])
            } else {
                notifyBlock([Style.dimmed("  /model: switched \(previous.id) → \(picked.id)")])
            }
        },
        onCancel: { [modal = ctx.modal, notifyBlock = ctx.notifyBlock] in
            modal.close()
            notifyBlock([Style.dimmed("  /model: cancelled")])
        }
    )
    ctx.modal.open(modal)
}

// MARK: - /login  ·  /logout

/// Captures the result of the suspended OAuth sub-flow (the `withSuspendedTUI`
/// body returns Void, so we thread the outcome through a box).
@MainActor
private final class LoginResultBox {
    var storeId: String?
    var error: String?
}

/// `/login` — opens the provider picker as a modal (same look and feel as
/// `/model`). Picking an API-key entry opens a `FormModal` in place, so the
/// whole credential flow stays inside the live TUI; picking an OAuth entry
/// closes the modal and suspends the TUI for the browser handoff (which
/// needs a cooked terminal for its stderr progress + Esc/Ctrl-C watcher).
/// Successful logins are additive — existing providers stay registered and
/// the fresh one becomes available to `/model` without a restart. A
/// logged-out session activates the new provider as the live model.
@MainActor
private func handleLoginCommand(_ ctx: SlashContext, _ args: String) async {
    guard let authResolvers = ctx.authResolvers else {
        ctx.notify(Style.error("  /login: not available in this session"))
        return
    }
    let picker = ListSelectorModal(
        title: "Log in to a provider",
        items: loginProviders.map { ListSelectorModal.Item(label: $0.display) },
        onSelect: { [modal = ctx.modal] index in
            let entry = loginProviders[index]
            switch entry.flow {
            case .oauth:
                modal.close()
                Task { @MainActor in
                    await runOAuthLoginSuspended(
                        providerId: entry.id, ctx: ctx, authResolvers: authResolvers
                    )
                }
            case .apiKey(let fields, let extrasKeys):
                let storeId = entry.id
                // Replace the picker with the credential form (ModalHost.open
                // swaps the active modal in place).
                modal.open(FormModal(
                    title: loginFormTitle(for: entry),
                    fields: fields,
                    onSubmit: { values in
                        modal.close()
                        Task { @MainActor in
                            await completeAPIKeyLogin(
                                values: values,
                                storeId: storeId,
                                extrasKeys: extrasKeys,
                                ctx: ctx,
                                authResolvers: authResolvers,
                                store: OAuthStore(url: OAuthStore.defaultURL())
                            )
                        }
                    },
                    onCancel: {
                        modal.close()
                        ctx.notify(Style.dimmed("  /login: login cancelled"))
                    }
                ))
            }
        },
        onCancel: { [modal = ctx.modal] in
            modal.close()
            ctx.notify(Style.dimmed("  /login: login cancelled"))
        }
    )
    ctx.modal.open(picker)
}

/// OAuth leg of `/login`: suspend the TUI, run the browser flow (which
/// persists credentials itself), then register the fresh provider live.
@MainActor
private func runOAuthLoginSuspended(
    providerId: String,
    ctx: SlashContext,
    authResolvers: SessionAuthResolvers
) async {
    let box = LoginResultBox()
    await ctx.withSuspendedTUI {
        do {
            try await runOAuthFlow(providerId: providerId)
            box.storeId = providerId
        } catch {
            box.error = error.localizedDescription
        }
    }
    if let err = box.error {
        // `.cancelled` (Esc) lands here too — a gentle note, not an error.
        ctx.notify(Style.dimmed("  /login: \(err)"))
        return
    }
    guard let storeId = box.storeId else { return }
    await activateFreshLogin(storeId: storeId, ctx: ctx, authResolvers: authResolvers)
}

/// API-key leg of `/login`: pack the submitted form values into sentinel
/// credentials, persist them (no stdout — the TUI is live; confirmation goes
/// through `ctx.notify`), then register the fresh provider live. `store` is
/// injectable so tests can point it at a temp file instead of the user's
/// real `~/.kwwk/oauth.json`.
@MainActor
func completeAPIKeyLogin(
    values: [String: String],
    storeId: String,
    extrasKeys: [String],
    ctx: SlashContext,
    authResolvers: SessionAuthResolvers,
    store: OAuthStore
) async {
    guard let credentials = apiKeyCredentials(values: values, extrasKeys: extrasKeys) else {
        ctx.notify(Style.error("  /login: API key required"))
        return
    }
    let saved: SavedLogin
    do {
        saved = try await saveCredentials(credentials, providerId: storeId, store: store)
    } catch {
        ctx.notify(Style.error("  /login: couldn't save credentials: \(error.localizedDescription)"))
        return
    }
    var lines = [Style.dimmed("  /login: saved \(storeId) credentials → \(saved.path)")]
    if !saved.otherProviderIds.isEmpty {
        lines.append(Style.dimmed("    (also logged in: \(saved.otherProviderIds.joined(separator: ", ")))"))
    }
    ctx.notifyBlock(lines)
    await activateFreshLogin(storeId: storeId, ctx: ctx, authResolvers: authResolvers, store: store)
}

/// Shared post-login registration for both `/login` legs: same-scope dedup,
/// live registration, session-slot upsert, and — when this is the first
/// provider of a logged-out session — activation of the fresh provider as
/// the live model so the user can prompt immediately.
@MainActor
func activateFreshLogin(
    storeId: String,
    ctx: SlashContext,
    authResolvers: SessionAuthResolvers,
    store: OAuthStore? = nil
) async {
    // Same-scope dedup, mirroring launch-time registerAllStored: two store ids
    // can share one wire scope (Anthropic OAuth + Anthropic API key both →
    // `anthropic`). Don't let a second same-scope login clobber the active
    // provider's registration/resolver this session. The credentials are still
    // saved on disk; priority order decides on the next launch.
    // Compare against each incumbent slot's ACTUAL registered scope
    // (template.provider), not one re-derived from its storeId: an
    // env-authenticated incumbent has storeId "env:<provider>" for which
    // modelProviderScope has no case, but its template.provider is the real
    // wire scope — so deriving from storeId would miss the collision.
    let newScope = modelProviderScope(forStoreId: storeId)
    if let existing = ctx.sessionProviders.slots.first(where: {
        $0.storeId != storeId && $0.template.provider == newScope
    }) {
        ctx.notify(Style.dimmed(
            "  /login: saved \(storeId), but it shares a provider slot with the active \(existing.storeId) — /logout \(existing.storeId) first to use it"
        ))
        return
    }
    guard let slot = await registerStoredProviderLive(
        storeId: storeId, authResolvers: authResolvers, context1m: ctx.context1m, store: store
    ) else {
        ctx.notify(Style.error("  /login: '\(storeId)' logged in but couldn't be activated"))
        return
    }
    let wasLoggedOut = ctx.sessionProviders.slots.isEmpty
    ctx.sessionProviders.upsert(slot)
    if wasLoggedOut {
        // First login of a logged-out session: replace the sentinel model so
        // the user can prompt without an extra /model trip.
        ctx.agent.state.model = slot.template
        ctx.notify(Style.dimmed("  /login: \(slot.displayName) ready — now on \(slot.template.id)"))
    } else {
        ctx.notify(Style.dimmed("  /login: \(slot.displayName) ready — /model to switch to it"))
    }
}

/// `/logout` — with no argument lists the logged-in providers; with a provider
/// id removes that login (from disk + this session's routing). Falls back to
/// another logged-in provider if the active one is removed, or back to the
/// logged-out sentinel state when the last provider goes.
@MainActor
private func handleLogoutCommand(_ ctx: SlashContext, _ args: String) async {
    await performLogout(ctx, args, store: OAuthStore(url: OAuthStore.defaultURL()))
}

/// `/logout` body with the credential store injected, so tests can drive it
/// against a temp file instead of the user's real `~/.kwwk/oauth.json`.
@MainActor
func performLogout(_ ctx: SlashContext, _ args: String, store: OAuthStore) async {
    let target = args.trimmingCharacters(in: .whitespacesAndNewlines)
    let all = await store.all()
    if all.isEmpty {
        ctx.notify(Style.dimmed("  /logout: no stored logins (running on env keys or none)"))
        return
    }
    let ids = storedProviderOrder(all)

    if target.isEmpty {
        var lines = [Style.dimmed("  logged-in providers:")]
        for id in ids {
            let isActive = ctx.agent.state.model.provider == modelProviderScope(forStoreId: id)
            let tag = isActive ? Style.dimmed("  · active") : ""
            lines.append("    " + id + "  " + Style.dimmed(providerDisplayName(forStoreId: id)) + tag)
        }
        lines.append(Style.dimmed("  /logout <provider> to remove one"))
        ctx.notifyBlock(lines)
        return
    }

    guard ids.contains(target) else {
        ctx.notify(Style.error("  /logout: '\(target)' is not logged in — run /logout to list"))
        return
    }

    let scope = modelProviderScope(forStoreId: target)
    // Only the store id that actually OWNS this session's slot for the scope
    // may tear down the scope's live registration. A shadowed same-scope login
    // (e.g. logging out `anthropic-api-key` while `anthropic` OAuth owns the
    // `anthropic` scope) was never registered — removing it from disk is
    // enough; touching the scope would wrongly unregister the active provider.
    let ownsSlot = ctx.sessionProviders.slot(forStoreId: target) != nil
    try? await store.remove(target)

    guard ownsSlot else {
        ctx.notify(Style.dimmed("  /logout: removed \(target) (was shadowed by a same-vendor login)"))
        return
    }

    await APIRegistry.shared.unregisterScope(scope)
    if let ar = ctx.authResolvers { await ar.remove(scope: scope) }
    ctx.sessionProviders.remove(storeId: target)

    // If the removed provider was the one in use, switch to a survivor so the
    // next request doesn't hit a now-unregistered provider. (A same-vendor
    // login still on disk isn't re-homed this session — it's available on the
    // next launch, where priority order re-registers it.) With no survivor
    // the session returns to the logged-out sentinel state: prompt submission
    // and /model are gated on the empty slot list, and the next /login
    // re-activates a live model.
    if ctx.agent.state.model.provider == scope {
        if let next = ctx.sessionProviders.slots.first {
            ctx.agent.state.model = next.template
            ctx.notify(Style.dimmed("  /logout: removed \(target); now on \(next.template.id) · \(next.displayName)"))
        } else {
            ctx.agent.state.model = loggedOutModel
            ctx.notify(Style.dimmed("  /logout: removed \(target) — no providers left; /login to sign in"))
        }
    } else {
        ctx.notify(Style.dimmed("  /logout: removed \(target)"))
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
            headers: picked.headers,
            compat: picked.compat,
            thinkingLevelMap: picked.thinkingLevelMap
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
        headers: current.headers,
        compat: picked.compat,
        thinkingLevelMap: picked.thinkingLevelMap
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
        ("Tab / ← / →", "switch the provider tab in /model"),
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
