import Foundation
import Testing
@testable import KWAI

@Suite("Anthropic tool_choice encoding")
struct AnthropicToolChoiceTests {
    static let model = AnthropicProviderTests.sampleModel
    static let minimalSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":1,"output_tokens":0}}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private func tool() -> Tool {
        Tool(
            name: "calc",
            description: "arithmetic",
            parameters: [
                "type": "object",
                "properties": ["a": ["type": "number"]],
                "required": ["a"],
            ]
        )
    }

    private func run(options: StreamOptions?) async throws -> [String: Any] {
        let client = StubSSEClient(body: Self.minimalSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let ctx = Context(
            messages: [.user(UserMessage(text: "hi"))],
            tools: [tool()]
        )
        _ = provider.stream(model: Self.model, context: ctx, options: options)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    @Test("omits tool_choice when caller didn't ask")
    func defaultOmitsToolChoice() async throws {
        let json = try await run(options: nil)
        #expect(json["tool_choice"] == nil)
    }

    @Test("disabling parallel emits disable_parallel_tool_use=true")
    func disableParallel() async throws {
        let json = try await run(options: StreamOptions(parallelToolCalls: false))
        let choice = json["tool_choice"] as? [String: Any]
        #expect(choice?["type"] as? String == "auto")
        #expect(choice?["disable_parallel_tool_use"] as? Bool == true)
    }

    @Test("toolChoice=.none maps to type=none")
    func choiceNone() async throws {
        // Explicit qualifier — bare `.none` collides with Optional.none.
        let json = try await run(options: StreamOptions(toolChoice: ToolChoice.none))
        let choice = json["tool_choice"] as? [String: Any]
        #expect(choice?["type"] as? String == "none")
    }

    @Test("toolChoice=.required maps to type=any")
    func choiceRequired() async throws {
        let json = try await run(options: StreamOptions(toolChoice: .required))
        let choice = json["tool_choice"] as? [String: Any]
        #expect(choice?["type"] as? String == "any")
    }

    @Test("toolChoice=.tool(name) maps to type=tool+name")
    func choiceNamed() async throws {
        let json = try await run(options: StreamOptions(toolChoice: .tool(name: "calc")))
        let choice = json["tool_choice"] as? [String: Any]
        #expect(choice?["type"] as? String == "tool")
        #expect(choice?["name"] as? String == "calc")
    }

    @Test("toolChoice + parallelToolCalls=false combines on the same block")
    func combined() async throws {
        let json = try await run(options: StreamOptions(
            toolChoice: .required,
            parallelToolCalls: false
        ))
        let choice = json["tool_choice"] as? [String: Any]
        #expect(choice?["type"] as? String == "any")
        #expect(choice?["disable_parallel_tool_use"] as? Bool == true)
    }
}
