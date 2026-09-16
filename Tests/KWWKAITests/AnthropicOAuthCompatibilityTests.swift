import Foundation
import Testing
@testable import KWWKAI

@Suite("Anthropic OAuth model compatibility")
struct AnthropicOAuthCompatibilityTests {
    private func resolve(_ id: String) async throws -> ResolvedAuth {
        let store = OAuthStore()
        try await store.set(
            OAuthCredentials(access: "test-oauth", refresh: "", expires: Int64.max),
            for: "anthropic"
        )
        let resolved = try await registerStored(storeId: "anthropic", store: store, modelOverride: id)
        return try #require(resolved)
    }

    @Test("OAuth preserves catalog wire capabilities while applying subscription ceilings",
          arguments: ["claude-fable-5-1", "claude-opus-4-8", "claude-sonnet-4-5"])
    func preservesCatalogCapabilities(id: String) async throws {
        let catalog = try #require(ModelsCatalog.model(provider: "anthropic", id: id))
        let resolved = try await resolve(id)
        #expect(resolved.model.compat == catalog.compat)
        #expect(resolved.model.thinkingLevelMap == catalog.thinkingLevelMap)
        #expect(resolved.model.contextWindow == min(catalog.contextWindow, 200_000))
        #expect(resolved.model.maxTokens == min(catalog.maxTokens, AnthropicProvider.claudeCodeMaximumOutputTokens))
    }

    @Test("Fable OAuth requests use adaptive thinking and the catalog effort mapping")
    func fableRequest() async throws {
        let resolved = try await resolve("claude-fable-5-1")
        let client = StubSSEClient(body: ProviderVariantsTests.anthropicSSE)
        let provider = ProviderVariants.anthropicOAuth(accessToken: "test-oauth", client: client)
        _ = await provider.stream(
            model: resolved.model,
            context: Context(messages: [.user(UserMessage(text: "hello"))]),
            options: StreamOptions(reasoning: .xhigh)
        ).result()
        let data = try #require(client.lastRequest?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "xhigh")
        #expect(client.lastRequest?.headers["anthropic-beta"]?.contains("interleaved-thinking") != true)
    }
}
