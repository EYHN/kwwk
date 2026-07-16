import Foundation
import Testing
@testable import KWWKAI

/// Integration tests for the **switch-provider-mid-session** path.
///
/// Unit tests in `TransformMessagesTests` prove each normalization pass in
/// isolation. These tests prove the passes actually fire *inside every
/// provider's real `stream()` encode path*: we build a transcript stamped as if
/// produced by provider A, send it through provider B's real encoder (via
/// `StubSSEClient`, which captures the outgoing request body), and assert the
/// wire body is clean. This is the regression net for "someone adds a provider
/// but forgets to call `TransformMessages.normalize`" or "someone reorders the
/// encode path and a foreign thinking signature leaks through".
///
/// `StubSSEClient` is defined in `AnthropicProviderTests.swift` (same test
/// target).
@Suite("Cross-provider switch")
struct CrossProviderSwitchTests {

    // MARK: - Models (text-only unless the test needs vision)

    static func anthropic(input: [InputModality] = [.text]) -> Model {
        Model(id: "claude-x", name: "Claude X", api: "anthropic-messages", provider: "anthropic",
              baseURL: "https://api.anthropic.com", reasoning: true, input: input,
              contextWindow: 200_000, maxTokens: 1024)
    }
    static func openai(input: [InputModality] = [.text]) -> Model {
        Model(id: "gpt-x", name: "GPT X", api: "openai-completions", provider: "openai",
              baseURL: "https://api.openai.com", reasoning: true, input: input,
              contextWindow: 128_000, maxTokens: 1024)
    }
    static func gemini(input: [InputModality] = [.text]) -> Model {
        Model(id: "gemini-x", name: "Gemini X", api: "google-generative-ai", provider: "google",
              baseURL: "https://generativelanguage.googleapis.com", reasoning: true, input: input,
              contextWindow: 1_000_000, maxTokens: 1024)
    }
    static func mistral() -> Model {
        Model(id: "magistral", name: "Magistral", api: "mistral-conversations", provider: "mistral",
              baseURL: "https://api.mistral.ai", reasoning: true, input: [.text],
              contextWindow: 128_000, maxTokens: 1024)
    }

    // MARK: - Minimal terminal SSE bodies (just enough to end the stream cleanly)

    static let anthropicDone = """
    event: message_start
    data: {"type":"message_start","message":{"id":"m","role":"assistant","content":[],"model":"claude-x","usage":{"input_tokens":1,"output_tokens":0}}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    static let openaiDone = """
    data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"}}]}

