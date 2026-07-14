import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// Stub HTTP client that streams a pre-recorded SSE body from memory. Also
/// captures the request body so we can assert on the encoding.
final class StubSSEClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    let body: String
    var statusCode: Int
    var lastRequest: (url: URL, method: String, headers: [String: String], body: Data?)?

    init(body: String, statusCode: Int = 200) {
        self.body = body
        self.statusCode = statusCode
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body requestBody: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        lock.withLock { lastRequest = (url, method, headers, requestBody) }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "text/event-stream"]
        )!

        let bodyData = Data(body.utf8)
        let stream = AsyncThrowingStream<Data, Error> { cont in
            Task {
                cont.yield(bodyData)
                cont.finish()
            }
        }
        return (response, stream)
    }
}

@Suite("Anthropic provider")
struct AnthropicProviderTests {

    static let sampleModel = Model(
        id: "claude-test",
        name: "Claude Test",
        api: "anthropic-messages",
        provider: "anthropic",
        baseURL: "https://api.anthropic.com",
        reasoning: false,
        input: [.text],
        contextWindow: 128_000,
        maxTokens: 1024
    )

    private static let textSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":5,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private static let toolUseSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_2","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":10,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"calc","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"a\\":1"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":",\\"b\\":2}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @Test("streams basic text and resolves final assistant message")
    func basicText() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        let s = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var types: [String] = []
        var accText = ""
        for await event in s {
            types.append(event.type)
            if case .textDelta(_, let delta, _) = event { accText += delta }
        }
        let result = await s.result()
        #expect(types.contains("message_start") == false) // no such type at our boundary
        #expect(types.first == "start")
        #expect(types.contains("text_start"))
        #expect(types.contains("text_delta"))
        #expect(types.contains("text_end"))
        #expect(types.last == "done")
        #expect(accText == "Hello, world")
        #expect(result.stopReason == .stop)
        #expect(result.content == [.text(TextContent(text: "Hello, world"))])
        #expect(result.usage.input == 5)
        #expect(result.usage.output == 4)
    }

    @Test("streams a tool_use block and parses incremental JSON input")
    func toolUse() async throws {
        let client = StubSSEClient(body: Self.toolUseSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        let s = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "please call calc"))]),
            options: nil
        )
        var seenToolEnd = false
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event {
                #expect(call.id == "toolu_1")
                #expect(call.name == "calc")
                #expect(call.arguments == .object(["a": 1, "b": 2]))
                seenToolEnd = true
            }
        }
        let result = await s.result()
        #expect(seenToolEnd)
        #expect(result.stopReason == .toolUse)
    }

    @Test("surfaces HTTP errors as terminal stream errors")
    func httpError() async throws {
        let client = StubSSEClient(body: "", statusCode: 500)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        let s = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var terminalError: AssistantMessage?
        for await event in s {
            if case .error(_, let err) = event { terminalError = err }
        }
        #expect(terminalError != nil)
        #expect(terminalError?.stopReason == .error)
    }

    @Test("sets x-api-key and anthropic-version headers")
    func headersWired() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(
            client: client,
            defaultAPIKey: "default-key",
            apiVersion: "2023-06-01"
        )
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(apiKey: "override-key")
        )
        // Give the detached task time to emit the request.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let req = client.lastRequest
        #expect(req != nil)
        #expect(req?.headers["x-api-key"] == "override-key")
        #expect(req?.headers["anthropic-version"] == "2023-06-01")
        #expect(req?.headers["accept"] == "text/event-stream")
    }

    @Test("model headers are included in Anthropic requests")
    func modelHeadersAreIncluded() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        var model = Self.sampleModel
        model.headers = ["User-Agent": "KimiCLI/1.5"]

        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.lastRequest?.headers["User-Agent"] == "KimiCLI/1.5")
    }

    @Test("resolved auth can select bearer scheme and merge custom headers")
    func resolvedAuthBearerHeaders() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "default-key")
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                apiKey: "ignored-key",
                headers: ["x-extra": "override"],
                resolvedAuth: ResolvedProviderAuth(
                    token: "oauth-token",
                    scheme: .bearer,
                    headers: ["anthropic-beta": "oauth-2025-04-20", "x-extra": "auth"]
                )
            )
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let headers = client.lastRequest?.headers ?? [:]
        #expect(headers["Authorization"] == "Bearer oauth-token")
        #expect(headers["x-api-key"] == nil)
        // The resolved-auth oauth beta is preserved; the interleaved-thinking
        // beta (pi default) is appended to the same header rather than
        // clobbering it.
        #expect(headers["anthropic-beta"]?.contains("oauth-2025-04-20") == true)
        #expect(headers["x-extra"] == "override")
    }

    @Test("encodes user text and tool blocks in Anthropic body shape")
    func encodesBody() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let tool = Tool(
            name: "calc",
            description: "arithmetic",
            parameters: [
                "type": "object",
                "properties": ["a": ["type": "number"], "b": ["type": "number"]],
                "required": ["a", "b"],
            ]
        )
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: "c-1", name: "calc", arguments: ["a": 1, "b": 2]))],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude-test",
            stopReason: .toolUse
        )
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [
                    .user(UserMessage(text: "calc 1 + 2")),
                    .assistant(assistant),
                    .toolResult(ToolResultMessage(
                        toolCallId: "c-1",
                        toolName: "calc",
                        content: [.text(TextContent(text: "3"))]
                    )),
                    .user(UserMessage(text: "thanks")),
                ],
                tools: [tool]
            ),
            // Opt out of caching so this test asserts the bare block shape
            // (string `system`); caching is covered separately below.
            options: StreamOptions(cacheRetention: CacheRetention.none)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)

        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "claude-test")
        #expect(json?["max_tokens"] as? Int == Self.sampleModel.maxTokens)
        #expect(json?["system"] as? String == "Be concise.")
        #expect((json?["messages"] as? [[String: Any]])?.count == 4)
        let tools = json?["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "calc")
    }

    @Test("rejects a non-positive required max_tokens before transport")
    func rejectsNonPositiveMaxTokens() async {
        var zeroMetadataModel = Self.sampleModel
        zeroMetadataModel.maxTokens = 0
        let cases: [(Model, StreamOptions?)] = [
            (zeroMetadataModel, nil),
            (Self.sampleModel, StreamOptions(maxTokens: 0)),
            (Self.sampleModel, StreamOptions(maxTokens: 0, reasoning: .high)),
            (Self.sampleModel, StreamOptions(maxTokens: -1, reasoning: .high)),
        ]

        for (model, options) in cases {
            let client = StubSSEClient(body: Self.textSSE)
            let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
            let response = provider.stream(
                model: model,
                context: Context(messages: [.user(UserMessage(text: "hi"))]),
                options: options
            )
            let result = await response.result()

            #expect(result.stopReason == .error)
            #expect(result.errorMessage?.contains("max_tokens must be positive") == true)
            #expect(client.lastRequest == nil)
        }
    }

    @Test("emits cache_control breakpoints on system, last tool, and final message by default")
    func cacheControlDefault() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let tool = Tool(name: "calc", description: "arithmetic", parameters: ["type": "object"])
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [.user(UserMessage(text: "hi"))],
                tools: [tool]
            ),
            options: nil // default retention = short
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        // system is array-form with a cache_control marker on the last block.
        let system = json?["system"] as? [[String: Any]]
        #expect(system?.last?["cache_control"] as? [String: Any] != nil)
        #expect((system?.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        // last tool definition carries a marker.
        let tools = json?["tools"] as? [[String: Any]]
        #expect(tools?.last?["cache_control"] as? [String: Any] != nil)
        // final message's last content block carries a marker.
        let messages = json?["messages"] as? [[String: Any]]
        let lastContent = messages?.last?["content"] as? [[String: Any]]
        #expect(lastContent?.last?["cache_control"] as? [String: Any] != nil)
        // short retention => no ttl + no extended-cache beta header.
        #expect((system?.last?["cache_control"] as? [String: Any])?["ttl"] == nil)
        #expect(client.lastRequest?.headers["anthropic-beta"]?.contains("extended-cache-ttl") != true)
    }

    @Test("long retention adds 1h ttl and the extended-cache beta header")
    func cacheControlLong() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(systemPrompt: "S", messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(cacheRetention: .long)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let system = json?["system"] as? [[String: Any]]
        #expect((system?.last?["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
        #expect(client.lastRequest?.headers["anthropic-beta"]?.contains("extended-cache-ttl-2025-04-11") == true)
    }

    @Test("cacheRetention .none omits all cache_control markers")
    func cacheControlOff() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(systemPrompt: "S", messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(cacheRetention: CacheRetention.none)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["system"] as? String == "S")
        let messages = json?["messages"] as? [[String: Any]]
        let lastContent = messages?.last?["content"] as? [[String: Any]]
        #expect(lastContent?.last?["cache_control"] == nil)
    }

    @Test("thinking block is emitted when reasoning level is set, temperature dropped")
    func thinkingBody() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        var model = Self.sampleModel
        model.reasoning = true
        model.maxTokens = 16_384
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(temperature: 0.2, reasoning: .medium)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let thinking = json?["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect(json?["max_tokens"] as? Int == model.maxTokens)
        // Default medium = 8192 tokens when no explicit ThinkingBudgets passed.
        #expect(thinking?["budget_tokens"] as? Int == 8192)
        // Claude Messages API rejects any temperature != 1 when thinking
        // is on, so we drop it from the body.
        #expect(json?["temperature"] == nil)
    }

    @Test("manual thinking raises a low explicit cap to preserve answer headroom")
    func thinkingRaisesLowExplicitMaxTokens() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        var model = Self.reasoningModel
        model.maxTokens = 64_000
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(maxTokens: 4_096, reasoning: .medium)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)

        let json = Self.decodeBody(client)
        let thinking = json["thinking"] as? [String: Any]
        #expect(json["max_tokens"] as? Int == 12_192)
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 8_192)
    }

    @Test("manual thinking is not silently disabled by a low explicit cap")
    func thinkingStaysEnabledBelowMinimumCombinedBudget() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        var model = Self.reasoningModel
        model.maxTokens = 64_000
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(temperature: 0.2, maxTokens: 2_047, reasoning: .high)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)

        let json = Self.decodeBody(client)
        let thinking = json["thinking"] as? [String: Any]
        #expect(json["max_tokens"] as? Int == 20_384)
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 16_384)
        #expect(json["temperature"] == nil)
    }

    @Test("signed thinking block is replayed even when its text is empty")
    func emptyThinkingWithSignaturePreserved() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let assistant = AssistantMessage(
            content: [
                .thinking(ThinkingContent(thinking: "", thinkingSignature: "signed-thinking")),
                .thinking(ThinkingContent(thinking: "  ")),
                .text(TextContent(text: "answer")),
            ],
            api: Self.sampleModel.api,
            provider: Self.sampleModel.provider,
            model: Self.sampleModel.id,
            usage: Usage(),
            stopReason: .stop,
            timestamp: Timestamp.now()
        )
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [
                .user(UserMessage(text: "hi")),
                .assistant(assistant),
                .user(UserMessage(text: "go on")),
            ]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 300_000_000)

        let json = Self.decodeBody(client)
        let messages = json["messages"] as? [[String: Any]]
        let content = messages?[1]["content"] as? [[String: Any]]
        // The signed empty block survives; the unsigned empty block is dropped.
        #expect(content?.count == 2)
        #expect(content?[0]["type"] as? String == "thinking")
        #expect(content?[0]["thinking"] as? String == "")
        #expect(content?[0]["signature"] as? String == "signed-thinking")
        #expect(content?[1]["type"] as? String == "text")
    }

    @Test("thinking is omitted when reasoning level is nil, temperature passes through")
    func thinkingOmittedWithoutReasoning() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(temperature: 0.2)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["thinking"] == nil)
        #expect(json?["temperature"] as? Double == 0.2)
    }

    // MARK: - pi parity helpers

    static let reasoningModel = Model(
        id: "claude-reason",
        name: "Claude Reason",
        api: "anthropic-messages",
        provider: "anthropic",
        baseURL: "https://api.anthropic.com",
        reasoning: true,
        input: [.text],
        contextWindow: 200_000,
        maxTokens: 1024
    )

    private static func decodeBody(_ client: StubSSEClient) -> [String: Any] {
        let body = client.lastRequest?.body ?? Data()
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    // MARK: - Feature 1: redacted_thinking decode

    private static let redactedThinkingSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_r","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":5,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"ENC_ABC"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @Test("redacted_thinking block decodes with [Reasoning redacted] + data + flag")
    func redactedThinkingDecodes() async throws {
        let client = StubSSEClient(body: Self.redactedThinkingSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var types: [String] = []
        for await event in s { types.append(event.type) }
        let result = await s.result()
        #expect(types.contains("thinking_start"))
        #expect(types.contains("thinking_end"))
        #expect(result.content == [.thinking(ThinkingContent(
            thinking: "[Reasoning redacted]",
            thinkingSignature: "ENC_ABC",
            redacted: true))])
    }

    // MARK: - Feature 2: thinking disabled when reasoning off

    @Test("thinking:{type:disabled} on reasoning model when reasoning is off")
    func thinkingDisabledWhenReasoningOff() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.reasoningModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions()
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let json = Self.decodeBody(client)
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }

    @Test("thinking disabled is skipped when thinkingLevelMap pins off to null")
    func thinkingDisabledSkippedWhenOffNull() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        var model = Self.reasoningModel
        model.thinkingLevelMap = ["off": nil]
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions()
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let json = Self.decodeBody(client)
        #expect(json["thinking"] == nil)
    }

    // MARK: - Feature 3: empty-signature / redacted encode

    @Test("empty-signature thinking degrades to a text block by default")
    func encodesEmptySignatureAsText() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let assistant = AssistantMessage(
            content: [.thinking(ThinkingContent(thinking: "reasoned", thinkingSignature: nil))],
            api: "anthropic-messages", provider: "anthropic", model: "claude-test"
        )
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [
                .user(UserMessage(text: "hi")),
                .assistant(assistant),
            ]),
            options: StreamOptions(cacheRetention: CacheRetention.none)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let json = Self.decodeBody(client)
        let messages = json["messages"] as? [[String: Any]]
        let content = messages?.last?["content"] as? [[String: Any]]
        #expect(content?.count == 1)
        #expect(content?.first?["type"] as? String == "text")
        #expect(content?.first?["text"] as? String == "reasoned")
    }

    @Test("empty-signature thinking kept as thinking when allowEmptySignature")
    func encodesEmptySignatureAsThinkingWhenAllowed() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        var model = Self.sampleModel
        var compat = ModelCompat()
        compat.allowEmptySignature = true
        model.compat = compat
        let assistant = AssistantMessage(
            content: [.thinking(ThinkingContent(thinking: "reasoned", thinkingSignature: nil))],
            api: "anthropic-messages", provider: "anthropic", model: "claude-test"
        )
        _ = provider.stream(
            model: model,
            context: Context(messages: [
                .user(UserMessage(text: "hi")),
                .assistant(assistant),
            ]),
            options: StreamOptions(cacheRetention: CacheRetention.none)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let json = Self.decodeBody(client)
        let messages = json["messages"] as? [[String: Any]]
        let content = messages?.last?["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "thinking")
        #expect(content?.first?["thinking"] as? String == "reasoned")
        #expect(content?.first?["signature"] as? String == "")
    }

    @Test("redacted thinking re-encodes as a redacted_thinking block")
    func encodesRedactedThinkingBack() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let assistant = AssistantMessage(
            content: [.thinking(ThinkingContent(
                thinking: "[Reasoning redacted]", thinkingSignature: "ENC", redacted: true))],
            api: "anthropic-messages", provider: "anthropic", model: "claude-test"
        )
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [
                .user(UserMessage(text: "hi")),
                .assistant(assistant),
            ]),
            options: StreamOptions(cacheRetention: CacheRetention.none)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let json = Self.decodeBody(client)
        let messages = json["messages"] as? [[String: Any]]
        let content = messages?.last?["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "redacted_thinking")
        #expect(content?.first?["data"] as? String == "ENC")
    }

    // MARK: - Feature 4: beta headers + eager_input_streaming

    @Test("interleaved-thinking beta sent by default")
    func interleavedBetaSentByDefault() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.reasoningModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.lastRequest?.headers["anthropic-beta"]?.contains("interleaved-thinking-2025-05-14") == true)
    }

    @Test("interleaved-thinking beta skipped for adaptive-thinking models")
    func interleavedBetaSkippedForAdaptive() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        var model = Self.reasoningModel
        var compat = ModelCompat()
        compat.forceAdaptiveThinking = true
        model.compat = compat
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.lastRequest?.headers["anthropic-beta"]?.contains("interleaved-thinking") != true)
    }

    @Test("fine-grained beta + no eager flag when eager streaming unsupported")
    func fineGrainedBetaWhenEagerUnsupported() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        var model = Self.sampleModel
        var compat = ModelCompat()
        compat.supportsEagerToolInputStreaming = false
        model.compat = compat
        let tool = Tool(name: "calc", description: "arithmetic", parameters: ["type": "object"])
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))], tools: [tool]),
            options: StreamOptions(cacheRetention: CacheRetention.none)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.lastRequest?.headers["anthropic-beta"]?.contains("fine-grained-tool-streaming-2025-05-14") == true)
        let json = Self.decodeBody(client)
        let tools = json["tools"] as? [[String: Any]]
        #expect(tools?.first?["eager_input_streaming"] == nil)
    }

    @Test("eager_input_streaming flag set + no fine-grained beta by default")
    func eagerStreamingByDefault() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let tool = Tool(name: "calc", description: "arithmetic", parameters: ["type": "object"])
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))], tools: [tool]),
            options: StreamOptions(cacheRetention: CacheRetention.none)
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.lastRequest?.headers["anthropic-beta"]?.contains("fine-grained-tool-streaming") != true)
        let json = Self.decodeBody(client)
        let tools = json["tools"] as? [[String: Any]]
        #expect(tools?.first?["eager_input_streaming"] as? Bool == true)
    }

    // MARK: - Feature 5: OAuth identity headers

    @Test("OAuth variant sends Claude Code identity headers")
    func oauthVariantSendsIdentityHeaders() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = ProviderVariants.anthropicOAuth(accessToken: "sk-ant-oat-x", client: client)
        var model = Self.sampleModel
        model.contextWindow = 1_000_000
        model.maxTokens = 128_000
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let headers = client.lastRequest?.headers ?? [:]
        #expect(headers["user-agent"] == "claude-cli/2.1.75")
        #expect(headers["x-app"] == "cli")
        #expect(headers["anthropic-beta"]?.contains("claude-code-20250219") == true)
        #expect(headers["anthropic-beta"]?.contains("oauth-2025-04-20") == true)
        #expect(headers["authorization"] == "Bearer sk-ant-oat-x")
        #expect(Self.decodeBody(client)["max_tokens"] as? Int == 64_000)
    }

    @Test("api-key provider has no Claude Code identity headers")
    func apiKeyProviderHasNoIdentityHeaders() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        let headers = client.lastRequest?.headers ?? [:]
        #expect(headers["x-app"] == nil)
        #expect(headers["anthropic-beta"]?.contains("claude-code-20250219") != true)
    }

    // MARK: - Feature 6: 1h cache write + reasoning tokens

    private static let usageSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_u","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":100,"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_1h_input_tokens":40}}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":20,"output_tokens_details":{"thinking_tokens":7}}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @Test("usage captures 1h cache-write and reasoning tokens without inflating total")
    func usageCaptures1hCacheWriteAndReasoning() async throws {
        let client = StubSSEClient(body: Self.usageSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        for await _ in s {}
        let result = await s.result()
        #expect(result.usage.cacheWrite1h == 40)
        #expect(result.usage.reasoning == 7)
        #expect(result.usage.output == 20)
        #expect(result.usage.totalTokens == 160)
    }
}
