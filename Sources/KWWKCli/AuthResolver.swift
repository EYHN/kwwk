import Foundation
import KWWKAI

/// Result of resolving which LLM + credentials to use for this session.
/// The provider has already been registered on `APIRegistry.shared`.
struct ResolvedAuth: Sendable {
    let model: Model
    let modelLabel: String
    /// For OAuth-backed providers (Codex, Anthropic OAuth, ...), an
    /// `authResolver` that calls back into `OAuthManager.apiKey(for:)` so
    /// tokens refresh on demand. Nil for static api-key providers.
    let authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)?
}

enum AuthResolveError: Error, LocalizedError {
    case noCredentials
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return """
            No credentials configured.

            Run `kwwk login` to pick a provider (OAuth subscription or
            API key).
            """
        case .unsupportedProvider(let id):
            return """
            Stored credentials for '\(id)' are not yet wired up in the
            kwwk CLI. Run `kwwk login` and pick a different provider.
            """
        }
    }
}

/// Resolve credentials:
///   1. `OAuthStore` has exactly one provider (kwwk login is exclusive) →
///      route based on that provider id.
///   2. Throw `noCredentials`.
///
/// Registers the chosen provider on `APIRegistry.shared` as a side effect so
/// the returned model can be used immediately.
///
/// `modelOverride` (optional) replaces the provider's hardcoded default model
/// id — catalog metadata is still resolved from `ModelsCatalog`, falling back
/// to sane defaults if the id is unknown.
///
/// `context1m` opts the Anthropic OAuth provider into the 1M-context beta
/// (adds `context-1m-2025-08-07` to the `anthropic-beta` header and bumps
/// `contextWindow` to 1M). It is silently ignored by other providers.
func resolveAgentAuth(
    modelOverride: String? = nil,
    context1m: Bool = false
) async throws -> ResolvedAuth {
    let store = OAuthStore()
    let all = await store.all()

    // Pick the single entry. If the store somehow holds multiple (legacy
    // files from before `setExclusive`), prefer OAuth subscriptions over
    // raw API keys so users on both don't silently land on the wrong one.
    if let providerId = pickStoredProvider(from: all), let creds = all[providerId] {
        switch providerId {
        case "openai-codex":
            return await registerCodex(store: store, creds: creds, modelOverride: modelOverride)
        case "anthropic":
            return await registerAnthropicOAuth(
                store: store, creds: creds,
                modelOverride: modelOverride, context1m: context1m
            )
        case "anthropic-api-key":
            return await registerAnthropicAPIKey(creds: creds, modelOverride: modelOverride)
        case "openai-api-key":
            return await registerOpenAIAPIKey(creds: creds, modelOverride: modelOverride)
        case "openai-compatible":
            return try await registerOpenAICompatible(creds: creds, modelOverride: modelOverride)
        case "google-api-key":
            return await registerGoogleAPIKey(creds: creds, modelOverride: modelOverride)
        case "github-copilot":
            return await registerGitHubCopilot(store: store, creds: creds, modelOverride: modelOverride)
        case "google-gemini-cli", "google-antigravity":
            throw AuthResolveError.unsupportedProvider(providerId)
        default:
            throw AuthResolveError.unsupportedProvider(providerId)
        }
    }

    throw AuthResolveError.noCredentials
}

/// Deterministic priority order when the store holds more than one entry.
/// OAuth subscriptions first, then api keys, then wrappers we don't yet
/// support (they'll surface a clear error rather than a silent miss).
private func pickStoredProvider(from all: [String: OAuthCredentials]) -> String? {
    let priority = [
        "openai-codex",
        "anthropic",
        "anthropic-api-key",
        "openai-api-key",
        "openai-compatible",
        "google-api-key",
        "google-gemini-cli",
        "google-antigravity",
        "github-copilot",
    ]
    for id in priority where all[id] != nil { return id }
    return all.keys.sorted().first
}

// MARK: - Codex (OAuth)

private func registerCodex(
    store: OAuthStore,
    creds: OAuthCredentials,
    modelOverride: String? = nil
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    // Grab a fresh token if expired. If the refresh fails we still register
    // the provider — the authResolver below will retry on the next request
    // and surface the error to the user there.
    _ = try? await manager.apiKey(for: "openai-codex")

    let refreshed = await store.get("openai-codex") ?? creds
    let accountId: String? = {
        if case .string(let s) = refreshed.extras["accountId"] ?? .null { return s }
        return nil
    }()

    await APIRegistry.shared.register(ProviderVariants.chatgptCodex(
        accessToken: nil,
        accountId: accountId,
        originator: "kwwk"
    ))

    let modelId = modelOverride ?? "gpt-5.4"
    let catalogEntry = ModelsCatalog.model(provider: "openai-codex", id: modelId)
    let model = Model(
        id: modelId,
        name: catalogEntry?.name ?? modelId,
        api: "chatgpt-codex",
        provider: "chatgpt-codex",
        baseUrl: "https://chatgpt.com",
        reasoning: catalogEntry?.reasoning ?? true,
        input: catalogEntry?.input ?? [.text, .image],
        contextWindow: catalogEntry?.contextWindow ?? 272_000,
        // Codex rejects max_output_tokens — setting to 0 skips emitting
        // the field in the request body regardless of what the catalog
        // reports.
        maxTokens: 0
    )

    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · ChatGPT Codex",
        authResolver: oauthResolver(manager: manager, providerId: "openai-codex", scheme: .bearer)
    )
}

