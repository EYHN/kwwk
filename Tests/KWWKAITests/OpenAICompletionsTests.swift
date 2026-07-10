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
        baseURL: "https://api.openai.com",
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

    @Test("OpenRouter omits the catalog default output cap but honors an explicit cap")
    func openRouterOutputCapPolicy() throws {
        var model = Self.model
        model.provider = "openrouter"
        model.baseURL = "https://openrouter.ai/api/v1"
        model.maxTokens = 131_072
        let context = Context(messages: [.user(UserMessage(text: "hi"))])

        let automatic = try OpenAICompletionsProvider.encodeBodyDict(
            model: model,
            context: context,
            options: nil
        )
        #expect(automatic["max_tokens"] == nil)
        #expect(automatic["max_completion_tokens"] == nil)

        let explicit = try OpenAICompletionsProvider.encodeBodyDict(
            model: model,
            context: context,
            options: StreamOptions(maxTokens: 8_192)
        )
        #expect(explicit["max_completion_tokens"] as? Int == 8_192)
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
        try? await Task.sleep(nanoseconds: 300_000_000)
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
        try? await Task.sleep(nanoseconds: 300_000_000)
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
        try? await Task.sleep(nanoseconds: 300_000_000)
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
        try? await Task.sleep(nanoseconds: 300_000_000)
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
        proxy.baseURL = "https://proxy.example.com"
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
        model.baseURL = "https://proxy.example.com"
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
        model.baseURL = "https://openrouter.ai/api"
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
        model.baseURL = "https://openrouter.ai/api"
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

    // MARK: - Feature 1: tool-result image forwarding

    @Test("forwards tool-result images as a following user message (vision model)")
    func toolResultImageForwarding() async throws {
        let visionModel = Model(id: "gpt-4o", name: "GPT-4o", api: "openai-completions",
            provider: "openai", baseURL: "https://api.openai.com", reasoning: false,
            input: [.text, .image], contextWindow: 128_000, maxTokens: 4096)
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let ctx = Context(messages: [
            .assistant(AssistantMessage(content: [.toolCall(ToolCall(id: "call_1", name: "shot", arguments: .object([:])))],
                api: "openai-completions", provider: "openai", model: "gpt-4o", stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "shot",
                content: [.image(ImageContent(data: "QUJD", mimeType: "image/png"))])),
        ])
        _ = provider.stream(model: visionModel, context: ctx, options: nil)
        await Self.waitForRequest(client)
        let body = try Self.decodeBody(client)
        let messages = body["messages"] as! [[String: Any]]
        let toolMsg = messages.first { $0["role"] as? String == "tool" }!
        #expect(toolMsg["content"] as? String == "(see attached image)")
        let userImg = messages.last!
        #expect(userImg["role"] as? String == "user")
        let parts = userImg["content"] as! [[String: Any]]
        #expect((parts.first?["text"] as? String) == "Attached image(s) from tool result:")
        #expect(parts.contains { ($0["type"] as? String) == "image_url" })
    }

    @Test("non-vision model drops tool-result images, no carrier user message")
    func toolResultImageOmittedNonVision() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let ctx = Context(messages: [
            .assistant(AssistantMessage(content: [.toolCall(ToolCall(id: "call_1", name: "shot", arguments: .object([:])))],
                api: "openai-completions", provider: "openai", model: "gpt-4o-mini", stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "shot",
                content: [.image(ImageContent(data: "QUJD", mimeType: "image/png"))])),
        ])
        _ = provider.stream(model: Self.model, context: ctx, options: nil)
        await Self.waitForRequest(client)
        let messages = (try Self.decodeBody(client))["messages"] as! [[String: Any]]
        #expect(!messages.contains { ($0["role"] as? String) == "user" && $0["content"] is [[String: Any]] })
        let toolMsg = messages.first { $0["role"] as? String == "tool" }!
        #expect((toolMsg["content"] as? String)?.contains("tool image omitted") == true)
    }

    // MARK: - Feature 2: encrypted reasoning round-trip

    @Test("decodes encrypted reasoning_details into the matching tool call's thoughtSignature")
    func reasoningDetailRoundTripDecode() async throws {
        let sse = """
        data: {"id":"c","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function","function":{"name":"f","arguments":"{}"}}]}}]}

        data: {"id":"c","choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.encrypted","id":"call_x","data":"ENC"}]}}]}

        data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let client = StubSSEClient(body: sse)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "x"))]), options: nil)
        let result = await s.result()
        guard case .toolCall(let tc)? = result.content.first(where: {
            if case .toolCall = $0 { return true }; return false }) else { Issue.record("no tool call"); return }
        #expect(tc.id == "call_x")
        let sig = tc.thoughtSignature ?? ""
        #expect(sig.contains("\"data\":\"ENC\"") || sig.contains("reasoning.encrypted"))
    }

    @Test("re-emits reasoning_details on encoded tool_calls")
    func reasoningDetailEncode() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let detail = "{\"type\":\"reasoning.encrypted\",\"id\":\"call_x\",\"data\":\"ENC\"}"
        let ctx = Context(messages: [
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: "call_x", name: "f", arguments: .object([:]), thoughtSignature: detail))],
                api: "openai-completions", provider: "openai", model: "gpt-4o-mini", stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "call_x", toolName: "f", content: [.text(TextContent(text: "ok"))])),
        ])
        _ = provider.stream(model: Self.model, context: ctx, options: nil)
        await Self.waitForRequest(client)
        let messages = (try Self.decodeBody(client))["messages"] as! [[String: Any]]
        let asst = messages.first { $0["role"] as? String == "assistant" }!
        let rd = asst["reasoning_details"] as! [[String: Any]]
        #expect((rd.first?["type"] as? String) == "reasoning.encrypted")
        #expect((rd.first?["data"] as? String) == "ENC")
    }

    // MARK: - Feature 3: tool-call-id normalization

    @Test("pipe-delimited tool-call id is split, sanitized, truncated; result id kept consistent")
    func toolCallIdNormalization() async throws {
        let longTail = String(repeating: "a/+=", count: 50)
        let rawId = "call_ab+cd|\(longTail)"
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let ctx = Context(messages: [
            .assistant(AssistantMessage(content: [.toolCall(ToolCall(id: rawId, name: "f", arguments: .object([:])))],
                api: "openai-completions", provider: "openai", model: "some-other-model", stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: rawId, toolName: "f", content: [.text(TextContent(text: "ok"))])),
        ])
        _ = provider.stream(model: Self.model, context: ctx, options: nil)
        await Self.waitForRequest(client)
        let messages = (try Self.decodeBody(client))["messages"] as! [[String: Any]]
        let asst = messages.first { $0["role"] as? String == "assistant" }!
        let calls = asst["tool_calls"] as! [[String: Any]]
        let normId = calls.first!["id"] as! String
        #expect(normId == "call_ab_cd")
        #expect(normId.count <= 40)
        let tool = messages.first { $0["role"] as? String == "tool" }!
        #expect(tool["tool_call_id"] as? String == normId)
    }

    @Test("provider==openai truncates a >40-char non-piped id to 40")
    func openaiTruncateId() async throws {
        let rawId = String(repeating: "x", count: 60)
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let ctx = Context(messages: [
            .assistant(AssistantMessage(content: [.toolCall(ToolCall(id: rawId, name: "f", arguments: .object([:])))],
                api: "openai-completions", provider: "openai", model: "some-other-model", stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: rawId, toolName: "f", content: [.text(TextContent(text: "ok"))])),
        ])
        _ = provider.stream(model: Self.model, context: ctx, options: nil)
        await Self.waitForRequest(client)
        let messages = (try Self.decodeBody(client))["messages"] as! [[String: Any]]
        let calls = (messages.first { $0["role"] as? String == "assistant" }!)["tool_calls"] as! [[String: Any]]
        #expect((calls.first!["id"] as! String).count == 40)
    }

    // MARK: - Feature 4: richer usage parsing

    @Test("parses DeepSeek prompt_cache_hit_tokens, cache_write_tokens, reasoning_tokens")
    func richUsageParsing() async throws {
        let sse = """
        data: {"id":"c","choices":[{"index":0,"delta":{"content":"hi"}}]}

        data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_cache_hit_tokens":30,"prompt_tokens_details":{"cache_write_tokens":10},"completion_tokens_details":{"reasoning_tokens":7}}}

        data: [DONE]

        """
        let client = StubSSEClient(body: sse)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "x"))]), options: nil)
        let r = await s.result()
        #expect(r.usage.cacheRead == 30)
        #expect(r.usage.cacheWrite == 10)
        #expect(r.usage.reasoning == 7)
        #expect(r.usage.input == 60)
        #expect(r.usage.output == 20)
        #expect(r.usage.totalTokens == 120)
    }

    @Test("falls back to choice.usage when chunk.usage absent (Moonshot)")
    func choiceUsageFallback() async throws {
        let sse = """
        data: {"id":"c","choices":[{"index":0,"delta":{"content":"hi"},"usage":{"prompt_tokens":8,"completion_tokens":4}}]}

        data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop","usage":{"prompt_tokens":8,"completion_tokens":4}}]}

        data: [DONE]

        """
        let client = StubSSEClient(body: sse)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "x"))]), options: nil)
        let r = await s.result()
        #expect(r.usage.input == 8)
        #expect(r.usage.output == 4)
    }

    // MARK: - Feature 5: stream-end validation

    @Test("throws when stream ends without finish_reason")
    func missingFinishReason() async throws {
        let sse = """
        data: {"id":"c","choices":[{"index":0,"delta":{"content":"partial"}}]}

        """
        let client = StubSSEClient(body: sse)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "x"))]), options: nil)
        var sawError = false
        for await e in s { if case .error = e { sawError = true } }
        let r = await s.result()
        #expect(sawError)
        #expect(r.stopReason == .error)
        #expect(r.errorMessage == "Stream ended without finish_reason")
    }

    @Test("content_filter finish_reason surfaces as an error")
    func contentFilterIsError() async throws {
        let sse = """
        data: {"id":"c","choices":[{"index":0,"delta":{"content":"x"},"finish_reason":"content_filter"}]}

        data: [DONE]

        """
        let client = StubSSEClient(body: sse)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "x"))]), options: nil)
        var sawError = false
        for await e in s { if case .error = e { sawError = true } }
        let r = await s.result()
        #expect(sawError)
        #expect(r.stopReason == .error)
    }
}
