import Foundation
import Testing
@testable import KWWKAI

@Suite("Max reasoning level")
struct MaxReasoningTests {
    private func model(
        api: String = "openai-completions",
        provider: String = "openai",
        id: String = "reasoning-model",
        map: [String: String?]
    ) -> Model {
        Model(
            id: id,
            api: api,
            provider: provider,
            baseURL: "https://api.openai.com",
            reasoning: true,
            thinkingLevelMap: map
        )
    }

    @Test("max is ordered above xhigh and extended levels clamp in both directions")
    func orderingAndClamping() {
        let maxOnly = model(map: ["max": "max"])
        #expect(supportedThinkingLevels(maxOnly) == [.off, .minimal, .low, .medium, .high, .max])
        #expect(clampThinkingLevel(maxOnly, .xhigh) == .max)
        #expect(resolveThinkingLevel(maxOnly, .xhigh) == "max")

        let xhighOnly = model(map: ["xhigh": "xhigh"])
        #expect(clampThinkingLevel(xhighOnly, .max) == .xhigh)
        #expect(resolveThinkingLevel(xhighOnly, .max) == "xhigh")

        let both = model(map: ["xhigh": "xhigh", "max": "max"])
        #expect(resolveThinkingLevel(both, .xhigh) == "xhigh")
        #expect(resolveThinkingLevel(both, .max) == "max")
        #expect(ModelThinkingLevel(reasoning: .max) == .max)
        #expect(ModelThinkingLevel.max.reasoningLevel == .max)
    }

    @Test("OpenAI Completions emits max and upgrades legacy xhigh on max-only models")
    func openAICompletions() throws {
        let maxOnly = model(map: ["max": "max"])
        let context = Context(messages: [.user(UserMessage(text: "hi"))])

        let exact = try OpenAICompletionsProvider.encodeBodyDict(
            model: maxOnly,
            context: context,
            options: StreamOptions(reasoning: .max)
        )
        #expect(exact["reasoning_effort"] as? String == "max")

        let legacy = try OpenAICompletionsProvider.encodeBodyDict(
            model: maxOnly,
            context: context,
            options: StreamOptions(reasoning: .xhigh)
        )
        #expect(legacy["reasoning_effort"] as? String == "max")
    }

    @Test("OpenAI Responses emits max")
    func openAIResponses() async throws {
        let client = StubSSEClient(body: Self.openAIResponsesSSE)
        let provider = OpenAIResponsesProvider(
            client: client,
            webSocketClient: nil,
            defaultAPIKey: "key"
        )
        let responseModel = model(
            api: "openai-responses",
            provider: "openai",
            map: ["max": "max"]
        )
        let stream = provider.stream(
            model: responseModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .max)
        )
        for await _ in stream {}

        let json = try JSONSerialization.jsonObject(
            with: client.lastRequest?.body ?? Data()
        ) as? [String: Any]
        let reasoning = json?["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "max")
    }

    @Test("Anthropic adaptive thinking upgrades legacy xhigh to max")
    func anthropic() async throws {
        let client = StubSSEClient(body: Self.anthropicSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "key")
        var compat = ModelCompat()
        compat.forceAdaptiveThinking = true
        var anthropicModel = model(
            api: "anthropic-messages",
            provider: "anthropic",
            id: "claude-opus-4-6",
            map: ["max": "max"]
        )
        anthropicModel.compat = compat

        let stream = provider.stream(
            model: anthropicModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .xhigh)
        )
        for await _ in stream {}

        let json = try JSONSerialization.jsonObject(
            with: client.lastRequest?.body ?? Data()
        ) as? [String: Any]
        let outputConfig = json?["output_config"] as? [String: Any]
        #expect(outputConfig?["effort"] as? String == "max")
    }

    @Test("Bedrock adaptive thinking upgrades legacy xhigh to max")
    func bedrock() {
        let bedrockModel = model(
            api: "bedrock-converse-stream",
            provider: "amazon-bedrock",
            id: "anthropic.claude-opus-4-6-v1",
            map: ["max": "max"]
        )
        let extras = BedrockProvider.buildAdditionalModelRequestFields(
            model: bedrockModel,
            options: StreamOptions(reasoning: .xhigh),
            env: [:]
        )
        let outputConfig = extras?["output_config"] as? [String: Any]
        #expect(outputConfig?["effort"] as? String == "max")
    }

    @Test("Gemini clamps max to its highest supported thinking level")
    func gemini() async throws {
        let client = StubSSEClient(body: Self.geminiSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "key")
        let geminiModel = model(
            api: "google-generative-ai",
            provider: "google",
            id: "gemini-3-pro-preview",
            map: [:]
        )
        let stream = provider.stream(
            model: geminiModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .max)
        )
        for await _ in stream {}

        let json = try JSONSerialization.jsonObject(
            with: client.lastRequest?.body ?? Data()
        ) as? [String: Any]
        let generationConfig = json?["generationConfig"] as? [String: Any]
        let thinkingConfig = generationConfig?["thinkingConfig"] as? [String: Any]
        #expect(thinkingConfig?["thinkingLevel"] as? String == "HIGH")
    }

    private static let openAIResponsesSSE = """
    data: {"type":"response.completed","response":{"id":"response","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}

    """

    private static let anthropicSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"message","role":"assistant","content":[],"model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":0}}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private static let geminiSSE = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}

    """
}
