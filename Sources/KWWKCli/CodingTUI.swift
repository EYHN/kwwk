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
    apiKeyResolver: (@Sendable (String) async -> String?)? = nil
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
    let headerModelLine = TextComponent([""])
    layout.header.lines = [
        Style.header("✻ kwwk coding agent"),
        Style.dimmed("  \(modelLabel)"),
        Style.dimmed("  \(shortenPath(cwd, to: max(20, runner.terminal.width - 4)))"),
    ]
    // `headerModelLine` is a no-op placeholder used by the unused-var
    // silencer below; the real header is `layout.header`.
    _ = headerModelLine
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

    let statusBar = CodingStatusBar(
        layout: layout,
        runner: runner,
        agent: agent,
        bgManager: bgManager,
        sessionId: sessionId
    )
    await statusBar.render()

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
                statusBar.setMode(.idle)
            default: break
            }
            layout.fitViewport(height: runner.terminal.height)
            runner.tui.requestRender()
        }
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
        notify: { line in
            notifications.append(line)
            if !modal.isOpen { recomputeTranscript() }
            runner.tui.requestRender()
        }
    )

    // --- keybindings ----------------------------------------------------

    // Enter. Three modes of operation:
    //   1. modal open → forward to modal's confirm handler.
    //   2. input starts with `/` → slash command dispatch.
    //   3. anything else → submit as an LLM prompt.
    runner.bind(.init("enter")) { _ in
        Task { @MainActor in
            if modal.isOpen {
                modal.routeConfirm()
                return
            }
            let text = layout.input.value
            guard !text.isEmpty else { return }
            layout.input.value = ""
            // Each non-empty Enter starts a fresh action — expire the
            // notifications from the previous one (e.g. stale `/help`
            // output, `/model: cancelled` crumbs) so they don't pile up
            // forever below the transcript.
            notifications.clear()
            recomputeTranscript()
            runner.tui.requestRender()

            switch SlashInput.parse(text) {
            case .command(let name, let args):
                if let cmd = slashRegistry.find(name) {
                    await cmd.handler(slashContext, args)
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

    // Periodic refresh so the background-task count stays live even when
    // there aren't any agent events firing. 500ms is invisibly slow for
    // a human but cheap (just an actor dict count).
    let pollTask = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await statusBar.render()
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
