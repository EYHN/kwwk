import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Canonical credential shape used by all OAuth providers. `expires` is Unix
/// time in milliseconds; `extras` holds provider-specific fields that must
/// round-trip through the store (e.g. a GitHub Copilot session token cache).
public struct OAuthCredentials: Codable, Sendable, Hashable {
    public var access: String
    public var refresh: String
    /// Unix ms of access-token expiry.
    public var expires: Int64
    public var extras: [String: JSONValue]

    public init(
        access: String,
        refresh: String,
        expires: Int64,
        extras: [String: JSONValue] = [:]
    ) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.extras = extras
    }

    public var isExpired: Bool {
        Int64(Date().timeIntervalSince1970 * 1000) >= expires
    }
}

/// A single OAuth provider's refresh flow. `login()` (device flow + local
/// callback server) is intentionally NOT in this protocol — it requires
/// browser + HTTP server integration that's out of scope for kw's runtime.
/// Callers obtain initial credentials elsewhere (e.g. via pi's CLI or by
/// hand) and drop them in the `OAuthStore`. We handle the refresh path.
public protocol OAuthProvider: Sendable {
    /// Stable identifier used as the store key: `"anthropic"`,
    /// `"github-copilot"`, etc.
    var id: String { get }
    var name: String { get }

    /// Exchange the refresh token for a fresh access token. Returns updated
    /// credentials for the caller to persist.
    func refresh(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials

    /// Convert credentials to the api-key string the provider expects. For
    /// most vendors this is just `credentials.access`; GitHub Copilot
    /// exchanges it for a short-lived session token on every call.
    func apiKey(from credentials: OAuthCredentials, using client: HTTPClient) async throws -> String
}

extension OAuthProvider {
    public func apiKey(
        from credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> String {
        credentials.access
    }
}

public enum OAuthError: Error, LocalizedError {
    case missing(providerId: String)
    case unknownProvider(String)
    case transport(String)
    case invalidResponse(String)
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let id): return "no OAuth credentials stored for '\(id)'"
        case .unknownProvider(let id): return "unknown OAuth provider '\(id)'"
        case .transport(let text): return "OAuth transport error: \(text)"
        case .invalidResponse(let text): return "OAuth invalid response: \(text)"
        case .refreshFailed(let text): return "OAuth refresh failed: \(text)"
        }
    }
}

// MARK: - Credential store

/// Persists credentials on disk. Default location is `~/.kwwk/oauth.json` —
/// compatible with pi's `~/.pi/agent/oauth.json` schema so users can migrate
/// by copying the file across.
public actor OAuthStore {
    public let url: URL
    private var credentials: [String: OAuthCredentials]

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let home: URL = {
                #if targetEnvironment(macCatalyst) || os(iOS)
                return URL(fileURLWithPath: NSHomeDirectory())
                #else
                return FileManager.default.homeDirectoryForCurrentUser
                #endif
            }()
            self.url = home.appendingPathComponent(".kwwk").appendingPathComponent("oauth.json")
        }
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode([String: OAuthCredentials].self, from: data) {
            self.credentials = decoded
        } else {
            self.credentials = [:]
        }
    }

    public func all() -> [String: OAuthCredentials] { credentials }
    public func get(_ providerId: String) -> OAuthCredentials? { credentials[providerId] }

    public func set(_ credentials: OAuthCredentials, for providerId: String) throws {
        self.credentials[providerId] = credentials
        try persist()
    }

    /// Replace the entire store with a single provider's credentials. Used by
    /// `kwwk login` to enforce a single active provider — logging in with a
    /// new provider drops any previously-saved ones in one atomic write.
    public func setExclusive(_ credentials: OAuthCredentials, for providerId: String) throws {
        self.credentials = [providerId: credentials]
        try persist()
    }

    public func remove(_ providerId: String) throws {
        credentials.removeValue(forKey: providerId)
        try persist()
    }

    private func persist() throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(credentials)
        try data.write(to: url, options: .atomic)
        // Best-effort lockdown: 0600 since the file carries refresh tokens.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Manager

/// Refresh-on-demand front end. Wrap an `OAuthStore` with a set of
/// `OAuthProvider`s. Call `apiKey(for:)` (or the `resolver()` closure) to
/// fetch a fresh api-key — `OAuthManager` checks `.isExpired`, refreshes, and
/// persists new credentials automatically.
public actor OAuthManager {
    public let store: OAuthStore
    public let client: HTTPClient
    private var providers: [String: OAuthProvider]

    public init(
        store: OAuthStore = OAuthStore(),
        providers: [OAuthProvider] = OAuthManager.defaultProviders(),
        client: HTTPClient = URLSessionHTTPClient()
    ) {
        self.store = store
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.client = client
    }

    public static func defaultProviders() -> [OAuthProvider] {
        [
            AnthropicOAuthProvider(),
            GoogleOAuthProvider.geminiCli(),
            GoogleOAuthProvider.antigravity(),
            OpenAICodexOAuthProvider(),
            GitHubCopilotOAuthProvider(),
        ]
    }

    public func register(_ provider: OAuthProvider) {
        providers[provider.id] = provider
    }

    /// Get a valid api-key for `providerId`, refreshing if the stored token
    /// is expired. Throws `OAuthError.missing` if no credentials are stored.
    public func apiKey(for providerId: String) async throws -> String {
        guard let provider = providers[providerId] else {
            throw OAuthError.unknownProvider(providerId)
        }
        guard var credentials = await store.get(providerId) else {
            throw OAuthError.missing(providerId: providerId)
        }
        if credentials.isExpired {
            credentials = try await provider.refresh(credentials, using: client)
            try await store.set(credentials, for: providerId)
        }
        return try await provider.apiKey(from: credentials, using: client)
    }

    /// Build an auth resolver closure. The resolver receives the active model;
    /// we map common provider ids to our OAuth ids and return a bearer token.
    public nonisolated func resolver() -> @Sendable (Model, String?) async -> ResolvedProviderAuth? {
        let manager = self
        return { model, _ in
            let oauthId = Self.oauthId(forProvider: model.provider)
            return try? await manager.resolvedAuth(for: oauthId)
        }
    }

    private func resolvedAuth(for providerId: String) async throws -> ResolvedProviderAuth {
        let token = try await apiKey(for: providerId)
        let credentials = await store.get(providerId)
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
        case "google-gemini-cli": return "google-gemini-cli"
        case "google-antigravity": return "google-antigravity"
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
