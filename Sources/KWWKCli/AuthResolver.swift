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
    /// Every provider registered this session, so `/model` can list + switch
    /// across all logged-in accounts. Single-login / env auth yields one slot.
    let providerSlots: [ProviderSlot]
    /// The mutable resolver map the agent's `authResolver` delegates to, so
    /// `/login` can add a provider mid-session. Nil for the single-provider
    /// helper paths that don't own one.
    let authResolvers: SessionAuthResolvers?

    init(
        model: Model,
        modelLabel: String,
        authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
        providerSlots: [ProviderSlot] = [],
        authResolvers: SessionAuthResolvers? = nil
    ) {
        self.model = model
        self.modelLabel = modelLabel
        self.authResolver = authResolver
        self.providerSlots = providerSlots
        self.authResolvers = authResolvers
    }
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
    let store = OAuthStore(url: OAuthStore.defaultURL())
    let all = await store.all()

    if !all.isEmpty {
        return try await registerAllStored(
            store: store, all: all,
            modelOverride: modelOverride, context1m: context1m
        )
    }

    // No stored login: fall back to environment API keys (lowest priority),
    // matching pi. An exported OPENROUTER_API_KEY / GROQ_API_KEY / etc. (or
    // ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY) runs kwwk without
    // an interactive `kwwk login`.
    if let env = await resolveEnvAuth(
        modelOverride: modelOverride,
        environment: ProcessInfo.processInfo.environment
    ) {
        // Give `/model` a single slot for the env provider so it can still
        // list that provider's catalog, and a resolver actor so a later
        // `/login` can add a stored provider mid-session.
        let slot = ProviderSlot(
            storeId: "env:\(env.model.provider)",
            catalogProvider: catalogProvider(forCatalogKey: env.model.provider),
            displayName: providerDisplayName(forStoreId: "env:\(env.model.provider)"),
            template: env.model
        )
        let authResolvers = SessionAuthResolvers()
        if let r = env.authResolver {
            await authResolvers.set(scope: env.model.provider, r)
        }
        return ResolvedAuth(
            model: env.model,
            modelLabel: env.modelLabel,
            authResolver: authResolvers.delegatingResolver(),
            providerSlots: [slot],
            authResolvers: authResolvers
        )
    }

    throw AuthResolveError.noCredentials
}

/// For env-auth the model's `provider` is already the catalog key (e.g.
/// `openai`, `google`, `anthropic`), except the Codex variant. Normalize it.
private func catalogProvider(forCatalogKey key: String) -> String {
    key == "chatgpt-codex" ? "openai-codex" : key
}

/// Register **every** stored provider on `APIRegistry.shared` (each scoped by
/// its `model.provider` so same-wire providers don't clobber each other), and
/// return a `ResolvedAuth` whose model is the *active* provider's default and
/// whose `authResolver` is a **unified** closure that dispatches by
/// `model.provider` across all logged-in accounts. `/model` can then switch to
/// any registered provider's models mid-session and requests route to the
/// right credentials.
///
/// Active-provider selection:
///   - `modelOverride` of the form `provider/id` activates that provider (if
///     logged in) with model `id`.
///   - Otherwise the highest-priority logged-in provider is active, and a bare
///     `modelOverride` names its model.
private func registerAllStored(
    store: OAuthStore,
    all: [String: OAuthCredentials],
    modelOverride: String?,
    context1m: Bool
) async throws -> ResolvedAuth {
    let order = storedProviderOrder(all)

    // Split an explicit `provider/model` override and resolve which logged-in
    // store id it targets (prefer the priority order on ambiguity, e.g.
    // `anthropic/...` with both OAuth and API-key logins → OAuth).
    var forcedStoreId: String?
    var activeModelId: String? = modelOverride
    if let mo = modelOverride, let slash = mo.firstIndex(of: "/") {
        let prefix = String(mo[..<slash])
        if let sid = order.first(where: { catalogProvider(forStoreId: $0) == prefix }) {
            forcedStoreId = sid
            activeModelId = String(mo[mo.index(after: slash)...])
        }
    }
    let activeStoreId = forcedStoreId ?? order.first

    // Register each provider once. Skip a later provider whose `model.provider`
    // scope is already taken (same-vendor dual login, e.g. Anthropic OAuth +
    // Anthropic API key both scope to `anthropic`) — priority order keeps the
    // preferred one.
    let authResolvers = SessionAuthResolvers()
    var seenScopes: Set<String> = []
    var slots: [ProviderSlot] = []
    var active: ResolvedAuth?

    for storeId in order {
        guard all[storeId] != nil else { continue }
        let scope = modelProviderScope(forStoreId: storeId)
        if seenScopes.contains(scope) {
            FileHandle.standardError.write(Data(
                "kwwk: '\(storeId)' shares the '\(scope)' provider slot with an already-registered login; skipping.\n".utf8
            ))
            continue
        }
        let mo = storeId == activeStoreId ? activeModelId : nil
        guard let resolved = try await registerStored(
            storeId: storeId, store: store, modelOverride: mo, context1m: context1m
        ) else { continue }
        seenScopes.insert(scope)
        if let r = resolved.authResolver {
            await authResolvers.set(scope: resolved.model.provider, r)
        }
        slots.append(ProviderSlot(
            storeId: storeId,
            catalogProvider: catalogProvider(forStoreId: storeId),
            displayName: providerDisplayName(forStoreId: storeId),
            template: resolved.model
        ))
        if storeId == activeStoreId { active = resolved }
    }

    guard let active else { throw AuthResolveError.noCredentials }

    // The agent holds one stable delegating closure; static-only sessions get
    // a resolver that always returns nil (providers use baked keys), which
    // still lets a later `/login` install an OAuth provider.
    return ResolvedAuth(
        model: active.model,
        modelLabel: active.modelLabel,
        authResolver: authResolvers.delegatingResolver(),
        providerSlots: slots,
        authResolvers: authResolvers
    )
}

