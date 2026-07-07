import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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

    /// Tolerate a missing `extras` key (hand-edited stores commonly omit
    /// it) — without this, one entry lacking `extras` fails the whole
    /// `[String: OAuthCredentials]` decode and silently drops every login.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access = try c.decode(String.self, forKey: .access)
        refresh = try c.decode(String.self, forKey: .refresh)
        expires = try c.decode(Int64.self, forKey: .expires)
        extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case access, refresh, expires, extras
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
    case corruptStore(path: String, detail: String)
    case persistFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let id): return "no OAuth credentials stored for '\(id)'"
        case .unknownProvider(let id): return "unknown OAuth provider '\(id)'"
        case .transport(let text): return "OAuth transport error: \(text)"
        case .invalidResponse(let text): return "OAuth invalid response: \(text)"
        case .refreshFailed(let text): return "OAuth refresh failed: \(text)"
        case .corruptStore(let path, let detail):
            return "OAuth store at \(path) is unreadable (refusing to overwrite it): \(detail)"
        case .persistFailed(let text): return "OAuth store write failed: \(text)"
        }
    }
}

// MARK: - Credential store

/// Persists credentials on disk when initialized with an explicit URL.
/// `OAuthStore()` is an in-memory empty store; the CLI opts into
/// `~/.kwwk/oauth.json` via `defaultURL()`.
public actor OAuthStore {
    public let url: URL
    public let isPersistent: Bool
    private var credentials: [String: OAuthCredentials]

    /// In-memory, non-persistent store. `set()`/`remove()` are no-ops on disk.
    public init() {
        self.url = URL(fileURLWithPath: "/dev/null")
        self.isPersistent = false
        self.credentials = [:]
    }

    /// Load a persistent store from `url`. A missing file is a normal fresh
    /// start (empty store). An existing file that cannot be read or decoded
    /// throws `OAuthError.corruptStore` — we must not silently drop the logins
    /// and then overwrite them on the next `set()`.
    public init(url: URL) throws {
        self.url = url
        self.isPersistent = true
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.credentials = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            self.credentials = try JSONDecoder().decode([String: OAuthCredentials].self, from: data)
        } catch {
            throw OAuthError.corruptStore(path: url.path, detail: String(describing: error))
        }
    }

    /// CLI-compatible OAuth store path: `~/.kwwk/oauth.json`.
    public static func defaultURL() -> URL {
        let home: URL = {
            #if targetEnvironment(macCatalyst) || os(iOS)
            return URL(fileURLWithPath: NSHomeDirectory())
            #else
            return FileManager.default.homeDirectoryForCurrentUser
            #endif
        }()
        return home.appendingPathComponent(".kwwk").appendingPathComponent("oauth.json")
    }

    public func all() -> [String: OAuthCredentials] { credentials }
    public func get(_ providerId: String) -> OAuthCredentials? { credentials[providerId] }

    public func set(_ credentials: OAuthCredentials, for providerId: String) throws {
        self.credentials[providerId] = credentials
        try persist()
    }

    public func remove(_ providerId: String) throws {
        credentials.removeValue(forKey: providerId)
        try persist()
    }

    private func persist() throws {
        guard isPersistent else { return }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(credentials)

        // Create the file 0600 up front (no world-readable window, no
        // chmod-after-write race), then rename(2) it over the destination so
        // the swap is atomic and the live file keeps the temp file's 0600
        // mode. Any failure throws — refresh tokens are too sensitive to
        // persist best-effort.
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]
        ) else {
            throw OAuthError.persistFailed("could not create temp store at \(tmp.path)")
        }
        if rename(tmp.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw OAuthError.persistFailed("rename into \(url.path) failed: \(reason)")
        }
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
    /// In-flight refresh per provider id. Concurrent `apiKey(for:)` callers
    /// await the same task instead of each launching their own refresh with
    /// the same (rotated-on-use) refresh token.
    private var inFlightRefresh: [String: Task<OAuthCredentials, Error>] = [:]

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
            OpenAICodexOAuthProvider(),
            GitHubCopilotOAuthProvider(),
            CursorOAuthProvider(),
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
            credentials = try await refresh(providerId, provider: provider, stale: credentials)
        }
        return try await provider.apiKey(from: credentials, using: client)
    }

    /// Refresh (or join an in-flight refresh for) `providerId`. The first
    /// caller starts the task and records it; concurrent callers await the
    /// same task. The task re-reads the store on entry so a refresh that
    /// landed while we were suspended is reused instead of re-run.
    private func refresh(
        _ providerId: String,
        provider: OAuthProvider,
        stale: OAuthCredentials
    ) async throws -> OAuthCredentials {
        if let existing = inFlightRefresh[providerId] {
            return try await existing.value
        }
        let store = self.store
        let client = self.client
        let task = Task<OAuthCredentials, Error> {
            let current = await store.get(providerId) ?? stale
            if !current.isExpired { return current }
            let refreshed = try await provider.refresh(current, using: client)
            try await store.set(refreshed, for: providerId)
            return refreshed
        }
        inFlightRefresh[providerId] = task
        defer { inFlightRefresh[providerId] = nil }
        return try await task.value
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
                return nil
            }
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
