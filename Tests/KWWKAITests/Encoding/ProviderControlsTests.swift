import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// The `ModelCompat` fields that stand in for a provider name: unset, every
/// name keeps the value it had before they existed; set, the field wins under
/// any name; and a relay's own name with the fields set sends what the
/// vendor's name sends.
@Suite("Provider-keyed behaviour controls")
struct ProviderControlsTests {
    static let labels = ["openrouter", "anthropic", "openai", "some-relay"]

    private static func model(
        _ provider: String,
        api: String = "openai-completions",
        id: String = "m",
        baseURL: String = "https://relay.example/llm",
        _ configure: (inout ModelCompat) -> Void = { _ in }
    ) -> Model {
        var compat = ModelCompat()
        configure(&compat)
        return Model(
            id: id,
            api: api,
            provider: provider,
            baseURL: baseURL,
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 1, output: 4, cacheRead: 0.5, cacheWrite: 0),
            contextWindow: 200_000,
            maxTokens: 64_000,
            compat: compat == ModelCompat() ? nil : compat
        )
    }

    // MARK: - Unset: the values each name had before

    @Test("unset controls keep each provider name's image limit")
    func imageLimitDefaults() {
        let expected = ["openrouter": 90, "anthropic": 90, "openai": 200, "some-relay": 5]
        for label in Self.labels {
            #expect(ProviderImageBudget.limit(for: Self.model(label)) == expected[label])
        }
    }

    @Test("unset controls keep each provider name's output-limit policy")
    func outputPolicyDefaults() {
        for label in Self.labels {
            let model = Self.model(label)
            let openRouter = label == "openrouter"
            #expect(OutputTokenPolicy.omitsAutomaticLimit(for: model) == openRouter)
            #expect(OutputTokenPolicy.usesSmallAnswerReserve(for: model) == openRouter)
            #expect(OutputTokenPolicy.automaticLimit(for: model) == (openRouter ? nil : 64_000))
        }
    }

    @Test("unset controls keep each provider name's tool-call id length")
    func toolCallIdLengthDefaults() {
        let expected = ["openrouter": 64, "anthropic": 64, "openai": 40, "some-relay": 64]
        let long = String(repeating: "a", count: 50)
        for label in Self.labels {
            let model = Self.model(label)
            #expect(TransformMessages.idLimit(for: model) == expected[label])
            let normalized = TransformMessages.normalizeId(long, model: model)
            #expect((normalized == long) == (expected[label] == 64))
            #expect(normalized.count <= expected[label]!)
            // A Responses-origin id is held to 40 under every name.
            #expect(TransformMessages.normalizeId(long + "|item", model: model).count == 40)
        }
    }

    @Test("unset controls keep each provider name's reading of usage.cost")
    func billedCostDefaults() async {
        for label in Self.labels {
            let usage = await Self.billedUsage(Self.model(label))
            #expect(usage.cost.billed == (label == "openrouter" ? true : nil))
            #expect(abs(usage.cost.total - (label == "openrouter" ? 0.0123 : 0.0011)) < 1e-12)
        }
    }

    @Test("unset controls keep the chat-completions wire defaults of each provider name")
    func completionsCompatDefaults() {
        for label in Self.labels {
            let compat = OpenAICompletionsProvider.resolveCompat(Self.model(label, id: "anthropic/claude"))
            let openRouter = label == "openrouter"
            #expect(compat.thinkingFormat == (openRouter ? "openrouter" : "openai"))
            #expect(compat.cacheControlFormat == (openRouter ? "anthropic" : nil))
            // Only OpenAI's name sends the developer role (pi #10741).
            #expect(compat.supportsDeveloperRole == (label == "openai"))
            #expect(compat.sendSessionAffinityHeaders == openRouter)
            #expect(compat.sessionAffinityFormat == (openRouter ? "openrouter" : "openai"))
            #expect(compat.supportsStore == true)
            #expect(compat.maxTokensField == "max_completion_tokens")
        }
        // OpenRouter no longer grants it to anthropic/ and openai/ ids; any id
        // gets system there, and developer under OpenAI's name or base URL.
        for id in ["x/y", "openai/gpt-6"] {
            #expect(OpenAICompletionsProvider.resolveCompat(Self.model("openrouter", id: id))
                .supportsDeveloperRole == false)
            #expect(OpenAICompletionsProvider.resolveCompat(Self.model("some-relay", id: id))
                .supportsDeveloperRole == false)
            #expect(OpenAICompletionsProvider.resolveCompat(Self.model("openai", id: id))
                .supportsDeveloperRole == true)
            #expect(OpenAICompletionsProvider.resolveCompat(
                Self.model("some-relay", id: id, baseURL: "https://api.openai.com/v1")
            ).supportsDeveloperRole == true)
        }
    }

    @Test("unset, prompt_cache_key follows the base URL and long retention")
    func promptCacheKeyDefaults() throws {
        let options = StreamOptions(cacheRetention: .short, sessionId: "s1")
        for label in Self.labels {
            let relayed = try Self.completionsBody(Self.model(label), options)
            #expect(relayed["prompt_cache_key"] == nil)
            let direct = try Self.completionsBody(
                Self.model(label, baseURL: "https://api.openai.com/v1"),
                options
            )
            #expect(direct["prompt_cache_key"] as? String == "s1")
        }
    }

    // MARK: - Set: the field wins under any name

    @Test("maxImagesPerRequest wins under any provider name")
    func imageLimitExplicit() {
        for label in Self.labels {
            #expect(ProviderImageBudget.limit(for: Self.model(label) { $0.maxImagesPerRequest = 37 }) == 37)
            #expect(ProviderImageBudget.limit(for: Self.model(label) { $0.maxImagesPerRequest = -1 }) == 0)
        }
    }

    @Test("omitsAutomaticOutputLimit and usesSmallAnswerReserve win under any provider name")
    func outputPolicyExplicit() throws {
        for label in Self.labels {
            let omitting = Self.model(label) { $0.omitsAutomaticOutputLimit = true }
            #expect(OutputTokenPolicy.automaticLimit(for: omitting) == nil)
            #expect(try Self.completionsBody(omitting, nil)["max_completion_tokens"] == nil)
            // An explicit request limit still goes on the wire.
            #expect(OutputTokenPolicy.effectiveLimit(for: omitting, requested: 8_192) == 8_192)

            let sending = Self.model(label) { $0.omitsAutomaticOutputLimit = false }
            #expect(OutputTokenPolicy.automaticLimit(for: sending) == 64_000)
            #expect(try Self.completionsBody(sending, nil)["max_completion_tokens"] as? Int == 64_000)

            #expect(OutputTokenPolicy.usesSmallAnswerReserve(
                for: Self.model(label) { $0.usesSmallAnswerReserve = true }))
            #expect(!OutputTokenPolicy.usesSmallAnswerReserve(
                for: Self.model(label) { $0.usesSmallAnswerReserve = false }))
        }
    }

    @Test("maxToolCallIdLength wins under any provider name")
    func toolCallIdLengthExplicit() {
        let long = String(repeating: "a", count: 50)
        for label in Self.labels {
            let short = Self.model(label) { $0.maxToolCallIdLength = 40 }
            #expect(TransformMessages.normalizeId(long, model: short).count == 40)
            let wide = Self.model(label) { $0.maxToolCallIdLength = 64 }
            #expect(TransformMessages.normalizeId(long, model: wide) == long)
            #expect(TransformMessages.normalizeId(long + "|item", model: wide).count == 40)
            #expect(TransformMessages.idLimit(for: Self.model(label) { $0.maxToolCallIdLength = 3 }) == 16)
        }
    }

    @Test("trustsReportedCost wins under any provider name")
    func billedCostExplicit() async {
        for label in Self.labels {
            let trusted = await Self.billedUsage(Self.model(label) { $0.trustsReportedCost = true })
            #expect(trusted.cost.total == 0.0123)
            #expect(trusted.cost.billed == true)
            let estimated = await Self.billedUsage(Self.model(label) { $0.trustsReportedCost = false })
            #expect(abs(estimated.cost.total - 0.0011) < 1e-12)
            #expect(estimated.cost.billed == nil)
        }
    }

    @Test("sendsPromptCacheKey wins under any provider name and base URL")
    func promptCacheKeyExplicit() throws {
        let options = StreamOptions(cacheRetention: .short, sessionId: "s1")
        for label in Self.labels {
            let on = try Self.completionsBody(Self.model(label) { $0.sendsPromptCacheKey = true }, options)
            #expect(on["prompt_cache_key"] as? String == "s1")
            let off = try Self.completionsBody(
                Self.model(label, baseURL: "https://api.openai.com/v1") { $0.sendsPromptCacheKey = false },
                StreamOptions(cacheRetention: .long, sessionId: "s1")
            )
            #expect(off["prompt_cache_key"] == nil)
        }
        // Anthropic cache markers and the OpenAI key never share a request.
        let marked = try Self.completionsBody(Self.model("some-relay") {
            $0.sendsPromptCacheKey = true
            $0.cacheControlFormat = "anthropic"
        }, options)
        #expect(marked["prompt_cache_key"] == nil)
    }

    // MARK: - behavesLikeProvider

    @Test("behavesLikeProvider gives another name's defaults and leaves the name alone")
    func behavesLike() async {
        let expectedImages = ["openrouter": 90, "anthropic": 90, "openai": 200]
        let expectedIds = ["openrouter": 64, "anthropic": 64, "openai": 40]
        for like in ["openrouter", "anthropic", "openai"] {
            let model = Self.model("some-relay", id: "anthropic/claude") { $0.behavesLikeProvider = like }
            let named = Self.model(like, id: "anthropic/claude")
            #expect(model.provider == "some-relay")
            #expect(model.behaviorProvider == like)
            #expect(ProviderImageBudget.limit(for: model) == expectedImages[like])
            #expect(TransformMessages.idLimit(for: model) == expectedIds[like])
            #expect(OutputTokenPolicy.automaticLimit(for: model) == OutputTokenPolicy.automaticLimit(for: named))
            #expect(OutputTokenPolicy.usesSmallAnswerReserve(for: model) == (like == "openrouter"))
            let compat = OpenAICompletionsProvider.resolveCompat(model)
            let namedCompat = OpenAICompletionsProvider.resolveCompat(named)
            #expect(compat.thinkingFormat == namedCompat.thinkingFormat)
            #expect(compat.cacheControlFormat == namedCompat.cacheControlFormat)
            #expect(compat.sendSessionAffinityHeaders == namedCompat.sendSessionAffinityHeaders)
            #expect(compat.sessionAffinityFormat == namedCompat.sessionAffinityFormat)
            #expect(await Self.billedUsage(model).cost.billed == (like == "openrouter" ? true : nil))
            #expect(ProviderAttribution.attributionHeaders(for: model)
                == ProviderAttribution.attributionHeaders(provider: like))
        }
        #expect(Self.model("some-relay").behaviorProvider == "some-relay")
        #expect(Self.model("some-relay") { $0.behavesLikeProvider = "" }.behaviorProvider == "some-relay")
        #expect(OpenAIResponsesProvider.isXai(Self.model("some-relay") { $0.behavesLikeProvider = "xai" }))
    }

    @Test("an explicit field wins over behavesLikeProvider")
    func explicitBeatsBehavesLike() {
        let model = Self.model("some-relay") {
            $0.behavesLikeProvider = "openrouter"
            $0.maxImagesPerRequest = 12
            $0.omitsAutomaticOutputLimit = false
            $0.usesSmallAnswerReserve = false
            $0.maxToolCallIdLength = 40
            $0.thinkingFormat = "openai"
            $0.sendSessionAffinityHeaders = false
        }
        #expect(ProviderImageBudget.limit(for: model) == 12)
        #expect(OutputTokenPolicy.automaticLimit(for: model) == 64_000)
        #expect(!OutputTokenPolicy.usesSmallAnswerReserve(for: model))
        #expect(TransformMessages.idLimit(for: model) == 40)
        let compat = OpenAICompletionsProvider.resolveCompat(model)
        #expect(compat.thinkingFormat == "openai")
        #expect(compat.sendSessionAffinityHeaders == false)
    }

    // MARK: - A relay's name with the fields set sends what the vendor's name sends

    /// What a model has to carry to send, under another name, what the
    /// `openrouter` name sends on chat completions.
    static func openRouterControls(id: String) -> (inout ModelCompat) -> Void {
        { compat in
            compat.thinkingFormat = "openrouter"
            if id.hasPrefix("anthropic/") { compat.cacheControlFormat = "anthropic" }
            compat.sendSessionAffinityHeaders = true
            compat.sessionAffinityFormat = "openrouter"
            compat.maxImagesPerRequest = 90
            compat.omitsAutomaticOutputLimit = true
            compat.usesSmallAnswerReserve = true
            compat.trustsReportedCost = true
        }
    }

    @Test(
        "chat completions: a relay's name with OpenRouter's controls sends OpenRouter's request",
        arguments: ["anthropic/claude-sonnet-5", "openai/gpt-6", "moonshotai/kimi-k3"]
    )
    func completionsEquivalence(id: String) async throws {
        let named = Self.model("openrouter", id: id)
        let variants = [
            Self.model("airbuild", id: id, Self.openRouterControls(id: id)),
            Self.model("airbuild", id: id) { $0.behavesLikeProvider = "openrouter" },
        ]
        for relay in variants {
            for images in [6, 91] {
                let expected = try await Self.request(named, images: images) {
                    OpenAICompletionsProvider(client: $0, defaultAPIKey: "k")
                }
                let actual = try await Self.request(relay, images: images) {
                    OpenAICompletionsProvider(client: $0, defaultAPIKey: "k")
                }
                #expect(actual == expected)
                #expect(expected.url.path == "/llm/v1/chat/completions")
                #expect(expected.headers["x-session-id"] == "session-1")
                #expect(expected.imageCount == min(images, 90))
                #expect(expected.body["max_completion_tokens"] == nil)
                #expect(expected.body["max_tokens"] == nil)
            }
            let expectedUsage = await Self.billedUsage(named)
            let actualUsage = await Self.billedUsage(relay)
            #expect(actualUsage == expectedUsage)
            #expect(actualUsage.cost.billed == true)
        }
        // Without the controls the relay's name falls to the defaults.
        let bare = try await Self.request(Self.model("airbuild", id: id), images: 6) {
            OpenAICompletionsProvider(client: $0, defaultAPIKey: "k")
        }
        #expect(bare.imageCount == 5)
        #expect(bare.headers["x-session-id"] == nil)
        #expect(bare.body["max_completion_tokens"] as? Int == 64_000)
    }

    @Test("Anthropic Messages: a relay's name with Anthropic's controls sends Anthropic's request")
    func anthropicEquivalence() async throws {
        let id = "claude-sonnet-5"
        let named = Self.model("anthropic", api: "anthropic-messages", id: id)
        let variants = [
            Self.model("airbuild", api: "anthropic-messages", id: id) { $0.maxImagesPerRequest = 90 },
            Self.model("airbuild", api: "anthropic-messages", id: id) { $0.behavesLikeProvider = "anthropic" },
        ]
        for relay in variants {
            for images in [6, 91] {
                let expected = try await Self.request(named, images: images) {
                    AnthropicProvider(client: $0, defaultAPIKey: "k")
                }
                let actual = try await Self.request(relay, images: images) {
                    AnthropicProvider(client: $0, defaultAPIKey: "k")
                }
                #expect(actual == expected)
                #expect(expected.url.path == "/llm/v1/messages")
                #expect(expected.imageCount == min(images, 90))
                #expect(expected.body["max_tokens"] as? Int == 64_000)
            }
        }
        let bare = try await Self.request(
            Self.model("airbuild", api: "anthropic-messages", id: id), images: 6
        ) { AnthropicProvider(client: $0, defaultAPIKey: "k") }
        #expect(bare.imageCount == 5)
    }

    @Test("OpenAI Responses: a relay's name with OpenAI's controls sends OpenAI's request")
    func responsesEquivalence() async throws {
        let id = "gpt-6"
        let named = Self.model("openai", api: "openai-responses", id: id)
        let variants = [
            Self.model("airbuild", api: "openai-responses", id: id) {
                $0.maxImagesPerRequest = 200
                $0.maxToolCallIdLength = 40
            },
            Self.model("airbuild", api: "openai-responses", id: id) { $0.behavesLikeProvider = "openai" },
        ]
        for relay in variants {
            for images in [6, 91] {
                let expected = try await Self.request(named, images: images) {
                    OpenAIResponsesProvider(client: $0, webSocketClient: nil, defaultAPIKey: "k")
                }
                let actual = try await Self.request(relay, images: images) {
                    OpenAIResponsesProvider(client: $0, webSocketClient: nil, defaultAPIKey: "k")
                }
                #expect(actual == expected)
                #expect(expected.url.path == "/llm/v1/responses")
                #expect(expected.imageCount == images)
                #expect(expected.body["max_output_tokens"] as? Int == 64_000)
            }
        }
        // Without the controls the relay's name keeps 5 images and lets the
        // other model's 50-character tool-call id through whole.
        let bare = try await Self.request(
            Self.model("airbuild", api: "openai-responses", id: id), images: 6
        ) { OpenAIResponsesProvider(client: $0, webSocketClient: nil, defaultAPIKey: "k") }
        #expect(bare.imageCount == 5)
        let expected = try await Self.request(named, images: 6) {
            OpenAIResponsesProvider(client: $0, webSocketClient: nil, defaultAPIKey: "k")
        }
        #expect(expected.bodyText.contains(Self.foreignCallId) == false)
        #expect(bare.bodyText.contains(Self.foreignCallId))
    }

    // MARK: - Catalog files written before these fields

    @Test("a catalog entry written before these fields decodes and encodes as it did")
    func oldCatalogEntry() throws {
        let json = """
        {"id":"anthropic/claude-opus-4.6","name":"Claude Opus 4.6","api":"openai-completions",
         "provider":"openrouter","baseUrl":"https://openrouter.ai/api/v1","reasoning":true,
         "input":["text","image"],"cost":{"input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25},
         "contextWindow":1000000,"maxTokens":128000,
         "compat":{"thinkingFormat":"openrouter","supportsDeveloperRole":true,
                   "cacheControlFormat":"anthropic","supportsLongCacheRetention":false}}
        """
        let decoded = try JSONDecoder().decode(Model.self, from: Data(json.utf8))

        var compat = ModelCompat()
        compat.thinkingFormat = "openrouter"
        compat.supportsDeveloperRole = true
        compat.cacheControlFormat = "anthropic"
        compat.supportsLongCacheRetention = false
        #expect(decoded == Model(
            id: "anthropic/claude-opus-4.6",
            name: "Claude Opus 4.6",
            api: "openai-completions",
            provider: "openrouter",
            baseURL: "https://openrouter.ai/api/v1",
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
            contextWindow: 1_000_000,
            maxTokens: 128_000,
            compat: compat
        ))
        #expect(decoded.compat?.behavesLikeProvider == nil)
        #expect(decoded.compat?.maxImagesPerRequest == nil)
        #expect(decoded.compat?.omitsAutomaticOutputLimit == nil)
        #expect(decoded.compat?.usesSmallAnswerReserve == nil)
        #expect(decoded.compat?.trustsReportedCost == nil)
        #expect(decoded.compat?.maxToolCallIdLength == nil)
        #expect(decoded.compat?.sendsPromptCacheKey == nil)
        #expect(decoded.behaviorProvider == "openrouter")

        // Unset fields are not written, so the entry round-trips key for key.
        let original = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary
        #expect(encoded == original)
    }

    @Test("the fields round-trip through Codable")
    func controlsRoundTrip() throws {
        var compat = ModelCompat()
        compat.behavesLikeProvider = "openrouter"
        compat.maxImagesPerRequest = 90
        compat.omitsAutomaticOutputLimit = true
        compat.usesSmallAnswerReserve = true
        compat.trustsReportedCost = true
        compat.maxToolCallIdLength = 40
        compat.sendsPromptCacheKey = false
        let decoded = try JSONDecoder().decode(ModelCompat.self, from: JSONEncoder().encode(compat))
        #expect(decoded == compat)
    }

    @Test("no bundled catalog model sets the fields")
    func bundledCatalogLeavesControlsUnset() {
        for model in ModelsCatalog.all {
            guard let compat = model.compat else { continue }
            #expect(compat.behavesLikeProvider == nil)
            #expect(compat.maxImagesPerRequest == nil)
            #expect(compat.omitsAutomaticOutputLimit == nil)
            #expect(compat.usesSmallAnswerReserve == nil)
            #expect(compat.trustsReportedCost == nil)
            #expect(compat.maxToolCallIdLength == nil)
            #expect(compat.sendsPromptCacheKey == nil)
        }
    }

    // MARK: - Support

    private static let billedSSE = """
    data: {"id":"c","choices":[{"index":0,"delta":{"content":"hi"}}]}

    data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1000,"completion_tokens":200,"prompt_tokens_details":{"cached_tokens":400},"cost":0.0123}}

    data: [DONE]

    """

    /// 600 input, 200 output and 400 cached tokens at 0.5 / 3 / 0.5 USD per
    /// million estimate to 0.0011; the stream reports 0.0123.
    private static func billedUsage(_ model: Model) async -> Usage {
        var model = model
        model.cost = ModelCost(input: 0.5, output: 3, cacheRead: 0.5, cacheWrite: 0)
        let provider = OpenAICompletionsProvider(client: StubSSEClient(body: billedSSE), defaultAPIKey: "k")
        return await provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "x"))]),
            options: nil
        ).result().usage
    }

    private static func completionsBody(_ model: Model, _ options: StreamOptions?) throws -> [String: Any] {
        try OpenAICompletionsProvider.encodeBodyDict(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: options
        )
    }

    struct CapturedRequest: Equatable {
        var url: URL
        var method: String
        var headers: [String: String]
        var bodyText: String

        var body: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any]) ?? [:]
        }

        var imageCount: Int {
            (0..<200).count { bodyText.contains("aW1hZ2Ut\(String(format: "%03d", $0))") }
        }
    }

    /// A 50-character id from another model's turn: past `openai`'s 40,
    /// within everyone else's 64.
    static let foreignCallId = "call_" + String(repeating: "f", count: 45)

    /// A turn another model answered with a tool call, then `images` images:
    /// the history every format has to reshape for the model it goes to.
    private static func context(images: Int) -> Context {
        Context(
            systemPrompt: "You are terse.",
            messages: [
                .user(UserMessage(text: "list the files")),
                .assistant(AssistantMessage(
                    content: [
                        .thinking(ThinkingContent(thinking: "I should look.", thinkingSignature: "sig")),
                        .toolCall(ToolCall(id: foreignCallId, name: "ls", arguments: .object(["path": "."]))),
                    ],
                    api: "google-generative-ai",
                    provider: "google",
                    model: "gemini",
                    stopReason: .toolUse,
                    timestamp: 1
                )),
                .toolResult(ToolResultMessage(
                    toolCallId: foreignCallId,
                    toolName: "ls",
                    content: [.text(TextContent(text: "a.txt"))],
                    timestamp: 2
                )),
                .user(UserMessage(content: [.text(TextContent(text: "and these"))] + (0..<images).map {
                    .image(ImageContent(data: "aW1hZ2Ut\(String(format: "%03d", $0))", mimeType: "image/png"))
                })),
            ],
            tools: [Tool(name: "ls", description: "List files", parameters: [
                "type": "object", "properties": ["path": ["type": "string"]],
            ])]
        )
    }

    /// The request the top-level `stream()` puts on the wire for `model`,
    /// through a registry holding only the provider under test.
    private static func request(
        _ model: Model,
        images: Int,
        provider make: (StubSSEClient) -> any APIProvider
    ) async throws -> CapturedRequest {
        let client = StubSSEClient(body: "")
        let registry = APIRegistry()
        await registry.register(make(client), scope: model.provider)
        let stream = try await stream(
            model: model,
            context: context(images: images),
            options: StreamOptions(cacheRetention: .short, sessionId: "session-1", reasoning: .high),
            registry: registry
        )
        _ = await stream.result()
        let request = try #require(client.lastRequest)
        return CapturedRequest(
            url: request.url,
            method: request.method,
            headers: request.headers,
            bodyText: String(decoding: request.body ?? Data(), as: UTF8.self)
        )
    }
}
