import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// OpenCode's gateway: each wire at its own path under the plan, the key as
/// a bearer token on every wire, and `x-opencode-session` on every request.
@Suite("OpenCode gateway")
struct OpenCodeGatewayTests {
    /// (plan, wire, model id, where the request must go)
    @Test("each wire goes to its own path under the plan, the key as a bearer token", arguments: [
        (OpenCodePlan.go, "openai-completions", "glm-5.2",
         "https://opencode.ai/inference/go/openai/v1/chat/completions"),
        (OpenCodePlan.go, "openai-responses", "grok-4.7",
         "https://opencode.ai/inference/go/openai/v1/responses"),
        (OpenCodePlan.go, "anthropic-messages", "claude-haiku-5-5",
         "https://opencode.ai/inference/go/anthropic/v1/messages"),
        (OpenCodePlan.go, "google-generative-ai", "gemini-4-argon",
         "https://opencode.ai/inference/go/google/v1beta/models/gemini-4-argon:streamGenerateContent?alt=sse"),
        (OpenCodePlan.zen, "openai-completions", "glm-5.2",
         "https://opencode.ai/inference/openai/v1/chat/completions"),
        (OpenCodePlan.zen, "openai-responses", "gpt-5.5",
         "https://opencode.ai/inference/openai/v1/responses"),
        (OpenCodePlan.zen, "anthropic-messages", "claude-sonnet-5",
         "https://opencode.ai/inference/anthropic/v1/messages"),
        (OpenCodePlan.zen, "google-generative-ai", "gemini-3.5-flash",
         "https://opencode.ai/inference/google/v1beta/models/gemini-3.5-flash:streamGenerateContent?alt=sse"),
    ])
    func wireRoutes(plan: OpenCodePlan, api: String, id: String, url: String) async throws {
        let client = StubSSEClient(body: "")
        let provider = try #require(
            ProviderVariants.openCodeProviders(plan: plan, apiKey: "oc_sk_test", client: client)
                .first { $0.api == api }
        )
        // The catalog's own address (Gemini's would 404) gives way to the plan's.
        let model = Model(id: id, api: api, provider: plan.id, baseURL: plan.rootURL + "/v1")
        let stream = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(sessionId: "ses_1")
        )
        for await _ in stream {}
        let request = try #require(client.lastRequest)
        #expect(request.url.absoluteString == url)
        #expect(Self.header(request.headers, "authorization") == "Bearer oc_sk_test")
        #expect(Self.header(request.headers, "x-api-key") == nil)
        #expect(Self.header(request.headers, "x-goog-api-key") == nil)
        #expect(Self.header(request.headers, "x-opencode-session") == "ses_1")
    }

    @Test("a request with no session gets the process's id; a caller's own header is kept")
    func sessionHeader() async throws {
        let cases: [(StreamOptions?, String)] = [
            (nil, OpenCodeRequestProvider.processSession),
            (StreamOptions(sessionId: ""), OpenCodeRequestProvider.processSession),
            (StreamOptions(sessionId: "ses_1", headers: ["X-OpenCode-Session": "mine"]), "mine"),
        ]
        for (options, expected) in cases {
            let client = StubSSEClient(body: "")
            let provider = try #require(
                ProviderVariants.openCodeProviders(plan: .go, apiKey: "k", client: client).first
            )
            let stream = provider.stream(
                model: Model(id: "glm-5.2", api: provider.api, provider: OpenCodePlan.go.id),
                context: Context(messages: [.user(UserMessage(text: "hi"))]),
                options: options
            )
            for await _ in stream {}
            let headers = try #require(client.lastRequest?.headers)
            #expect(Self.header(headers, "x-opencode-session") == expected)
            #expect(headers.keys.filter { $0.lowercased() == "x-opencode-session" }.count == 1)
        }
        #expect(!OpenCodeRequestProvider.processSession.isEmpty)
    }

    @Test("native compaction and session cleanup pass through, routed and stamped")
    func passThrough() async throws {
        let client = StubSSEClient(body: #"{"output":[{"type":"compaction","encrypted_content":"opaque"}]}"#)
        let provider = try #require(
            ProviderVariants.openCodeProviders(plan: .zen, apiKey: "k", client: client)
                .first { $0.api == "openai-responses" } as? any NativeCompactionProvider
        )
        var model = Model(id: "gpt-5.5", api: "openai-responses", provider: OpenCodePlan.zen.id)
        var compat = ModelCompat()
        compat.supportsServerCompaction = true
        model.compat = compat
        let result = try await provider.compact(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "goal"))]),
            instructions: "summary",
            options: StreamOptions(sessionId: "ses_2")
        )
        #expect(result != nil)
        let request = try #require(client.lastRequest)
        #expect(request.url.absoluteString == "https://opencode.ai/inference/openai/v1/responses/compact")
        #expect(Self.header(request.headers, "x-opencode-session") == "ses_2")

        let base = ClosingProvider()
        await OpenCodeRequestProvider(base: base, plan: .go).closeSession(sessionId: "ses_3")
        #expect(base.closed == ["ses_3"])
    }

    private static func header(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }
}

private final class ClosingProvider: APIProvider, APIProviderSessionLifecycle, @unchecked Sendable {
    let api = "openai-completions"
    private let lock = NSLock()
    private var sessions: [String] = []

    var closed: [String] { lock.withLock { sessions } }

    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        AssistantMessageStream()
    }

    func closeSession(sessionId: String) async {
        lock.withLock { sessions.append(sessionId) }
    }
}
