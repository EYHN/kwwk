import Crypto
import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKMCP

/// A fake MCP resource server's metadata plus an authorization server.
final class FakeAuthServer: MCPAuthHTTPClient, @unchecked Sendable {
    struct Recorded: Sendable {
        var request: MCPAuthHTTPRequest
        var form: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    var requests: [Recorded] { lock.withLock { recorded } }

    var issuer = "https://auth.example.com"
    var issParameterSupported = true
    var clientIDMetadataDocumentSupported = false
    var registrationResponse: JSONValue = ["client_id": "client-1", "client_secret": "secret-1"]
    var refreshError: String?
    var issueRefreshTokenOnRefresh = false
    /// Serve PRM only at the root well-known URL.
    var prmAtRootOnly = false
    var codesIssued = 0

    func send(_ request: MCPAuthHTTPRequest) async throws -> MCPAuthHTTPResponse {
        let form = Self.parseForm(request.body)
        lock.withLock { recorded.append(Recorded(request: request, form: form)) }
        let url = request.url.absoluteString
        switch (request.method, url) {
        case ("GET", "https://mcp.example.com/.well-known/oauth-protected-resource/mcp") where !prmAtRootOnly,
             ("GET", "https://mcp.example.com/.well-known/oauth-protected-resource") where prmAtRootOnly:
            return json(request, 200, [
                "resource": "https://mcp.example.com/mcp",
                "authorization_servers": .array([.string(issuer)]),
                "scopes_supported": ["read", "write"],
            ])
        case ("GET", "https://auth.example.com/.well-known/oauth-authorization-server"):
            return json(request, 200, [
                "issuer": .string(issuer),
                "authorization_endpoint": "https://auth.example.com/authorize",
                "token_endpoint": "https://auth.example.com/token",
                "registration_endpoint": "https://auth.example.com/register",
                "response_types_supported": ["code"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["client_secret_basic", "client_secret_post", "none"],
                "authorization_response_iss_parameter_supported": .bool(issParameterSupported),
                "client_id_metadata_document_supported": .bool(clientIDMetadataDocumentSupported),
            ])
        case ("POST", "https://auth.example.com/register"):
            return json(request, 201, registrationResponse)
        case ("POST", "https://auth.example.com/token"):
            switch form["grant_type"] {
            case "authorization_code":
                return json(request, 200, [
                    "access_token": "access-1", "token_type": "Bearer", "expires_in": 3600,
                    "refresh_token": "refresh-1", "scope": "read write",
                ])
            case "refresh_token":
                if let refreshError {
                    return json(request, 400, ["error": .string(refreshError), "error_description": "nope"])
                }
                var body: JSONValue = ["access_token": "access-2", "token_type": "Bearer", "expires_in": 3600]
                if issueRefreshTokenOnRefresh, case .object(var object) = body {
                    object["refresh_token"] = "refresh-2"
                    body = .object(object)
                }
                return json(request, 200, body)
            default:
                return json(request, 400, ["error": "unsupported_grant_type"])
            }
        default:
            return MCPAuthHTTPResponse(status: 404, body: Data("not found".utf8), url: request.url)
        }
    }

    private func json(_ request: MCPAuthHTTPRequest, _ status: Int, _ body: JSONValue) -> MCPAuthHTTPResponse {
        MCPAuthHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: (try? JSONEncoder().encode(body)) ?? Data(),
            url: request.url
        )
    }

    static func parseForm(_ body: Data?) -> [String: String] {
        guard let body, let text = String(data: body, encoding: .utf8), text.contains("=") else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let decode = { (value: String) in
                value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
            }
            result[decode(parts[0])] = decode(parts[1])
        }
        return result
    }
}

