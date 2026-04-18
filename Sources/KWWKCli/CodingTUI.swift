import Foundation
import KWWKAI
import KWWKAgent

/// Internal implementation of the coding-agent TUI. Public entry points
/// live on `KWWK` (see KWWK.swift) and resolve credentials before calling
/// in here. `@MainActor` because `TranscriptRenderer`, `CodingStatusBar`,
/// and the TUI layout mutate main-thread-only state.
@MainActor
func runCodingTUIInternal(
    model: Model,
    modelLabel: String,
    cwd: String,
    tools: CodingTools,
    apiKeyResolver: (@Sendable (String) async -> String?)? = nil,
    autoCompactThreshold: Double? = 0.75
) async throws {
    // --- agent + background manager -------------------------------------
    let bgManager = BackgroundTaskManager()
    let sessionId = UUID().uuidString
    let agent = await makeCodingAgent(CodingAgentConfig(
        model: model,
        cwd: cwd,
        tools: tools,
        backgroundManager: bgManager,
        sessionId: sessionId
    ))
    // Wire the OAuth resolver (Codex) so access tokens refresh on every
    // stream request. Nil for static api-key providers like Anthropic.
    if let apiKeyResolver {
        agent.apiKeyResolver = apiKeyResolver
    }

    // --- TUI (shared layout) --------------------------------------------
    // Inline render mode — the frame anchors at the current cursor and
    // preserves the user's shell scrollback above it (the Claude Code
    // behavior). Pass `useAlternateScreen: true` if you want a blank
    // fullscreen buffer instead.
    let runner = TUIRunner(useAlternateScreen: false, hideCursor: false)
    let layout = CodingLayout(statusRows: 1)
    let renderer = TranscriptRenderer()

    // Header is rebuilt whenever the context-usage reading changes, so
    // the capacity suffix stays fresh. As a captured closure (not a
    // local `func`) so the auto-compact callback can be @Sendable.
    let cwdShort = shortenPath(cwd, to: max(20, runner.terminal.width - 4))
    let renderHeader: @MainActor @Sendable (String) -> Void = { capacityHint in
        var modelLine = "  \(modelLabel)"
        if !capacityHint.isEmpty {
            modelLine += "  \(capacityHint)"
        }
        layout.header.lines = [
            Style.header("✻ kwwk coding agent"),
            Style.dimmed(modelLine),
            Style.dimmed("  \(cwdShort)"),
        ]
    }
    renderHeader("")
    layout.install(into: runner.tui)
    layout.fitViewport(height: runner.terminal.height)
    runner.focus(layout.promptRow)
    _ = runner.terminal.onResize { _, h in
        Task { @MainActor in
            layout.fitViewport(height: h)
            runner.tui.requestRender()
        }
    }

    // Non-LLM messages the coding TUI wants to surface to the user
    // ("switched to gpt-5.4", "unknown slash command /foo", etc.). These
    // ride along with the transcript so they stay visible as the view
    // scrolls.
    let notifications = NotificationLog()
    // `recomputeTranscript` is a captured @Sendable closure (not a local
    // `func`) so it can be passed into the agent's `subscribe` callback
    // and into ModalHost without Swift 6's strict-concurrency checker
    // complaining about non-Sendable function references.
    let recomputeTranscript: @MainActor @Sendable () -> Void = {
        layout.setTranscript(renderer.lines.all + notifications.all)
    }

    // Modal overlay host — takes over the transcript area for selectors
    // (/model). Only one modal is active at a time; its bindings are
    // wired below via `modal.routeXxx`.
    let modal = ModalHost(
        layout: layout,
        restoreTranscript: recomputeTranscript,
        requestRender: { runner.tui.requestRender() }
    )

    // Queue panel: a persistent listing of steering messages waiting
    // for a turn boundary, rendered between the status bar and the
    // prompt. Rebuilt from `agent.queuedSteeringMessages()` whenever
    // something might have changed the queue:
    //   - Enter handler after an implicit steer.
    //   - `/queue clear` outcome.
    //   - Every agent event (turn boundaries drain the queue).
    //   - The 500ms poll tick already used by the status bar.
    //
    // The panel collapses to zero rows when empty, so the transcript
    // reclaims the space — no wasted real estate when idle.
    let refreshQueuePanel: @MainActor @Sendable () -> Void = {
        let messages = agent.queuedSteeringMessages()
        if messages.isEmpty {
            layout.setQueueLines([])
            return
        }
        var lines: [String] = [
            Style.dimmed("  ↓ \(messages.count) queued \(messages.count == 1 ? "prompt" : "prompts"):")
        ]
        for (i, msg) in messages.enumerated() {
            let preview = previewQueuedMessageLine(msg)
            lines.append(Style.dimmed("    \(i + 1). \(preview)"))
        }
        layout.setQueueLines(lines)
    }
    refreshQueuePanel()

    let statusBar = CodingStatusBar(
        layout: layout,
        runner: runner,
        agent: agent,
        bgManager: bgManager,
        sessionId: sessionId
    )
    await statusBar.render()

    // Auto-compact controller. Watches per-turn usage and summarizes
    // the transcript when it approaches the model's contextWindow.
    // The controller fires `performCompact` only on `agentEnd` so we
    // never rewrite `agent.state.messages` while the loop is mid-flight.
    let autoCompact = AutoCompactController(
        agent: agent,
        backgroundManager: bgManager,
        sessionId: sessionId,
        threshold: autoCompactThreshold,
        onStatusChange: { status in
            switch status {
            case .compacting(let count):
                statusBar.setCompacting(messageCount: count)
                notifications.append(Style.dimmed("  auto-compact: summarizing \(count) messages…"))
                if !modal.isOpen { recomputeTranscript() }
                runner.tui.requestRender()
            case .idle:
                statusBar.setMode(.idle)
            }
        },
        onUsageChange: { usage in
            renderHeader(formatCapacityHint(
                usage: usage,
                threshold: autoCompactThreshold
            ))
            runner.tui.requestRender()
        },
        onCompactFinished: { outcome in
            // Surface outcome as a transcript notification. The
            // `notifications` log is cleared on the next Enter so the
            // "compacted N → 1 recap" line doesn't stick around forever.
            switch outcome {
            case .compacted(let n, let hasLedger):
                var note = "  auto-compact: compacted \(n) messages → 1 recap"
                if hasLedger { note += " (+ running-task ledger)" }
                notifications.append(Style.prompt(note))
            case .refusedAgentBusy:
                // Can't happen: we only enter maybeCompact on agentEnd
                // and the guard in `performCompact` is belt-and-braces.
                break
            case .refusedTooFewMessages:
                break  // never surface for the auto path
            case .failed(let msg):
                notifications.append(Style.error("  auto-compact: \(msg)"))
            }
            if !modal.isOpen { recomputeTranscript() }
            runner.tui.requestRender()
        }
    )

    _ = agent.subscribe { event, _ in
        await MainActor.run {
            renderer.apply(event)
            // Don't clobber an open modal. When it closes, the host's
            // restoreTranscript hook runs `recomputeTranscript()` so any
            // state that accumulated during the modal pops back into view.
            if !modal.isOpen {
                recomputeTranscript()
            }
            switch event {
            case .agentStart:
                statusBar.setMode(.streaming)
            case .agentEnd:
                // Only flip to idle when no auto-compact took over.
                // `observe(event:)` below runs synchronously-enough that
                // its status-change callback beats this switch, so if
                // a compact is about to fire the bar will read
                // "auto-compacting…" on the next render.
                if !autoCompact.isCompacting {
                    statusBar.setMode(.idle)
                }
            default: break
            }
            // The agent loop drains the steering queue at turn
            // boundaries — refresh the panel on every event so a
            // queued prompt disappears as soon as it enters context.
            refreshQueuePanel()
            layout.fitViewport(height: runner.terminal.height)
            runner.tui.requestRender()
        }
        await autoCompact.observe(event)
        await statusBar.render()
    }

    // Slash command registry. Handlers get a `SlashContext` with the
    // agent + modal host + a `notify` hook that prints a dimmed line into
    // the transcript.
    let slashRegistry = SlashCommandRegistry()
    registerBuiltinSlashCommands(slashRegistry)
    let slashContext = SlashContext(
        agent: agent,
        modal: modal,
        backgroundManager: bgManager,
        sessionId: sessionId,
        notify: { line in
            notifications.append(line)
            if !modal.isOpen { recomputeTranscript() }
            runner.tui.requestRender()
        }
    )

    // --- keybindings ----------------------------------------------------

    // Enter. Four modes of operation:
    //   1. modal open → forward to modal's confirm handler.
    //   2. input starts with `/` → slash command dispatch.
    //   3. LLM prompt while the agent is idle → submit.
    //   4. LLM prompt while the agent is streaming → steer as a user
    //      message so it runs at the next turn boundary. We do NOT
    //      drop the typed text: starting a second agent.prompt while
    //      the first is streaming would throw `alreadyRunning` and
    //      blow the input away. Steering lets the user queue a
    //      follow-up without racing the current turn.
    runner.bind(.init("enter")) { _ in
        Task { @MainActor in
            if modal.isOpen {
                modal.routeConfirm()
                return
            }
            let text = layout.input.value
            guard !text.isEmpty else { return }

            let parsed = SlashInput.parse(text)

            // Slash commands always work, even while streaming or
            // auto-compacting, because they don't call `agent.prompt`.
            // For LLM prompts we check state first so we can steer
            // instead of racing the current turn / the pending
            // message-array replacement. The queue panel above the
            // input (see `refreshQueuePanel`) shows what's waiting —
            // no transcript notification needed since the panel is
            // persistent until the message drains.
            if case .prompt = parsed, agent.state.isStreaming || autoCompact.isCompacting {
                agent.steer(.user(UserMessage(content: [.text(TextContent(text: text))])))
                layout.input.value = ""
                refreshQueuePanel()
                runner.tui.requestRender()
                return
            }

            layout.input.value = ""
            // Each non-empty Enter starts a fresh action — expire the
            // notifications from the previous one (e.g. stale `/help`
            // output, `/model: cancelled` crumbs) so they don't pile up
            // forever below the transcript.
            notifications.clear()
            recomputeTranscript()
            runner.tui.requestRender()

            switch parsed {
            case .command(let name, let args):
                if let cmd = slashRegistry.find(name) {
                    await cmd.handler(slashContext, args)
                    // `/queue clear` (and maybe future commands) may
                    // mutate the steering queue — refresh so the
                    // panel above the input stays accurate.
                    refreshQueuePanel()
                    runner.tui.requestRender()
                } else {
                    notifications.append(Style.error("  unknown slash command: /\(name)"))
                    recomputeTranscript()
                    runner.tui.requestRender()
                }
            case .prompt(let body):
                Task.detached {
                    do {
                        try await agent.prompt(body)
                    } catch {
                        await MainActor.run {
                            layout.status.lines = [Style.error("error: \(error)")]
                            runner.tui.requestRender()
                        }
                    }
                }
            }
        }
    }

    // Arrow keys — only have meaning inside a modal (move selection).
    // Outside a modal they're no-ops, which matches pi-mono's behavior
    // (we don't have a scrollback feature yet).
    runner.bind(.init("up"))   { _ in Task { @MainActor in modal.routeUp() } }
    runner.bind(.init("down")) { _ in Task { @MainActor in modal.routeDown() } }

    // Ctrl-C: always exits (single tap). Keep it as the hard-stop key so
    // there's always a predictable way out.
    runner.bind(.ctrl("c")) { _ in
        Task { @MainActor in
            await agent.abortAndKillBackgroundTasks()
            runner.exit()
        }
    }

    // Esc. Three modes of operation:
    //   1. modal open → cancel the modal (no agent state touched).
    //   2. agent streaming → abort the current generation.
    //   3. idle AND background tasks running → kill them all.
    //   4. idle, no bg tasks → no-op (Ctrl-C is the only way out).
    runner.bind(.init("escape")) { _ in
        Task { @MainActor in
            if modal.isOpen {
                modal.routeCancel()
                return
            }
            if agent.state.isStreaming {
                agent.abort()
                statusBar.setMode(.aborting)
                await statusBar.render()
                return
            }
            let running = await bgManager.list(sessionId: sessionId)
                .filter { $0.status == .running }.count
            if running > 0 {
                await bgManager.killAll(sessionId: sessionId)
                statusBar.flashKilled(count: running)
                await statusBar.render()
            }
            // No bg tasks, nothing streaming → Esc does nothing. The
            // user exits via Ctrl-C.
        }
    }

    // Periodic refresh so the background-task count + queue panel stay
    // live even when there aren't any agent events firing. 500ms is
    // invisibly slow for a human but cheap — just an actor dict count
    // and a queue snapshot.
    let pollTask = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await statusBar.render()
            await MainActor.run { refreshQueuePanel() }
        }
    }
    defer { pollTask.cancel() }

    try await runner.run()

    // Shutdown cleanup: kill any still-running background tasks and
    // tear down the isolated tmux socket so we don't leak processes
    // after the user exits.
    pollTask.cancel()
    await agent.abortAndKillBackgroundTasks()
    await TmuxSessionManager.shared.teardown()
}

// MARK: - Helpers

/// Non-LLM lines surfaced beneath the transcript (slash-command output,
/// modal results, error toasts). Kept separate from `TranscriptRenderer`'s
/// accumulated lines so we can rebuild the display as
/// `renderer + notifications` without losing either stream.
///
/// Lifetime: cleared on each new Enter press so feedback from a previous
/// action doesn't accumulate indefinitely.
@MainActor
final class NotificationLog {
    private(set) var all: [String] = []
    func append(_ line: String) { all.append(line) }
    func clear() { all.removeAll() }
}

private func shortenPath(_ path: String, to maxLen: Int) -> String {
    if path.count <= maxLen { return path }
    let head = path.prefix(maxLen / 2 - 1)
    let tail = path.suffix(maxLen / 2 - 2)
    return "\(head)…\(tail)"
}

/// Flatten a queued user message to a single truncated line for the
/// queue panel above the input. Multi-line bodies collapse to spaces
/// so the panel's row count stays predictable (1 per queued message
/// plus a header line).
func previewQueuedMessageLine(_ msg: Message, max: Int = 100) -> String {
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
