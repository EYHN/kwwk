import Foundation

// Stored-credential provider registration: turn the credentials an
// `OAuthManager` can read (the `~/.kwwk/oauth.json` shape, whether they come
// from that file or from an external `OAuthCredentialSource`) into live,
// request-ready providers on `APIRegistry.shared`. Shared by the kwwk CLI's
// launch/login paths and by library consumers that hold credentials elsewhere
// (e.g. a backend serving per-tenant BYOK tokens). Pure library code: no
// terminal output — diagnostics go through the `notice` callbacks.
//
// Every entry point comes in two shapes: one taking an `OAuthManager` (the
// general form — works over any source, with that manager's refresh policy)
// and one taking a bare `OAuthStore`, which is the file-backed convenience
// wrapper the CLI uses.

/// Result of resolving which LLM + credentials to use for this session.
/// The provider has already been registered on `APIRegistry.shared`.
public struct ResolvedAuth: Sendable {
    public let model: Model
    public let modelLabel: String
    /// For OAuth-backed providers (Codex, Anthropic OAuth, ...), an
    /// `authResolver` that calls back into `OAuthManager.apiKey(for:)` so
    /// tokens refresh on demand. Nil for static api-key providers.
    public let authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    /// Every provider registered this session, so the CLI's `/model` can list
    /// + switch across all logged-in accounts. Single-login / env auth yields
    /// one slot.
    public let providerSlots: [ProviderSlot]
    /// The mutable resolver map the agent's `authResolver` delegates to, so
    /// `/login` can add a provider mid-session. Nil for the single-provider
    /// helper paths that don't own one.
    public let authResolvers: SessionAuthResolvers?