// MARK: - Anthropic OAuth

private func registerAnthropicOAuth(
    store: OAuthStore,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    context1m: Bool = false
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    _ = try? await manager.apiKey(for: "anthropic")

    // Opt into the 1M-context beta when requested. Sent alongside the OAuth
    // beta as a single comma-separated `anthropic-beta` header value, which
    // is the wire format the Messages API expects. Requires the account to
    // have long-context billing enabled — without that, every request 401s
    // with `"Extra usage is required for long context requests."` even on
    // small prompts.
    let beta = context1m
        ? "oauth-2025-04-20,context-1m-2025-08-07"
        : "oauth-2025-04-20"
    await APIRegistry.shared.register(ProviderVariants.anthropicOAuth(
        accessToken: nil,
        beta: beta
    ))

    let modelId = modelOverride ?? "claude-sonnet-4-5-20250929"
    let catalog = ModelsCatalog.model(provider: "anthropic", id: modelId)
    let defaultContext = context1m ? 1_000_000 : 200_000
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text, .image],
        contextWindow: context1m ? 1_000_000 : (catalog?.contextWindow ?? defaultContext),
        maxTokens: catalog?.maxTokens ?? 8192
    )

    let suffix = context1m ? " · Anthropic OAuth (1M ctx)" : " · Anthropic OAuth"
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId)\(suffix)",
        authResolver: oauthResolver(manager: manager, providerId: "anthropic", scheme: .bearer)
    )
}

// MARK: - GitHub Copilot (OAuth)

private func registerGitHubCopilot(
    store: OAuthStore,
    creds: OAuthCredentials,
    modelOverride: String? = nil
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    // Prime the session token — Copilot's `refresh` is actually a PAT →
    // session-token exchange that must happen before the proxy will route.
    // We ignore the returned token; the resolver below re-fetches on demand
    // (`OAuthManager` caches until `expires_at` so we don't round-trip
    // every request). The refresh also persists the proxy endpoint into
    // `extras["endpoint"]`, which we read below.
    _ = try? await manager.apiKey(for: "github-copilot")
    let refreshed = await store.get("github-copilot") ?? creds

    // Copilot Business / Enterprise get a proxy-endpoint claim (e.g.
    // `https://api.business.githubcopilot.com`) that the session-token
    // refresh already stashed in `extras["endpoint"]`. Individual/Pro
    // users fall back to the canonical host.
    let baseURLString: String = {
        if case .string(let s) = refreshed.extras["endpoint"] ?? .null, !s.isEmpty {
            return s
        }
        return "https://api.individual.githubcopilot.com"
    }()
    let baseURL = URL(string: baseURLString)
        ?? URL(string: "https://api.individual.githubcopilot.com")!

    // Register one provider per wire format. Copilot's catalog mixes all
    // three: Claude models use anthropic-messages, GPT-4.x and Gemini use
    // openai-completions, GPT-5 family uses openai-responses. With
    // single-provider login (`setExclusive`) these don't collide with the
    // direct-API providers; they replace them for this session.
    await APIRegistry.shared.register(ProviderVariants.githubCopilot(
        sessionToken: nil,
        integrationID: "vscode-chat",
        baseURL: baseURL
    ))
    await APIRegistry.shared.register(ProviderVariants.githubCopilotAnthropic(
        sessionToken: nil,
        integrationID: "vscode-chat",
        baseURL: baseURL
    ))
    await APIRegistry.shared.register(ProviderVariants.githubCopilotResponses(
        sessionToken: nil,
        integrationID: "vscode-chat",
        baseURL: baseURL
    ))

    // Default to `gpt-4.1` — generally available on all Copilot tiers, no
    // policy-enable dependency. Users can /model to Claude/GPT-5/etc after
    // login-time policy-enable has run, or set `--model` at launch.
    let defaultId = modelOverride ?? "gpt-4.1"
    let fallback = Model(
        id: defaultId,
        name: defaultId,
        api: "openai-completions",
        provider: "github-copilot",
        baseUrl: baseURLString,
        reasoning: false,
        input: [.text, .image],
        contextWindow: 128_000,
        maxTokens: 16_384
    )
    // Use catalog model for wire-format api + capabilities, but stamp
    // the session's resolved `baseUrl` on it — catalog entries hardcode
    // `api.individual.githubcopilot.com` which would bypass the
    // Business/Enterprise proxy. `adoptFields` preserves this session
    // baseUrl across `/model` switches, so every Copilot model routes
    // through the right host.
    let model: Model = {
        guard let catalog = ModelsCatalog.model(provider: "github-copilot", id: defaultId)
        else { return fallback }
        return Model(
            id: catalog.id,
            name: catalog.name,
            api: catalog.api,
            provider: catalog.provider,
            baseUrl: baseURLString,
            reasoning: catalog.reasoning,
            input: catalog.input,
            cost: catalog.cost,
            contextWindow: catalog.contextWindow,
            maxTokens: catalog.maxTokens,
            headers: catalog.headers
        )
    }()

    return ResolvedAuth(
        model: model,
        modelLabel: "\(defaultId) · GitHub Copilot",
        authResolver: oauthResolver(
            manager: manager,
            providerId: "github-copilot",
            scheme: .bearer,
            baseURL: baseURLString
        )
    )
}

