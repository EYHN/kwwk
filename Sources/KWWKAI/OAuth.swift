import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Manager

/// Refresh-on-demand front end. Wrap a credential source with a set of
/// `OAuthProvider`s. Call `apiKey(for:)` (or the `resolver()` closure) to
/// fetch a fresh api-key — `OAuthManager` checks `.isExpired`, refreshes
/// entries that carry a refresh token, and persists new credentials to the
/// store when the source is one.
///
/// There is deliberately no refresh-policy switch: the credentials decide.
/// An entry whose `refresh` is empty is unrefreshable, so expiry is an error
/// (`OAuthError.expired`) — which is exactly how an external authority keeps
/// refresh to itself: serve access tokens with `refresh: ""`.
public actor OAuthManager {
    /// The writable store when the source is one — the store-backed init sets
    /// it, and refreshed credentials persist there. A plain `init(source:)`
    /// has nowhere durable to write; see `refreshedOverlay`.
    public let store: OAuthStore?
    /// Where credentials are read from. Same object as `store` for the
    /// store-backed init.
    public let source: any OAuthCredentialSource
    public let client: HTTPClient
    private var providers: [String: OAuthProvider]
    /// In-flight refresh per provider id. Concurrent `apiKey(for:)` callers
    /// await the same task instead of each launching their own refresh with
    /// the same (rotated-on-use) refresh token.
    private var inFlightRefresh: [String: Task<OAuthCredentials, Error>] = [:]
    /// Rotations with nowhere durable to go. When a store-less source serves
    /// a refresh-bearing entry and it expires, the provider rotation must not
    /// be lost — re-running it with the consumed refresh token would kill the
    /// login on rotating providers. Each overlay entry remembers the exact
    /// credentials it was refreshed *from*: while the source still serves
    /// those, reads see the rotation; the moment the source serves anything
    /// else (a new login, its own newer tokens), the overlay yields.
    private var refreshedOverlay: [String: (base: OAuthCredentials, result: OAuthCredentials)] = [:]

    public init(
        store: OAuthStore = OAuthStore(),
        providers: [OAuthProvider] = OAuthManager.defaultProviders(),
        client: HTTPClient = URLSessionHTTPClient()
    ) {
        self.store = store
        self.source = store
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.client = client
    }

    /// Manager over an external credential source. Behavior follows the data
    /// the source serves: refresh-less entries are consumed as-is and expiry
    /// is the source's fault; refresh-bearing entries refresh normally, with
    /// the rotation held in this actor's memory (the source stays the
    /// authority — a changed entry from it drops the held rotation).
    public init(
        source: any OAuthCredentialSource,
        providers: [OAuthProvider] = OAuthManager.defaultProviders(),
        client: HTTPClient = URLSessionHTTPClient()
    ) {
        self.store = nil
        self.source = source
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.client = client
    }

    public static func defaultProviders() -> [OAuthProvider] {
        [
            AnthropicOAuthProvider(),
            OpenAICodexOAuthProvider(),
            GitHubCopilotOAuthProvider(),
            CursorOAuthProvider(),
            DevinOAuthProvider(),
            KimiCodingOAuthProvider(),
            XaiOAuthProvider(),
        ]
    }

    public func register(_ provider: OAuthProvider) {
        providers[provider.id] = provider
    }

    /// Ids the backing source holds credentials for, and the credentials
    /// themselves. Registration code reads through these so it works the same
    /// over a file store and over an external authority.
    public func providerIds() async -> [String] {
        await source.providerIds()
    }

    public func credentials(for providerId: String) async throws -> OAuthCredentials? {
        let served: OAuthCredentials?
        do {
            served = try await source.credentials(for: providerId)
        } catch let error as OAuthCredentialSourceError {
            throw error
        } catch {
            // The source's refusal cannot be retried away (see
            // `OAuthCredentialSourceError`). Wrapped here so every read
            // path — apiKey, priming, registration — reports it uniformly.
            throw OAuthCredentialSourceError(providerId: providerId, underlying: error)
        }
        // A held rotation stands in for exactly the entry it rotated; any
        // other answer from the source supersedes it (see `reconciled`).
        return reconciled(served, for: providerId)
    }

    /// Get a valid api-key for `providerId`, refreshing if the stored token
    /// is expired and refreshable. Throws `OAuthError.missing` if no
    /// credentials are stored, and `OAuthError.expired` for a stale entry
    /// with no refresh token — that entry's authority failed to serve a
    /// fresh one.
    public func apiKey(for providerId: String) async throws -> String {
        guard let provider = providers[providerId] else {
            throw OAuthError.unknownProvider(providerId)
        }
        guard var credentials = try await credentials(for: providerId) else {
            throw OAuthError.missing(providerId: providerId)
        }
        if credentials.isExpired {
            guard !credentials.refresh.isEmpty else {
                throw OAuthError.expired(providerId: providerId)
            }
            credentials = try await refresh(providerId, provider: provider, stale: credentials)
        }
        return try await provider.apiKey(from: credentials, using: client)
    }

    /// Refresh (or join an in-flight refresh for) `providerId`. The first
    /// caller starts the task and records it; concurrent callers await the
    /// same task. The task re-reads the credentials on entry so a refresh
    /// that landed while we were suspended is reused instead of re-run.
    private func refresh(
        _ providerId: String,
        provider: OAuthProvider,
        stale: OAuthCredentials
    ) async throws -> OAuthCredentials {
        if let existing = inFlightRefresh[providerId] {
            return try await existing.value
        }
        let client = self.client
        let task = Task<OAuthCredentials, Error> { [store] in
            // Re-read the raw source answer: the overlay key must be what the
            // source serves, or the next read would mistake the source's
            // unchanged entry for a new login and drop the held rotation —
            // then re-refresh with a consumed refresh token.
            let served = try await self.source.credentials(for: providerId)
            let current = await self.reconciled(served, for: providerId) ?? stale
            if !current.isExpired { return current }
            let refreshed = try await provider.refresh(current, using: client)
            if let store {
                try await store.set(refreshed, for: providerId)
            } else {
                await self.holdRotation(refreshed, from: served ?? stale, for: providerId)
            }
            return refreshed
        }
        inFlightRefresh[providerId] = task
        defer { inFlightRefresh[providerId] = nil }
        return try await task.value
    }

    /// The credentials in effect for a raw source answer: the held rotation
    /// while the source still serves the entry it rotated, the source's
    /// answer otherwise (dropping any superseded rotation).
    private func reconciled(
        _ served: OAuthCredentials?, for providerId: String
    ) -> OAuthCredentials? {
        guard let served else {
            refreshedOverlay[providerId] = nil
            return nil
        }
        if let overlay = refreshedOverlay[providerId] {
            if overlay.base == served { return overlay.result }
            refreshedOverlay[providerId] = nil
        }
        return served
    }

    private func holdRotation(
        _ refreshed: OAuthCredentials,
        from base: OAuthCredentials,
        for providerId: String
    ) {
        refreshedOverlay[providerId] = (base: base, result: refreshed)
    }

    /// Build an auth resolver closure. The resolver receives the active model;
    /// we map common provider ids to our OAuth ids and return a bearer token.
    public nonisolated func resolver() -> @Sendable (Model, String?) async throws -> ResolvedProviderAuth? {
        let manager = self
        return { model, _ in
            let oauthId = Self.oauthId(forProvider: model.provider)
            do {
                return try await manager.resolvedAuth(for: oauthId)
            } catch OAuthError.missing, OAuthError.unknownProvider {
                // No credentials stored for this provider ⇒ an anonymous
                // request is the correct outcome. A refresh/exchange failure
                // (any other error) propagates so the provider surfaces it
                // rather than silently sending an unauthenticated request.
                // `.expired` is one of those propagating errors on purpose: a
                // logged-in account whose source served a stale token is a
                // real fault, and reporting it as "not logged in" would hide
                // it behind a downstream 401.
                return nil
            }
        }
    }

    private func resolvedAuth(for providerId: String) async throws -> ResolvedProviderAuth {
        let token = try await apiKey(for: providerId)
        let credentials = try await source.credentials(for: providerId)
        return ResolvedProviderAuth(
            token: token,
            scheme: .bearer,
            baseURL: Self.baseURL(forOAuthId: providerId, credentials: credentials)
        )
    }

    private static func oauthId(forProvider provider: String) -> String {
        switch provider {
        case "anthropic": return "anthropic"
        case "github-copilot": return "github-copilot"
        case "openai-codex": return "openai-codex"
        case "cursor": return "cursor"
        default: return provider
        }
    }

    private static func baseURL(forOAuthId providerId: String, credentials: OAuthCredentials?) -> String? {
        guard providerId == "github-copilot",
              case .string(let endpoint) = credentials?.extras["endpoint"] ?? .null,
              !endpoint.isEmpty else {
            return nil
        }
        return endpoint
    }
}
