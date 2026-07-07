import Foundation

/// Provider display names + branded attribution headers, ported from pi's
/// `provider-display-names.ts` and `provider-attribution.ts`.
///
/// This is the single source of truth for human-readable provider names;
/// `EnvAPIKeys.displayName(for:)` delegates here. The attribution headers mirror
/// pi's behavior of stamping aggregator/gateway requests with branded
/// referer/title/origin headers (OpenRouter, NVIDIA NIM, Cloudflare, Vercel AI
/// Gateway) so usage is attributed to the kwwk client.
public enum ProviderAttribution {
    // MARK: - Display names

    /// Complete provider id → human-readable display name map. Ported from pi's
    /// `BUILT_IN_PROVIDER_DISPLAY_NAMES`, plus the kwwk-specific ids the CLI
    /// registers (`chatgpt-codex` wire scope, `openai-codex` catalog key,
    /// `openai-compatible` custom endpoints).
    public static let displayNames: [String: String] = [
        "anthropic": "Anthropic",
        "amazon-bedrock": "Amazon Bedrock",
        "ant-ling": "Ant Ling",
        "azure-openai-responses": "Azure OpenAI Responses",
        "cerebras": "Cerebras",
        "chatgpt-codex": "ChatGPT Codex",
        "cursor": "Cursor",
        "cloudflare-ai-gateway": "Cloudflare AI Gateway",
        "cloudflare-workers-ai": "Cloudflare Workers AI",
        "deepseek": "DeepSeek",
        "fireworks": "Fireworks",
        "github-copilot": "GitHub Copilot",
        "google": "Google Gemini",
        "google-vertex": "Google Vertex AI",
        "groq": "Groq",
        "huggingface": "Hugging Face",
        "kimi-coding": "Kimi For Coding",
        "mistral": "Mistral",
        "minimax": "MiniMax",
        "minimax-cn": "MiniMax (China)",
        "moonshotai": "Moonshot AI",
        "moonshotai-cn": "Moonshot AI (China)",
        "nvidia": "NVIDIA NIM",
        "opencode": "OpenCode Zen",
        "opencode-go": "OpenCode Go",
        "openai": "OpenAI",
        "openai-codex": "ChatGPT Codex",
        "openai-compatible": "OpenAI-compatible",
        "openrouter": "OpenRouter",
        "together": "Together AI",
        "vercel-ai-gateway": "Vercel AI Gateway",
        "xai": "xAI",
        "zai": "ZAI Coding Plan (Global)",
        "zai-coding-cn": "ZAI Coding Plan (China)",
        "xiaomi": "Xiaomi MiMo",
        "xiaomi-token-plan-cn": "Xiaomi MiMo Token Plan (China)",
        "xiaomi-token-plan-ams": "Xiaomi MiMo Token Plan (Amsterdam)",
        "xiaomi-token-plan-sgp": "Xiaomi MiMo Token Plan (Singapore)",
    ]

    /// Human-readable name for `provider`, falling back to the id itself.
    /// Used by the model selector / auth-status display.
    public static func getProviderDisplayName(_ provider: String) -> String {
        displayNames[provider] ?? provider
    }

    // MARK: - Attribution headers

    private static let openRouterHost = "openrouter.ai"
    private static let nvidiaNimHost = "integrate.api.nvidia.com"
    private static let cloudflareAPIHost = "api.cloudflare.com"
    private static let cloudflareAIGatewayHost = "gateway.ai.cloudflare.com"
    private static let vercelGatewayHost = "ai-gateway.vercel.sh"

    private static func matchesHost(_ baseURL: String, _ expectedHost: String) -> Bool {
        guard let host = URLComponents(string: baseURL)?.host else { return false }
        return host == expectedHost
    }

    private static func isOpenRouter(provider: String, baseURL: String) -> Bool {
        provider == "openrouter" || baseURL.contains(openRouterHost)
    }

    private static func isNvidiaNim(provider: String, baseURL: String) -> Bool {
        provider == "nvidia" || matchesHost(baseURL, nvidiaNimHost)
    }

    private static func isCloudflare(provider: String, baseURL: String) -> Bool {
        provider == "cloudflare-workers-ai"
            || provider == "cloudflare-ai-gateway"
            || matchesHost(baseURL, cloudflareAPIHost)
            || matchesHost(baseURL, cloudflareAIGatewayHost)
    }

    private static func isVercelGateway(provider: String, baseURL: String) -> Bool {
        provider == "vercel-ai-gateway" || matchesHost(baseURL, vercelGatewayHost)
    }

    /// Branded attribution headers to merge into a request for `provider`,
    /// or nil when the provider has no branded headers. Ported from pi's
    /// `getDefaultAttributionHeaders`.
    ///
    /// Caller is responsible for merging these into the outgoing request
    /// headers (explicit per-model `Model.headers` should win on conflict).
    public static func attributionHeaders(
        provider: String,
        baseURL: String = ""
    ) -> [String: String]? {
        if isOpenRouter(provider: provider, baseURL: baseURL) {
            return [
                "HTTP-Referer": "https://kwwk.dev",
                "X-OpenRouter-Title": "kwwk",
                "X-OpenRouter-Categories": "cli-agent",
            ]
        }
        if isNvidiaNim(provider: provider, baseURL: baseURL) {
            return ["X-BILLING-INVOKE-ORIGIN": "kwwk"]
        }
        if isCloudflare(provider: provider, baseURL: baseURL) {
            return ["User-Agent": "kwwk-coding-agent"]
        }
        if isVercelGateway(provider: provider, baseURL: baseURL) {
            return [
                "http-referer": "https://kwwk.dev",
                "x-title": "kwwk",
            ]
        }
        return nil
    }

    /// Convenience overload taking a `Model`.
    public static func attributionHeaders(for model: Model) -> [String: String]? {
        attributionHeaders(provider: model.provider, baseURL: model.baseURL)
    }

    /// Merge attribution headers for `model` with any caller-supplied header
    /// sources. Later sources win on key conflict (so explicit per-model
    /// `Model.headers` override attribution). Returns nil when empty.
    public static func mergedHeaders(
        for model: Model,
        _ headerSources: [String: String]?...
    ) -> [String: String]? {
        var merged: [String: String] = attributionHeaders(for: model) ?? [:]
        for source in headerSources {
            guard let source else { continue }
            for (k, v) in source { merged[k] = v }
        }
        return merged.isEmpty ? nil : merged
    }
}