    public init(
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

public enum AuthResolveError: Error, LocalizedError {
    case noCredentials
    case unsupportedProvider(String)

    public var errorDescription: String? {
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
            Stored credentials for '\(id)' are not yet wired up. Launch
            `kwwk` and run `/login` to pick a different provider.
            """
        }
    }
}

/// One logged-in provider's session-scoped routing template. The CLI's
/// `/model` uses `template` to stamp correct wire routing (api / provider
/// scope / baseURL / headers) onto any catalog model the user switches to,
/// and lists that provider's catalog under `catalogProvider` / `displayName`.
public struct ProviderSlot: Sendable {
    /// The OAuth-store key this provider was logged in under
    /// (`anthropic`, `openai-codex`, `github-copilot`, `anthropic-api-key`, …),
    /// or a synthetic `env:<provider>` marker for environment-key auth.
    public let storeId: String
    /// The `ModelsCatalog.byProvider` key whose models this slot lists.
    public let catalogProvider: String
    /// Human label shown as the group header in the `/model` picker.
    public let displayName: String
    /// The default model built at registration time — carries the resolved
    /// wire `api`, provider scope, session `baseURL`, and headers that every
    /// model under this provider must route through.
    public let template: Model

    public init(
        storeId: String,
        catalogProvider: String,
        displayName: String,
        template: Model
    ) {
        self.storeId = storeId
        self.catalogProvider = catalogProvider
        self.displayName = displayName
        self.template = template
    }
}

/// Thread-safe, mutable map of per-provider auth resolvers keyed by
/// `model.provider` scope. The agent holds one **stable** closure
/// (`delegatingResolver()`) that reads through here, so `/login` can install a
/// newly-authenticated provider's resolver mid-session and its tokens resolve
/// on the next request — no agent rebuild. Static api-key providers have no
/// entry; `resolve` returns nil and the provider falls back to its baked key.
public actor SessionAuthResolvers {
    private var map: [String: @Sendable (Model, String?) async throws -> ResolvedProviderAuth?]

    public init(_ initial: [String: @Sendable (Model, String?) async throws -> ResolvedProviderAuth?] = [:]) {
        self.map = initial
    }

    public func set(scope: String, _ resolver: @escaping @Sendable (Model, String?) async throws -> ResolvedProviderAuth?) {
        map[scope] = resolver
    }

    public func remove(scope: String) {
        map.removeValue(forKey: scope)
    }

    public func resolve(_ model: Model, _ sessionId: String?) async throws -> ResolvedProviderAuth? {
        guard let r = map[model.provider] else { return nil }
        return try await r(model, sessionId)
    }

    /// One stable delegating closure to hand the agent. It closes over this
    /// actor, so later `set` / `remove` calls are visible without swapping the
    /// agent's `authResolver`.
    public nonisolated func delegatingResolver() -> @Sendable (Model, String?) async throws -> ResolvedProviderAuth? {
        { model, sid in try await self.resolve(model, sid) }
    }
}

/// Register **every** provider `manager` holds credentials for on
/// `APIRegistry.shared` (each scoped by its `model.provider` so same-wire
/// providers don't clobber each other), and return a `ResolvedAuth` whose
/// model is the *active* provider's default and whose `authResolver` is a
/// **unified** closure that dispatches by `model.provider` across all
/// logged-in accounts. The CLI's `/model` can then switch to any registered
/// provider's models mid-session and requests route to the right credentials.
///
/// Active-provider selection:
///   - `modelOverride` of the form `provider/id` activates that provider (if
///     logged in) with model `id`.
///   - Otherwise the highest-priority logged-in provider is active, and a bare
///     `modelOverride` names its model.
///
/// Throws `AuthResolveError.noCredentials` when the manager's source holds
/// nothing (or no entry could be registered). Skipped entries — same-scope
/// dual logins, unwired ids — are reported through `notice`.
public func registerAllStored(
    manager: OAuthManager,
    modelOverride: String? = nil,
    context1m: Bool = false,
    notice: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> ResolvedAuth {
    let order = await storedProviderOrder(ids: manager.providerIds())

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
        let scope = modelProviderScope(forStoreId: storeId)
        if seenScopes.contains(scope) {
            notice("'\(storeId)' shares the '\(scope)' provider slot with an already-registered login; skipping.")
            continue
        }
        let mo = storeId == activeStoreId ? activeModelId : nil
        // Only the active provider primes its OAuth token at startup — the
        // others register their scoped provider + resolver + slot and refresh
        // lazily on first use (a `/model` switch). Priming every stored login
        // fired an OAuth refresh/exchange network round-trip per account on
        // every launch, for accounts the session may never touch.
        guard let resolved = try await registerStored(
            storeId: storeId, manager: manager, modelOverride: mo, context1m: context1m,
            primeToken: storeId == activeStoreId,
            notice: notice
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

/// File-store convenience wrapper: register everything in `store` through a
/// refresh-on-demand `OAuthManager`. What the CLI calls at launch.
public func registerAllStored(
    store: OAuthStore,
    modelOverride: String? = nil,
    context1m: Bool = false,
    notice: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> ResolvedAuth {
    try await registerAllStored(
        manager: OAuthManager(store: store),
        modelOverride: modelOverride, context1m: context1m, notice: notice
    )
}

/// Register one stored provider on `APIRegistry.shared` (scoped by its
/// `model.provider`) and return its `ResolvedAuth` (default model + optional
/// per-provider resolver). Shared by launch-time `registerAllStored` and the
/// CLI's in-session `/login` path. Returns nil for unwired store ids or
/// missing credentials (reporting a `notice` for the former).
public func registerStored(
    storeId: String,
    manager: OAuthManager,
    modelOverride: String? = nil,
    context1m: Bool = false,
    // When false, skip the eager OAuth token refresh/exchange network call at
    // registration and read any needed endpoint/account claims from the stored
    // credentials instead. The provider's resolver still refreshes on demand at
    // first request. Passed false for non-active providers at startup.
    primeToken: Bool = true,
    notice: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> ResolvedAuth? {
    guard let creds = try await manager.credentials(for: storeId) else { return nil }
    switch storeId {
    case "openai-codex":
        return await registerCodex(manager: manager, creds: creds, modelOverride: modelOverride, primeToken: primeToken)
    case "anthropic":
        return await registerAnthropicOAuth(
            manager: manager, creds: creds, modelOverride: modelOverride, context1m: context1m, primeToken: primeToken
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
        return await registerGitHubCopilot(manager: manager, creds: creds, modelOverride: modelOverride, primeToken: primeToken)
    case "cursor":
        return await registerCursor(manager: manager, creds: creds, modelOverride: modelOverride, primeToken: primeToken)
    case "kimi-coding":
        return await registerKimiCoding(manager: manager, creds: creds, modelOverride: modelOverride, primeToken: primeToken)
    case "zai", "zai-coding-cn":
        return await registerZai(storeId: storeId, creds: creds, modelOverride: modelOverride)
    default:
        notice("stored credentials for '\(storeId)' aren't wired up; skipping.")
        return nil
    }
}

/// File-store convenience wrapper for `registerStored(storeId:manager:…)`.
public func registerStored(
    storeId: String,
    store: OAuthStore,
    modelOverride: String? = nil,
    context1m: Bool = false,
    primeToken: Bool = true,
    notice: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> ResolvedAuth? {
    try await registerStored(
        storeId: storeId, manager: OAuthManager(store: store),
        modelOverride: modelOverride, context1m: context1m,
        primeToken: primeToken, notice: notice
    )
}

// MARK: - Codex (OAuth)

private func registerCodex(
    manager: OAuthManager,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    // Grab a fresh token if expired. If the refresh fails we still register
    // the provider — the authResolver below will retry on the next request
    // and surface the error to the user there. When not priming, read the
    // stored `accountId` (persisted at login) and let the resolver refresh
    // lazily on first use.
    if primeToken {
        _ = try? await manager.apiKey(for: "openai-codex")
    }

    let refreshed = primeToken ? await primed(manager, "openai-codex", fallback: creds) : creds
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
    manager: OAuthManager,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    context1m: Bool = false,
    primeToken: Bool = true
) async -> ResolvedAuth {
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
    manager: OAuthManager,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
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
    let refreshed = primeToken ? await primed(manager, "github-copilot", fallback: creds) : creds

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
    manager: OAuthManager,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
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
    manager: OAuthManager,
    creds: OAuthCredentials,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    // Prime the token only for the active provider; the resolver refreshes
    // lazily on the first request for the others.
    if primeToken {
        _ = try? await manager.apiKey(for: "kimi-coding")
    }

    // Kimi's coding endpoint speaks anthropic-messages but authenticates with
    // a Bearer token instead of `x-api-key`. The resolver below supplies the
    // OAuth token per request; the header builder covers any static-key path.
    await APIRegistry.shared.register(AnthropicProvider(
        authHeaderBuilder: { key in ["Authorization": bearerHeaderValue(key)] }
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

/// Re-read `id` after priming, so the caller sees whatever claims the token
/// exchange just persisted (Copilot's proxy `endpoint`, Codex's `accountId`).
/// Falls back to the pre-prime credentials when the source has nothing to add
/// — priming is best-effort, and a consume-only source never changes here.
private func primed(
    _ manager: OAuthManager,
    _ id: String,
    fallback: OAuthCredentials
) async -> OAuthCredentials {
    (try? await manager.credentials(for: id)) ?? fallback
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
            // (refresh/exchange error, or a consume-only source serving an
            // expired token) propagates so the request surfaces it instead of
            // silently going out unauthenticated.
            return nil
        }
    }
}
