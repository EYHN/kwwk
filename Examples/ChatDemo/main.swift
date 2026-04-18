import Foundation
import KWAI
import KWAgent
import KWTUI

/// Wires `AnthropicProvider` into an `Agent` driving a minimal chat TUI.
///
/// Environment:
///   ANTHROPIC_API_KEY   — required
///   ANTHROPIC_MODEL     — optional, default claude-sonnet-4-5-20250929
@main
struct ChatDemo {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = env["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
            FileHandle.standardError.write(Data("Error: set ANTHROPIC_API_KEY\n".utf8))
            Foundation.exit(1)
        }
        let modelId = env["ANTHROPIC_MODEL"] ?? "claude-sonnet-4-5-20250929"
        let baseURL = env["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"

        // Register the Anthropic provider into the shared API registry. The
        // Agent's default streamFn looks up providers by model.api.
        let provider = AnthropicProvider(defaultAPIKey: apiKey)
        await APIRegistry.shared.register(provider)

        let model = Model(
            id: modelId,
            name: modelId,
            api: "anthropic-messages",
            provider: "anthropic",
            baseUrl: baseURL,
            reasoning: false,
            input: [.text],
            contextWindow: 200_000,
            maxTokens: 8192
        )

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "You are a concise, helpful assistant.",
            model: model
        ))

        // TUI layout: transcript / divider / status / input
        let runner = TUIRunner(useAlternateScreen: true, hideCursor: false)
        let transcript = TextComponent([])
        let divider = TextComponent(String(repeating: "─", count: 80))
        let status = TextComponent("ready. type a message, Enter to send, Esc / Ctrl-C to exit.")
        let input = InputComponent()

        runner.tui.addChild(transcript)
        runner.tui.addChild(TextComponent(""))
        runner.tui.addChild(divider)
        runner.tui.addChild(status)
        runner.tui.addChild(TextComponent(""))
        runner.tui.addChild(input)
        runner.focus(input)

        // Subscribe to agent events; marshal UI updates onto the main queue.
        _ = agent.subscribe { event, _ in
            await MainActor.run {
                switch event {
                case .messageStart(let message):
                    if case .assistant = message {
                        // Reserve a line for the streamed reply.
                        var lines = transcript.lines
                        lines.append("assistant: ")
                        transcript.lines = lines
                        transcript.invalidate()
                    }

                case .messageUpdate(let message, _):
                    let text = assistantText(of: message)
                    var lines = transcript.lines
                    if let lastIndex = lines.indices.last, lines[lastIndex].hasPrefix("assistant: ") {
                        lines[lastIndex] = "assistant: " + text
                    } else {
                        lines.append("assistant: " + text)
                    }
                    transcript.lines = lines
                    transcript.invalidate()

                case .messageEnd(let message):
                    if case .assistant(let a) = message {
                        let text = assistantText(of: a)
                        var lines = transcript.lines
                        if let lastIndex = lines.indices.last, lines[lastIndex].hasPrefix("assistant: ") {
                            lines[lastIndex] = "assistant: " + text
                        }
                        transcript.lines = lines
                        transcript.invalidate()
                        if let err = a.errorMessage {
                            status.lines = ["error: \(err)"]
                        }
                    }

                case .agentStart:
                    status.lines = ["streaming…"]

                case .agentEnd:
                    status.lines = ["ready. ^C to exit."]

                default: break
                }
                runner.tui.requestRender()
            }
        }

        // Enter key → send the current input as a prompt.
        runner.bind(.init("enter")) { _ in
            let text = input.value
            guard !text.isEmpty else { return }
            input.value = ""
            var lines = transcript.lines
            lines.append("you: \(text)")
            transcript.lines = lines
            transcript.invalidate()
            runner.tui.requestRender()

            Task.detached {
                do {
                    try await agent.prompt(text)
                } catch {
                    await MainActor.run {
                        status.lines = ["error: \(error)"]
                        runner.tui.requestRender()
                    }
                }
            }
        }

        runner.bind(.ctrl("c")) { _ in runner.exit() }
        runner.bind(.init("escape")) { _ in runner.exit() }

        try await runner.run()
    }

    static func assistantText(of message: AssistantMessage) -> String {
        message.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined()
    }
}
