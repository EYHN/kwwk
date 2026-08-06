import Foundation
import KWWKAI

// The store-backed registration layer (`registerAllStored` / `registerStored`,
// `ResolvedAuth`, `ProviderSlot`, `SessionAuthResolvers`, and the provider
// directory) lives in `KWWKAI` so non-CLI hosts can drive it too. This file
// keeps the CLI-specific pieces: the default `~/.kwwk` store path, terminal
// notices, and the environment-variable fallback.

/// Sentinel `Model` a logged-out interactive session starts on (no stored
/// logins, no env keys). The empty `id` / `provider` match no catalog entry
/// and no `APIRegistry` scope; the TUI gates prompt submission and `/model`
/// while the session's provider-slot list is empty, so this model is never
/// sent to a provider. The first successful `/login` replaces it with the
/// fresh slot's template; `/logout` of the last provider restores it.
let loggedOutModel = Model(id: "", api: "", provider: "", contextWindow: 0, maxTokens: 0)

/// Prompt-box / status label for the logged-out state.
let loggedOutModelLabel = "no provider — /login to sign in"

/// Library notices ("provider slot already taken", "not wired up") land on
/// stderr with the CLI's usual prefix.
let cliAuthNotice: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("kwwk: \(message)\n".utf8))
}

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
            store: store,
            modelOverride: modelOverride, context1m: context1m,
            notice: cliAuthNotice
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
        storeId: storeId, store: resolvedStore, modelOverride: nil, context1m: context1m,
        notice: cliAuthNotice
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

private func cliBearerHeaderValue(_ token: String) -> String {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: "Bearer ", options: [.anchored, .caseInsensitive]) != nil {
        return trimmed
    }
    return "Bearer \(trimmed)"
}
