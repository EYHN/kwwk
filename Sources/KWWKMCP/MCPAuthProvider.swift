import Foundation
import KWWKAI

/// What a transport hands to `MCPAuthProvider.onUnauthorized` when the
/// server answers 401.
public struct MCPUnauthorizedContext: Sendable {
    /// The MCP server URL.
    public var serverURL: URL
    /// The parsed `WWW-Authenticate` challenge of the 401 response.
    public var challenge: MCPAuthChallenge
    /// The bearer token the server rejected, if one was sent.
    public var rejectedToken: String?

    public init(serverURL: URL, challenge: MCPAuthChallenge, rejectedToken: String? = nil) {
        self.serverURL = serverURL
        self.challenge = challenge
        self.rejectedToken = rejectedToken
    }
}

/// Minimal bearer-token authentication for an MCP transport, the same seam
/// as the MCP TypeScript SDK's `AuthProvider`.
///
/// The transport calls `token()` before every request. When the server
/// answers 401 it calls `onUnauthorized(_:)` once and retries the request;
/// a second 401 fails with `MCPAuthError.unauthorizedAfterRetry`. A provider
/// that cannot recover throws from `onUnauthorized` (typically
/// `MCPAuthError.unauthorized`), and the request fails with that error.
///
/// Implement this directly when something else owns the credentials (an API
/// key, a gateway, a host that refreshes tokens itself). For a full OAuth
/// client use `MCPOAuthClientProvider`, which `MCPTransportAuth.oauth`
/// adapts to this protocol.
public protocol MCPAuthProvider: Sendable {
    /// The current bearer token, or nil to send no `Authorization` header.
    func token() async throws -> String?
    /// Make the next `token()` return a credential the server accepts, or
    /// throw. The default throws `MCPAuthError.unauthorized`.
    func onUnauthorized(_ context: MCPUnauthorizedContext) async throws
}

extension MCPAuthProvider {
    public func onUnauthorized(_ context: MCPUnauthorizedContext) async throws {
        throw MCPAuthError.unauthorized(nil)
    }
}

/// Which credentials `MCPOAuthClientProvider.invalidateCredentials` should
/// discard.
public enum MCPOAuthCredentialScope: String, Sendable, Hashable {
    case all, client, tokens, verifier, discovery
}

/// Context of the credential-persistence calls: the authorization server the
/// values belong to (SEP-2352). Providers that keep one credential set may
/// ignore it.
public struct MCPOAuthStorageContext: Sendable, Hashable {
    public var issuer: String

    public init(issuer: String) {
        self.issuer = issuer
    }
}

/// An end-to-end OAuth client for one MCP server, the same contract as the
/// MCP TypeScript SDK's `OAuthClientProvider`. `MCPOAuth.auth(_:options:)`
/// drives it; the provider stores what the flow produces and sends the
/// user to the authorization page.
///
/// Optional capabilities are separate protocols a provider may also adopt:
/// `MCPOAuthClientRegistrationStore` (dynamic client registration),
/// `MCPOAuthDiscoveryStore` (persisted discovery results),
/// `MCPOAuthCredentialInvalidation` and `MCPOAuthResourceValidation`.
public protocol MCPOAuthClientProvider: Sendable {
    /// Where the authorization server redirects the user agent afterwards.
    var redirectURL: URL { get }
    /// Metadata registered for this client (dynamic registration) or
    /// published at `clientMetadataURL`.
    var clientMetadata: MCPOAuthClientMetadata { get }
    /// An HTTPS URL serving this client's metadata document (SEP-991 client
    /// ID metadata document). Used as the client ID when the authorization
    /// server supports it.
    var clientMetadataURL: URL? { get }

    /// A fresh OAuth `state` value, or nil to send none. The default
    /// generates a random value. The caller compares it on the callback.
    func state() async throws -> String?

    /// The registered client for `context.issuer`, or nil when none is known.
    func clientInformation(_ context: MCPOAuthStorageContext?) async throws -> MCPOAuthClientInformation?

    /// The stored tokens. Called with nil for the per-request read: return
    /// the most recently saved set.
    func tokens(_ context: MCPOAuthStorageContext?) async throws -> MCPOAuthTokens?
    func saveTokens(_ tokens: MCPOAuthTokens, context: MCPOAuthStorageContext?) async throws

    /// Send the user agent to `url` to begin authorization.
    func redirectToAuthorization(_ url: URL) async throws

    func saveCodeVerifier(_ verifier: String) async throws
    func codeVerifier() async throws -> String
}

extension MCPOAuthClientProvider {
    public var clientMetadataURL: URL? { nil }

    public func state() async throws -> String? {
        PKCE.randomStateValue()
    }
}

/// A provider that can store a client registered dynamically. Without it,
/// `MCPOAuth.auth` never registers and needs pre-known client information.
public protocol MCPOAuthClientRegistrationStore: MCPOAuthClientProvider {
    func saveClientInformation(_ information: MCPOAuthClientInformation, context: MCPOAuthStorageContext?) async throws
}

/// A provider that persists discovery results. Its state must survive the
/// redirect round trip like the code verifier: the callback leg is refused
/// when it cannot read back the authorization server the request went to.
public protocol MCPOAuthDiscoveryStore: MCPOAuthClientProvider {
    func discoveryState() async throws -> MCPOAuthDiscoveryState?
    func saveDiscoveryState(_ state: MCPOAuthDiscoveryState) async throws
}

