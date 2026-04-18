import Foundation
import KWAI
import KWAgent
import KWCoding
import KWCodingTUIKit
import KWTUI

/// Offline TUI "screenshot" tool. Uses the Faux provider to script a
/// deterministic agent session, renders the CodingTUI layout into a
/// VirtualTerminal, and prints the viewport grid as text. Lets us see what
/// the live UI will look like without talking to a real LLM.
///
/// Scenarios:
///   swift run kw-tui-snapshot empty
///   swift run kw-tui-snapshot one-turn        (default)
///   swift run kw-tui-snapshot tool-use
///   swift run kw-tui-snapshot long-history
///   swift run kw-tui-snapshot wide-tool-result
@main
struct TUISnapshot {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let scenario = args.first ?? "one-turn"
        let width = Int(args.dropFirst().first ?? "100") ?? 100
        let height = Int(args.dropFirst(2).first ?? "32") ?? 32

        let terminal = VirtualTerminal(width: width, height: height)
        let tui = TUI(terminal: terminal)
        let layout = await MainActor.run { CodingLayout() }
        let renderer = await MainActor.run { TranscriptRenderer() }

        await MainActor.run {
            layout.install(into: tui)
            layout.header.lines = [
                Style.header("✻ kw coding agent"),
                Style.dimmed("  claude-sonnet-4-5-20250929"),
                Style.dimmed("  /Users/eyhn/kw"),
            ]
            layout.status.lines = [Style.dimmed("ready · Ctrl-C to abort · Esc to exit")]
        }

        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        scriptResponses(scenario: scenario, faux: faux)

        let model = faux.getModel()
        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "",
            model: model,
            tools: await MainActor.run { tools(for: scenario) }
        ))
        _ = await MainActor.run {
            agent.subscribe { event, _ in
                await MainActor.run { renderer.apply(event) }
            }
        }

        // Drive the agent through the scripted turn.
        for userMessage in prompts(for: scenario) {
            try await agent.prompt(userMessage)
        }

        // Apply renderer output into the layout.
        await MainActor.run {
            layout.setTranscript(renderer.lines.all)
            layout.fitViewport(height: height)
            layout.input.value = ""
            layout.input.focused = true
            tui.start()
        }
        await terminal.waitForRender()

        // Print the viewport as plain ASCII so we can see exactly what lives
        // on screen at the moment the snapshot was taken.
        let viewport = terminal.getViewport()
        print(String(repeating: "═", count: width))
        for (i, row) in viewport.enumerated() {
            let label = String(format: "%2d ", i + 1)
            print(label + row)
        }
        print(String(repeating: "═", count: width))
        print("scenario: \(scenario) · terminal: \(width)×\(height)")
    }

    // MARK: - Scenarios

    static func prompts(for scenario: String) -> [String] {
        switch scenario {
        case "empty": return []
        case "one-turn": return ["hello"]
        case "tool-use": return ["what's in Package.swift"]
        case "long-history":
            return [
                "first question",
                "second question",
                "third question",
                "can you summarize the earlier replies",
            ]
        case "wide-tool-result": return ["read a large file for me"]
        case "bash-failures":
            // Reproduces the flow the user hit: greeting, then user asks for
            // a build, then several tool calls fail, then one runs. The
            // header should stay visible at the top of the viewport.
            return ["你新建一个文件夹然后创建一个 helloworld react 项目然后构建好"]
        default: return ["hello"]
        }
    }

    static func scriptResponses(scenario: String, faux: FauxProviderRegistration) {
        switch scenario {
        case "empty":
            break
        case "one-turn":
            faux.setResponses([
                .message(fauxAssistantMessage("Hi! I'm ready when you are.")),
            ])
        case "tool-use":
            faux.setResponses([
                .message(fauxAssistantMessage(
                    blocks: [
                        fauxText("Let me check."),
                        fauxToolCall(name: "read", arguments: ["path": "Package.swift"], id: "t1"),
                    ],
                    stopReason: .toolUse
                )),
                .message(fauxAssistantMessage(
                    "Package.swift declares 4 libraries (KWAI, KWAgent, KWCoding, KWTUI) and 3 executables, plus test targets mirroring each library."
                )),
            ])
        case "long-history":
            faux.setResponses([
                .message(fauxAssistantMessage("Reply to the first question with a longer body that spans multiple lines so we can see how wrapping and viewport clipping hold up under pressure.")),
                .message(fauxAssistantMessage("Reply two — still lots of text to push the buffer along.")),
                .message(fauxAssistantMessage("Reply three — approaching the bottom of the viewport now.")),
                .message(fauxAssistantMessage("Sure — earlier replies covered three unrelated questions and this one is the fourth.")),
            ])
        case "wide-tool-result":
            faux.setResponses([
                .message(fauxAssistantMessage(
                    blocks: [
                        fauxToolCall(name: "read", arguments: ["path": "long.txt"], id: "t1"),
                    ],
                    stopReason: .toolUse
                )),
                .message(fauxAssistantMessage("Summary of the file…")),
            ])
        case "bash-failures":
            faux.setResponses([
                .message(fauxAssistantMessage(
                    blocks: [
                        fauxText("好的，我来帮你创建一个 React Hello World 项目并构建它。"),
                        fauxToolCall(
                            name: "bash",
                            arguments: ["command": "mkdir helloworld-react && cd helloworld-react && npm create vite"],
                            id: "b1"
                        ),
                    ],
                    stopReason: .toolUse
                )),
                .message(fauxAssistantMessage(
                    blocks: [
                        fauxText("让我重新尝试更快的方式:"),
                        fauxToolCall(
                            name: "bash",
                            arguments: ["command": "cd /Users/eyhn/kw/helloworld && npm run build"],
                            id: "b2"
                        ),
                    ],
                    stopReason: .toolUse
                )),
                .message(fauxAssistantMessage("创建完成。")),
            ])
        default: break
        }
    }

    @MainActor
    static func tools(for scenario: String) -> [AgentTool] {
        switch scenario {
        case "tool-use":
            return [AgentTool(
                name: "read",
                label: "read",
                description: "read a file",
                parameters: .object(["type": .string("object")]),
                execute: { _, _, _, _ in
                    AgentToolResult(content: [.text(TextContent(text: """
                    // swift-tools-version: 6.0
                    import PackageDescription

                    let package = Package(
                        name: "kw",
                        platforms: [.macOS(.v14)],
                        products: [.library(name: "KWAI", targets: ["KWAI"])],
                        targets: [...]
                    )
                    """))])
                }
            )]
        case "wide-tool-result":
            return [AgentTool(
                name: "read",
                label: "read",
                description: "read a file",
                parameters: .object(["type": .string("object")]),
                execute: { _, _, _, _ in
                    let body = (1...40).map { "line \($0): lorem ipsum dolor sit amet consectetur adipiscing elit" }.joined(separator: "\n")
                    return AgentToolResult(content: [.text(TextContent(text: body))])
                }
            )]
        case "bash-failures":
            return [AgentTool(
                name: "bash",
                label: "bash",
                description: "run shell",
                parameters: .object(["type": .string("object")]),
                execute: { id, _, _, _ in
                    struct BashFail: Error, LocalizedError {
                        let msg: String
                        var errorDescription: String? { msg }
                    }
                    if id == "b1" {
                        throw BashFail(msg: "Command timed out after 120000ms")
                    }
                    if id == "b2" {
                        throw BashFail(msg: "zsh:cd:1: no such file or directory: /Users/eyhn/kw/helloworld")
                    }
                    return AgentToolResult(content: [.text(TextContent(text: "ok"))])
                }
            )]
        default: return []
        }
    }
}
