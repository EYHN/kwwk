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
        default:
            throw AuthResolveError.unsupportedProvider(providerId)
        }
    }

    // No stored login: fall back to environment API keys (lowest priority),
    // matching pi. An exported OPENROUTER_API_KEY / GROQ_API_KEY / etc. (or
    // ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY) runs kwwk without
    // an interactive `kwwk login`.
    if let env = await resolveEnvAuth(modelOverride: modelOverride) {
        return env
    }

    throw AuthResolveError.noCredentials
}

/// Resolve a session from environment-variable API keys. Honors a
/// `provider/model` override; otherwise scans providers in priority order and
/// uses the first one whose env key is set and whose wire protocol kwwk can
/// already speak. Returns nil when nothing is configured / supported.
func resolveEnvAuth(modelOverride: String?) async -> ResolvedAuth? {
    // Split an explicit `provider/model` override.
    var forcedProvider: String?
    var forcedId: String? = modelOverride
    if let mo = modelOverride, let slash = mo.firstIndex(of: "/") {
        let prefix = String(mo[..<slash])
        if ModelsCatalog.byProvider[prefix] != nil {
            forcedProvider = prefix
            forcedId = String(mo[mo.index(after: slash)...])
        }
    }

    let candidates: [String] = forcedProvider.map { [$0] } ?? EnvAPIKeys.configuredProviders()
    for provider in candidates {
        // Amazon Bedrock authenticates via ambient AWS credentials, not a
        // single API key — register the SigV4-backed BedrockProvider directly.
        if provider == "amazon-bedrock" {
            guard EnvAPIKeys.hasBedrockKeys() else { continue }
            guard let model = pickEnvModel(provider: provider, id: forcedId) else { continue }
            await APIRegistry.shared.register(BedrockProvider(region: bedrockRegion(for: model)))
            return ResolvedAuth(
                model: model,
                modelLabel: "\(model.id) · Amazon Bedrock (env)",
                authResolver: nil
            )
        }
        // Azure OpenAI / Cloudflare authenticate via a key plus extra config
        // (endpoint / account+gateway ids) and ride bespoke ProviderVariants.
        if provider == "azure-openai-responses" {
            guard let azure = EnvAPIKeys.azure() else { continue }
            return await registerAzureEnv(azure, modelOverride: forcedId)
        }
        if provider == "cloudflare-ai-gateway" {
            guard let cf = EnvAPIKeys.cloudflare(), cf.accountId != nil, cf.gatewayId != nil else { continue }
            return await registerCloudflareEnv(cf, gateway: true, modelOverride: forcedId)
        }
        if provider == "cloudflare-workers-ai" {
            guard let cf = EnvAPIKeys.cloudflare(), cf.accountId != nil else { continue }
            return await registerCloudflareEnv(cf, gateway: false, modelOverride: forcedId)
        }
        guard let key = EnvAPIKeys.apiKey(for: provider), !key.isEmpty else { continue }
        guard let model = pickEnvModel(provider: provider, id: forcedId) else { continue }
        guard await registerEnvProvider(for: model, apiKey: key) else { continue }
        let label = "\(model.id) · \(EnvAPIKeys.displayName(for: provider)) (env)"
        return ResolvedAuth(model: model, modelLabel: label, authResolver: nil)
    }
    return nil
}

/// Register Azure OpenAI (Responses wire) from resolved env config.
private func registerAzureEnv(_ azure: EnvAPIKeys.Azure, modelOverride: String?) async -> ResolvedAuth {
    let endpoint = URL(string: azure.baseURL) ?? URL(string: "https://example.openai.azure.com/openai/v1")!
    await APIRegistry.shared.register(ProviderVariants.azureOpenAIResponsesV1(
        endpoint: endpoint, apiVersion: azure.apiVersion, apiKey: azure.apiKey
    ))
    let modelId = modelOverride ?? "gpt-5"
    let catalog = ModelsCatalog.model(provider: "azure-openai-responses", id: modelId)
    let model = Model(
        id: modelId, name: catalog?.name ?? modelId,
        api: "azure-openai-responses", provider: "azure-openai-responses",
        baseUrl: azure.baseURL, reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text, .image],
        contextWindow: catalog?.contextWindow ?? 200_000, maxTokens: catalog?.maxTokens ?? 16_384
    )
    return ResolvedAuth(model: model, modelLabel: "\(modelId) · Azure OpenAI (env)", authResolver: nil)
}