    data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}

    data: [DONE]

    """
    static let geminiDone = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}

    """

    // MARK: - Transcript factory (as if produced by `source`)

    /// A representative turn a foreign provider would leave in the transcript:
    /// signed reasoning, visible text, a signed tool call, and its result,
    /// followed by a fresh user turn that drives the switched request.
    static func foreignTurn(
        provider: String, api: String, model: String,
        toolId: String, thinkingSig: String? = "SIG-ABC", tcSig: String? = "TSIG-XYZ"
    ) -> [Message] {
        [
            .user(UserMessage(text: "please read the file")),
            .assistant(AssistantMessage(content: [
                .thinking(ThinkingContent(thinking: "secret reasoning text", thinkingSignature: thinkingSig)),
                .text(TextContent(text: "Reading now.")),
                .toolCall(ToolCall(id: toolId, name: "read",
                                   arguments: .object(["path": .string("a.txt")]),
                                   thoughtSignature: tcSig)),
            ], api: api, provider: provider, model: model, stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: toolId, toolName: "read",
                                          content: [.text(TextContent(text: "file contents"))])),
            .user(UserMessage(text: "now summarize")),
        ]
    }

    // MARK: - Drive + capture helpers

    /// Run the provider's real stream to completion and return the captured
    /// request body decoded as JSON. `client` must be the same stub injected
    /// into `provider`.
    static func capture(
        _ provider: APIProvider, _ client: StubSSEClient, model: Model, messages: [Message]
    ) async throws -> [String: Any] {
        let ctx = Context(systemPrompt: "You are helpful.", messages: messages)
        let s = provider.stream(model: model, context: ctx, options: nil)
        for await _ in s {}   // drain; body is captured when the request fires
        let data = client.lastRequest?.body ?? Data()
        #expect(!data.isEmpty, "request body was never captured")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // Body walkers -----------------------------------------------------------

    /// Flatten every JSON string value anywhere in the body — used for
    /// "this signature must not appear anywhere on the wire" assertions.
    static func allStrings(_ any: Any) -> [String] {
        switch any {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(allStrings)
        case let d as [String: Any]: return d.values.flatMap(allStrings)
        default: return []
        }
    }
    /// Every JSON object key present anywhere in the body.
    static func allKeys(_ any: Any) -> Set<String> {
        switch any {
        case let a as [Any]: return a.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
        case let d as [String: Any]:
            return d.reduce(into: Set<String>(d.keys)) { $0.formUnion(allKeys($1.value)) }
        default: return []
        }
    }

    // OpenAI/Mistral chat body: role→tool_calls[].id and role:"tool" ids.
    static func openaiToolIds(_ body: [String: Any]) -> (calls: [String], results: [String]) {
        let msgs = body["messages"] as? [[String: Any]] ?? []
        var calls: [String] = [], results: [String] = []
        for m in msgs {
            if (m["role"] as? String) == "tool", let id = m["tool_call_id"] as? String { results.append(id) }
            for c in (m["tool_calls"] as? [[String: Any]] ?? []) {
                if let id = c["id"] as? String { calls.append(id) }
            }
        }
        return (calls, results)
    }

    // Anthropic body: assistant tool_use ids and tool_result tool_use_ids.
    static func anthropicToolIds(_ body: [String: Any]) -> (calls: [String], results: [String]) {
        let msgs = body["messages"] as? [[String: Any]] ?? []
        var calls: [String] = [], results: [String] = []
        for m in msgs {
            for b in (m["content"] as? [[String: Any]] ?? []) {
                switch b["type"] as? String {
                case "tool_use": if let id = b["id"] as? String { calls.append(id) }
                case "tool_result": if let id = b["tool_use_id"] as? String { results.append(id) }
                default: break
                }
            }
        }
        return (calls, results)
    }

    // MARK: - Anthropic → OpenAI

    @Test("anthropic → openai: thinking signature dropped, reasoning replayed as text, ids matched")
    func anthropicToOpenAI() async throws {
        let client = StubSSEClient(body: Self.openaiDone)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(
            provider, client, model: Self.openai(),
            messages: Self.foreignTurn(provider: "anthropic", api: "anthropic-messages", model: "claude-src",
                                       toolId: "toolu_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789extra_tail")
        )

        // Foreign reasoning must NOT come back as structured reasoning fields
        // (its signature was model-specific and got stripped cross-model).
        #expect(!Self.allKeys(body).contains("reasoning_content"))
        #expect(!Self.allKeys(body).contains("reasoning_details"))
        // But the reasoning text is preserved (downgraded to plain content), not lost.
        #expect(Self.allStrings(body).contains { $0.contains("secret reasoning text") })
        // No foreign signature leaks onto the wire.
        #expect(!Self.allStrings(body).contains { $0.contains("SIG-ABC") || $0.contains("TSIG-XYZ") })

        // Tool call/result ids stay linked and are OpenAI-legal (≤ 40 chars).
        let ids = Self.openaiToolIds(body)
        #expect(ids.calls.count == 1)
        #expect(ids.calls == ids.results)
        #expect(ids.calls.allSatisfy { $0.count <= 40 })
    }

    // MARK: - OpenAI → Anthropic

    @Test("openai → anthropic: no thinking block or signature key, tool ids matched")
    func openAIToAnthropic() async throws {
        let client = StubSSEClient(body: Self.anthropicDone)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(
            provider, client, model: Self.anthropic(),
            messages: Self.foreignTurn(provider: "openai", api: "openai-completions", model: "gpt-src",
                                       toolId: "call_9f8e7d6c")
        )

        // Cross-model thinking is downgraded to text: no `thinking` block, and
        // no `signature` field anywhere (a foreign one would 400 the Messages API).
        let msgs = body["messages"] as? [[String: Any]] ?? []
        let assistantBlocks = msgs.filter { ($0["role"] as? String) == "assistant" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        #expect(!assistantBlocks.contains { ($0["type"] as? String) == "thinking" })
        #expect(!Self.allKeys(body).contains("signature"))
        #expect(!Self.allStrings(body).contains { $0.contains("SIG-ABC") || $0.contains("TSIG-XYZ") })
        #expect(Self.allStrings(body).contains { $0.contains("secret reasoning text") })

        let ids = Self.anthropicToolIds(body)
        #expect(ids.calls == ["call_9f8e7d6c"])
        #expect(ids.calls == ids.results)
    }

    // MARK: - Responses-style pipe id → Anthropic

    @Test("openai-responses pipe id is normalized (segment before '|') and stays linked on switch")
    func responsesPipeIdAcrossSwitch() async throws {
        let client = StubSSEClient(body: Self.anthropicDone)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(
            provider, client, model: Self.anthropic(),
            messages: Self.foreignTurn(provider: "openai", api: "openai-responses", model: "o-src",
                                       toolId: "call_abc123|fc_0e9d8c7b6a")
        )
        let ids = Self.anthropicToolIds(body)
        #expect(ids.calls == ["call_abc123"])   // everything from '|' onward dropped
        #expect(ids.calls == ids.results)         // result id rewritten to match
    }

    // MARK: - Switch to Mistral (delegation + 9-char id rebinding)

    @Test("switch to mistral: tool ids rebound to 9 alphanumeric chars, still linked")
    func switchToMistral() async throws {
        let client = StubSSEClient(body: Self.openaiDone)   // Mistral speaks OpenAI chat
        let provider = MistralConversationsProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(
            provider, client, model: Self.mistral(),
            messages: Self.foreignTurn(provider: "anthropic", api: "anthropic-messages", model: "claude-src",
                                       toolId: "toolu_01ABC-xyz/verylongid")
        )
        let ids = Self.openaiToolIds(body)
        #expect(ids.calls.count == 1)
        #expect(ids.calls == ids.results)
        #expect(ids.calls.allSatisfy { id in id.count == 9 && id.allSatisfy { $0.isLetter || $0.isNumber } })
    }

    // MARK: - Anthropic → Gemini (thought signature stripped)

    @Test("anthropic → gemini: foreign thoughtSignature stripped, ids matched")
    func anthropicToGemini() async throws {
        let client = StubSSEClient(body: Self.geminiDone)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k-test")
        let body = try await Self.capture(
            provider, client, model: Self.gemini(),
            messages: Self.foreignTurn(provider: "anthropic", api: "anthropic-messages", model: "claude-src",
                                       toolId: "toolu_gemini_switch")
        )
        // Gemini would replay `thoughtSignature`/`thought` only for same-model
        // turns; a foreign one must be gone.
        #expect(!Self.allKeys(body).contains("thoughtSignature"))
        #expect(!Self.allStrings(body).contains { $0.contains("TSIG-XYZ") || $0.contains("SIG-ABC") })
    }

    // MARK: - Orphan tool call synthesized on switch

    @Test("orphaned tool call gets a synthetic error result when switching providers")
    func orphanToolCallOnSwitch() async throws {
        let messages: [Message] = [
            .user(UserMessage(text: "read it")),
            .assistant(AssistantMessage(content: [
                .toolCall(ToolCall(id: "toolu_orphan1", name: "read", arguments: .object([:]))),
            ], api: "anthropic-messages", provider: "anthropic", model: "claude-src", stopReason: .toolUse)),
            // No tool result — the switch happens before it arrived.
            .user(UserMessage(text: "never mind, summarize")),
        ]
        let client = StubSSEClient(body: Self.anthropicDone)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(provider, client, model: Self.anthropic(), messages: messages)

        let ids = Self.anthropicToolIds(body)
        #expect(ids.calls == ["toolu_orphan1"])
        #expect(ids.results == ["toolu_orphan1"])   // synthesized result balances the call
        #expect(Self.allStrings(body).contains { $0.contains("No result provided") })
    }

    // MARK: - Errored turn skipped on switch

    @Test("an errored assistant turn is not replayed after switching providers")
    func erroredTurnSkipped() async throws {
        let messages: [Message] = [
            .user(UserMessage(text: "first")),
            .assistant(AssistantMessage(content: [.text(TextContent(text: "BROKEN_PARTIAL_OUTPUT"))],
                                        api: "openai-completions", provider: "openai", model: "gpt-src",
                                        stopReason: .error)),
            .user(UserMessage(text: "try again")),
        ]
        let client = StubSSEClient(body: Self.openaiDone)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(provider, client, model: Self.openai(), messages: messages)
        #expect(!Self.allStrings(body).contains { $0.contains("BROKEN_PARTIAL_OUTPUT") })
    }

    // MARK: - Image history downgraded when switching to a text-only model

    @Test("switching to a text-only model replaces image history with a placeholder")
    func imageDowngradedOnSwitch() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCA— placeholder base64 —"
        let messages: [Message] = [
            .user(UserMessage(content: [
                .text(TextContent(text: "what is in this screenshot?")),
                .image(ImageContent(data: png, mimeType: "image/png")),
            ])),
            .assistant(AssistantMessage(content: [.text(TextContent(text: "a cat"))],
                                        api: "google-generative-ai", provider: "google", model: "gemini-src")),
            .user(UserMessage(text: "and this one?")),
        ]
        let client = StubSSEClient(body: Self.openaiDone)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(provider, client, model: Self.openai(input: [.text]), messages: messages)

        // No image survives, and the raw base64 is gone.
        #expect(!Self.allKeys(body).contains("image_url"))
        #expect(!Self.allStrings(body).contains { $0.contains(png) })
        #expect(Self.allStrings(body).contains { $0.contains("image omitted") })
    }

    // MARK: - Negative control: same-model replay keeps its signed thinking

    @Test("same-model replay preserves the signed thinking block (no over-stripping)")
    func sameModelKeepsSignedThinking() async throws {
        let model = Self.anthropic()
        let messages: [Message] = [
            .user(UserMessage(text: "think")),
            .assistant(AssistantMessage(content: [
                .thinking(ThinkingContent(thinking: "deliberate", thinkingSignature: "VALID_SIG_123")),
                .text(TextContent(text: "done")),
            ], api: model.api, provider: model.provider, model: model.id, stopReason: .stop)),
            .user(UserMessage(text: "continue")),
        ]
        let client = StubSSEClient(body: Self.anthropicDone)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(provider, client, model: model, messages: messages)

        let assistantBlocks = (body["messages"] as? [[String: Any]] ?? [])
            .filter { ($0["role"] as? String) == "assistant" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let thinking = assistantBlocks.first { ($0["type"] as? String) == "thinking" }
        #expect(thinking != nil, "same-model thinking block must be replayed")
        #expect(thinking?["signature"] as? String == "VALID_SIG_123")
    }
}
