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
    let authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
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
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
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

            Launch `kwwk` and run `/login` to pick a provider (OAuth
            subscription or API key), or export a supported API-key
            environment variable (ANTHROPIC_API_KEY, OPENAI_API_KEY,
            GEMINI_API_KEY, OPENROUTER_API_KEY, ...).
            """
        case .unsupportedProvider(let id):
            return """
            Stored credentials for '\(id)' are not yet wired up in the
            kwwk CLI. Launch `kwwk` and run `/login` to pick a different
            provider.
            """
        }
    }
}

/// Sentinel `Model` a logged-out interactive session starts on (no stored
/// logins, no env keys). The empty `id` / `provider` match no catalog entry
/// and no `APIRegistry` scope; the TUI gates prompt submission and `/model`
/// while the session's provider-slot list is empty, so this model is never
/// sent to a provider. The first successful `/login` replaces it with the
/// fresh slot's template; `/logout` of the last provider restores it.
let loggedOutModel = Model(id: "", api: "", provider: "", contextWindow: 0, maxTokens: 0)

/// Prompt-box / status label for the logged-out state.
let loggedOutModelLabel = "no provider — /login to sign in"

/// Resolve credentials:
///   1. If `OAuthStore` holds any logins, register ALL of them via
///      `registerAllStored` (each scoped by `model.provider`) and build a
///      unified cross-provider resolver; same-scope dual logins are
///      de-duplicated by priority. The highest-priority (or `provider/model`
///      override's) provider is the active model.
///   2. Otherwise fall back to environment API keys (lowest priority).
///   3. Throw `noCredentials`.
///
/// Registers every resolved provider on `APIRegistry.shared` as a side effect
/// so the returned model — and any `/model` switch to another logged-in
/// provider — can be used immediately.
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
    let store = try OAuthStore(url: OAuthStore.defaultURL())
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
    // an interactive `/login`.
    if let env = await resolveEnvAuth(
        modelOverride: modelOverride,
        environment: ProcessInfo.processInfo.environment
    ) {
        // Give `/model` a single slot for the env provider so it can still
        // list that provider's catalog, and a resolver actor so a later
        // `/login` can add a stored provider mid-session.
        let slot = ProviderSlot(
            storeId: "env:\(env.model.provider)",
            catalogProvider: catalogProviderKey(forAgentProvider: env.model.provider),
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
        // Only the active provider primes its OAuth token at startup — the
        // others register their scoped provider + resolver + slot and refresh
        // lazily on first use (a `/model` switch). Priming every stored login
        // fired an OAuth refresh/exchange network round-trip per account on
        // every launch, for accounts the session may never touch.
        guard let resolved = try await registerStored(
            storeId: storeId, store: store, modelOverride: mo, context1m: context1m,
            primeToken: storeId == activeStoreId
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
    context1m: Bool,
    // When false, skip the eager OAuth token refresh/exchange network call at
    // registration and read any needed endpoint/account claims from the stored
    // credentials instead. The provider's resolver still refreshes on demand at
    // first request. Passed false for non-active providers at startup.
    primeToken: Bool = true
) async throws -> ResolvedAuth? {
    guard let creds = await store.get(storeId) else { return nil }
    switch storeId {
    case "openai-codex":
        return await registerCodex(store: store, creds: creds, modelOverride: modelOverride, primeToken: primeToken)
    case "anthropic":
        return await registerAnthropicOAuth(
            store: store, creds: creds, modelOverride: modelOverride, context1m: context1m, primeToken: primeToken
        )
    case "anthropic-api-key":
        return await registerAnthropicAPIKey(creds: creds, modelOverride: modelOverride)
    case "openai-api-key":
        return await registerOpenAIAPIKey(creds: creds, modelOverride: modelOverride)
    case "openai-compatible":
        return try await registerOpenAICompatible(creds: creds, modelOverride: modelOverride)
    case "google-api-key":
        return await registerGoogleAPIKey(creds: creds, modelOverride: modelOverride)
    case "openrouter":
        return await registerOpenRouter(creds: creds, modelOverride: modelOverride)
    case "github-copilot":
        return await registerGitHubCopilot(store: store, creds: creds, modelOverride: modelOverride, primeToken: primeToken)
    case "cursor":
        return await registerCursor(store: store, creds: creds, modelOverride: modelOverride, primeToken: primeToken)
    case "kimi-coding":
        return await registerKimiCoding(store: store, creds: creds, modelOverride: modelOverride, primeToken: primeToken)
    case "zai", "zai-coding-cn":
        return await registerZai(storeId: storeId, creds: creds, modelOverride: modelOverride)
    default:
        FileHandle.standardError.write(Data(
            "kwwk: stored credentials for '\(storeId)' aren't wired up; skipping.\n".utf8
        ))
        return nil
    }
}

/// Register a single freshly-logged-in provider mid-session: scoped provider
/// on `APIRegistry`, resolver into `authResolvers`, and a `ProviderSlot` for
/// `/model`. Returns nil if the provider isn't stored / wired up. `store`
/// defaults to the real `~/.kwwk/oauth.json`; tests inject a temp one.
@MainActor
func registerStoredProviderLive(
    storeId: String,
    authResolvers: SessionAuthResolvers,
    context1m: Bool = false,
    store: OAuthStore? = nil
) async -> ProviderSlot? {
    let resolvedStore: OAuthStore
    if let store { resolvedStore = store }
    else {
        guard let opened = try? OAuthStore(url: OAuthStore.defaultURL()) else { return nil }
        resolvedStore = opened
    }
    guard let resolved = try? await registerStored(
        storeId: storeId, store: resolvedStore, modelOverride: nil, context1m: context1m
    ) else { return nil }
    // Keep the scope's provider instance and its resolver consistent: an
    // OAuth provider installs a resolver; a static api-key provider has none
    // and must clear any stale resolver left under this scope, else the next
    // request would send a token through the wrong provider instance.
    if let r = resolved.authResolver {
        await authResolvers.set(scope: resolved.model.provider, r)
    } else {
        await authResolvers.remove(scope: resolved.model.provider)
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
        // Cursor rides its own agent wire (cursor-agent), not one of the flat
        // env-provider wire protocols, so register it explicitly from the env
        // access token.
        if provider == "cursor" {
            guard let token = EnvAPIKeys.apiKey(for: "cursor", env: environment), !token.isEmpty else { continue }
            return await registerCursorEnv(token: token, modelOverride: forcedId)
        }
        guard let key = EnvAPIKeys.apiKey(for: provider, env: environment), !key.isEmpty else { continue }
        guard let model = pickEnvModel(provider: provider, id: forcedId) else { continue }
        guard await registerEnvProviders(for: provider, apiKey: key) else { continue }
        let label = "\(model.id) · \(EnvAPIKeys.displayName(for: provider)) (env)"
        return ResolvedAuth(model: model, modelLabel: label, authResolver: nil)
    }
    return nil
}

/// Register Cursor from a `CURSOR_ACCESS_TOKEN` env var (static token, no
/// refresh — the token is used as-is until it expires).
private func registerCursorEnv(token: String, modelOverride: String?) async -> ResolvedAuth {
    await APIRegistry.shared.register(CursorAgentProvider(defaultAPIKey: token), scope: "cursor")
    let modelId = modelOverride ?? "default"
    let catalog = ModelsCatalog.model(provider: "cursor", id: modelId)
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "cursor-agent",
        provider: "cursor",
        baseURL: "https://api2.cursor.sh",
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text],
        contextWindow: catalog?.contextWindow ?? 200_000,
        maxTokens: catalog?.maxTokens ?? 64_000
    )
    return ResolvedAuth(model: model, modelLabel: "\(modelId) · Cursor (env)", authResolver: nil)
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
        baseURL: azure.baseURL, reasoning: catalog?.reasoning ?? true,
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
    // (e.g. anthropic) wire whose baseURL doesn't match the openai-compat gateway
    // endpoint, so we ignore the catalog there and use the compat fallback base.
    let catalog = gateway ? nil : ModelsCatalog.model(provider: providerId, id: modelId)
    let model = Model(
        id: modelId, name: catalog?.name ?? modelId,
        api: providerId, provider: providerId,
        baseURL: catalog?.baseURL ?? fallbackBase, reasoning: catalog?.reasoning ?? false,
        input: catalog?.input ?? [.text],
        contextWindow: catalog?.contextWindow ?? 128_000, maxTokens: catalog?.maxTokens ?? 16_384,
        compat: catalog?.compat, thinkingLevelMap: catalog?.thinkingLevelMap
    )
    let label = gateway ? "Cloudflare AI Gateway" : "Cloudflare Workers AI"
    return ResolvedAuth(model: model, modelLabel: "\(modelId) · \(label) (env)", authResolver: nil)
}

/// Derive the AWS region for a Bedrock model from its catalog baseURL host
/// (`bedrock-runtime.<region>.amazonaws.com`), falling back to AWS_REGION /
/// us-east-1. Keeps EU/APAC-hosted models from being misrouted to us-east-1.
private func bedrockRegion(for model: Model, environment: [String: String]) -> String {
    if let host = URL(string: model.baseURL)?.host {
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
        // provider's wire api/baseURL from any sibling model.
        if let sibling = models.first {
            return Model(
                id: id, name: id, api: sibling.api, provider: provider,
                baseURL: sibling.baseURL, reasoning: sibling.reasoning,
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
    // Tag each flat env registration with its vendor so a model whose
    // `provider` differs can never fall back onto this vendor's key.
    switch api {
    case "openai-completions":
        await APIRegistry.shared.register(OpenAICompletionsProvider(defaultAPIKey: apiKey), providerVendor: provider)
        return true
    case "openai-responses":
        await APIRegistry.shared.register(OpenAIResponsesProvider(defaultAPIKey: apiKey), providerVendor: provider)
        return true
    case "google-generative-ai":
        await APIRegistry.shared.register(GoogleGeminiProvider(defaultAPIKey: apiKey), providerVendor: provider)
        return true
    case "mistral-conversations":
        await APIRegistry.shared.register(MistralConversationsProvider(defaultAPIKey: apiKey), providerVendor: provider)
        return true
    case "anthropic-messages":
        if provider == "anthropic" {
            await APIRegistry.shared.register(AnthropicProvider(defaultAPIKey: apiKey), providerVendor: provider)
        } else {
            await APIRegistry.shared.register(AnthropicProvider(
                defaultAPIKey: apiKey,
                authHeaderBuilder: { key in ["Authorization": cliBearerHeaderValue(key)] }
            ), providerVendor: provider)
        }
        return true
    default:
        return false
    }
}

// MARK: - Codex (OAuth)

private func registerCodex(
    store: OAuthStore,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    // Grab a fresh token if expired. If the refresh fails we still register
    // the provider — the authResolver below will retry on the next request
    // and surface the error to the user there. When not priming, read the
    // stored `accountId` (persisted at login) and let the resolver refresh
    // lazily on first use.
    if primeToken {
        _ = try? await manager.apiKey(for: "openai-codex")
    }

    let refreshed = primeToken ? (await store.get("openai-codex") ?? creds) : creds
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
        baseURL: "https://chatgpt.com",
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
    context1m: Bool = false,
    primeToken: Bool = true
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    // Prime the token only for the active provider; otherwise the resolver
    // refreshes lazily on the first request.
    if primeToken {
        _ = try? await manager.apiKey(for: "anthropic")
    }

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
    let catalogContext = catalog?.contextWindow ?? 200_000
    let contextWindow = context1m ? 1_000_000 : min(catalogContext, 200_000)
    // Claude Code's OAuth wire requests at most 64k output tokens. Keep the
    // route-specific model metadata aligned with that cap so context preflight
    // reserves exactly what the provider request will claim.
    let catalogMaxTokens = catalog?.maxTokens ?? 128_000
    let routeMaxTokens = AnthropicProvider.claudeCodeMaximumOutputTokens
    let maxTokens = catalogMaxTokens > 0
        ? min(catalogMaxTokens, routeMaxTokens)
        : routeMaxTokens
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "anthropic-messages",
        provider: "anthropic",
        baseURL: "https://api.anthropic.com",
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text, .image],
        contextWindow: contextWindow,
        maxTokens: maxTokens
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
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    // Prime the session token — Copilot's `refresh` is actually a PAT →
    // session-token exchange that must happen before the proxy will route.
    // We ignore the returned token; the resolver below re-fetches on demand
    // (`OAuthManager` caches until `expires_at` so we don't round-trip
    // every request). The refresh also persists the proxy endpoint into
    // `extras["endpoint"]`, which we read below. For a non-active provider we
    // skip the eager exchange and read the endpoint the previous session's
    // login already persisted; the resolver primes it on first use.
    if primeToken {
        _ = try? await manager.apiKey(for: "github-copilot")
    }
    let refreshed = primeToken ? (await store.get("github-copilot") ?? creds) : creds

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
    // openai-completions, GPT-5 family uses openai-responses. All register
    // under scope "github-copilot", so they live in the provider-scoped map
    // and COEXIST with (rather than replace) the direct-API anthropic/openai
    // providers — dispatch prefers the scoped instance only for models whose
    // `provider == "github-copilot"`, falling back to the flat map otherwise.
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
        baseURL: baseURLString,
        reasoning: false,
        input: [.text, .image],
        contextWindow: 200_000,
        maxTokens: 128_000
    )
    // Use catalog model for wire-format api + capabilities, but stamp
    // the session's resolved `baseURL` on it — catalog entries hardcode
    // `api.individual.githubcopilot.com` which would bypass the
    // Business/Enterprise proxy. `adoptFields` preserves this session
    // baseURL across `/model` switches, so every Copilot model routes
    // through the right host.
    let model: Model = {
        guard let catalog = ModelsCatalog.model(provider: "github-copilot", id: defaultId)
        else { return fallback }
        return Model(
            id: catalog.id,
            name: catalog.name,
            api: catalog.api,
            provider: catalog.provider,
            baseURL: baseURLString,
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

// MARK: - Cursor (OAuth subscription)

private func registerCursor(
    store: OAuthStore,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    // Prime the token only for the active provider; the resolver refreshes
    // lazily on the first request for the others. Cursor's `refresh` exchanges
    // the stored refresh token for a fresh short-lived JWT access token.
    if primeToken {
        _ = try? await manager.apiKey(for: "cursor")
    }

    await APIRegistry.shared.register(CursorAgentProvider(), scope: "cursor")

    let modelId = modelOverride ?? "default"
    let catalog = ModelsCatalog.model(provider: "cursor", id: modelId)
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "cursor-agent",
        provider: "cursor",
        baseURL: "https://api2.cursor.sh",
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text],
        contextWindow: catalog?.contextWindow ?? 200_000,
        maxTokens: catalog?.maxTokens ?? 64_000
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · Cursor",
        authResolver: oauthResolver(manager: manager, providerId: "cursor", scheme: .bearer)
    )
}

// MARK: - Kimi For Coding (OAuth device flow)

private func registerKimiCoding(
    store: OAuthStore,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    // Prime the token only for the active provider; the resolver refreshes
    // lazily on the first request for the others.
    if primeToken {
        _ = try? await manager.apiKey(for: "kimi-coding")
    }

    // Kimi's coding endpoint speaks anthropic-messages but authenticates with
    // a Bearer token instead of `x-api-key`. The resolver below supplies the
    // OAuth token per request; the header builder covers any static-key path.
    await APIRegistry.shared.register(AnthropicProvider(
        authHeaderBuilder: { key in ["Authorization": cliBearerHeaderValue(key)] }
    ), scope: "kimi-coding")

    let modelId = modelOverride ?? "kimi-for-coding"
    let catalog = ModelsCatalog.model(provider: "kimi-coding", id: modelId)
    // Uncatalogued ids still need the thinking wire shape every bundled
    // kimi-coding model pins (adaptive thinking, unsigned thinking blocks).
    let fallbackCompat: ModelCompat = {
        var c = ModelCompat()
        c.allowEmptySignature = true
        c.forceAdaptiveThinking = true
        return c
    }()
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "anthropic-messages",
        provider: "kimi-coding",
        baseURL: catalog?.baseURL ?? "https://api.kimi.com/coding",
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text, .image],
        cost: catalog?.cost ?? ModelCost(),
        contextWindow: catalog?.contextWindow ?? 262_144,
        maxTokens: catalog?.maxTokens ?? 32_768,
        // Uncatalogued ids still need the KimiCLI agent string the coding
        // endpoint expects.
        headers: catalog?.headers ?? ["User-Agent": "KimiCLI/1.5"],
        compat: catalog?.compat ?? fallbackCompat,
        thinkingLevelMap: catalog?.thinkingLevelMap
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · Kimi For Coding",
        authResolver: oauthResolver(manager: manager, providerId: "kimi-coding", scheme: .bearer)
    )
}

// MARK: - Z.AI GLM Coding Plan (login form)

private func registerZai(
    storeId: String,
    creds: OAuthCredentials,
    modelOverride: String? = nil
) async -> ResolvedAuth {
    await APIRegistry.shared.register(
        OpenAICompletionsProvider(defaultAPIKey: creds.access),
        scope: storeId
    )

    let fallbackBase = storeId == "zai-coding-cn"
        ? "https://open.bigmodel.cn/api/coding/paas/v4"
        : "https://api.z.ai/api/coding/paas/v4"
    let modelId = modelOverride ?? "glm-5.2"
    let catalog = ModelsCatalog.model(provider: storeId, id: modelId)
    // Uncatalogued ids still route with the Z.AI thinking format so reasoning
    // deltas keep parsing.
    let fallbackCompat: ModelCompat = {
        var c = ModelCompat()
        c.thinkingFormat = "zai"
        c.zaiToolStream = true
        return c
    }()
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "openai-completions",
        provider: storeId,
        baseURL: catalog?.baseURL ?? fallbackBase,
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text],
        cost: catalog?.cost ?? ModelCost(),
        contextWindow: catalog?.contextWindow ?? 204_800,
        maxTokens: catalog?.maxTokens ?? 131_072,
        headers: catalog?.headers,
        compat: catalog?.compat ?? fallbackCompat,
        thinkingLevelMap: catalog?.thinkingLevelMap
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · \(providerDisplayName(forStoreId: storeId))",
        authResolver: nil
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
        baseURL: baseURL,
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
        baseURL: baseURL,
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
        // itself (and tolerates a baseURL that already includes it, which
        // is what catalog models carry).
        baseURL: baseURL,
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

// MARK: - OpenRouter (login form)

private func registerOpenRouter(
    creds: OAuthCredentials,
    modelOverride: String? = nil
) async -> ResolvedAuth {
    await APIRegistry.shared.register(
        OpenAICompletionsProvider(defaultAPIKey: creds.access),
        scope: "openrouter"
    )

    let modelId = modelOverride
        ?? stringExtra(creds, "defaultModel")
        ?? "anthropic/claude-sonnet-5"
    let catalog = ModelsCatalog.model(provider: "openrouter", id: modelId)
    // Uncatalogued ids still route — OpenRouter fronts far more models than
    // the bundled catalog. The fallback compat keeps reasoning deltas parsing
    // via the OpenRouter thinking format.
    let fallbackCompat: ModelCompat = {
        var c = ModelCompat()
        c.thinkingFormat = "openrouter"
        return c
    }()
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: "openai-completions",
        provider: "openrouter",
        baseURL: catalog?.baseURL ?? "https://openrouter.ai/api/v1",
        reasoning: catalog?.reasoning ?? true,
        input: catalog?.input ?? [.text],
        cost: catalog?.cost ?? ModelCost(),
        contextWindow: catalog?.contextWindow ?? 131_072,
        maxTokens: catalog?.maxTokens ?? 32_000,
        headers: catalog?.headers,
        compat: catalog?.compat ?? fallbackCompat,
        thinkingLevelMap: catalog?.thinkingLevelMap
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · OpenRouter",
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
        baseURL: baseURL,
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
) -> @Sendable (Model, String?) async throws -> ResolvedProviderAuth? {
    { _, _ in
        do {
            let token = try await manager.apiKey(for: providerId)
            return ResolvedProviderAuth(token: token, scheme: scheme, baseURL: baseURL)
        } catch OAuthError.missing, OAuthError.unknownProvider {
            // Not logged in for this provider ⇒ anonymous. Any other failure
            // (refresh/exchange error) propagates so the request surfaces it
            // instead of silently going out unauthenticated.
            return nil
        }
    }
}
