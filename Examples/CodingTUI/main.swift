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
        let tools: [AgentTool] = [
            createReadTool(cwd: cwd),
            createWriteTool(cwd: cwd),
            createEditTool(cwd: cwd),
            createBashTool(cwd: cwd),
            createGrepTool(cwd: cwd),
            createFindTool(cwd: cwd),
            createLSTool(cwd: cwd),
        ]
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

        // --- TUI (shared layout) ------------------------------------------
        // Inline render mode — the frame anchors at the current cursor and
        // preserves the user's shell scrollback above it (the Claude Code
        // behavior). Pass `useAlternateScreen: true` if you want a blank
        // fullscreen buffer instead.
        let runner = TUIRunner(useAlternateScreen: false, hideCursor: false)
        let layout = CodingLayout()
        let renderer = TranscriptRenderer()

        layout.header.lines = [
            Style.header("✻ kw coding agent"),
            Style.dimmed("  \(modelId)"),
            Style.dimmed("  \(shorten(cwd, to: max(20, runner.terminal.width - 4)))"),
        ]
        layout.status.lines = [Style.dimmed("ready · Ctrl-C to abort · Esc to exit")]
        layout.install(into: runner.tui)
        layout.fitViewport(height: runner.terminal.height)
        runner.focus(layout.promptRow)
        _ = runner.terminal.onResize { _, h in
            Task { @MainActor in
                layout.fitViewport(height: h)
                runner.tui.requestRender()
            }
        }

        _ = agent.subscribe { event, _ in
            await MainActor.run {
                renderer.apply(event)
                layout.setTranscript(renderer.lines.all)
                switch event {
                case .agentStart:
                    layout.status.lines = [Style.running("● streaming… Ctrl-C to abort")]
                case .agentEnd:
                    layout.status.lines = [Style.dimmed("ready · Ctrl-C to abort · Esc to exit")]
                default: break
                }
                layout.fitViewport(height: runner.terminal.height)
                runner.tui.requestRender()
            }
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
                        layout.status.lines = [Style.error("error: \(error)")]
                        runner.tui.requestRender()
                    }
                }
            }
        }
        // Claude-Code-style Ctrl-C: first press aborts the running turn,
        // a second press (while still aborting / idle) force-quits.
        let abortPending = AbortFlag()
        runner.bind(.ctrl("c")) { _ in
            if !agent.state.isStreaming {
                runner.exit()
                return
            }
            if abortPending.isSet {
                runner.exit()
                return
            }
            abortPending.set()
            agent.abort()
            Task { @MainActor in
                layout.status.lines = [
                    Style.running("● aborting… press Ctrl-C again to force quit")
                ]
                runner.tui.requestRender()
            }
        }
        _ = agent.subscribe { event, _ in
            if case .agentEnd = event {
                await MainActor.run { abortPending.clear() }
            }
        }
        runner.bind(.init("escape")) { _ in runner.exit() }

        try await runner.run()
    }
}

private func shorten(_ path: String, to maxLen: Int) -> String {
    if path.count <= maxLen { return path }
    let head = path.prefix(maxLen / 2 - 1)
    let tail = path.suffix(maxLen / 2 - 2)
    return "\(head)…\(tail)"
}

final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
    func clear() { lock.lock(); _value = false; lock.unlock() }
}
