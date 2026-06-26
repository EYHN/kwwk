import Foundation
import Testing
@testable import KWWKAI

@Suite("Reasoning encoders (compat)")
struct ReasoningEncoderTests {

    static let anthropicSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"m","role":"assistant","content":[],"model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":0}}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    static let geminiSSE = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"hi"}]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}

    """

    private func reasoningModel(provider: String, baseUrl: String, compat: ModelCompat? = nil,
                                thinkingLevelMap: [String: String?]? = nil) -> Model {
        Model(
            id: "m", name: "m", api: "openai-completions", provider: provider,
            baseUrl: baseUrl, reasoning: true, input: [.text],
            contextWindow: 128_000, maxTokens: 4096,
            compat: compat, thinkingLevelMap: thinkingLevelMap
        )
    }

    private func body(_ model: Model, _ reasoning: ReasoningLevel?) throws -> [String: Any] {
        try OpenAICompletionsProvider.encodeBodyDict(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: reasoning)
        )
    }

    // MARK: openai-completions thinkingFormat

    @Test("openai default emits flat reasoning_effort")
    func openaiDefault() throws {
        let b = try body(reasoningModel(provider: "openai", baseUrl: "https://api.openai.com"), .high)
        #expect(b["reasoning_effort"] as? String == "high")
        #expect(b["reasoning"] == nil)
        #expect(b["thinking"] == nil)
    }

    @Test("openrouter (detected from baseUrl) emits nested reasoning.effort")
    func openrouterNested() throws {
        let b = try body(reasoningModel(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1"), .medium)
        let reasoning = b["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "medium")
        #expect(b["reasoning_effort"] == nil)
    }

    @Test("deepseek emits thinking{type:enabled} + reasoning_effort")
    func deepseekFormat() throws {
        let b = try body(reasoningModel(provider: "deepseek", baseUrl: "https://api.deepseek.com"), .high)
        let thinking = b["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
    }

    @Test("zai emits thinking + tool_stream via compat")
    func zaiFormat() throws {
        let model = reasoningModel(provider: "zai", baseUrl: "https://api.z.ai/api/coding/paas/v4",
                                   compat: { var c = ModelCompat(); c.zaiToolStream = true; c.supportsReasoningEffort = true; return c }())
        let b = try OpenAICompletionsProvider.encodeBodyDict(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))],
                             tools: [Tool(name: "t", description: "d", parameters: ["type": "object"])]),
            options: StreamOptions(reasoning: .high)
        )
        let thinking = b["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect(b["tool_stream"] as? Bool == true)
    }

    @Test("thinkingLevelMap remaps the wire effort value")
    func levelMapRemap() throws {
        // xhigh maps to "max"; request xhigh -> reasoning_effort "max".
        let model = reasoningModel(provider: "openai", baseUrl: "https://api.openai.com",
                                   thinkingLevelMap: ["xhigh": "max"])
        let b = try body(model, .xhigh)
        #expect(b["reasoning_effort"] as? String == "max")
    }

    @Test("non-reasoning model emits no reasoning fields")
    func nonReasoning() throws {
        let model = Model(id: "m", name: "m", api: "openai-completions", provider: "openai",
                          baseUrl: "https://api.openai.com", reasoning: false)
        let b = try OpenAICompletionsProvider.encodeBodyDict(
            model: model, context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .high))
        #expect(b["reasoning_effort"] == nil)
        #expect(b["reasoning"] == nil)
    }

    // MARK: Anthropic adaptive thinking

    @Test("anthropic adaptive thinking emits output_config.effort")
    func anthropicAdaptive() async throws {
        let client = StubSSEClient(body: Self.anthropicSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        var compat = ModelCompat(); compat.forceAdaptiveThinking = true
        let model = Model(id: "claude-opus-4-6", name: "Opus", api: "anthropic-messages",
                          provider: "anthropic", baseUrl: "https://api.anthropic.com",
                          reasoning: true, input: [.text], contextWindow: 200_000, maxTokens: 8192,
                          compat: compat, thinkingLevelMap: ["xhigh": "max"])
        _ = provider.stream(model: model,
                            context: Context(messages: [.user(UserMessage(text: "hi"))]),
                            options: StreamOptions(reasoning: .xhigh))
        try? await Task.sleep(nanoseconds: 300_000_000)
        let json = try JSONSerialization.jsonObject(with: client.lastRequest?.body ?? Data()) as? [String: Any]
        let thinking = json?["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "adaptive")
        #expect((json?["output_config"] as? [String: Any])?["effort"] as? String == "max")
        // budget_tokens must NOT be present in adaptive mode.
        #expect(thinking?["budget_tokens"] == nil)
    }

    // MARK: Gemini thinkingLevel

    @Test("gemini 3 pro emits string thinkingLevel, not integer budget")
    func gemini3Level() async throws {
        let client = StubSSEClient(body: Self.geminiSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k")
        let model = Model(id: "gemini-3-pro-preview", name: "G3", api: "google-generative-ai",
                          provider: "google", baseUrl: "https://generativelanguage.googleapis.com",
                          reasoning: true, input: [.text], contextWindow: 1_000_000, maxTokens: 8192)
        _ = provider.stream(model: model,
                            context: Context(messages: [.user(UserMessage(text: "hi"))]),
                            options: StreamOptions(reasoning: .low))
        try? await Task.sleep(nanoseconds: 300_000_000)
        let json = try JSONSerialization.jsonObject(with: client.lastRequest?.body ?? Data()) as? [String: Any]
        let tc = (json?["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(tc?["thinkingLevel"] as? String == "LOW")
        #expect(tc?["thinkingBudget"] == nil)
    }
}
