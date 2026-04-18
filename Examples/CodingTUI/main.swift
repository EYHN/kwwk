import Foundation
import KWAI
import KWAgent
import KWCoding
import KWCodingTUIKit
import KWTUI

/// Claude-Code-shaped coding agent TUI. Uses the shared CodingLayout +
/// TranscriptRenderer from KWCodingTUIKit so the live UI matches what the
/// `kw-tui-snapshot` debug tool prints.
///
/// Environment:
///   ANTHROPIC_API_KEY    — required
///   ANTHROPIC_MODEL      — optional, default claude-sonnet-4-5-20250929
///   ANTHROPIC_BASE_URL   — optional, default https://api.anthropic.com
///   KW_CWD               — optional, default `pwd`
@main
struct CodingTUI {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = env["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
            FileHandle.standardError.write(Data("Error: set ANTHROPIC_API_KEY\n".utf8))
            Foundation.exit(1)
        }
        let modelId = env["ANTHROPIC_MODEL"] ?? "claude-sonnet-4-5-20250929"
        let baseURL = env["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"
        let cwd = env["KW_CWD"] ?? FileManager.default.currentDirectoryPath

        // --- agent ---------------------------------------------------------
        await APIRegistry.shared.register(AnthropicProvider(defaultAPIKey: apiKey))
        let model = Model(
            id: modelId,
            name: modelId,
            api: "anthropic-messages",
            provider: "anthropic",
            baseUrl: baseURL,
            reasoning: false,
            input: [.text, .image],
            contextWindow: 200_000,
            maxTokens: 8192
        )

        // Background-task infrastructure. Enables `run_in_background`,
        // auto-background on timeout, `bg_status`, and completion
        // notifications surfaced as <task-notification> user messages.
        let bgManager = BackgroundTaskManager()
        let sessionId = UUID().uuidString

        var tools: [AgentTool] = [
            createReadTool(cwd: cwd),
            createWriteTool(cwd: cwd),
            createEditTool(cwd: cwd),
            createBashTool(cwd: cwd, options: BashToolOptions(
                defaultTimeoutSeconds: 120,
                manager: bgManager,
                sessionId: sessionId,
                autoBackgroundOnTimeout: true
            )),
            createGrepTool(cwd: cwd),
            createFindTool(cwd: cwd),
            createLSTool(cwd: cwd),
            createBgStatusTool(manager: bgManager, sessionId: sessionId),
        ]
        // Optional: tmux pane tool for driving TUI programs (vim, htop, …).
        // Registered only when tmux is on PATH so the agent doesn't see a
        // tool it can't actually use.
        if let tmuxTool = await createTmuxTool() {
            tools.append(tmuxTool)
        }

        let systemPrompt = buildSystemPrompt(SystemPromptOptions(
            cwd: cwd,
            selectedToolNames: tools.map { $0.name },
            toolSnippets: DefaultToolSnippets.all
        ))
        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: model,
            tools: tools
        ))

        // Wire background notifications into the agent: completions are
        // steered as user messages (picked up at the next turn boundary);
        // idle agents get woken with a fresh `continue()`.
        let detachBg = await agent.attachBackgroundManager(bgManager, sessionId: sessionId)
        _ = detachBg // retained for process lifetime

        // --- TUI (shared layout) ------------------------------------------
        // Inline render mode — the frame anchors at the current cursor and
        // preserves the user's shell scrollback above it (the Claude Code
        // behavior). Pass `useAlternateScreen: true` if you want a blank
        // fullscreen buffer instead.
        let runner = TUIRunner(useAlternateScreen: false, hideCursor: false)
        let layout = CodingLayout(statusRows: 2)
        let renderer = TranscriptRenderer()

        layout.header.lines = [
            Style.header("✻ kw coding agent"),
            Style.dimmed("  \(modelId)"),
            Style.dimmed("  \(shorten(cwd, to: max(20, runner.terminal.width - 4)))"),
        ]
        layout.install(into: runner.tui)
        layout.fitViewport(height: runner.terminal.height)
        runner.focus(layout.promptRow)
        _ = runner.terminal.onResize { _, h in
            Task { @MainActor in
                layout.fitViewport(height: h)
                runner.tui.requestRender()
            }
        }

        // Shared status bar model. The status line has two rows:
        //   row 1: dynamic state (streaming / aborting / bg-running / ready)
        //   row 2: static keyboard hints
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
                layout.setTranscript(renderer.lines.all)
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

        runner.bind(.init("enter")) { _ in
            let text = layout.input.value
            guard !text.isEmpty else { return }
            layout.input.value = ""
            runner.tui.requestRender()
            Task.detached {
                do {
                    try await agent.prompt(text)
                } catch {
                    await MainActor.run {
                        layout.status.lines = [
                            Style.error("error: \(error)"),
                            Style.dimmed("  Esc: cancel / stop bg tasks · Ctrl-C: quit"),
                        ]
                        runner.tui.requestRender()
                    }
                }
            }
        }

        // Ctrl-C: always exits (single tap). Keep it as the hard-stop key so
        // there's always a predictable way out.
        runner.bind(.ctrl("c")) { _ in
            Task { @MainActor in
                await agent.abortAndKillBackgroundTasks()
                runner.exit()
            }
        }

        // Esc: the primary "stop" key. Never exits — Ctrl-C is the only
        // way out of the app.
        //   1. While the agent is streaming → abort the current generation.
        //   2. While idle AND background tasks are running → kill them all.
        //   3. Otherwise → no-op.
        runner.bind(.init("escape")) { _ in
            if agent.state.isStreaming {
                agent.abort()
                Task { @MainActor in
                    statusBar.setMode(.aborting)
                    await statusBar.render()
                }
                return
            }
            Task { @MainActor in
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
}

// MARK: - Status bar

/// Two-line status bar with dynamic state + static keyboard hints.
///
///   row 1: ● generating… · Esc to cancel
///          ○ 3 background tasks running · Esc to stop them
///          ready
///          killed 2 background tasks (flashes briefly)
///   row 2: Esc: cancel generation / stop bg tasks · Ctrl-C: quit
///
/// The bar is re-rendered on agent events AND on a poll timer (so background
/// task counts stay live even when the agent is idle).
@MainActor
final class CodingStatusBar {
    enum Mode { case idle, streaming, aborting, flashing }

    private let layout: CodingLayout
    private let runner: TUIRunner
    private let agent: Agent
    private let bgManager: BackgroundTaskManager
    private let sessionId: String
    private var mode: Mode = .idle
    private var flashText: String?
    private var lastRenderedLines: [String] = []

    init(
        layout: CodingLayout,
        runner: TUIRunner,
        agent: Agent,
        bgManager: BackgroundTaskManager,
        sessionId: String
    ) {
        self.layout = layout
        self.runner = runner
        self.agent = agent
        self.bgManager = bgManager
        self.sessionId = sessionId
    }

    func setMode(_ mode: Mode) { self.mode = mode }

    func flashKilled(count: Int) {
        let noun = count == 1 ? "task" : "tasks"
        flashText = "killed \(count) background \(noun)"
        mode = .flashing
        // Auto-clear the flash after ~1s.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            await MainActor.run {
                self.flashText = nil
                if self.mode == .flashing { self.mode = .idle }
            }
            await self.render()
        }
    }

    /// Recompute the two status lines and re-render.
    func render() async {
        let running = await bgManager.list(sessionId: sessionId)
            .filter { $0.status == .running }.count
        let isStreaming = agent.state.isStreaming

        let line1: String
        if let flash = flashText {
            line1 = Style.dimmed(flash)
        } else if mode == .aborting {
            // Aborting takes precedence over streaming: after `agent.abort()`
            // fires, `isStreaming` stays true for a beat until agentEnd
            // lands, but we want the user to see "aborting…" immediately.
            line1 = Style.running("● aborting…") + " " +
                Style.dimmed("· Ctrl-C to force quit")
        } else if isStreaming {
            var parts = [Style.running("● generating…")]
            parts.append(Style.dimmed("· Esc to cancel"))
            if running > 0 {
                parts.append(Style.dimmed("· \(running) bg \(running == 1 ? "task" : "tasks") running"))
            }
            line1 = parts.joined(separator: " ")
        } else if running > 0 {
            let noun = running == 1 ? "task" : "tasks"
            line1 = Style.dimmed("○ \(running) background \(noun) running") + " " +
                Style.dimmed("· Esc to stop them")
        } else {
            line1 = Style.dimmed("ready")
        }

        let line2 = Style.dimmed("  Esc: cancel generation / stop bg tasks · Ctrl-C: quit")
        let newLines = [line1, line2]
        if newLines != lastRenderedLines {
            lastRenderedLines = newLines
            layout.status.lines = newLines
            runner.tui.requestRender()
        }
    }
}

// MARK: - Helpers

private func shorten(_ path: String, to maxLen: Int) -> String {
    if path.count <= maxLen { return path }
    let head = path.prefix(maxLen / 2 - 1)
    let tail = path.suffix(maxLen / 2 - 2)
    return "\(head)…\(tail)"
}
