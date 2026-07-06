import Foundation
import Testing
@testable import KWWKAI

@Suite("Provider attribution")
struct ProviderAttributionTests {
    @Test("display-name lookup returns branded names")
    func displayNames() {
        #expect(ProviderAttribution.getProviderDisplayName("openrouter") == "OpenRouter")
        #expect(ProviderAttribution.getProviderDisplayName("nvidia") == "NVIDIA NIM")
        #expect(ProviderAttribution.getProviderDisplayName("google") == "Google Gemini")
        #expect(ProviderAttribution.getProviderDisplayName("vercel-ai-gateway") == "Vercel AI Gateway")
        #expect(ProviderAttribution.getProviderDisplayName("kimi-coding") == "Kimi For Coding")
    }

    @Test("unknown provider falls back to its id")
    func unknownDisplayName() {
        #expect(ProviderAttribution.getProviderDisplayName("nope-xyz") == "nope-xyz")
    }

    @Test("EnvAPIKeys.displayName delegates to ProviderAttribution")
    func envDelegation() {
        #expect(EnvAPIKeys.displayName(for: "nvidia") == "NVIDIA NIM")
        #expect(EnvAPIKeys.displayNames["openrouter"] == "OpenRouter")
    }

    @Test("OpenRouter attribution headers by provider id")
    func openRouterHeaders() {
        let h = ProviderAttribution.attributionHeaders(provider: "openrouter")
        #expect(h?["HTTP-Referer"] == "https://kwwk.dev")
        #expect(h?["X-OpenRouter-Title"] == "kwwk")
        #expect(h?["X-OpenRouter-Categories"] == "cli-agent")
    }

    @Test("OpenRouter attribution headers detected by base URL")
    func openRouterByBaseUrl() {
        let h = ProviderAttribution.attributionHeaders(
            provider: "custom",
            baseURL: "https://openrouter.ai/api/v1"
        )
        #expect(h?["HTTP-Referer"] == "https://kwwk.dev")
    }

    @Test("NVIDIA NIM billing origin header")
    func nvidiaHeaders() {
        let byId = ProviderAttribution.attributionHeaders(provider: "nvidia")
        #expect(byId?["X-BILLING-INVOKE-ORIGIN"] == "kwwk")
        let byHost = ProviderAttribution.attributionHeaders(
            provider: "x",
            baseURL: "https://integrate.api.nvidia.com/v1"
        )
        #expect(byHost?["X-BILLING-INVOKE-ORIGIN"] == "kwwk")
    }

    @Test("Vercel AI Gateway attribution headers")
    func vercelHeaders() {
        let h = ProviderAttribution.attributionHeaders(provider: "vercel-ai-gateway")
        #expect(h?["http-referer"] == "https://kwwk.dev")
        #expect(h?["x-title"] == "kwwk")
    }

    @Test("Cloudflare attribution sets branded user agent")
    func cloudflareHeaders() {
        let h = ProviderAttribution.attributionHeaders(provider: "cloudflare-workers-ai")
        #expect(h?["User-Agent"] == "kwwk-coding-agent")
    }

    @Test("non-attributed provider returns nil")
    func noHeaders() {
        #expect(ProviderAttribution.attributionHeaders(provider: "anthropic") == nil)
        #expect(ProviderAttribution.attributionHeaders(provider: "openai") == nil)
    }

    @Test("mergedHeaders lets caller headers override attribution")
    func merged() {
        let model = Model(
            id: "x",
            api: "openai-completions",
            provider: "openrouter",
            baseURL: "https://openrouter.ai/api/v1"
        )
        let merged = ProviderAttribution.mergedHeaders(
            for: model,
            ["X-OpenRouter-Title": "override", "Extra": "1"]
        )
        #expect(merged?["X-OpenRouter-Title"] == "override")
        #expect(merged?["Extra"] == "1")
        // Untouched attribution header survives.
        #expect(merged?["HTTP-Referer"] == "https://kwwk.dev")
    }

    @Test("mergedHeaders returns nil when nothing applies")
    func mergedNil() {
        let model = Model(id: "x", api: "anthropic-messages", provider: "anthropic")
        #expect(ProviderAttribution.mergedHeaders(for: model) == nil)
    }
}
