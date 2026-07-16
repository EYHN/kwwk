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
/// Every provider that calls `TransformMessages.normalize` is covered as a
/// switch **target**: anthropic-messages, openai-completions,
/// google-generative-ai, openai-responses, bedrock-converse-stream, and
/// mistral-conversations (via its openai-completions delegation).
///
/// Some encoders self-gate signatures on same-model (Gemini's `resolveSig`,
/// Responses' `parseReasoningItem` replay); for those targets the load-bearing
/// assertion is the one behavior only `normalize` provides — cross-model
/// thinking downgraded to plain text — not signature absence, which would pass
/// even without normalize.
///
/// `StubSSEClient` is defined in `AnthropicProviderTests.swift` (same test
/// target). The suite-level time limit converts a provider path that forgets
/// `out.end(...)` (an unbounded drain) into a test failure instead of a CI hang.
@Suite("Cross-provider switch", .timeLimit(.minutes(1)))
struct CrossProviderSwitchTests {

    // MARK: - Foreign-signature fixtures

    /// Thinking-block signature stamped on the foreign turn. Referenced by both
    /// the fixture and the leak assertions so they cannot drift apart.
    static let foreignThinkingSig = "SIG-ABC-FOREIGN"
    /// Marker inside the tool-call thought signature; must never reach the wire.
    static let foreignEncryptedPayload = "FOREIGN-ENC-PAYLOAD"
    /// A realistic tool-call thoughtSignature: OpenAI-completions re-emits a
    /// signature under `reasoning_details` only when it parses as a
    /// `reasoning.encrypted` detail object, so an unparseable placeholder would
    /// make the leak checks tautological.
    static let foreignToolSig = #"{"type":"reasoning.encrypted","data":"FOREIGN-ENC-PAYLOAD"}"#

    // MARK: - Models (all text-only; vision is exercised via the image test's target)