/// An in-memory OAuth client with every optional capability.
final class MemoryOAuthProvider: MCPOAuthClientRegistrationStore, MCPOAuthDiscoveryStore,
    MCPOAuthCredentialInvalidation, @unchecked Sendable {
    private let lock = NSLock()
    var client: MCPOAuthClientInformation?
    var storedTokens: MCPOAuthTokens?
    var verifier: String?
    var discovery: MCPOAuthDiscoveryState?
    var redirects: [URL] = []
    var invalidated: [MCPOAuthCredentialScope] = []
    var metadataURL: URL?

    let redirectURL = URL(string: "http://127.0.0.1:4567/callback")!
    var clientMetadata: MCPOAuthClientMetadata {
        MCPOAuthClientMetadata(redirectURIs: [redirectURL.absoluteString], clientName: "Test Client")
    }
    var clientMetadataURL: URL? { metadataURL }

    func state() async throws -> String? { "state-1" }
    func clientInformation(_ context: MCPOAuthStorageContext?) async throws -> MCPOAuthClientInformation? {
        lock.withLock { client }
    }
    func saveClientInformation(_ information: MCPOAuthClientInformation, context: MCPOAuthStorageContext?) async throws {
        lock.withLock { client = information }
    }
    func tokens(_ context: MCPOAuthStorageContext?) async throws -> MCPOAuthTokens? { lock.withLock { storedTokens } }
    func saveTokens(_ tokens: MCPOAuthTokens, context: MCPOAuthStorageContext?) async throws {
        lock.withLock { storedTokens = tokens }
    }
    func redirectToAuthorization(_ url: URL) async throws { lock.withLock { redirects.append(url) } }
    func saveCodeVerifier(_ verifier: String) async throws { lock.withLock { self.verifier = verifier } }
    func codeVerifier() async throws -> String {
        guard let verifier = lock.withLock({ verifier }) else { throw MCPAuthError.providerMisconfigured("no verifier") }
        return verifier
    }
    func discoveryState() async throws -> MCPOAuthDiscoveryState? { lock.withLock { discovery } }
    func saveDiscoveryState(_ state: MCPOAuthDiscoveryState) async throws { lock.withLock { discovery = state } }
    func invalidateCredentials(_ scope: MCPOAuthCredentialScope) async throws {
        lock.withLock {
            invalidated.append(scope)
            switch scope {
            case .all: client = nil; storedTokens = nil; verifier = nil; discovery = nil
            case .client: client = nil
            case .tokens: storedTokens = nil
            case .verifier: verifier = nil
            case .discovery: discovery = nil
            }
        }
    }
}

private func query(_ url: URL) -> [String: String] {
    FakeAuthServer.parseForm(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery.map { Data($0.utf8) })
}

@Suite("MCP OAuth")
struct MCPOAuthTests {
    let serverURL = URL(string: "https://mcp.example.com/mcp")!

    @Test("WWW-Authenticate parameters, quoted or not, Bearer or DPoP")
    func challenge() {
        let header = #"Bearer realm="OAuth", resource_metadata="https://x.example/.well-known/oauth-protected-resource/mcp", scope="read write", error=insufficient_scope"#
        let challenge = MCPAuthChallenge(header: header)
        #expect(challenge.resourceMetadataURL?.absoluteString == "https://x.example/.well-known/oauth-protected-resource/mcp")
        #expect(challenge.scope == "read write")
        #expect(challenge.error == "insufficient_scope")
        #expect(MCPAuthChallenge(header: #"DPoP scope="a""#).scope == "a")
        #expect(MCPAuthChallenge(header: #"Basic realm="x""#) == MCPAuthChallenge())
        // `scope` must start a parameter, not match inside another name.
        #expect(MCPAuthChallenge(header: #"Bearer xscope="no""#).scope == nil)
    }

