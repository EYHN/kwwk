import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
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
    case expired(providerId: String)
    case unknownProvider(String)
    case transport(String)
    case invalidResponse(String)
    case refreshFailed(String)
    case corruptStore(path: String, detail: String)
    case persistFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let id): return "no OAuth credentials stored for '\(id)'"
        case .expired(let id):
            return "OAuth credentials for '\(id)' are expired and carry no refresh token — the credential source must serve fresh ones"
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

/// A credential source that failed to answer for `providerId`. The agent
/// loop never retries this one: the source is an external authority (a
/// backend minting tokens, a keychain daemon), and its refusal means the
/// user must act — a deleted login, a parked refresh chain — not that a
/// second attempt would fare better. The underlying error's own text is
/// what surfaces, so the authority's copy reaches the user unchanged.
public struct OAuthCredentialSourceError: Error, LocalizedError {
    public let providerId: String
    public let underlying: any Error

    public init(providerId: String, underlying: any Error) {
        self.providerId = providerId
        self.underlying = underlying
    }

    public var errorDescription: String? {
        (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
    }
}

// MARK: - Credential source

/// Where an `OAuthManager` reads credentials from. `OAuthStore` is the
/// file-backed implementation; a host that owns refresh elsewhere (a backend
/// minting per-tenant tokens, a keychain daemon, …) implements this instead
/// and hands it to `OAuthManager(source:)`.
///
/// There is no mode switch: whether the manager refreshes is decided by the
/// credentials themselves. An entry with an empty `refresh` cannot be
/// refreshed, so an authority that wants to keep refresh (and the refresh
/// token) entirely to itself simply serves access tokens with `refresh: ""` —
/// then this process never refreshes and never writes anything, and an
/// expired credential is the source's fault (`OAuthError.expired`). Sources
/// that talk to a network authority should do their own caching so the
/// per-request read stays cheap.
public protocol OAuthCredentialSource: Sendable {
    /// Ids the source currently holds credentials for. Registration walks this
    /// to decide which providers to wire up and in what priority order, so it
    /// should be as cheap as a cache read.
    func providerIds() async -> [String]

    /// Current credentials for `providerId`, or nil when the source holds none
    /// (the caller reports that as `OAuthError.missing`).
    func credentials(for providerId: String) async throws -> OAuthCredentials?
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

/// The file store is itself a credential source — reading it can't fail (the
/// only failure mode, a corrupt file, is caught at `init`), so these witness
/// the throwing requirements without throwing.
extension OAuthStore: OAuthCredentialSource {
    public func providerIds() -> [String] { Array(credentials.keys) }
    public func credentials(for providerId: String) -> OAuthCredentials? { credentials[providerId] }
}
