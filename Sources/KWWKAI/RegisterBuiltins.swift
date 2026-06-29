import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One-call convenience: register all four production providers with the
/// shared `APIRegistry` using the given per-provider API keys. Only providers
/// with a non-nil key are registered — pass `anthropic: nil` to skip it, etc.
///
/// ```swift
/// await registerBuiltins(
///     anthropic: env["ANTHROPIC_API_KEY"],
///     openaiResponses: env["OPENAI_API_KEY"],
///     google: env["GOOGLE_API_KEY"]
/// )
/// ```
///
/// Each provider is registered under the `sourceId` `"kw-builtins"` so
/// callers can `APIRegistry.shared.unregisterSource("kw-builtins")` in tests.
@discardableResult
public func registerBuiltins(
    anthropic: String? = nil,
    openaiCompletions: String? = nil,
    openaiResponses: String? = nil,
    google: String? = nil,
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

/// CLI-style convenience that explicitly registers built-ins from a supplied
/// environment snapshot. Library callers should prefer `registerBuiltins(...)`
/// and pass credentials directly.
@discardableResult
public func registerBuiltinsFromEnvironment(
    env: [String: String],
    sourceId: String = "kw-builtins",
    client: HTTPClient = URLSessionHTTPClient()
) async -> [String] {
    await registerBuiltins(
        anthropic: env["ANTHROPIC_API_KEY"],
        openaiCompletions: env["OPENAI_API_KEY"],
        openaiResponses: env["OPENAI_API_KEY"],
        google: env["GOOGLE_API_KEY"] ?? env["GEMINI_API_KEY"],
        sourceId: sourceId,
        client: client
    )
}

// MARK: - Model catalog (curated, not exhaustive)

/// Hand-curated model metadata — pricing / context windows / capabilities
/// per model id. Mirrors the most common entries from pi-ai's
/// `models.generated.ts`. Not a full replacement; callers can freely
/// construct `Model` values by hand.
public enum Models {
    public static let claudeOpus48 = Model(
        id: "claude-opus-4-8",
        name: "Claude Opus 4.8",
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        contextWindow: 1_000_000,
        maxTokens: 128_000
    )

    public static let claudeSonnet46 = Model(
        id: "claude-sonnet-4-6",
        name: "Claude Sonnet 4.6",
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        contextWindow: 1_000_000,
        maxTokens: 64_000
    )

    public static let claudeHaiku45 = Model(
        id: "claude-haiku-4-5",
        name: "Claude Haiku 4.5",
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        contextWindow: 200_000,
        maxTokens: 64_000
    )

    public static let gpt55 = Model(
        id: "gpt-5.5",
        name: "GPT-5.5",
        api: "openai-responses",
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 0),
        contextWindow: 272_000,
        maxTokens: 128_000
    )

    public static let gpt54Mini = Model(
        id: "gpt-5.4-mini",
        name: "GPT-5.4 mini",
        api: "openai-responses",
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 0.75, output: 4.5, cacheRead: 0.075, cacheWrite: 0),
        contextWindow: 400_000,
        maxTokens: 128_000
    )

    public static let gemini35Flash = Model(
        id: "gemini-3.5-flash",
        name: "Gemini 3.5 Flash",
        api: "google-generative-ai",
        provider: "google",
        baseUrl: "https://generativelanguage.googleapis.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 1.5, output: 9, cacheRead: 0.15, cacheWrite: 0),
        contextWindow: 1_048_576,
        maxTokens: 65_536
    )

    public static let gemini31Pro = Model(
        id: "gemini-3.1-pro-preview",
        name: "Gemini 3.1 Pro Preview",
        api: "google-generative-ai",
        provider: "google",
        baseUrl: "https://generativelanguage.googleapis.com",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 2, output: 12, cacheRead: 0.2, cacheWrite: 0),
        contextWindow: 1_048_576,
        maxTokens: 65_536
    )

    /// OpenAI-compat baseline: xAI Grok via `/v1/chat/completions`.
    public static func xaiGrok(id: String = "grok-4.3") -> Model {
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
            maxTokens: 32_000
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
            maxTokens: 32_000
        )
    }
}
