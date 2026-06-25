import Foundation

/// Provider → environment-variable API-key resolution, ported from pi's
/// `env-api-keys.ts`. Lets an exported `OPENROUTER_API_KEY` / `GROQ_API_KEY` /
/// etc. drive kwwk without an interactive `kwwk login`, matching pi's behavior
/// where env keys are the lowest-priority credential source.
///
/// This reports *API-key* variables only; ambient credential sources (AWS
/// profiles/IAM, Google ADC) are handled by their providers' own auth paths.
public enum EnvAPIKeys {
    /// Ordered provider → candidate env vars (first non-empty wins). Order
    /// within a provider mirrors pi (e.g. Anthropic OAuth token before key).
    public static let envVars: [String: [String]] = [
        "anthropic": ["ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
        "github-copilot": ["COPILOT_GITHUB_TOKEN"],
        "ant-ling": ["ANT_LING_API_KEY"],
        "openai": ["OPENAI_API_KEY"],
        "azure-openai-responses": ["AZURE_OPENAI_API_KEY"],
        "nvidia": ["NVIDIA_API_KEY"],
        "deepseek": ["DEEPSEEK_API_KEY"],
        "google": ["GEMINI_API_KEY"],
        "google-vertex": ["GOOGLE_CLOUD_API_KEY"],
        "groq": ["GROQ_API_KEY"],
        "cerebras": ["CEREBRAS_API_KEY"],
        "xai": ["XAI_API_KEY"],
        "openrouter": ["OPENROUTER_API_KEY"],
        "vercel-ai-gateway": ["AI_GATEWAY_API_KEY"],
        "zai": ["ZAI_API_KEY"],
        "zai-coding-cn": ["ZAI_CODING_CN_API_KEY"],
        "mistral": ["MISTRAL_API_KEY"],
        "minimax": ["MINIMAX_API_KEY"],
        "minimax-cn": ["MINIMAX_CN_API_KEY"],
        "moonshotai": ["MOONSHOT_API_KEY"],
        "moonshotai-cn": ["MOONSHOT_API_KEY"],
        "huggingface": ["HF_TOKEN"],
        "fireworks": ["FIREWORKS_API_KEY"],
        "together": ["TOGETHER_API_KEY"],
        "opencode": ["OPENCODE_API_KEY"],
        "opencode-go": ["OPENCODE_API_KEY"],
        "kimi-coding": ["KIMI_API_KEY"],
        "cloudflare-workers-ai": ["CLOUDFLARE_API_KEY"],
        "cloudflare-ai-gateway": ["CLOUDFLARE_API_KEY"],
        "xiaomi": ["XIAOMI_API_KEY"],
        "xiaomi-token-plan-cn": ["XIAOMI_TOKEN_PLAN_CN_API_KEY"],
        "xiaomi-token-plan-ams": ["XIAOMI_TOKEN_PLAN_AMS_API_KEY"],
        "xiaomi-token-plan-sgp": ["XIAOMI_TOKEN_PLAN_SGP_API_KEY"],
    ]

    /// Priority order used when scanning for any configured env key (no
    /// explicit provider requested). Direct first-party providers first, then
    /// aggregators, then the rest. Providers absent here are tried last in
    /// alphabetical order.
    public static let scanPriority: [String] = [
        "anthropic", "openai", "google",
        "openrouter", "deepseek", "groq", "xai", "cerebras", "together",
        "fireworks", "moonshotai", "kimi-coding", "zai", "mistral",
        "minimax", "nvidia", "huggingface", "vercel-ai-gateway",
        "opencode", "ant-ling",
    ]

    /// Human-readable provider names. The source of truth now lives in
    /// `ProviderAttribution.displayNames` (full port of pi's
    /// `BUILT_IN_PROVIDER_DISPLAY_NAMES`); this delegates so callers keep a
    /// single map.
    public static var displayNames: [String: String] {
        ProviderAttribution.displayNames
    }

    public static func displayName(for provider: String) -> String {
        ProviderAttribution.getProviderDisplayName(provider)
    }

    /// The configured env vars (non-empty) that can authenticate `provider`.
    public static func foundEnvVars(for provider: String, env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard let candidates = envVars[provider] else { return [] }
        return candidates.filter { (env[$0]?.isEmpty == false) }
    }

    /// The API key for `provider` from env, or nil. Does not cover OAuth-only
    /// providers' bearer tokens beyond the env-key form.
    public static func apiKey(for provider: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let first = foundEnvVars(for: provider, env: env).first {
            return env[first]
        }
        return nil
    }

    /// Whether ambient AWS credentials that `BedrockProvider` can actually use
    /// (long-term IAM keys) are present. Profile/bearer/ECS/web-identity are
    /// recognized for reachability but not yet consumed by the SigV4 path.
    public static func hasBedrockKeys(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        (env["AWS_ACCESS_KEY_ID"]?.isEmpty == false) && (env["AWS_SECRET_ACCESS_KEY"]?.isEmpty == false)
    }

    /// Every provider that currently has a usable env key configured, in scan
    /// priority order (then alphabetical for the rest). Amazon Bedrock is
    /// appended when ambient AWS credentials are present.
    public static func configuredProviders(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let ranked = scanPriority + envVars.keys.filter { !scanPriority.contains($0) }.sorted()
        var out = ranked.filter { !foundEnvVars(for: $0, env: env).isEmpty }
        if hasBedrockKeys(env: env) { out.append("amazon-bedrock") }
        return out
    }
}