/// Register one stored provider on `APIRegistry.shared` (scoped by its
/// `model.provider`) and return its `ResolvedAuth` (default model + optional
/// per-provider resolver). Shared by launch-time `registerAllStored` and the
/// in-session `/login` path. Returns nil for unwired store ids or missing
/// credentials (logging a notice for the former).
func registerStored(
    storeId: String,
    store: OAuthStore,
    modelOverride: String?,
    context1m: Bool
) async throws -> ResolvedAuth? {
    guard let creds = await store.get(storeId) else { return nil }
    switch storeId {
    case "openai-codex":
        return await registerCodex(store: store, creds: creds, modelOverride: modelOverride)
    case "anthropic":
        return await registerAnthropicOAuth(
            store: store, creds: creds, modelOverride: modelOverride, context1m: context1m
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
        FileHandle.standardError.write(Data(
            "kwwk: stored credentials for '\(storeId)' aren't wired up; skipping.\n".utf8
        ))
        return nil
    }
}

/// Register a single freshly-logged-in provider mid-session: scoped provider
/// on `APIRegistry`, resolver into `authResolvers`, and a `ProviderSlot` for
/// `/model`. Returns nil if the provider isn't stored / wired up.
@MainActor
func registerStoredProviderLive(
    storeId: String,
    authResolvers: SessionAuthResolvers,
    context1m: Bool = false
) async -> ProviderSlot? {
    let store = OAuthStore(url: OAuthStore.defaultURL())
    guard let resolved = try? await registerStored(
        storeId: storeId, store: store, modelOverride: nil, context1m: context1m
    ) else { return nil }
    if let r = resolved.authResolver {
        await authResolvers.set(scope: resolved.model.provider, r)
    }
    return ProviderSlot(
        storeId: storeId,
        catalogProvider: catalogProvider(forStoreId: storeId),
        displayName: providerDisplayName(forStoreId: storeId),
        template: resolved.model
    )
}

/// Resolve a session from environment-variable API keys. Honors a
/// `provider/model` override; otherwise scans providers in priority order and
/// uses the first one whose env key is set and whose wire protocol kwwk can
/// already speak. Returns nil when nothing is configured / supported.
func resolveEnvAuth(
    modelOverride: String?,
    environment: [String: String]
) async -> ResolvedAuth? {
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

    let candidates: [String] = forcedProvider.map { [$0] }
        ?? EnvAPIKeys.configuredProviders(env: environment)
    for provider in candidates {
        // Amazon Bedrock authenticates via ambient AWS credentials, not a
        // single API key — register the SigV4-backed BedrockProvider directly.
        if provider == "amazon-bedrock" {
            guard EnvAPIKeys.hasBedrockAuth(env: environment) else { continue }
            guard let model = pickEnvModel(provider: provider, id: forcedId) else { continue }
            await APIRegistry.shared.register(BedrockProvider(
                region: bedrockRegion(for: model, environment: environment),
                environment: environment,
                resolveProfileFiles: true
            ))
            return ResolvedAuth(
                model: model,
                modelLabel: "\(model.id) · Amazon Bedrock (env)",
                authResolver: nil
            )
        }
        // Azure OpenAI / Cloudflare authenticate via a key plus extra config
        // (endpoint / account+gateway ids) and ride bespoke ProviderVariants.
        if provider == "azure-openai-responses" {
            guard let azure = EnvAPIKeys.azure(env: environment) else { continue }
            return await registerAzureEnv(azure, modelOverride: forcedId)
        }
        if provider == "cloudflare-ai-gateway" {
            guard let cf = EnvAPIKeys.cloudflare(env: environment),
                  cf.accountId != nil,
                  cf.gatewayId != nil else { continue }
            return await registerCloudflareEnv(cf, gateway: true, modelOverride: forcedId)
        }
        if provider == "cloudflare-workers-ai" {
            guard let cf = EnvAPIKeys.cloudflare(env: environment), cf.accountId != nil else { continue }
            return await registerCloudflareEnv(cf, gateway: false, modelOverride: forcedId)
        }
        guard let key = EnvAPIKeys.apiKey(for: provider, env: environment), !key.isEmpty else { continue }
        guard let model = pickEnvModel(provider: provider, id: forcedId) else { continue }
        guard await registerEnvProviders(for: provider, apiKey: key) else { continue }
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
    let modelId = modelOverride ?? "gpt-5.5"
    let catalog = ModelsCatalog.model(provider: "azure-openai-responses", id: modelId)
    let model = Model(
        id: modelId, name: catalog?.name ?? modelId,
        api: "azure-openai-responses", provider: "azure-openai-responses",
        baseUrl: azure.baseURL, reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text, .image],
        contextWindow: catalog?.contextWindow ?? 200_000, maxTokens: catalog?.maxTokens ?? 128_000
    )
    return ResolvedAuth(model: model, modelLabel: "\(modelId) · Azure OpenAI (env)", authResolver: nil)
}

/// Register Cloudflare Workers AI / AI Gateway from resolved env config.
private func registerCloudflareEnv(_ cf: EnvAPIKeys.Cloudflare, gateway: Bool, modelOverride: String?) async -> ResolvedAuth {
    let providerId = gateway ? "cloudflare-ai-gateway" : "cloudflare-workers-ai"
    if gateway {
        await APIRegistry.shared.register(ProviderVariants.cloudflareAIGateway(
            apiKey: cf.apiKey,
            accountId: cf.accountId,
            gatewayId: cf.gatewayId
        ))
    } else {
        await APIRegistry.shared.register(ProviderVariants.cloudflareWorkersAI(
            apiKey: cf.apiKey,
            accountId: cf.accountId
        ))
    }
    let fallbackBase = gateway
        ? "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/compat"
        : "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1"
    let modelId = modelOverride ?? (gateway ? "claude-haiku-4-5" : "@cf/google/gemma-4-26b-a4b-it")
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
private func bedrockRegion(for model: Model, environment: [String: String]) -> String {
    if let host = URL(string: model.baseUrl)?.host {
        let parts = host.split(separator: ".")
        if parts.count >= 3, parts[0] == "bedrock-runtime" {
            return String(parts[1])
        }
    }
    return environment["AWS_REGION"]
        ?? environment["AWS_DEFAULT_REGION"]
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

/// Register every wire `api` used by the provider, using the env key as the
/// static credential. Returns false when none of the provider's wire protocols
/// can be driven from a raw environment credential.
private func registerEnvProviders(for provider: String, apiKey: String) async -> Bool {
    guard let catalog = ModelsCatalog.byProvider[provider] else { return false }
    var apis: Set<String> = []
    for model in catalog.values {
        apis.insert(model.api)
    }

    var registered = false
    for api in apis {
        if await registerEnvProvider(api: api, provider: provider, apiKey: apiKey) {
            registered = true
        }
    }
    return registered
}

private func registerEnvProvider(api: String, provider: String, apiKey: String) async -> Bool {
    switch api {
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
    case "anthropic-messages":
        if provider == "anthropic" {
            await APIRegistry.shared.register(AnthropicProvider(defaultAPIKey: apiKey))
        } else {
            await APIRegistry.shared.register(AnthropicProvider(
                defaultAPIKey: apiKey,
                authHeaderBuilder: { key in ["Authorization": cliBearerHeaderValue(key)] }
            ))
        }
        return true
    default:
        return false
    }
}

/// Deterministic priority order for the stored provider ids that are actually
/// present. OAuth subscriptions first, then api keys; the first entry is the
/// default *active* provider at launch, and the order also breaks same-scope
/// ties (e.g. Anthropic OAuth wins over Anthropic API key). Unknown ids sort
/// last so they surface a clear "not wired up" notice rather than a silent
/// miss.
private let storedProviderPriority = [
    "openai-codex",
    "anthropic",
    "anthropic-api-key",
    "openai-api-key",
    "openai-compatible",
    "google-api-key",
    "github-copilot",
]

func storedProviderOrder(_ all: [String: OAuthCredentials]) -> [String] {
    var order = storedProviderPriority.filter { all[$0] != nil }
    let extras = all.keys.filter { !storedProviderPriority.contains($0) }.sorted()
    order.append(contentsOf: extras)
    return order
}

/// The `model.provider` scope a stored provider registers under on
/// `APIRegistry` — the key `stream` dispatches on. Several store ids collapse
/// onto the same catalog provider (`anthropic` OAuth and `anthropic-api-key`
/// both drive Anthropic's `anthropic-messages` wire), so this is intentionally
/// many-to-one; `registerAllStored` skips the later of any collision.
func modelProviderScope(forStoreId storeId: String) -> String {
    switch storeId {
    case "openai-codex": return "chatgpt-codex"
    case "anthropic", "anthropic-api-key": return "anthropic"
    case "openai-api-key": return "openai"
    case "google-api-key": return "google"
    case "openai-compatible": return "openai-compatible"
    default: return storeId  // github-copilot, and any future 1:1 ids
    }
}

/// The `ModelsCatalog.byProvider` key holding a stored provider's models —
/// used to list a provider's models for `/model` and to match a
/// `provider/model` launch override to a logged-in account.
func catalogProvider(forStoreId storeId: String) -> String {
    switch storeId {
    case "openai-codex": return "openai-codex"
    case "anthropic", "anthropic-api-key": return "anthropic"
    case "openai-api-key": return "openai"
    case "google-api-key": return "google"
    case "openai-compatible": return "openai-compatible"
    default: return storeId  // github-copilot
    }
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
    ), scope: "chatgpt-codex")

    let modelId = modelOverride ?? "gpt-5.5"
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
    ), scope: "anthropic")

    let modelId = modelOverride ?? "claude-opus-4-8"
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
        maxTokens: catalog?.maxTokens ?? 128_000
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
    ), scope: "github-copilot")
    await APIRegistry.shared.register(ProviderVariants.githubCopilotAnthropic(
        sessionToken: nil,
        integrationID: "vscode-chat",
        baseURL: baseURL
    ), scope: "github-copilot")
    await APIRegistry.shared.register(ProviderVariants.githubCopilotResponses(
        sessionToken: nil,
        integrationID: "vscode-chat",
        baseURL: baseURL
    ), scope: "github-copilot")

    // Default to `gpt-5.5` — generally available on all Copilot tiers, no
    // policy-enable dependency. Users can /model to Claude/GPT-5/etc after
    // login-time policy-enable has run, or set `--model` at launch.
    let defaultId = modelOverride ?? "gpt-5.5"
    let fallback = Model(
        id: defaultId,
        name: defaultId,
        api: "openai-completions",
        provider: "github-copilot",
        baseUrl: baseURLString,
        reasoning: false,
        input: [.text, .image],
        contextWindow: 200_000,
        maxTokens: 128_000
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
    await APIRegistry.shared.register(AnthropicProvider(defaultAPIKey: creds.access), scope: "anthropic")

    let modelId = modelOverride ?? "claude-opus-4-8"
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
        maxTokens: catalog?.maxTokens ?? 128_000
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
    await APIRegistry.shared.register(OpenAIResponsesProvider(defaultAPIKey: creds.access), scope: "openai")

    let modelId = modelOverride ?? "gpt-5.5"
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
        maxTokens: catalog?.maxTokens ?? 128_000
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
    await APIRegistry.shared.register(GoogleGeminiProvider(defaultAPIKey: creds.access), scope: "google")

    let modelId = modelOverride ?? "gemini-3.1-pro-preview"
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
        maxTokens: catalog?.maxTokens ?? 128_000
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
    await APIRegistry.shared.register(OpenAICompletionsProvider(defaultAPIKey: creds.access), scope: "openai-compatible")

    let model = Model(
        id: modelId,
        name: modelId,
        api: "openai-completions",
        provider: "openai-compatible",
        baseUrl: baseURL,
        reasoning: false,
        input: [.text],
        contextWindow: 131_072,
        maxTokens: 32_000
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

private func cliBearerHeaderValue(_ token: String) -> String {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: "Bearer ", options: [.anchored, .caseInsensitive]) != nil {
        return trimmed
    }
    return "Bearer \(trimmed)"
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
