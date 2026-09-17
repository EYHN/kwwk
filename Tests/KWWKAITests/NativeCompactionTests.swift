import Foundation
import Testing
@testable import KWWKAI

@Suite("Native compaction providers")
struct NativeCompactionTests {
    static let codexSSE = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"compaction\",\"encrypted_content\":\"opaque\",\"status\":\"completed\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{}}\n\n"
    static let codex = Model(id: "gpt-5.6", api: "chatgpt-codex", provider: "chatgpt-codex")
    static let claude = Model(id: "claude-sonnet-4-6", api: "anthropic-messages",
                              provider: "anthropic", baseURL: "https://api.anthropic.com")

    @Test("Codex compact uses subscription route and replays all replacement items")
    func codexRoundTrip() async throws {
        let client = StubSSEClient(body: Self.codexSSE)
        let provider = ProviderVariants.chatgptCodex(accessToken: "token", accountId: "account",
                                                    client: client, webSocketClient: nil)
        let source: [Message] = [.user(UserMessage(text: "goal"))]
        let compacted = try #require(try await provider.compact(model: Self.codex,
            context: Context(systemPrompt: "system", messages: source), instructions: "summary",
            options: StreamOptions(sessionId: "session")))
        let request = try #require(client.lastRequest)
        #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(request.headers["chatgpt-account-id"] == "account")
        #expect(request.headers["session_id"] == "session")
        let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.body))
        #expect(body["stream"] == true)
        #expect(body["store"] == false)
        #expect(body["input"]?.arrayValue?.last == ["type": "compaction_trigger"])
        #expect(body["instructions"] == "system")
        var recap = UserMessage(text: compacted.summary, source: .compaction)
        recap.nativeCompaction = compacted.payload
        let restored = try JSONDecoder().decode(UserMessage.self, from: JSONEncoder().encode(recap))
        #expect(restored.nativeCompaction == compacted.payload)
        let stream = provider.stream(model: Self.codex,
            context: Context(messages: [.user(restored), .user(UserMessage(text: "continue"))]), options: nil)
        for await _ in stream {}
        let replay = try JSONDecoder().decode([String: JSONValue].self, from: #require(client.lastRequest?.body))
        let input = try #require(replay["input"]?.arrayValue)
        #expect(input.contains(["type": "compaction", "encrypted_content": "opaque"]))
        #expect(TransformMessages.normalize([.user(restored)], model: Self.claude) == source)
    }

    @Test("Anthropic compact keeps tools and auth, then replays encrypted compaction")
    func anthropicRoundTrip() async throws {
        let client = StubSSEClient(body: #"{"stop_reason":"compaction","content":[{"type":"compaction","content":"Keep working on the SDK","encrypted_content":"signed"}]}"#)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "token",
            extraHeaders: ["anthropic-beta": "oauth-2025-04-20"],
            authHeaderBuilder: { ["authorization": "Bearer \($0)"] })
        let tool = Tool(name: "read", description: "read files", parameters: ["type": "object"])
        let result = try #require(try await provider.compact(model: Self.claude,
            context: Context(systemPrompt: "system", messages: [.user(UserMessage(text: "history"))], tools: [tool]),
            instructions: "Summarize only old history", options: nil))
        let request = try #require(client.lastRequest)
        #expect(request.headers["authorization"] == "Bearer token")
        #expect(request.headers["anthropic-beta"]?.contains("oauth-2025-04-20") == true)
        #expect(request.headers["anthropic-beta"]?.contains("compact-2026-01-12") == true)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.body))
        #expect(body["stream"] == false)
        #expect(body["tools"]?.arrayValue?.count == 1)
        var recap = UserMessage(text: result.summary, source: .compaction)
        recap.nativeCompaction = result.payload
        let encoded = try AnthropicProvider.encodeBody(model: Self.claude,
            context: Context(messages: [.user(recap), .user(UserMessage(text: "next"))]), options: nil)
        let replay = String(decoding: encoded, as: UTF8.self)
        #expect(replay.contains("encrypted_content"))
        #expect(replay.contains("signed"))
        #expect(replay.contains("context_management"))
        #expect(replay.contains("compact_20260112"))
        let portable = TransformMessages.normalize([.user(recap)], model: Self.codex)
        guard case .user(let user)? = portable.first else { Issue.record("missing portable summary"); return }
        #expect(user.content.contains(.text(TextContent(text: result.summary))))
    }

    @Test("unsupported Anthropic routes do not issue native requests")
    func unsupportedRoute() async throws {
        let client = StubSSEClient(body: "{}")
        let provider = AnthropicProvider(client: client)
        var model = Self.claude
        model.baseURL = "https://proxy.example"
        #expect(try await provider.compact(model: model, context: Context(messages: []), instructions: "", options: nil) == nil)
        #expect(client.lastRequest == nil)
    }

    @Test("missing native payload and HTTP failures remain errors")
    func nativeFailures() async throws {
        let malformed = ProviderVariants.chatgptCodex(client: StubSSEClient(body: #"{"output":[{"type":"compaction"}]}"#))
        await #expect(throws: ProviderFailure.self) {
            try await malformed.compact(model: Self.codex, context: Context(messages: []), instructions: "", options: nil)
        }
        let failing = ProviderVariants.chatgptCodex(client: StubSSEClient(body: "overloaded", statusCode: 529))
        do {
            _ = try await failing.compact(model: Self.codex, context: Context(messages: []), instructions: "", options: nil)
            Issue.record("expected HTTP failure")
        } catch let error as ProviderFailure { #expect(error.httpStatus == 529) }
    }

    // Adapted from omp compaction-v2-streaming.ts/remote-compaction.test.ts:
    // completion alone or an unfinished native item must not replace history.
    @Test(arguments: ["", "data: {\"type\":\"response.completed\",\"response\":{}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}}\n\n"])
    func codexRejectsIncompleteNativePayload(body: String) async {
        let provider = ProviderVariants.chatgptCodex(client: StubSSEClient(body: body))
        await #expect(throws: ProviderFailure.self) {
            try await provider.compact(model: Self.codex, context: Context(messages: []), instructions: "", options: nil)
        }
    }

    @Test func nativePaymentFailureRemainsTerminal() async {
        let provider = ProviderVariants.chatgptCodex(client: StubSSEClient(body: "temporarily unavailable", statusCode: 402))
        do {
            _ = try await provider.compact(model: Self.codex, context: Context(messages: []), instructions: "", options: nil)
            Issue.record("Expected payment failure")
        } catch {
            let failure = ProviderFailure.capture(error)
            #expect(failure.httpStatus == 402)
            #expect(!failure.isRetryable)
        }
    }

    @Test func anthropicAssistantFinalIsNotAPrefill() async throws {
        let client = StubSSEClient(body: #"{"stop_reason":"compaction","content":[{"type":"compaction","content":"summary"}]}"#)
        _ = try await AnthropicProvider(client: client).compact(model: Self.claude,
            context: Context(messages: [.assistant(AssistantMessage(content: [.text(TextContent(text: "notes\n"))],
                api: Self.claude.api, provider: Self.claude.provider, model: Self.claude.id))]), instructions: "", options: nil)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(client.lastRequest?.body))
        #expect(body["messages"]?.arrayValue?.last?["role"] == "user")
    }

    @Test func explicitResponsesV1RouteStillWorks() async throws {
        var model = Self.codex
        model.api = "openai-responses"
        model.provider = "openai"
        var compat = ModelCompat()
        compat.supportsServerCompaction = true
        model.compat = compat
        let client = StubSSEClient(body: #"{"output":[{"type":"compaction","encrypted_content":"opaque"}]}"#)
        let result = try await OpenAIResponsesProvider(client: client).compact(model: model,
            context: Context(messages: []), instructions: "", options: nil)
        #expect(result != nil)
        #expect(client.lastRequest?.url.path.hasSuffix("/responses/compact") == true)
    }

    // pi #7048's no-truncated-summary invariant also applies to native payloads.
    @Test(arguments: ["max_tokens", "end_turn", "refusal"])
    func anthropicPartialSummaryIsNotAccepted(stop: String) async {
        let body = "{\"stop_reason\":\"\(stop)\",\"content\":[{\"type\":\"compaction\",\"content\":\"partial summary\"}]}"
        let provider = AnthropicProvider(client: StubSSEClient(body: body))
        await #expect(throws: ProviderFailure.self) {
            try await provider.compact(model: Self.claude, context: Context(messages: []), instructions: "", options: nil)
        }
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}
