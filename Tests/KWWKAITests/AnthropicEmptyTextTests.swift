import Foundation
import Testing
@testable import KWWKAI

@Suite("Anthropic empty-text replay")
struct AnthropicEmptyTextTests {
    private func model(_ provider: String) -> Model {
        var model = AnthropicProviderTests.sampleModel
        model.provider = provider
        model.input = [.text, .image]
        return model
    }

    private func body(_ messages: [Message], model: Model) async throws -> [[String: Any]] {
        let client = StubSSEClient(body: "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test")
        _ = await provider.stream(model: model, context: Context(messages: messages), options: nil).result()
        let data = try #require(client.lastRequest?.body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["messages"] as? [[String: Any]])
    }

    @Test("drops blank cross-provider turns without trimming real text", arguments: ["anthropic", "kimi-coding"])
    func crossProviderHistory(provider: String) async throws {
        let model = model(provider)
        let history: [Message] = [
            .user(UserMessage(text: "first")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: ""))],
                api: "openai-responses", provider: "openai", model: "previous-model"
            )),
            .user(UserMessage(text: " \n\t")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "\n")), .text(TextContent(text: " answer \n"))],
                api: model.api, provider: model.provider, model: model.id
            )),
            .user(UserMessage(content: [.text(TextContent(text: "")), .text(TextContent(text: "next"))])),
        ]
        let messages = try await body(history, model: model)
        #expect(messages.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
        let texts = messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["text"] as? String }
        #expect(texts == ["first", " answer \n", "next"])
        // Encoding must not rewrite persisted history.
        if case .assistant(let original) = history[1], case .text(let text) = original.content[0] {
            #expect(text.text.isEmpty)
        } else {
            Issue.record("Expected the original empty assistant text")
        }
    }

    @Test("blank tool output still answers its call", arguments: [false, true])
    func emptyToolResult(isError: Bool) async throws {
        let model = model("kimi-coding")
        let messages = try await body([
            .user(UserMessage(text: "run command")),
            .assistant(AssistantMessage(
                content: [
                    .text(TextContent(text: "")),
                    .toolCall(ToolCall(id: "call-1", name: "bash", arguments: [:])),
                ],
                api: model.api, provider: model.provider, model: model.id, stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "call-1", toolName: "bash",
                content: [.text(TextContent(text: "")), .text(TextContent(text: " \n"))],
                isError: isError
            )),
        ], model: model)
        let call = try #require((messages[1]["content"] as? [[String: Any]])?.first)
        let result = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        #expect(call["type"] as? String == "tool_use")
        #expect(result["type"] as? String == "tool_result")
        #expect(result["tool_use_id"] as? String == call["id"] as? String)
        #expect(result["content"] == nil)
        #expect((result["is_error"] as? Bool ?? false) == isError)
        #expect(result["cache_control"] != nil)
    }

    @Test("preserves images, meaningful tool output and signed empty thinking")
    func preservesNonemptyBlocks() async throws {
        let model = model("kimi-coding")
        let image = ImageContent(data: "image-data", mimeType: "image/png")
        let messages = try await body([
            .user(UserMessage(content: [.text(TextContent(text: "")), .image(image)])),
            .assistant(AssistantMessage(
                content: [
                    .text(TextContent(text: "\t")),
                    .thinking(ThinkingContent(thinking: "", thinkingSignature: "signature")),
                    .toolCall(ToolCall(id: "call-1", name: "inspect", arguments: [:])),
                ],
                api: model.api, provider: model.provider, model: model.id, stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "call-1", toolName: "inspect",
                content: [.text(TextContent(text: "")), .image(image), .text(TextContent(text: " output \n"))]
            )),
        ], model: model)
        let user = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(user.compactMap { $0["type"] as? String } == ["image"])
        #expect((user[0]["source"] as? [String: Any])?["data"] as? String == image.data)
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant.compactMap { $0["type"] as? String } == ["thinking", "tool_use"])
        #expect(assistant[0]["signature"] as? String == "signature")
        let result = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        let inner = try #require(result["content"] as? [[String: Any]])
        #expect(inner.compactMap { $0["type"] as? String } == ["image", "text"])
        #expect(inner[1]["text"] as? String == " output \n")
    }
}