    @Test("first authorization: discovery, registration, PKCE redirect, then the code exchange")
    func fullFlow() async throws {
        let server = FakeAuthServer()
        let provider = MemoryOAuthProvider()
        let result = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: serverURL, httpClient: server))
        #expect(result == .redirect)

        let register = try #require(server.requests.first { $0.request.url.path == "/register" })
        let registered = try JSONDecoder().decode(JSONValue.self, from: register.request.body ?? Data())
        #expect(registered["client_name"] == "Test Client")
        #expect(registered["redirect_uris"] == ["http://127.0.0.1:4567/callback"])
        #expect(registered["grant_types"] == ["authorization_code", "refresh_token"])
        #expect(registered["application_type"] == "native")
        #expect(registered["scope"] == "read write")
        #expect(provider.client?.clientID == "client-1")
        #expect(provider.client?.issuer == "https://auth.example.com")
        #expect(provider.discovery?.authorizationServerURL == "https://auth.example.com")

        let redirect = try #require(provider.redirects.first)
        let params = query(redirect)
        #expect(redirect.absoluteString.hasPrefix("https://auth.example.com/authorize?"))
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == "client-1")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["redirect_uri"] == "http://127.0.0.1:4567/callback")
        #expect(params["state"] == "state-1")
        #expect(params["scope"] == "read write")
        #expect(params["resource"] == "https://mcp.example.com/mcp")
        let verifier = try #require(provider.verifier)
        let challenge = PKCE.base64URL(Data(SHA256Hasher.hash(verifier)))
        #expect(params["code_challenge"] == challenge)

        try await MCPOAuth.finishAuthorization(
            provider,
            serverURL: serverURL,
            callbackParameters: ["code": "code-1", "state": "state-1", "iss": "https://auth.example.com"],
            httpClient: server
        )
        let token = try #require(server.requests.last { $0.request.url.path == "/token" })
        #expect(token.form["grant_type"] == "authorization_code")
        #expect(token.form["code"] == "code-1")
        #expect(token.form["code_verifier"] == verifier)
        #expect(token.form["resource"] == "https://mcp.example.com/mcp")
        // A client with a secret authenticates with HTTP Basic.
        #expect(token.request.headers["Authorization"] == "Basic " + Data("client-1:secret-1".utf8).base64EncodedString())
        #expect(token.form["client_secret"] == nil)
        #expect(provider.storedTokens?.accessToken == "access-1")
        #expect(provider.storedTokens?.issuer == "https://auth.example.com")
        #expect(provider.storedTokens?.expiresAt != nil)
    }

    @Test("RFC 9207: a missing iss is refused when the server advertises it")
    func issuerRequired() async throws {
        let server = FakeAuthServer()
        let provider = MemoryOAuthProvider()
        _ = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: serverURL, httpClient: server))
        await #expect(throws: MCPAuthError.issuerMismatch(kind: "authorization response", expected: "https://auth.example.com", actual: nil)) {
            try await MCPOAuth.finishAuthorization(
                provider, serverURL: serverURL, callbackParameters: ["code": "c"], httpClient: server
            )
        }
        await #expect(throws: MCPAuthError.issuerMismatch(kind: "authorization response", expected: "https://auth.example.com", actual: "https://evil.example")) {
            try await MCPOAuth.finishAuthorization(
                provider, serverURL: serverURL, callbackParameters: ["code": "c", "iss": "https://evil.example"], httpClient: server
            )
        }
        #expect(!server.requests.contains { $0.request.url.path == "/token" })
        // An error callback is surfaced only after its iss checks out.
        await #expect(throws: MCPAuthError.oauth(MCPOAuthErrorResponse(code: "access_denied", description: "no"))) {
            try await MCPOAuth.finishAuthorization(
                provider, serverURL: serverURL,
                callbackParameters: ["error": "access_denied", "error_description": "no", "iss": "https://auth.example.com"],
                httpClient: server
            )
        }
    }

    @Test("metadata whose issuer differs from the authorization server URL is rejected")
    func metadataIssuerEcho() async throws {
        let server = FakeAuthServer()
        server.issuer = "https://auth.example.com"
        // PRM points at the server, metadata claims another issuer.
        let wrong = FakeAuthServerWrongIssuer(base: server)
        await #expect(throws: MCPAuthError.issuerMismatch(kind: "metadata", expected: "https://auth.example.com", actual: "https://other.example")) {
            _ = try await MCPOAuth.discoverServerInfo(serverURL: serverURL, httpClient: wrong)
        }
    }

    @Test("protected resource metadata falls back to the root well-known URL")
    func prmFallback() async throws {
        let server = FakeAuthServer()
        server.prmAtRootOnly = true
        let info = try await MCPOAuth.discoverServerInfo(serverURL: serverURL, httpClient: server)
        #expect(info.authorizationServerURL == "https://auth.example.com")
        let paths = server.requests.map(\.request.url.path)
        #expect(paths.prefix(2) == ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"])
    }

    @Test("refresh keeps the old refresh token when none comes back")
    func refresh() async throws {
        let server = FakeAuthServer()
        let provider = MemoryOAuthProvider()
        provider.client = MCPOAuthClientInformation(clientID: "client-1", clientSecret: "secret-1", issuer: "https://auth.example.com")
        provider.storedTokens = MCPOAuthTokens(accessToken: "old", refreshToken: "refresh-1", issuer: "https://auth.example.com")
        let result = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: serverURL, httpClient: server))
        #expect(result == .authorized)
        #expect(provider.storedTokens?.accessToken == "access-2")
        #expect(provider.storedTokens?.refreshToken == "refresh-1")
        let refresh = try #require(server.requests.last { $0.request.url.path == "/token" })
        #expect(refresh.form["grant_type"] == "refresh_token")
        #expect(refresh.form["resource"] == "https://mcp.example.com/mcp")
        #expect(!server.requests.contains { $0.request.url.path == "/register" })
    }

    @Test("a token about to expire is refreshed once before it is sent, even by concurrent requests")
    func proactiveRefresh() async throws {
        let server = FakeAuthServer()
        server.issueRefreshTokenOnRefresh = true
        let provider = MemoryOAuthProvider()
        provider.client = MCPOAuthClientInformation(clientID: "client-1", issuer: "https://auth.example.com")
        provider.storedTokens = MCPOAuthTokens(
            accessToken: "old", refreshToken: "refresh-1",
            expiresAt: Date().addingTimeInterval(5), issuer: "https://auth.example.com"
        )
        let adapter = MCPOAuthAdapter(provider: provider, serverURL: serverURL, httpClient: server)
        async let a = adapter.token()
        async let b = adapter.token()
        let tokens = try await [a, b]
        #expect(tokens == ["access-2", "access-2"])
        #expect(server.requests.filter { $0.form["grant_type"] == "refresh_token" }.count == 1)
        #expect(provider.storedTokens?.refreshToken == "refresh-2")
        // A fresh token is sent as is.
        provider.storedTokens?.expiresAt = Date().addingTimeInterval(3600)
        #expect(try await adapter.token() == "access-2")
        #expect(server.requests.filter { $0.form["grant_type"] == "refresh_token" }.count == 1)
    }

    @Test("a non-interactive run only refreshes: no registration, verifier or redirect")
    func nonInteractive() async throws {
        let server = FakeAuthServer()
        let provider = MemoryOAuthProvider()
        let unknown = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(
            serverURL: serverURL, interactive: false, httpClient: server
        ))
        #expect(unknown == .authorizationRequired)
        #expect(!server.requests.contains { $0.request.url.path == "/register" })
        #expect(provider.redirects.isEmpty)
        #expect(provider.verifier == nil)

        server.refreshError = "invalid_grant"
        provider.client = MCPOAuthClientInformation(clientID: "client-1", issuer: "https://auth.example.com")
        provider.storedTokens = MCPOAuthTokens(accessToken: "old", refreshToken: "r", issuer: "https://auth.example.com")
        let refused = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(
            serverURL: serverURL, interactive: false, httpClient: server
        ))
        #expect(refused == .authorizationRequired)
        #expect(provider.redirects.isEmpty)
        #expect(provider.verifier == nil)

        // A transient failure is thrown, not mistaken for needing sign-in.
        server.refreshError = "server_error"
        provider.storedTokens = MCPOAuthTokens(accessToken: "old", refreshToken: "r", issuer: "https://auth.example.com")
        await #expect(throws: MCPAuthError.self) {
            _ = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(
                serverURL: serverURL, interactive: false, httpClient: server
            ))
        }
        #expect(provider.redirects.isEmpty)
    }

    @Test("a failed proactive refresh sends the old token and never redirects")
    func proactiveRefreshFailure() async throws {
        let server = FakeAuthServer()
        server.refreshError = "invalid_grant"
        let provider = MemoryOAuthProvider()
        provider.client = MCPOAuthClientInformation(clientID: "client-1", issuer: "https://auth.example.com")
        provider.storedTokens = MCPOAuthTokens(
            accessToken: "old", refreshToken: "r", expiresAt: Date().addingTimeInterval(1), issuer: "https://auth.example.com"
        )
        let adapter = MCPOAuthAdapter(provider: provider, serverURL: serverURL, httpClient: server)
        _ = try await adapter.token()
        #expect(provider.redirects.isEmpty)
        #expect(provider.verifier == nil)
    }

    @Test("invalid_grant on refresh drops the tokens and starts a new authorization")
    func invalidGrant() async throws {
        let server = FakeAuthServer()
        server.refreshError = "invalid_grant"
        let provider = MemoryOAuthProvider()
        provider.client = MCPOAuthClientInformation(clientID: "client-1", issuer: "https://auth.example.com")
        provider.storedTokens = MCPOAuthTokens(accessToken: "old", refreshToken: "refresh-1", issuer: "https://auth.example.com")
        let result = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: serverURL, httpClient: server))
        #expect(result == .redirect)
        #expect(provider.invalidated == [.tokens])
        #expect(provider.storedTokens == nil)
        #expect(provider.redirects.count == 1)
    }

    @Test("tokens stamped for another issuer are never sent to this one")
    func issuerStamp() async throws {
        let server = FakeAuthServer()
        let provider = MemoryOAuthProvider()
        provider.client = MCPOAuthClientInformation(clientID: "client-1", issuer: "https://auth.example.com")
        provider.storedTokens = MCPOAuthTokens(accessToken: "old", refreshToken: "elsewhere", issuer: "https://other.example")
        let result = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: serverURL, httpClient: server))
        #expect(result == .redirect)
        #expect(!server.requests.contains { $0.form["refresh_token"] == "elsewhere" })
    }

    @Test("a client ID metadata document is used instead of registering")
    func clientIDMetadataDocument() async throws {
        let server = FakeAuthServer()
        server.clientIDMetadataDocumentSupported = true
        let provider = MemoryOAuthProvider()
        provider.metadataURL = URL(string: "https://client.example/oauth/client.json")
        _ = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: serverURL, httpClient: server))
        #expect(provider.client?.clientID == "https://client.example/oauth/client.json")
        #expect(!server.requests.contains { $0.request.url.path == "/register" })
        #expect(query(try #require(provider.redirects.first))["client_id"] == "https://client.example/oauth/client.json")
    }

    @Test("the callback leg is refused when the authorization server changed")
    func callbackLegGate() async throws {
        let server = FakeAuthServer()
        let provider = MemoryOAuthProvider()
        _ = try await MCPOAuth.auth(provider, options: MCPOAuthOptions(serverURL: serverURL, httpClient: server))
        provider.discovery?.authorizationServerURL = "https://previous.example"
        provider.discovery?.authorizationServerMetadata?.issuer = "https://previous.example"
        await #expect(throws: MCPAuthError.self) {
            try await MCPOAuth.finishAuthorization(
                provider, serverURL: serverURL,
                callbackParameters: ["code": "c", "iss": "https://auth.example.com"], httpClient: server
            )
        }
    }

    @Test("scope selection, union and superset")
    func scopes() {
        let metadata = MCPOAuthClientMetadata(redirectURIs: [], scope: "fallback", grantTypes: ["authorization_code", "refresh_token"])
        let prm = MCPProtectedResourceMetadata(resource: "https://x", scopesSupported: ["a", "b"])
        let asWithOffline = MCPAuthorizationServerMetadata(
            issuer: "https://as", authorizationEndpoint: "https://as/a", tokenEndpoint: "https://as/t",
            scopesSupported: ["a", "offline_access"]
        )
        #expect(MCPOAuth.determineScope(requestedScope: "c", resourceMetadata: prm, authorizationServerMetadata: nil, clientMetadata: metadata) == "c")
        #expect(MCPOAuth.determineScope(requestedScope: nil, resourceMetadata: prm, authorizationServerMetadata: nil, clientMetadata: metadata) == "a b")
        #expect(MCPOAuth.determineScope(requestedScope: nil, resourceMetadata: nil, authorizationServerMetadata: nil, clientMetadata: metadata) == "fallback")
        #expect(MCPOAuth.determineScope(requestedScope: "a", resourceMetadata: nil, authorizationServerMetadata: asWithOffline, clientMetadata: metadata) == "a offline_access")
        #expect(MCPOAuth.scopeUnion("a b", nil, "b c") == "a b c")
        #expect(MCPOAuth.isStrictScopeSuperset("a b c", of: "a b"))
        #expect(!MCPOAuth.isStrictScopeSuperset("a b", of: "b a"))
        #expect(MCPOAuth.isStrictScopeSuperset("a", of: nil))
    }

    @Test("client authentication method and resource checks")
    func helpers() {
        let secret = MCPOAuthClientInformation(clientID: "c", clientSecret: "s")
        let assigned = MCPOAuthClientInformation(clientID: "c", clientSecret: "s", tokenEndpointAuthMethod: "client_secret_post")
        let publicClient = MCPOAuthClientInformation(clientID: "c")
        #expect(MCPOAuth.selectClientAuthMethod(client: secret, supportedMethods: []) == "client_secret_basic")
        #expect(MCPOAuth.selectClientAuthMethod(client: secret, supportedMethods: ["client_secret_post"]) == "client_secret_post")
        #expect(MCPOAuth.selectClientAuthMethod(client: assigned, supportedMethods: ["client_secret_basic", "client_secret_post"]) == "client_secret_post")
        #expect(MCPOAuth.selectClientAuthMethod(client: publicClient, supportedMethods: ["client_secret_basic", "none"]) == "none")
        let server = URL(string: "https://mcp.example.com/mcp")!
        #expect(MCPOAuth.checkResourceAllowed(requested: server, configured: URL(string: "https://mcp.example.com")!))
        #expect(MCPOAuth.checkResourceAllowed(requested: server, configured: URL(string: "https://mcp.example.com/mcp")!))
        #expect(!MCPOAuth.checkResourceAllowed(requested: server, configured: URL(string: "https://mcp.example.com/mcpx")!))
        #expect(!MCPOAuth.checkResourceAllowed(requested: server, configured: URL(string: "https://other.example.com/mcp")!))
        #expect(throws: MCPAuthError.insecureTokenEndpoint("http://as.example/token")) {
            try MCPOAuth.assertSecureTokenEndpoint(URL(string: "http://as.example/token")!)
        }
        #expect(throws: Never.self) { try MCPOAuth.assertSecureTokenEndpoint(URL(string: "http://127.0.0.1:8080/token")!) }
    }

    @Test("redirects are followed only within the origin, keeping the method")
    func redirectPolicy() async throws {
        final class Redirecting: MCPAuthHTTPClient, @unchecked Sendable {
            func send(_ request: MCPAuthHTTPRequest) async throws -> MCPAuthHTTPResponse {
                switch request.url.absoluteString {
                case "https://a.example/start": return MCPAuthHTTPResponse(status: 302, headers: ["Location": "/next"], url: request.url)
                case "https://a.example/next": return MCPAuthHTTPResponse(status: 302, headers: ["Location": "https://b.example/x"], url: request.url)
                default: return MCPAuthHTTPResponse(status: 200, body: Data("ok".utf8), url: request.url)
                }
            }
        }
        let response = try await MCPAuthHTTP.send(MCPAuthHTTPRequest(url: URL(string: "https://a.example/start")!), using: Redirecting())
        // The same-origin hop is followed; the cross-origin one is returned.
        #expect(response.status == 302)
        #expect(response.url.absoluteString == "https://a.example/next")
        let post = try await MCPAuthHTTP.send(
            MCPAuthHTTPRequest(url: URL(string: "https://a.example/start")!, method: "POST"), using: Redirecting()
        )
        #expect(post.url.absoluteString == "https://a.example/start")
    }
}

/// Serves metadata whose `issuer` differs from the URL it was fetched for.
final class FakeAuthServerWrongIssuer: MCPAuthHTTPClient, @unchecked Sendable {
    let base: FakeAuthServer
    init(base: FakeAuthServer) { self.base = base }
    func send(_ request: MCPAuthHTTPRequest) async throws -> MCPAuthHTTPResponse {
        var response = try await base.send(request)
        if request.url.path == "/.well-known/oauth-authorization-server",
           var json = try? JSONDecoder().decode(JSONValue.self, from: response.body),
           case .object(var object) = json {
            object["issuer"] = "https://other.example"
            json = .object(object)
            response.body = try JSONEncoder().encode(json)
        }
        return response
    }
}

enum SHA256Hasher {
    static func hash(_ text: String) -> [UInt8] {
        Array(Crypto.SHA256.hash(data: Data(text.utf8)))
    }
}