/// A provider that can discard credentials the server reported invalid.
public protocol MCPOAuthCredentialInvalidation: MCPOAuthClientProvider {
    func invalidateCredentials(_ scope: MCPOAuthCredentialScope) async throws
}

/// A provider that picks the RFC 8707 resource indicator itself.
public protocol MCPOAuthResourceValidation: MCPOAuthClientProvider {
    /// The resource to request for `serverURL`, given the protected
    /// resource metadata's `resource` if any. Must match the MCP server.
    func validateResourceURL(serverURL: URL, resource: String?) async throws -> URL?
}

/// How a transport authenticates.
public enum MCPTransportAuth: Sendable {
    /// A bearer-token provider; 401 handling only.
    case provider(any MCPAuthProvider)
    /// A full OAuth client: a 401 runs `MCPOAuth.auth`, a 403
    /// `insufficient_scope` runs step-up re-authorization. With
    /// `interactive: false` those runs only refresh and never involve the
    /// user (no registration, no redirect); the request then fails with
    /// `MCPAuthError.unauthorized` and the host signs the user in itself.
    case oauth(any MCPOAuthClientProvider, interactive: Bool = true)

    /// The OAuth client, when there is one.
    public var oauthProvider: (any MCPOAuthClientProvider)? {
        if case .oauth(let provider, _) = self { return provider }
        return nil
    }

    /// Whether OAuth runs started by the transport may involve the user.
    public var isInteractive: Bool {
        if case .oauth(_, let interactive) = self { return interactive }
        return false
    }
}

/// Adapts an `MCPOAuthClientProvider` to `MCPAuthProvider`, like the
/// TypeScript SDK's `adaptOAuthProvider`: `token()` returns the stored
/// access token and `onUnauthorized` runs `MCPOAuth.auth`.
///
/// With a `serverURL`, a token within `refreshSkewSeconds` of expiry is
/// refreshed before it is sent (as Codex does), by a non-interactive run
/// that never redirects. Every run of one adapter goes through one gate, so
/// concurrent refreshes and 401 recoveries share a single `auth` run and a
/// rotating refresh token is never spent twice.
public final class MCPOAuthAdapter: MCPAuthProvider, @unchecked Sendable {
    public static let refreshSkewSeconds: TimeInterval = 30

    public let provider: any MCPOAuthClientProvider
    public let serverURL: URL?
    public let httpClient: any MCPAuthHTTPClient
    /// Whether `onUnauthorized` may start an authorization the user takes part in.
    public let interactive: Bool
    let gate: MCPAuthRunGate

    public convenience init(
        provider: any MCPOAuthClientProvider,
        serverURL: URL? = nil,
        interactive: Bool = true,
        httpClient: any MCPAuthHTTPClient = URLSessionMCPAuthHTTPClient()
    ) {
        self.init(provider: provider, serverURL: serverURL, interactive: interactive, httpClient: httpClient, gate: MCPAuthRunGate())
    }

    init(
        provider: any MCPOAuthClientProvider,
        serverURL: URL?,
        interactive: Bool,
        httpClient: any MCPAuthHTTPClient,
        gate: MCPAuthRunGate
    ) {
        self.provider = provider
        self.serverURL = serverURL
        self.interactive = interactive
        self.httpClient = httpClient
        self.gate = gate
    }

    public func token() async throws -> String? {
        guard let tokens = try await provider.tokens(nil) else { return nil }
        guard let serverURL, tokens.refreshToken != nil, let expiresAt = tokens.expiresAt,
              expiresAt.timeIntervalSinceNow < Self.refreshSkewSeconds
        else { return tokens.accessToken }
        // Best effort: a failed refresh sends the old token, and the
        // server's 401 takes the usual recovery path.
        _ = try? await gate.run { [provider, httpClient] in
            try await MCPOAuth.auth(provider, options: MCPOAuthOptions(
                serverURL: serverURL, interactive: false, httpClient: httpClient
            ))
        }
        return try await provider.tokens(nil)?.accessToken
    }

    /// The stored access token, without refreshing.
    public func storedToken() async throws -> String? {
        try await provider.tokens(nil)?.accessToken
    }

    public func onUnauthorized(_ context: MCPUnauthorizedContext) async throws {
        let interactive = interactive
        let result = try await gate.run { [provider, httpClient] in
            try await MCPOAuth.auth(provider, options: MCPOAuthOptions(
                serverURL: context.serverURL,
                scope: context.challenge.scope,
                resourceMetadataURL: context.challenge.resourceMetadataURL,
                interactive: interactive,
                httpClient: httpClient
            ))
        }
        guard result == .authorized else { throw MCPAuthError.unauthorized(nil) }
    }
}

/// Runs one authorization at a time; callers arriving while one runs share
/// its result.
actor MCPAuthRunGate {
    private var running: Task<MCPOAuthResult, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> MCPOAuthResult) async throws -> MCPOAuthResult {
        if let running { return try await running.value }
        let task = Task { try await operation() }
        running = task
        defer { running = nil }
        return try await task.value
    }
}

extension PKCE {
    /// A random OAuth `state` value (32 bytes, base64url).
    static func randomStateValue() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return base64URL(Data(bytes))
    }
}
