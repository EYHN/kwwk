import Foundation

/// One-call convenience: register all four production providers with the
/// shared `APIRegistry` using the given per-provider API keys. Only providers
/// with a non-nil key are registered — pass `anthropic: nil` to skip it, etc.
///
/// ```swift
/// await registerBuiltins(
///     anthropic: env["ANTHROPIC_API_KEY"],
///     openai: env["OPENAI_API_KEY"],
///     google: env["GOOGLE_API_KEY"]
/// )
/// ```
///
/// Each provider is registered under the `sourceId` `"kw-builtins"` so
/// callers can `APIRegistry.shared.unregisterSource("kw-builtins")` in tests.
@discardableResult
public func registerBuiltins(
    anthropic: String? = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
    openaiCompletions: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
    openaiResponses: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
    google: String? = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
        ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
    sourceId: String = "kw-builtins",
    client: HTTPClient = URLSessionHTTPClient()
) async -> [String] {
    var registered: [String] = []
    if let key = anthropic {
        let provider = AnthropicProvider(client: client, defaultAPIKey: key)
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        registered.append(provider.api)
    }
    if let key = openaiCompletions {
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: key)
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        registered.append(provider.api)
    }
    if let key = openaiResponses {
        let provider = OpenAIResponsesProvider(client: client, defaultAPIKey: key)
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        registered.append(provider.api)
    }
    if let key = google {
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: key)
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        registered.append(provider.api)
    }
    return registered
}

// MARK: - Model catalog (curated, not exhaustive)

/// Hand-curated model metadata — pricing / context windows / capabilities
/// per model id. Mirrors the most common entries from pi-ai's
/// `models.generated.ts`. Not a full replacement; callers can freely
/// construct `Model` values by hand.
public enum Models {
    public static let claudeSonnet45 = Model(
        id: "claude-sonnet-4-5-20250929",
        name: "Claude Sonnet 4.5",
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        contextWindow: 200_000,
        maxTokens: 8192
    )

    public static let claudeHaiku45 = Model(
        id: "claude-haiku-4-5-20251001",
        name: "Claude Haiku 4.5",
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: false,
        input: [.text, .image],
        cost: ModelCost(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        contextWindow: 200_000,
        maxTokens: 8192
    )

    public static let gpt5 = Model(
        id: "gpt-5",
        name: "GPT-5",
        api: "openai-responses",
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 2.5, output: 10, cacheRead: 0.25, cacheWrite: 0),
        contextWindow: 200_000,
        maxTokens: 16_384
    )

    public static let gpt4oMini = Model(
        id: "gpt-4o-mini",
        name: "GPT-4o Mini",
        api: "openai-completions",
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: false,
        input: [.text, .image],
        cost: ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0),
        contextWindow: 128_000,
        maxTokens: 16_384
    )

    public static let gemini25Flash = Model(
        id: "gemini-2.5-flash",
        name: "Gemini 2.5 Flash",
        api: "google-generative-ai",
        provider: "google",
        baseUrl: "https://generativelanguage.googleapis.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 0.075, output: 0.3, cacheRead: 0.01875, cacheWrite: 0),
        contextWindow: 1_000_000,
        maxTokens: 8192
    )

    public static let gemini25Pro = Model(
        id: "gemini-2.5-pro",
        name: "Gemini 2.5 Pro",
        api: "google-generative-ai",
        provider: "google",
        baseUrl: "https://generativelanguage.googleapis.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 1.25, output: 10, cacheRead: 0.31, cacheWrite: 0),
        contextWindow: 2_000_000,
        maxTokens: 8192
    )

    /// OpenAI-compat baseline: xAI Grok via `/v1/chat/completions`.
    public static func xaiGrok(id: String = "grok-code-fast-1") -> Model {
        Model(
            id: id,
            name: id,
            api: "openai-completions",
            provider: "xai",
            baseUrl: "https://api.x.ai",
            reasoning: true,
            input: [.text],
            contextWindow: 131_072,
            maxTokens: 16_384
        )
    }

    /// OpenAI-compat baseline: Groq.
    public static func groq(id: String) -> Model {
        Model(
            id: id,
            name: id,
            api: "openai-completions",
            provider: "groq",
            baseUrl: "https://api.groq.com/openai",
            reasoning: true,
            input: [.text],
            contextWindow: 131_072,
            maxTokens: 16_384
        )
    }

    /// OpenAI-compat baseline: OpenRouter.
    public static func openRouter(id: String) -> Model {
        Model(
            id: id,
            name: id,
            api: "openai-completions",
            provider: "openrouter",
            baseUrl: "https://openrouter.ai/api",
            reasoning: true,
            input: [.text],
            contextWindow: 131_072,
            maxTokens: 16_384
        )
    }
}
