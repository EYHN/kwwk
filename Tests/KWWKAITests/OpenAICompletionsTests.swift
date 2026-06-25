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

    private static func waitForRequest(_ client: StubSSEClient) async {
        for _ in 0..<200 where client.lastRequest == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func decodeBody(_ client: StubSSEClient) throws -> [String: Any] {
        let body = client.lastRequest?.body ?? Data()
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

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
        #expect(client.lastRequest?.headers["Authorization"] == "Bearer sk-override")
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
        #expect(client.lastRequest?.headers["Authorization"] == "Bearer sk-resolved")
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

    @Test("prompt cache key is clamped and gated by provider compatibility")
    func promptCacheKeyEncoding() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                cacheRetention: .long,
                sessionId: String(repeating: "x", count: 67)
            )
        )
        await Self.waitForRequest(client)
        let json = try Self.decodeBody(client)
        #expect(json["prompt_cache_key"] as? String == String(repeating: "x", count: 64))
        #expect(json["prompt_cache_retention"] as? String == "24h")

        var proxy = Self.model
        proxy.baseUrl = "https://proxy.example.com"
        var compat = ModelCompat()
        compat.supportsLongCacheRetention = false
        proxy.compat = compat
        let proxyClient = StubSSEClient(body: Self.textSSE)
        let proxyProvider = OpenAICompletionsProvider(client: proxyClient, defaultAPIKey: "k")
        _ = proxyProvider.stream(
            model: proxy,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(cacheRetention: .long, sessionId: "session-proxy")
        )
        await Self.waitForRequest(proxyClient)
        let proxyJSON = try Self.decodeBody(proxyClient)
        #expect(proxyJSON["prompt_cache_key"] == nil)
        #expect(proxyJSON["prompt_cache_retention"] == nil)
    }

    @Test("session affinity headers honor cache retention and caller overrides")
    func sessionAffinityHeaders() async throws {
        var model = Self.model
        model.baseUrl = "https://proxy.example.com"
        model.headers = ["x-model-header": "model"]
        var compat = ModelCompat()
        compat.sendSessionAffinityHeaders = true
        model.compat = compat

        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                cacheRetention: .short,
                sessionId: "session-affinity",
                headers: ["x-session-affinity": "override-affinity"]
            )
        )
        await Self.waitForRequest(client)
        let headers = client.lastRequest?.headers ?? [:]
        #expect(headers["x-model-header"] == "model")
        #expect(headers["session_id"] == "session-affinity")
        #expect(headers["x-client-request-id"] == "session-affinity")
        #expect(headers["x-session-affinity"] == "override-affinity")

        let noneClient = StubSSEClient(body: Self.textSSE)
        let noneProvider = OpenAICompletionsProvider(client: noneClient, defaultAPIKey: "k")
        _ = noneProvider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(cacheRetention: CacheRetention.none, sessionId: "session-affinity")
        )
        await Self.waitForRequest(noneClient)
        let noneHeaders = noneClient.lastRequest?.headers ?? [:]
        #expect(noneHeaders["session_id"] == nil)
        #expect(noneHeaders["x-client-request-id"] == nil)
        #expect(noneHeaders["x-session-affinity"] == nil)
    }

    @Test("compat chat-template kwargs and routing fields are encoded")
    func compatChatTemplateAndRouting() async throws {
        var model = Self.model
        model.reasoning = true
        model.thinkingLevelMap = ["high": "max"]
        var compat = ModelCompat()
        compat.thinkingFormat = "chat-template"
        compat.chatTemplateKwargs = .object([
            "enable_thinking": .object(["$var": .string("thinking.enabled")]),
            "effort": .object(["$var": .string("thinking.effort"), "omitWhenOff": .bool(true)]),
            "static": .string("value"),
        ])
        compat.openRouterRouting = .object(["only": .array([.string("anthropic")])])
        compat.vercelGatewayRouting = .object(["order": .array([.string("openai")])])
        model.compat = compat

        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .high)
        )
        await Self.waitForRequest(client)
        let json = try Self.decodeBody(client)
        let kwargs = json["chat_template_kwargs"] as? [String: Any]
        #expect(kwargs?["enable_thinking"] as? Bool == true)
        #expect(kwargs?["effort"] as? String == "max")
        #expect(kwargs?["static"] as? String == "value")

        let routing = json["provider"] as? [String: Any]
        #expect(routing?["only"] as? [String] == ["anthropic"])
        let providerOptions = json["providerOptions"] as? [String: Any]
        let gateway = providerOptions?["gateway"] as? [String: Any]
        #expect(gateway?["order"] as? [String] == ["openai"])
    }

    @Test("anthropic cache_control compat marks prompt and tool definitions")
    func anthropicCacheControlCompat() async throws {
        var model = Self.model
        model.provider = "openrouter"
        model.baseUrl = "https://openrouter.ai/api"
        var compat = ModelCompat()
        compat.cacheControlFormat = "anthropic"
        model.compat = compat

        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: model,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [.user(UserMessage(text: "hi"))],
                tools: [Tool(name: "noop", description: "n", parameters: ["type": "object"])]
            ),
            options: StreamOptions(cacheRetention: .long)
        )
        await Self.waitForRequest(client)
        let json = try Self.decodeBody(client)
        let messages = json["messages"] as? [[String: Any]]
        let systemContent = messages?.first?["content"] as? [[String: Any]]
        let systemCache = systemContent?.first?["cache_control"] as? [String: Any]
        #expect(systemCache?["type"] as? String == "ephemeral")
        #expect(systemCache?["ttl"] as? String == "1h")
        let tools = json["tools"] as? [[String: Any]]
        let toolCache = tools?.last?["cache_control"] as? [String: Any]
        #expect(toolCache?["type"] as? String == "ephemeral")
        let userContent = messages?.last?["content"] as? [[String: Any]]
        let userCache = userContent?.first?["cache_control"] as? [String: Any]
        #expect(userCache?["ttl"] as? String == "1h")
    }

    @Test("anthropic cache_control endpoint does not also emit prompt_cache_key")
    func anthropicCacheExcludesNativeCache() async throws {
        var model = Self.model
        model.provider = "openrouter"
        model.baseUrl = "https://openrouter.ai/api"
        var compat = ModelCompat()
        compat.cacheControlFormat = "anthropic"
        compat.supportsLongCacheRetention = true
        model.compat = compat

        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(cacheRetention: .long, sessionId: "sess-123")
        )
        await Self.waitForRequest(client)
        let json = try Self.decodeBody(client)
        // anthropic cache_control applied …
        let messages = json["messages"] as? [[String: Any]]
        let userContent = messages?.last?["content"] as? [[String: Any]]
        #expect(userContent?.first?["cache_control"] != nil)
        // … but the conflicting OpenAI-native fields are NOT mixed in.
        #expect(json["prompt_cache_key"] == nil)
        #expect(json["prompt_cache_retention"] == nil)
    }

    @Test("assistant thinking round-trips as reasoning_content, not a signature key")
    func thinkingRoundTripsAsReasoningContent() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
        let assistant = AssistantMessage(
            content: [
                .thinking(ThinkingContent(thinking: "deduced", thinkingSignature: "sig-xyz")),
                .text(TextContent(text: "answer")),
            ],
            api: "openai-completions",
            provider: "openai",
            model: "gpt-4o-mini",
            stopReason: .stop
        )
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [
                .user(UserMessage(text: "q")),
                .assistant(assistant),
                .user(UserMessage(text: "follow up")),
            ]),
            options: nil
        )
        await Self.waitForRequest(client)
        let json = try Self.decodeBody(client)
        let messages = json["messages"] as? [[String: Any]] ?? []
        let assistantEntry = messages.first { ($0["role"] as? String) == "assistant" }
        #expect(assistantEntry?["reasoning_content"] as? String == "deduced")
        // The signature value must never become a JSON field name.
        #expect(assistantEntry?["sig-xyz"] == nil)
    }
}