    static func anthropic() -> Model {
        // maxTokens is sized so the reasoning-enabled same-model test can fit a
        // thinking budget plus answer headroom without the encoder throwing.
        Model(id: "claude-x", name: "Claude X", api: "anthropic-messages", provider: "anthropic",
              baseURL: "https://api.anthropic.com", reasoning: true, input: [.text],
              contextWindow: 200_000, maxTokens: 32_768)
    }
    static func openai() -> Model {
        Model(id: "gpt-x", name: "GPT X", api: "openai-completions", provider: "openai",
              baseURL: "https://api.openai.com", reasoning: true, input: [.text],
              contextWindow: 128_000, maxTokens: 1024)
    }
    static func gemini() -> Model {
        Model(id: "gemini-x", name: "Gemini X", api: "google-generative-ai", provider: "google",
              baseURL: "https://generativelanguage.googleapis.com", reasoning: true, input: [.text],
              contextWindow: 1_000_000, maxTokens: 1024)
    }
    static func mistral() -> Model {
        Model(id: "magistral", name: "Magistral", api: "mistral-conversations", provider: "mistral",
              baseURL: "https://api.mistral.ai", reasoning: true, input: [.text],
              contextWindow: 128_000, maxTokens: 1024)
    }
    static func responses() -> Model {
        Model(id: "o-x", name: "O X", api: "openai-responses", provider: "openai",
              baseURL: "https://api.openai.com", reasoning: true, input: [.text],
              contextWindow: 200_000, maxTokens: 8192)
    }
    static func bedrock() -> Model {
        // A claude-family id so the encoder's thinking-signature path
        // (`supportsThinkingSignature`) is reachable — the exact path that
        // would leak a foreign signature if normalize were skipped.
        Model(id: "anthropic.claude-x-v1:0", name: "claude", api: "bedrock-converse-stream",
              provider: "amazon-bedrock", reasoning: true, input: [.text],
              contextWindow: 200_000, maxTokens: 8192)
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
    static let responsesDone = """
    data: {"type":"response.created","response":{"id":"r","status":"in_progress"}}

    data: {"type":"response.completed","response":{"id":"r","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}

    """
    // Bedrock speaks AWS eventstream; an empty response body yields zero events
    // and the provider finalizes cleanly. Only the captured request matters.
    static let bedrockDone = ""

    // MARK: - Transcript factory

    /// A representative turn a foreign provider (identified by the
    /// provider/api/model stamps) would leave in the transcript: signed
    /// reasoning, visible text, a signed tool call, and its result, followed by
    /// a fresh user turn that drives the switched request.
    static func foreignTurn(
        provider: String, api: String, model: String, toolId: String
    ) -> [Message] {
        [
            .user(UserMessage(text: "please read the file")),
            .assistant(AssistantMessage(content: [
                .thinking(ThinkingContent(thinking: "secret reasoning text",
                                          thinkingSignature: foreignThinkingSig)),
                .text(TextContent(text: "Reading now.")),
                .toolCall(ToolCall(id: toolId, name: "read",
                                   arguments: .object(["path": .string("a.txt")]),
                                   thoughtSignature: foreignToolSig)),
            ], api: api, provider: provider, model: model, stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: toolId, toolName: "read",
                                          content: [.text(TextContent(text: "file contents"))])),
            .user(UserMessage(text: "now summarize")),
        ]
    }

    // MARK: - Drive + capture helpers

    /// Run the provider's real stream to completion and return the captured
    /// request body decoded as JSON. `client` must be the same stub injected
    /// into `provider`. Fails (rather than returning an empty body) when the
    /// request never fired — e.g. the encoder threw — and surfaces the
    /// provider's own error message for diagnosis.
    static func capture(
        _ provider: APIProvider, _ client: StubSSEClient, model: Model,
        messages: [Message], options: StreamOptions? = nil
    ) async throws -> [String: Any] {
        let ctx = Context(systemPrompt: "You are helpful.", messages: messages)
        let s = provider.stream(model: model, context: ctx, options: options)
        for await _ in s {}   // drain; body is captured when the request fires
        let result = await s.result()
        let data = try #require(
            client.lastRequest?.body,
            "request never fired; provider result: \(result.errorMessage ?? String(describing: result.stopReason))"
        )
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "request body is not a JSON object"
        )
    }

    // Body walkers -----------------------------------------------------------

    /// Flatten every JSON string anywhere in the body — values AND object keys.
    /// Keys matter: the historical signature-leak bug shape was a signature
    /// value used as a JSON key (see OpenAICompletionsProvider's
    /// `reasoning_content` comment), which a values-only walk cannot see.
    static func allStrings(_ any: Any) -> [String] {
        switch any {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(allStrings)
        case let d as [String: Any]: return d.keys + d.values.flatMap(allStrings)
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

    /// Assert neither foreign signature value appears anywhere on the wire
    /// (keys or values). Shared by every switch test so the fixture constants
    /// and the leak checks cannot drift apart.
    static func expectNoForeignSignatureLeak(_ body: [String: Any]) {
        let strings = allStrings(body)
        #expect(!strings.contains { $0.contains(foreignThinkingSig) })
        #expect(!strings.contains { $0.contains(foreignEncryptedPayload) })
    }

    // OpenAI/Mistral chat body: assistant tool_calls[].id and role:"tool" ids.
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
        var calls: [String] = [], results: [String] = []
        for m in (body["messages"] as? [[String: Any]] ?? []) {
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

    /// All content blocks of assistant-role messages in an Anthropic body.
    static func anthropicAssistantBlocks(_ body: [String: Any]) -> [[String: Any]] {
        (body["messages"] as? [[String: Any]] ?? [])
            .filter { ($0["role"] as? String) == "assistant" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
    }

    // Responses body: input[] function_call / function_call_output call_ids.
    static func responsesToolIds(_ body: [String: Any]) -> (calls: [String], results: [String]) {
        var calls: [String] = [], results: [String] = []
        for item in (body["input"] as? [[String: Any]] ?? []) {
            switch item["type"] as? String {
            case "function_call": if let id = item["call_id"] as? String { calls.append(id) }
            case "function_call_output": if let id = item["call_id"] as? String { results.append(id) }
            default: break
            }
        }
        return (calls, results)
    }

    // Bedrock Converse body: toolUse.toolUseId / toolResult.toolUseId.
    static func bedrockToolIds(_ body: [String: Any]) -> (calls: [String], results: [String]) {
        var calls: [String] = [], results: [String] = []
        for m in (body["messages"] as? [[String: Any]] ?? []) {
            for b in (m["content"] as? [[String: Any]] ?? []) {
                if let tu = b["toolUse"] as? [String: Any], let id = tu["toolUseId"] as? String {
                    calls.append(id)
                }
                if let tr = b["toolResult"] as? [String: Any], let id = tr["toolUseId"] as? String {
                    results.append(id)
                }
            }
        }
        return (calls, results)
    }

    // MARK: - Anthropic → OpenAI (completions)

    @Test("anthropic → openai: reasoning replayed as text, encrypted detail dropped, ids matched")
    func anthropicToOpenAI() async throws {
        let client = StubSSEClient(body: Self.openaiDone)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let body = try await Self.capture(
            provider, client, model: Self.openai(),
            messages: Self.foreignTurn(provider: "anthropic", api: "anthropic-messages", model: "claude-src",
                                       toolId: "toolu_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789extra_tail")
        )

        // Foreign reasoning must NOT come back as structured reasoning fields.
        // Both checks are live: without normalize, the surviving thinking
        // signature re-enables `reasoning_content`, and the parseable
        // reasoning.encrypted thoughtSignature re-emits `reasoning_details`.
        #expect(!Self.allKeys(body).contains("reasoning_content"))
        #expect(!Self.allKeys(body).contains("reasoning_details"))
        // But the reasoning text is preserved (downgraded to plain content), not lost.
        #expect(Self.allStrings(body).contains { $0.contains("secret reasoning text") })
        Self.expectNoForeignSignatureLeak(body)

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
        // no `signature` field anywhere (a foreign one would 400 the Messages
        // API). Live: without normalize the encoder replays the signed block.
        #expect(!Self.anthropicAssistantBlocks(body).contains { ($0["type"] as? String) == "thinking" })
        #expect(!Self.allKeys(body).contains("signature"))
        #expect(Self.allStrings(body).contains { $0.contains("secret reasoning text") })
        Self.expectNoForeignSignatureLeak(body)

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

    // MARK: - Switch to OpenAI Responses (normalize inside makeRequest)

    @Test("switch to openai-responses: foreign thinking downgraded to output text, ids truncated and linked")
    func switchToResponses() async throws {
        let client = StubSSEClient(body: Self.responsesDone)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "sk-test")
        let body = try await Self.capture(
            provider, client, model: Self.responses(),
            messages: Self.foreignTurn(provider: "anthropic", api: "anthropic-messages", model: "claude-src",
                                       toolId: "toolu_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789extra_tail")
        )

        // The load-bearing normalize check for this target: the Responses
        // encoder silently drops thinking blocks it cannot replay, so the
        // foreign reasoning text survives ONLY via normalize's downgrade of
        // cross-model thinking to a plain text block.
        #expect(Self.allStrings(body).contains { $0.contains("secret reasoning text") })
        Self.expectNoForeignSignatureLeak(body)

        // Foreign id truncated to the 40-char OpenAI limit, pair still linked.
        let ids = Self.responsesToolIds(body)
        #expect(ids.calls.count == 1)
        #expect(ids.calls == ids.results)
        #expect(ids.calls.allSatisfy { $0.count <= 40 })
    }

    // MARK: - Switch to Bedrock (normalize + Bedrock's own id pass)

    @Test("switch to bedrock: no reasoningContent block, thinking preserved as text, ids linked")
    func switchToBedrock() async throws {
        let client = StubSSEClient(body: Self.bedrockDone)
        let provider = BedrockProvider(
            client: client,
            region: "us-east-1",
            environment: [:],
            resolveProfileFiles: false,
            credentialsProvider: { AWSSigV4.Credentials(accessKeyId: "k", secretAccessKey: "s") }
        )
        let body = try await Self.capture(
            provider, client, model: Self.bedrock(),
            messages: Self.foreignTurn(provider: "anthropic", api: "anthropic-messages", model: "claude-src",
                                       toolId: "toolu_bedrock_switch")
        )

        // Live: this claude-family Bedrock model takes the thinking-signature
        // encode path, so without normalize the foreign signed thinking would
        // be emitted as reasoningContent.reasoningText.signature.
        #expect(!Self.allKeys(body).contains("reasoningContent"))
        #expect(Self.allStrings(body).contains { $0.contains("secret reasoning text") })
        Self.expectNoForeignSignatureLeak(body)

        let ids = Self.bedrockToolIds(body)
        #expect(ids.calls.count == 1)
        #expect(ids.calls == ids.results)
    }

    // MARK: - Switch to Mistral (delegation + 9-char id rebinding)

    @Test("switch to mistral: tool ids rebound to 9 ASCII alphanumerics, still linked")
    func switchToMistral() async throws {
        let client = StubSSEClient(body: Self.openaiDone)   // Mistral speaks OpenAI chat
        let provider = MistralConversationsProvider(client: client, defaultAPIKey: "sk-test")
        // 9 characters INCLUDING a non-ASCII letter: a regression to a
        // Unicode-permissive filter would keep this id verbatim via the
        // "already-valid 9-char" fast path, which Mistral rejects.
        let body = try await Self.capture(
            provider, client, model: Self.mistral(),
            messages: Self.foreignTurn(provider: "anthropic", api: "anthropic-messages", model: "claude-src",
                                       toolId: "toolü1234")
        )
        let ids = Self.openaiToolIds(body)
        #expect(ids.calls.count == 1)
        #expect(ids.calls == ids.results)
        #expect(ids.calls.allSatisfy { id in
            id.count == 9 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        })
    }

    // MARK: - Anthropic → Gemini

    @Test("anthropic → gemini: foreign thinking downgraded to plain text, no thought part")
    func anthropicToGemini() async throws {
        let client = StubSSEClient(body: Self.geminiDone)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k-test")
        let body = try await Self.capture(
            provider, client, model: Self.gemini(),
            messages: Self.foreignTurn(provider: "anthropic", api: "anthropic-messages", model: "claude-src",
                                       toolId: "toolu_gemini_switch")
        )

        // The load-bearing normalize check for this target: Gemini's encoder
        // self-gates thoughtSignature on same-model, so signature absence alone
        // would pass even without normalize. What only normalize provides is
        // downgrading the foreign thinking block to plain text — without it the
        // encoder replays it as a `"thought": true` part.
        #expect(!Self.allKeys(body).contains("thought"))
        #expect(Self.allStrings(body).contains { $0.contains("secret reasoning text") })
        // Positive shape check so an empty `contents` can't pass vacuously.
        #expect(Self.allKeys(body).contains("functionCall"))
        // Defense-in-depth: signatures must be gone regardless of which layer
        // strips them.
        #expect(!Self.allKeys(body).contains("thoughtSignature"))
        Self.expectNoForeignSignatureLeak(body)
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

    @Test("switching to a text-only model replaces image history with the non-vision placeholder")
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
        let body = try await Self.capture(provider, client, model: Self.openai(), messages: messages)

        // No image survives, and the raw base64 is gone. Matching the exact
        // exported placeholder (not a substring) distinguishes the non-vision
        // downgrade from ProviderImageBudget's separate "[image omitted: …]"
        // text, so the assertion can't be satisfied by the wrong pass.
        #expect(!Self.allKeys(body).contains("image_url"))
        #expect(!Self.allStrings(body).contains { $0.contains(png) })
        #expect(Self.allStrings(body).contains {
            $0.contains(TransformMessages.nonVisionUserImagePlaceholder)
        })
    }

    // MARK: - Negative control: same-model replay keeps its signed thinking

    @Test("same-model replay preserves the signed thinking block with thinking enabled")
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
        // Reasoning ON: replaying signed thinking matters in production when
        // the outgoing request also enables thinking, so that's the mode the
        // negative control must certify (with options nil the body would carry
        // thinking: disabled instead).
        let body = try await Self.capture(
            provider, client, model: model, messages: messages,
            options: StreamOptions(reasoning: .low)
        )

        let thinkingConfig = body["thinking"] as? [String: Any]
        #expect(thinkingConfig?["type"] as? String == "enabled")

        let thinking = Self.anthropicAssistantBlocks(body).first { ($0["type"] as? String) == "thinking" }
        #expect(thinking != nil, "same-model thinking block must be replayed")
        #expect(thinking?["signature"] as? String == "VALID_SIG_123")
    }
}
