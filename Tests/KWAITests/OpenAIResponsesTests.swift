import Foundation
import Testing
@testable import KWAI

@Suite("OpenAI Responses provider")
struct OpenAIResponsesTests {
    static let model = Model(
        id: "gpt-5",
        name: "GPT-5",
        api: "openai-responses",
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: true,
        input: [.text, .image],
        contextWindow: 200_000,
        maxTokens: 8192
    )

    static let textSSE = """
    data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}

    data: {"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}

    data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hello"}

    data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":", world"}

    data: {"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hello, world"}}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message"}}

    data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":5,"output_tokens":3}}}

    """

    static let toolUseSSE = """
    data: {"type":"response.created","response":{"id":"resp_2","status":"in_progress"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"calc","arguments":""}}

    data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"a\\":1"}

    data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":",\\"b\\":2}"}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"calc"}}

    data: {"type":"response.completed","response":{"id":"resp_2","status":"completed","usage":{"input_tokens":12,"output_tokens":8}}}

    """

    static let reasoningSSE = """
    data: {"type":"response.created","response":{"id":"resp_3","status":"in_progress"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"r_1"}}

    data: {"type":"response.reasoning_text.delta","output_index":0,"delta":"think…"}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning"}}

    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","role":"assistant","content":[]}}

    data: {"type":"response.content_part.added","output_index":1,"content_index":0,"part":{"type":"output_text","text":""}}

    data: {"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"answer"}

    data: {"type":"response.content_part.done","output_index":1,"content_index":0,"part":{"type":"output_text","text":"answer"}}

    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message"}}

    data: {"type":"response.completed","response":{"id":"resp_3","status":"completed","usage":{"input_tokens":20,"output_tokens":10}}}

    """

    @Test("streams text + completes with usage")
    func basicText() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var acc = ""
        for await event in s {
            if case .textDelta(_, let d, _) = event { acc += d }
        }
        let result = await s.result()
        #expect(acc == "Hello, world")
        #expect(result.stopReason == .stop)
        #expect(result.usage.input == 5)
        #expect(result.usage.output == 3)
        #expect(result.responseId == "resp_1")
    }

    @Test("streams function_call with incremental arguments")
    func toolUse() async throws {
        let client = StubSSEClient(body: Self.toolUseSSE)
        let provider = OpenAIResponsesProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "go"))]),
            options: nil
        )
        var seenEnd = false
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event {
                #expect(call.id == "call_1")
                #expect(call.name == "calc")
                #expect(call.arguments == .object(["a": 1, "b": 2]))
                seenEnd = true
            }
        }
        let result = await s.result()
        #expect(seenEnd)
        #expect(result.stopReason == .toolUse)
    }

    @Test("surfaces reasoning items as thinking blocks")
    func reasoningBlocks() async throws {
        let client = StubSSEClient(body: Self.reasoningSSE)
        let provider = OpenAIResponsesProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "think"))]),
            options: StreamOptions(reasoning: .high)
        )
        for await _ in s {}
        let result = await s.result()
        #expect(result.content.count == 2)
        if case .thinking(let th) = result.content.first {
            #expect(th.thinking == "think…")
        } else { Issue.record("expected thinking first") }
        if case .text(let t) = result.content.last {
            #expect(t.text == "answer")
        } else { Issue.record("expected text last") }
    }

    @Test("encodes input array with instructions + tools")
    func bodyEncoding() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.model,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [.user(UserMessage(text: "hi"))],
                tools: [Tool(
                    name: "calc",
                    description: "arith",
                    parameters: ["type": "object", "properties": ["a": ["type": "number"]]]
                )]
            ),
            options: StreamOptions(
                reasoning: .medium,
                toolChoice: .required,
                parallelToolCalls: false
            )
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["instructions"] as? String == "Be concise.")
        #expect(json?["parallel_tool_calls"] as? Bool == false)
        #expect(json?["tool_choice"] as? String == "required")
        let reasoning = json?["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "medium")
        let input = json?["input"] as? [[String: Any]]
        #expect(input?.first?["type"] as? String == "message")
        #expect(input?.first?["role"] as? String == "user")
        let tools = json?["tools"] as? [[String: Any]]
        #expect(tools?.first?["type"] as? String == "function")
        #expect(tools?.first?["name"] as? String == "calc")
    }

    @Test("represents tool_result as function_call_output in the input array")
    func toolResultEncoding() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: client, defaultAPIKey: "k")
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call_1", name: "calc", arguments: ["a": 1]))],
            api: "openai-responses",
            provider: "openai",
            model: "gpt-5",
            stopReason: .toolUse
        )
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [
                .user(UserMessage(text: "compute")),
                .assistant(assistant),
                .toolResult(ToolResultMessage(
                    toolCallId: "call_1",
                    toolName: "calc",
                    content: [.text(TextContent(text: "1"))]
                )),
            ]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let input = json?["input"] as? [[String: Any]]
        #expect(input?.count == 3)
        #expect(input?[1]["type"] as? String == "function_call")
        #expect(input?[2]["type"] as? String == "function_call_output")
        #expect(input?[2]["call_id"] as? String == "call_1")
    }

    @Test("reports upstream error event as terminal stream error")
    func providerError() async throws {
        let errorSSE = """
        data: {"type":"response.failed","response":{"status":"failed","error":{"message":"quota exceeded"}}}

        """
        let client = StubSSEClient(body: errorSSE)
        let provider = OpenAIResponsesProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        for await _ in s {}
        let result = await s.result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "quota exceeded")
    }
}