/// Register Cloudflare Workers AI / AI Gateway from resolved env config.
private func registerCloudflareEnv(_ cf: EnvAPIKeys.Cloudflare, gateway: Bool, modelOverride: String?) async -> ResolvedAuth {
    let providerId = gateway ? "cloudflare-ai-gateway" : "cloudflare-workers-ai"
    if gateway {
        await APIRegistry.shared.register(ProviderVariants.cloudflareAIGateway(apiKey: cf.apiKey))
    } else {
        await APIRegistry.shared.register(ProviderVariants.cloudflareWorkersAI(apiKey: cf.apiKey))
    }
    let fallbackBase = gateway
        ? "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/compat"
        : "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1"
    let modelId = modelOverride ?? (gateway ? "claude-3.5-haiku" : "@cf/google/gemma-4-26b-a4b-it")
    // The provider is registered under `providerId`, and `APIRegistry` dispatches
    // by `model.api` — so the model's `api` MUST equal `providerId`, otherwise the
    // request is routed to a generic provider (e.g. `openai-completions`) that
    // lacks the account-scoped base URL, `{CLOUDFLARE_*}` substitution and key.
    //
    // Workers AI catalog entries are themselves openai-completions models, so we
    // borrow their metadata. AI Gateway catalog entries describe the *native*
    // (e.g. anthropic) wire whose baseUrl doesn't match the openai-compat gateway
    // endpoint, so we ignore the catalog there and use the compat fallback base.
    let catalog = gateway ? nil : ModelsCatalog.model(provider: providerId, id: modelId)
    let model = Model(
        id: modelId, name: catalog?.name ?? modelId,
        api: providerId, provider: providerId,
        baseUrl: catalog?.baseUrl ?? fallbackBase, reasoning: catalog?.reasoning ?? false,
        input: catalog?.input ?? [.text],
        contextWindow: catalog?.contextWindow ?? 128_000, maxTokens: catalog?.maxTokens ?? 16_384,
        compat: catalog?.compat, thinkingLevelMap: catalog?.thinkingLevelMap
    )
    let label = gateway ? "Cloudflare AI Gateway" : "Cloudflare Workers AI"
    return ResolvedAuth(model: model, modelLabel: "\(modelId) · \(label) (env)", authResolver: nil)
}

/// Derive the AWS region for a Bedrock model from its catalog baseUrl host
/// (`bedrock-runtime.<region>.amazonaws.com`), falling back to AWS_REGION /
/// us-east-1. Keeps EU/APAC-hosted models from being misrouted to us-east-1.
private func bedrockRegion(for model: Model) -> String {
    if let host = URL(string: model.baseUrl)?.host {
        let parts = host.split(separator: ".")
        if parts.count >= 3, parts[0] == "bedrock-runtime" {
            return String(parts[1])
        }
    }
    return ProcessInfo.processInfo.environment["AWS_REGION"]
        ?? ProcessInfo.processInfo.environment["AWS_DEFAULT_REGION"]
        ?? "us-east-1"
}

/// Pick the catalog model to launch for an env-authenticated provider: the
/// requested id if it exists, else a reasoning-capable model, else the first
/// model by id.
private func pickEnvModel(provider: String, id: String?) -> Model? {
    if let id, let exact = ModelsCatalog.model(provider: provider, id: id) {
        return exact
    }
    let models = ModelsCatalog.models(for: provider)
    if let id, !id.isEmpty {
        // Honor an override id even if it isn't catalogued, inheriting the
        // provider's wire api/baseUrl from any sibling model.
        if let sibling = models.first {
            return Model(
                id: id, name: id, api: sibling.api, provider: provider,
                baseUrl: sibling.baseUrl, reasoning: sibling.reasoning,
                input: sibling.input, cost: sibling.cost,
                contextWindow: sibling.contextWindow, maxTokens: sibling.maxTokens,
                headers: sibling.headers, compat: sibling.compat
            )
        }
    }
    return models.first(where: { $0.reasoning }) ?? models.first
}

/// Register the provider implementation matching a model's wire `api`, using
/// the env key as the static credential. Returns false for protocols kwwk
/// can't yet drive from a raw key (handled in later phases).
private func registerEnvProvider(for model: Model, apiKey: String) async -> Bool {
    switch model.api {
    case "openai-completions":
        await APIRegistry.shared.register(OpenAICompletionsProvider(defaultAPIKey: apiKey))
        return true
    case "openai-responses":
        await APIRegistry.shared.register(OpenAIResponsesProvider(defaultAPIKey: apiKey))
        return true
    case "google-generative-ai":
        await APIRegistry.shared.register(GoogleGeminiProvider(defaultAPIKey: apiKey))
        return true
    case "mistral-conversations":
        await APIRegistry.shared.register(MistralConversationsProvider(defaultAPIKey: apiKey))
        return true
    case "anthropic-messages" where model.provider == "anthropic":
        // Direct Anthropic uses x-api-key (AnthropicProvider's default).
        // Anthropic-compatible providers (fireworks/vercel) need Bearer and
        // are wired in a later phase.
        await APIRegistry.shared.register(AnthropicProvider(defaultAPIKey: apiKey))
        return true
    default:
        return false
    }
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