// MARK: - Anthropic API key (login form)

private func registerAnthropicAPIKey(
    creds: OAuthCredentials,
    modelOverride: String? = nil
) async -> ResolvedAuth {
    let baseURL = stringExtra(creds, "baseUrl") ?? "https://api.anthropic.com"
    await APIRegistry.shared.register(AnthropicProvider(defaultAPIKey: creds.access))

    let modelId = modelOverride ?? "claude-sonnet-4-5-20250929"
    let catalog = ModelsCatalog.model(provider: "anthropic", id: modelId)
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: baseURL,
        reasoning: catalog?.reasoning ?? false,
        input: catalog?.input ?? [.text, .image],
        contextWindow: catalog?.contextWindow ?? 200_000,
        maxTokens: catalog?.maxTokens ?? 8192
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · Anthropic (API key)",
        authResolver: nil
    )
}

// MARK: - OpenAI API key (login form)

private func registerOpenAIAPIKey(
    creds: OAuthCredentials,
    modelOverride: String? = nil
) async -> ResolvedAuth {
    let baseURL = stringExtra(creds, "baseUrl") ?? "https://api.openai.com"
    await APIRegistry.shared.register(OpenAIResponsesProvider(defaultAPIKey: creds.access))

    let modelId = modelOverride ?? "gpt-5"
    let catalog = ModelsCatalog.model(provider: "openai", id: modelId)
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "openai-responses",
        provider: "openai",
        baseUrl: baseURL,
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text, .image],
        contextWindow: catalog?.contextWindow ?? 200_000,
        maxTokens: catalog?.maxTokens ?? 16_384
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · OpenAI (API key)",
        authResolver: nil
    )
}

// MARK: - Google AI Studio (Gemini direct, login form)

private func registerGoogleAPIKey(
    creds: OAuthCredentials,
    modelOverride: String? = nil
) async -> ResolvedAuth {
    let baseURL = stringExtra(creds, "baseUrl") ?? "https://generativelanguage.googleapis.com"
    await APIRegistry.shared.register(GoogleGeminiProvider(defaultAPIKey: creds.access))

    let modelId = modelOverride ?? "gemini-2.5-pro"
    let catalog = ModelsCatalog.model(provider: "google", id: modelId)
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "google-generative-ai",
        provider: "google",
        // Host root — `GoogleGeminiProvider`'s urlBuilder appends `/v1beta`
        // itself (and tolerates a baseUrl that already includes it, which
        // is what catalog models carry).
        baseUrl: baseURL,
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text, .image],
        contextWindow: catalog?.contextWindow ?? 1_048_576,
        maxTokens: catalog?.maxTokens ?? 8192
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · Google AI Studio",
        authResolver: nil
    )
}

// MARK: - OpenAI-compatible (login form)

private func registerOpenAICompatible(
    creds: OAuthCredentials,
    modelOverride: String? = nil
) async throws -> ResolvedAuth {
    guard let baseURL = stringExtra(creds, "baseUrl"), !baseURL.isEmpty else {
        throw AuthResolveError.unsupportedProvider("openai-compatible (missing baseUrl)")
    }
    let storedModel = stringExtra(creds, "defaultModel")
    guard let modelId = modelOverride ?? storedModel, !modelId.isEmpty else {
        throw AuthResolveError.unsupportedProvider("openai-compatible (missing defaultModel)")
    }
    await APIRegistry.shared.register(OpenAICompletionsProvider(defaultAPIKey: creds.access))

    let model = Model(
        id: modelId,
        name: modelId,
        api: "openai-completions",
        provider: "openai-compatible",
        baseUrl: baseURL,
        reasoning: false,
        input: [.text],
        contextWindow: 131_072,
        maxTokens: 16_384
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · \(baseURL)",
        authResolver: nil
    )
}

// MARK: - helpers

private func stringExtra(_ creds: OAuthCredentials, _ key: String) -> String? {
    if case .string(let s) = creds.extras[key] ?? .null { return s }
    return nil
}

private func oauthResolver(
    manager: OAuthManager,
    providerId: String,
    scheme: AuthScheme,
    baseURL: String? = nil
) -> @Sendable (Model, String?) async -> ResolvedProviderAuth? {
    { _, _ in
        guard let token = try? await manager.apiKey(for: providerId) else { return nil }
        return ResolvedProviderAuth(token: token, scheme: scheme, baseURL: baseURL)
    }
}
