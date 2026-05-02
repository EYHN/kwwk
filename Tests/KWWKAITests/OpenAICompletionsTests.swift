import Foundation
import Testing
@testable import KWWKAI

@Suite("OpenAI Completions provider")
struct OpenAICompletionsTests {
    static let model = Model(
        id: "gpt-4o-mini",
        name: "GPT-4o Mini",
        api: "openai-completions",
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: false,
        input: [.text],
        contextWindow: 128_000,
        maxTokens: 4096
    )

    static let textSSE = """
    data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"}}]}

    data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":", world"}}]}

    data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3}}

    data: [DONE]

    """

    static let toolUseSSE = """
    data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"calc","arguments":""}}]}}]}

    data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"a\\":1"}}]}}]}

    data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":",\\"b\\":2}"}}]}}]}

    data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """

    @Test("streams text content")
    func basicText() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var types: [String] = []
        var acc = ""
        for await event in s {
            types.append(event.type)
            if case .textDelta(_, let d, _) = event { acc += d }
        }
        let result = await s.result()
        #expect(types.contains("start"))
        #expect(types.contains("text_start"))
        #expect(types.contains("text_delta"))
        #expect(types.contains("text_end"))
        #expect(types.last == "done")
        #expect(acc == "Hello, world")
        #expect(result.content == [.text(TextContent(text: "Hello, world"))])
        #expect(result.stopReason == .stop)
        #expect(result.usage.input == 5)
        #expect(result.usage.output == 3)
    }

    @Test("streams tool_calls with incremental JSON args")
    func toolUse() async throws {
        let client = StubSSEClient(body: Self.toolUseSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "compute"))]),
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

    @Test("uses bearer authorization header")
    func authHeader() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-default")
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(apiKey: "sk-override")
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.lastRequest?.headers["authorization"] == "Bearer sk-override")
    }

    @Test("resolved auth overrides apiKey and default key")
    func resolvedAuthHeader() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-default")
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                apiKey: "sk-ignored",
                resolvedAuth: ResolvedProviderAuth(token: "sk-resolved", scheme: .bearer)
            )
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.lastRequest?.headers["authorization"] == "Bearer sk-resolved")
    }

    @Test("encodes parallel_tool_calls=false + tool_choice at the root")
    func parallelOffEncoding() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.model,
            context: Context(
                messages: [.user(UserMessage(text: "hi"))],
                tools: [Tool(name: "noop", description: "n", parameters: ["type": "object"])]
            ),
            options: StreamOptions(toolChoice: .required, parallelToolCalls: false)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["parallel_tool_calls"] as? Bool == false)
        #expect(json?["tool_choice"] as? String == "required")
    }

    @Test("encodes assistant+toolResult messages in OpenAI shape")
    func transcriptEncoding() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call_1", name: "noop", arguments: ["x": 1]))],
            api: "openai-completions",
            provider: "openai",
            model: "gpt-4o-mini",
            stopReason: .toolUse
        )
        _ = provider.stream(
            model: Self.model,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [
                    .user(UserMessage(text: "hi")),
                    .assistant(assistant),
                    .toolResult(ToolResultMessage(
                        toolCallId: "call_1",
                        toolName: "noop",
                        content: [.text(TextContent(text: "ok"))]
                    )),
                ],
                tools: [Tool(name: "noop", description: "n", parameters: ["type": "object"])]
            ),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]]
        #expect(messages?.count == 4)                // system, user, assistant, tool
        #expect(messages?[0]["role"] as? String == "system")
        #expect(messages?[1]["role"] as? String == "user")
        #expect(messages?[2]["role"] as? String == "assistant")
        let calls = messages?[2]["tool_calls"] as? [[String: Any]]
        #expect(calls?.first?["id"] as? String == "call_1")
        #expect(messages?[3]["role"] as? String == "tool")
        #expect(messages?[3]["tool_call_id"] as? String == "call_1")
    }
}
