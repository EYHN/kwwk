import Foundation
import Testing
@testable import KWWKAI

/// A tool call stored with an empty name is never sent, nor its result: a
/// Responses request refuses it ("Invalid 'input[33].name': empty string"),
/// and the transcript would fail the same way on every later turn.
@Suite("Tool calls stored with an empty name")
struct UnnamedToolCallTests {
    /// The stored shape: a Chat relay sent a call with neither id nor name,
    /// it ran as "Tool  not found", and the model then called a real tool.
    static let history: [Message] = [
        .user(UserMessage(text: "read the message")),
        .assistant(AssistantMessage(content: [
            .text(TextContent(text: "Reading it.")),
            .toolCall(ToolCall(id: "", name: "", arguments: [:])),
        ], api: "openai-completions", provider: "openrouter", model: "z-ai/glm-5.3-flash", stopReason: .toolUse)),
        .toolResult(ToolResultMessage(
            toolCallId: "",
            toolName: "",
            content: [.text(TextContent(text: "Tool  not found"))],
            isError: true
        )),
        .assistant(AssistantMessage(content: [
            .toolCall(ToolCall(id: "call_8b7d", name: "read_message", arguments: ["id": "m1"])),
        ], api: "openai-completions", provider: "openrouter", model: "z-ai/glm-5.3-flash", stopReason: .toolUse)),
        .toolResult(ToolResultMessage(
            toolCallId: "call_8b7d",
            toolName: "read_message",
            content: [.text(TextContent(text: "hello"))]
        )),
        .user(UserMessage(text: "go on")),
    ]

    @Test("the unnamed call and its result are left out; the turn's text and every other call stay")
    func dropped() {
        let out = TransformMessages.dropUnnamedToolCalls(TransformMessages.fillEmptyToolCallIds(Self.history))
        #expect(out.count == 5)
        guard case .assistant(let a) = out[1], case .assistant(let b) = out[2], case .toolResult(let r) = out[3]
        else { Issue.record("shape"); return }
        #expect(a.content.count == 1)
        if case .text(let t) = a.content.first { #expect(t.text == "Reading it.") } else { Issue.record("text") }
        if case .toolCall(let tc) = b.content.first { #expect(tc.name == "read_message") } else { Issue.record("call") }
        #expect(r.toolCallId == "call_8b7d")
    }

    @Test("a turn holding only the unnamed call goes whole")
    func emptyTurnDropped() {
        let history: [Message] = [
            .user(UserMessage(text: "x")),
            .assistant(AssistantMessage(content: [.toolCall(ToolCall(id: "c1", name: "", arguments: [:]))],
                                        api: "openai-completions", provider: "openrouter", model: "m",
                                        stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "",
                                          content: [.text(TextContent(text: "Tool  not found"))], isError: true)),
            .user(UserMessage(text: "y")),
        ]
        let out = TransformMessages.dropUnnamedToolCalls(history)
        #expect(out.map(\.role) == [.user, .user])
    }

    @Test("Codex's Responses request holds no item with an empty name or call id, and no output without its call")
    func responsesRequest() async throws {
        let client = StubSSEClient(body: OpenAIResponsesTests.textSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "sk-test")
        var model = OpenAIResponsesTests.model
        model.api = "chatgpt-codex"
        model.provider = "openai-codex"
        _ = await provider.stream(model: model, context: Context(messages: Self.history), options: nil).result()
        let body = try #require(client.lastRequest?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = json["input"] as? [[String: Any]] ?? []
        let calls = input.filter { $0["type"] as? String == "function_call" }
        let outputs = input.filter { $0["type"] as? String == "function_call_output" }
        #expect(calls.map { $0["name"] as? String } == ["read_message"])
        #expect(calls.map { $0["call_id"] as? String } == outputs.map { $0["call_id"] as? String })
        #expect(!input.contains { ($0["name"] as? String)?.isEmpty == true || ($0["call_id"] as? String)?.isEmpty == true })
    }
}
