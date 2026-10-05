import Foundation
import KWWKAI

/// Options of `MCPOAuth.auth(_:options:)`.
public struct MCPOAuthOptions: Sendable {
    /// The MCP server URL: the protected resource being authorized.
    public var serverURL: URL
    /// The authorization code from the redirect callback. When set, `auth`
    /// exchanges it; otherwise it refreshes or starts an authorization.
    public var authorizationCode: String?
    /// The callback's `iss` parameter (RFC 9207), if present.
    public var iss: String?
    /// The scope to request; chosen by the MCP scope selection strategy when nil.
    public var scope: String?
    /// The `resource_metadata` URL from a `WWW-Authenticate` challenge.
    public var resourceMetadataURL: URL?
    /// Skip refresh and start a new authorization (step-up past the
    /// current token's scope, which a refresh cannot widen).
    public var forceReauthorization: Bool
    /// Skip the RFC 8414 §3.3 issuer echo check. Weakens security; only for
    /// authorization servers known to publish a mismatched issuer.
    public var skipIssuerMetadataValidation: Bool
    /// Whether this run may involve the user. A non-interactive run only
    /// refreshes: it never registers a client, writes a code verifier or
    /// calls `redirectToAuthorization`, and answers
    /// `.authorizationRequired` when a person has to sign in. A transient
    /// refresh failure is thrown rather than treated as needing sign-in.
    public var interactive: Bool
    public var httpClient: any MCPAuthHTTPClient

    public init(
        serverURL: URL,
        authorizationCode: String? = nil,
        iss: String? = nil,
        scope: String? = nil,
        resourceMetadataURL: URL? = nil,
        forceReauthorization: Bool = false,
        skipIssuerMetadataValidation: Bool = false,
        interactive: Bool = true,
        httpClient: any MCPAuthHTTPClient = URLSessionMCPAuthHTTPClient()
    ) {
        self.serverURL = serverURL
        self.authorizationCode = authorizationCode
        self.iss = iss
        self.scope = scope
        self.resourceMetadataURL = resourceMetadataURL
        self.forceReauthorization = forceReauthorization
        self.skipIssuerMetadataValidation = skipIssuerMetadataValidation
        self.interactive = interactive
        self.httpClient = httpClient
    }
}

/// The outcome of `MCPOAuth.auth`.
public enum MCPOAuthResult: Sendable, Hashable {
    /// Tokens are stored and usable.
    case authorized
    /// The user agent was sent to the authorization page; finish with the
    /// callback's code.
    case redirect
    /// A non-interactive run found that a person has to sign in.
    case authorizationRequired
}

/// The authorization server found for an MCP server.
public struct MCPOAuthServerInfo: Sendable, Hashable {
    public var authorizationServerURL: String
    public var authorizationServerMetadata: MCPAuthorizationServerMetadata?
    public var resourceMetadata: MCPProtectedResourceMetadata?
}

/// The MCP authorization flow (MCP 2025-11-25), ported from the MCP
/// TypeScript SDK's `auth.ts`: protected resource metadata (RFC 9728),
/// authorization server metadata (RFC 8414 / OIDC Discovery), client ID
/// metadata documents (SEP-991), dynamic client registration (RFC 7591),
/// PKCE, resource indicators (RFC 8707), authorization response issuer
/// validation (RFC 9207), issuer-bound credentials (SEP-2352) and step-up
/// scope selection. DPoP, Cross-App Access and non-interactive grants are
/// not implemented.
public enum MCPOAuth {
    public static let protocolVersionHeader = "MCP-Protocol-Version"

    // MARK: - auth

    /// Run the authorization flow. Recoverable OAuth errors are retried once
    /// after discarding the affected credentials: `invalid_client` /
    /// `unauthorized_client` drop the client and tokens, `invalid_grant`
    /// drops the tokens.
    public static func auth(_ provider: any MCPOAuthClientProvider, options: MCPOAuthOptions) async throws -> MCPOAuthResult {
        do {
            return try await authInternal(provider, options: options)
        } catch MCPAuthError.oauth(let error) {
            switch error.code {
            case MCPOAuthErrorResponse.invalidClient, MCPOAuthErrorResponse.unauthorizedClient:
                try await invalidate(provider, .client)
                try await invalidate(provider, .tokens)
                return try await authInternal(provider, options: options)
            case MCPOAuthErrorResponse.invalidGrant:
                try await invalidate(provider, .tokens)
                return try await authInternal(provider, options: options)
            default:
                throw MCPAuthError.oauth(error)
            }
        }
    }

    private static func invalidate(_ provider: any MCPOAuthClientProvider, _ scope: MCPOAuthCredentialScope) async throws {
        try await (provider as? any MCPOAuthCredentialInvalidation)?.invalidateCredentials(scope)
    }

    private static func authInternal(_ provider: any MCPOAuthClientProvider, options: MCPOAuthOptions) async throws -> MCPOAuthResult {
        let http = options.httpClient
        let clientMetadata = resolveClientMetadata(provider)
        let discoveryStore = provider as? any MCPOAuthDiscoveryStore
        let cached = try await discoveryStore?.discoveryState()

        var resourceMetadataURL = options.resourceMetadataURL
        if resourceMetadataURL == nil, let saved = cached?.resourceMetadataURL {
            resourceMetadataURL = URL(string: saved)
        }

        let authorizationServerURL: String
        var metadata: MCPAuthorizationServerMetadata?
        var resourceMetadata: MCPProtectedResourceMetadata?
        var freshState: MCPOAuthDiscoveryState?

        if let cached {
            authorizationServerURL = cached.authorizationServerURL
            resourceMetadata = cached.resourceMetadata
            if let cachedMetadata = cached.authorizationServerMetadata {
                metadata = cachedMetadata
            } else {
                metadata = try await discoverAuthorizationServerMetadata(
                    authorizationServerURL,
                    skipIssuerValidation: options.skipIssuerMetadataValidation,
                    httpClient: http
                )
            }
            if resourceMetadata == nil {
                resourceMetadata = try? await discoverProtectedResourceMetadata(
                    serverURL: options.serverURL,
                    resourceMetadataURL: resourceMetadataURL,
                    httpClient: http
                )
            }
            if metadata != cached.authorizationServerMetadata || resourceMetadata != cached.resourceMetadata {
                try await discoveryStore?.saveDiscoveryState(MCPOAuthDiscoveryState(
                    authorizationServerURL: authorizationServerURL,
                    resourceMetadataURL: resourceMetadataURL?.absoluteString,
                    resourceMetadata: resourceMetadata,
                    authorizationServerMetadata: metadata
                ))
            }
        } else {
            let info = try await discoverServerInfo(
                serverURL: options.serverURL,
                resourceMetadataURL: resourceMetadataURL,
                skipIssuerMetadataValidation: options.skipIssuerMetadataValidation,
                httpClient: http
            )
            authorizationServerURL = info.authorizationServerURL
            metadata = info.authorizationServerMetadata
            resourceMetadata = info.resourceMetadata
            freshState = MCPOAuthDiscoveryState(
                authorizationServerURL: authorizationServerURL,
                resourceMetadataURL: resourceMetadataURL?.absoluteString,
                resourceMetadata: resourceMetadata,
                authorizationServerMetadata: metadata
            )
        }

        // SEP-2352: the authorization server identity of this flow.
        let issuer = metadata?.issuer ?? authorizationServerURL
        let context = MCPOAuthStorageContext(issuer: issuer)

        // SEP-2352 callback-leg gate: the code and verifier belong to the
        // authorization server the user approved at.
        if options.authorizationCode != nil {
            let recorded = cached?.authorizationServerMetadata?.issuer ?? cached?.authorizationServerURL
            if let recorded {
                guard issuersMatch(recorded, issuer) else {
                    throw MCPAuthError.authorizationServerMismatch(expected: recorded, actual: issuer)
                }
            } else if discoveryStore != nil {
                throw MCPAuthError.authorizationServerMismatch(
                    expected: "discovery state was not available on the callback leg; persist it alongside the code verifier",
                    actual: issuer
                )
            }
        }
        if let freshState {
            try await discoveryStore?.saveDiscoveryState(freshState)
        }

        // Send the metadata's resource indicator verbatim.
        let resource = try await selectResource(serverURL: options.serverURL, provider: provider, resourceMetadata: resourceMetadata)

        let resolvedScope = determineScope(
            requestedScope: options.scope,
            resourceMetadata: resourceMetadata,
            authorizationServerMetadata: metadata,
            clientMetadata: provider.clientMetadata
        )

        // Client registration.
        let registrationStore = provider as? any MCPOAuthClientRegistrationStore
        let rawClient = try await provider.clientInformation(context)
        var client = discardIfIssuerMismatch(rawClient, issuer: issuer)
        if client == nil, let rawIssuer = rawClient?.issuer, registrationStore == nil {
            throw MCPAuthError.authorizationServerMismatch(expected: rawIssuer, actual: issuer)
        }
        if var stamped = client, stamped.issuer == nil {
            stamped.issuer = issuer
            client = stamped
            try await registrationStore?.saveClientInformation(stamped, context: context)
        }
        if client == nil && !options.interactive {
            return .authorizationRequired
        }
        if client == nil {
            guard options.authorizationCode == nil else {
                throw MCPAuthError.providerMisconfigured(
                    "Existing OAuth client information is required when exchanging an authorization code"
                )
            }
            if let metadataURL = provider.clientMetadataURL, !isHTTPSURLWithPath(metadataURL) {
                throw MCPAuthError.oauth(MCPOAuthErrorResponse(
                    code: MCPOAuthErrorResponse.invalidClientMetadata,
                    description: "clientMetadataURL must be an HTTPS URL with a non-root path, got: \(metadataURL.absoluteString)"
                ))
            }
            if metadata?.clientIDMetadataDocumentSupported == true, let metadataURL = provider.clientMetadataURL {
                let information = MCPOAuthClientInformation(clientID: metadataURL.absoluteString, issuer: issuer)
                try await registrationStore?.saveClientInformation(information, context: context)
                client = information
            } else {
                guard let registrationStore else {
                    throw MCPAuthError.providerMisconfigured(
                        "OAuth client information must be saveable for dynamic registration"
                    )
                }
                var registered = try await registerClient(
                    authorizationServerURL: authorizationServerURL,
                    metadata: metadata,
                    clientMetadata: clientMetadata,
                    scope: resolvedScope,
                    httpClient: http
                )
                registered.issuer = issuer
                try await registrationStore.saveClientInformation(registered, context: context)
                client = registered
            }
        }
        guard let client else { throw MCPAuthError.providerMisconfigured("No OAuth client information") }

        // Exchange an authorization code.
        if let code = options.authorizationCode {
            try validateAuthorizationResponseIssuer(
                iss: options.iss,
                expectedIssuer: metadata?.issuer,
                issParameterSupported: metadata?.authorizationResponseIssParameterSupported == true
            )
            let verifier = try await provider.codeVerifier()
            let tokens = try await exchangeAuthorization(
                authorizationServerURL: authorizationServerURL,
                metadata: metadata,
                client: client,
                code: code,
                codeVerifier: verifier,
                redirectURI: provider.redirectURL,
                resource: resource,
                httpClient: http
            )
            var stamped = tokens
            stamped.issuer = issuer
            try await provider.saveTokens(stamped, context: context)
            return .authorized
        }

        // Refresh.
        var tokens = discardIfIssuerMismatch(try await provider.tokens(context), issuer: issuer)
        if var current = tokens, current.issuer == nil {
            current.issuer = issuer
            tokens = current
            try await provider.saveTokens(current, context: context)
        }
        if let refreshToken = tokens?.refreshToken, !options.forceReauthorization {
            do {
                var refreshed = try await refreshAuthorization(
                    authorizationServerURL: authorizationServerURL,
                    metadata: metadata,
                    client: client,
                    refreshToken: refreshToken,
                    resource: resource,
                    httpClient: http
                )
                refreshed.issuer = issuer
                try await provider.saveTokens(refreshed, context: context)
                return .authorized
            } catch MCPAuthError.insecureTokenEndpoint(let url) {
                throw MCPAuthError.insecureTokenEndpoint(url)
            } catch MCPAuthError.oauth(let error) where error.code != MCPOAuthErrorResponse.serverError {
                throw MCPAuthError.oauth(error)
            } catch {
                // A server error or a non-OAuth failure: an interactive run
                // falls through to a new authorization, as the TypeScript SDK
                // does; a background run reports it as the transient failure
                // it is.
                if !options.interactive {
                    throw MCPAuthError.requestFailed("Could not refresh OAuth tokens: \(MCPClient.describe(error))")
                }
            }
        }

        guard options.interactive else { return .authorizationRequired }

        // New authorization.
        let state = try await provider.state()
        let start = try startAuthorization(
            authorizationServerURL: authorizationServerURL,
            metadata: metadata,
            client: client,
            redirectURI: provider.redirectURL,
            scope: resolvedScope,
            state: state,
            resource: resource
        )
        try await provider.saveCodeVerifier(start.codeVerifier)
        try await provider.redirectToAuthorization(start.authorizationURL)
        return .redirect
    }

    // MARK: - Callback

    /// Finish an authorization from the callback's query parameters. Reads
    /// `code` and `iss`. A callback without a code is an error response:
    /// its `iss` is checked first, and only then is its `error` surfaced.
    /// The caller checks `state` before calling this.
    public static func finishAuthorization(
        _ provider: any MCPOAuthClientProvider,
        serverURL: URL,
        callbackParameters: [String: String],
        scope: String? = nil,
        resourceMetadataURL: URL? = nil,
        httpClient: any MCPAuthHTTPClient = URLSessionMCPAuthHTTPClient()
    ) async throws {
        let iss = callbackParameters["iss"]
        guard let code = callbackParameters["code"], !code.isEmpty else {
            var metadata = try await (provider as? any MCPOAuthDiscoveryStore)?.discoveryState()?.authorizationServerMetadata
            if metadata == nil {
                metadata = try? await discoverServerInfo(
                    serverURL: serverURL, resourceMetadataURL: resourceMetadataURL, httpClient: httpClient
                ).authorizationServerMetadata
            }
            guard let metadata else {
                throw MCPAuthError.unauthorized("Authorization callback failed and the issuer could not be verified")
            }
            try validateAuthorizationResponseIssuer(
                iss: iss,
                expectedIssuer: metadata.issuer,
                issParameterSupported: metadata.authorizationResponseIssParameterSupported == true
            )
            if let error = callbackParameters["error"] {
                throw MCPAuthError.oauth(MCPOAuthErrorResponse(
                    code: error,
                    description: callbackParameters["error_description"],
                    uri: callbackParameters["error_uri"]
                ))
            }
            throw MCPAuthError.unauthorized("Authorization callback contained neither code nor error")
        }
        let result = try await auth(provider, options: MCPOAuthOptions(
            serverURL: serverURL,
            authorizationCode: code,
            iss: iss,
            scope: scope,
            resourceMetadataURL: resourceMetadataURL,
            httpClient: httpClient
        ))
        guard result == .authorized else { throw MCPAuthError.unauthorized("Failed to authorize") }
    }

    // MARK: - Issuers

    /// RFC 9207 §2.4: with an advertised `iss` parameter, a missing or
    /// different `iss` is refused; without it, a present `iss` must still
    /// match. Simple string comparison.
    public static func validateAuthorizationResponseIssuer(
        iss: String?,
        expectedIssuer: String?,
        issParameterSupported: Bool
    ) throws {
        guard let expectedIssuer else { return }
        guard let iss else {
            if issParameterSupported {
                throw MCPAuthError.issuerMismatch(kind: "authorization response", expected: expectedIssuer, actual: nil)
            }
            return
        }
        guard iss == expectedIssuer else {
            throw MCPAuthError.issuerMismatch(kind: "authorization response", expected: expectedIssuer, actual: iss)
        }
    }

    /// Issuer identity tolerating one trailing `/` difference.
    static func issuersMatch(_ a: String, _ b: String) -> Bool {
        a == b || (a.hasSuffix("/") && String(a.dropLast()) == b) || (b.hasSuffix("/") && String(b.dropLast()) == a)
    }

    static func discardIfIssuerMismatch(_ stored: MCPOAuthClientInformation?, issuer: String) -> MCPOAuthClientInformation? {
        guard let stored else { return nil }
        guard let stamp = stored.issuer else { return stored }
        return issuersMatch(stamp, issuer) ? stored : nil
    }

    static func discardIfIssuerMismatch(_ stored: MCPOAuthTokens?, issuer: String) -> MCPOAuthTokens? {
        guard let stored else { return nil }
        guard let stamp = stored.issuer else { return stored }
        return issuersMatch(stamp, issuer) ? stored : nil
    }

    // MARK: - Scope

    /// MCP scope selection: the challenge's scope, else the protected
    /// resource's `scopes_supported`, else the client metadata's scope.
    /// `offline_access` is added when the authorization server offers it and
    /// the client registers the refresh_token grant (SEP-2207).
    public static func determineScope(
        requestedScope: String?,
        resourceMetadata: MCPProtectedResourceMetadata?,
        authorizationServerMetadata: MCPAuthorizationServerMetadata?,
        clientMetadata: MCPOAuthClientMetadata
    ) -> String? {
        var scope = nonEmpty(requestedScope)
            ?? nonEmpty(resourceMetadata?.scopesSupported?.joined(separator: " "))
            ?? nonEmpty(clientMetadata.scope)
        if let current = scope,
           authorizationServerMetadata?.scopesSupported?.contains("offline_access") == true,
           !current.split(separator: " ").contains("offline_access"),
           clientMetadata.grantTypes?.contains("refresh_token") == true {
            scope = current + " offline_access"
        }
        return scope
    }

    /// Distinct scope tokens of all inputs, in first-seen order.
    public static func scopeUnion(_ scopes: String?...) -> String? {
        var seen: [String] = []
        for scope in scopes {
            for token in (scope ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init) where !seen.contains(token) {
                seen.append(token)
            }
        }
        return seen.isEmpty ? nil : seen.joined(separator: " ")
    }

    /// Whether `union` has a scope token `current` lacks. An absent
    /// `current` is empty.
    public static func isStrictScopeSuperset(_ union: String?, of current: String?) -> Bool {
        guard let union, !union.isEmpty else { return false }
        let have = Set((current ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
        return union.split(whereSeparator: { $0.isWhitespace }).contains { !have.contains(String($0)) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    // MARK: - Resource

    /// The RFC 8707 resource indicator, as the string to send.
    static func selectResource(
        serverURL: URL,
        provider: any MCPOAuthClientProvider,
        resourceMetadata: MCPProtectedResourceMetadata?
    ) async throws -> String? {
        let defaultResource = resourceURL(fromServerURL: serverURL)
        if let validating = provider as? any MCPOAuthResourceValidation {
            return try await validating.validateResourceURL(serverURL: defaultResource, resource: resourceMetadata?.resource)?
                .absoluteString
        }
        guard let resourceMetadata else { return nil }
        guard let configured = URL(string: resourceMetadata.resource),
              checkResourceAllowed(requested: defaultResource, configured: configured)
        else {
            throw MCPAuthError.resourceMismatch(resource: resourceMetadata.resource, expected: defaultResource.absoluteString)
        }
        return resourceMetadata.resource
    }

    /// The server URL without its fragment.
    public static func resourceURL(fromServerURL url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    /// Same origin, and the requested path at or under the configured path.
    public static func checkResourceAllowed(requested: URL, configured: URL) -> Bool {
        guard MCPAuthHTTP.isSameOrigin(requested, configured) else { return false }
        let requestedPath = requested.path.isEmpty ? "/" : requested.path
        let configuredPath = configured.path.isEmpty ? "/" : configured.path
        guard requestedPath.count >= configuredPath.count else { return false }
        let a = requestedPath.hasSuffix("/") ? requestedPath : requestedPath + "/"
        let b = configuredPath.hasSuffix("/") ? configuredPath : configuredPath + "/"
        return a.hasPrefix(b)
    }

    // MARK: - Discovery

    /// RFC 9728 protected resource metadata: the given URL, else path-aware
    /// `/.well-known/oauth-protected-resource<path>`, falling back to the
    /// root. Throws when the server publishes none.
    public static func discoverProtectedResourceMetadata(
        serverURL: URL,
        resourceMetadataURL: URL? = nil,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPProtectedResourceMetadata {
        let response = try await discoverMetadataWithFallback(
            serverURL: serverURL,
            wellKnown: "oauth-protected-resource",
            metadataURL: resourceMetadataURL,
            httpClient: httpClient
        )
        guard let response, response.status != 404 else {
            throw MCPAuthError.requestFailed("Resource server does not implement OAuth 2.0 Protected Resource Metadata.")
        }
        guard response.isSuccess else {
            throw MCPAuthError.requestFailed("HTTP \(response.status) trying to load OAuth protected resource metadata.")
        }
        do {
            return try JSONDecoder().decode(MCPProtectedResourceMetadata.self, from: response.body)
        } catch {
            throw MCPAuthError.requestFailed("Invalid OAuth protected resource metadata: \(error)")
        }
    }

    private static func discoverMetadataWithFallback(
        serverURL: URL,
        wellKnown: String,
        metadataURL: URL?,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPAuthHTTPResponse? {
        let headers = [protocolVersionHeader: MCPClient.protocolVersion]
        if let metadataURL {
            return try await MCPAuthHTTP.send(MCPAuthHTTPRequest(url: metadataURL, headers: headers), using: httpClient)
        }
        var path = serverURL.path
        if path.hasSuffix("/") { path.removeLast() }
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/.well-known/\(wellKnown)\(path)"
        components.fragment = nil
        guard let pathAware = components.url else { return nil }
        let response = try await MCPAuthHTTP.send(MCPAuthHTTPRequest(url: pathAware, headers: headers), using: httpClient)
        let atRoot = path.isEmpty || path == "/"
        let shouldFallBack = !atRoot && ((!response.isSuccess && response.status < 500) || response.status == 502)
        guard shouldFallBack else { return response }
        components.path = "/.well-known/\(wellKnown)"
        components.query = nil
        guard let root = components.url else { return response }
        return try await MCPAuthHTTP.send(MCPAuthHTTPRequest(url: root, headers: headers), using: httpClient)
    }

    /// The URLs to try for authorization server metadata, in order: RFC 8414
    /// path insertion, then OIDC (path insertion, then path appending).
    public static func discoveryURLs(authorizationServerURL: String) -> [(url: URL, isOIDC: Bool)] {
        guard let url = URL(string: authorizationServerURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [] }
        components.query = nil
        components.fragment = nil
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        func at(_ newPath: String) -> URL? {
            var c = components
            c.path = newPath
            return c.url
        }
        if path.isEmpty {
            return [
                at("/.well-known/oauth-authorization-server").map { ($0, false) },
                at("/.well-known/openid-configuration").map { ($0, true) },
            ].compactMap { $0 }
        }
        return [
            at("/.well-known/oauth-authorization-server\(path)").map { ($0, false) },
            at("/.well-known/openid-configuration\(path)").map { ($0, true) },
            at("\(path)/.well-known/openid-configuration").map { ($0, true) },
        ].compactMap { $0 }
    }

    /// RFC 8414 / OIDC Discovery metadata of an authorization server, or nil
    /// when none is published. The document's `issuer` must equal
    /// `authorizationServerURL` (one trailing `/` tolerated) unless
    /// `skipIssuerValidation`.
    public static func discoverAuthorizationServerMetadata(
        _ authorizationServerURL: String,
        skipIssuerValidation: Bool = false,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPAuthorizationServerMetadata? {
        let headers = [protocolVersionHeader: MCPClient.protocolVersion, "Accept": "application/json"]
        for (url, isOIDC) in discoveryURLs(authorizationServerURL: authorizationServerURL) {
            let response = try await MCPAuthHTTP.send(MCPAuthHTTPRequest(url: url, headers: headers), using: httpClient)
            guard response.isSuccess else {
                if response.status < 500 || response.status == 502 { continue }
                throw MCPAuthError.requestFailed(
                    "HTTP \(response.status) trying to load \(isOIDC ? "OpenID provider" : "OAuth") metadata from \(url.absoluteString)"
                )
            }
            let metadata: MCPAuthorizationServerMetadata
            do {
                metadata = try JSONDecoder().decode(MCPAuthorizationServerMetadata.self, from: response.body)
            } catch {
                throw MCPAuthError.requestFailed("Invalid authorization server metadata from \(url.absoluteString): \(error)")
            }
            if !skipIssuerValidation {
                let expected = authorizationServerURL
                let matches = metadata.issuer == expected
                    || (expected.hasSuffix("/") && metadata.issuer == String(expected.dropLast()))
                guard matches else {
                    throw MCPAuthError.issuerMismatch(kind: "metadata", expected: expected, actual: metadata.issuer)
                }
            }
            return metadata
        }
        return nil
    }

    /// Find the authorization server of an MCP server: RFC 9728 first, else
    /// the server's origin as the authorization server (legacy fallback).
    public static func discoverServerInfo(
        serverURL: URL,
        resourceMetadataURL: URL? = nil,
        skipIssuerMetadataValidation: Bool = false,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthServerInfo {
        var resourceMetadata: MCPProtectedResourceMetadata?
        var authorizationServerURL: String?
        do {
            let found = try await discoverProtectedResourceMetadata(
                serverURL: serverURL,
                resourceMetadataURL: resourceMetadataURL,
                httpClient: httpClient
            )
            resourceMetadata = found
            authorizationServerURL = found.authorizationServers?.first
        } catch let error as MCPAuthError {
            // No protected resource metadata: fall back below. Transport
            // failures (URLError) propagate.
            _ = error
        }
        if authorizationServerURL == nil {
            var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
            components?.path = "/"
            components?.query = nil
            components?.fragment = nil
            authorizationServerURL = components?.url?.absoluteString ?? serverURL.absoluteString
        }
        let server = authorizationServerURL ?? serverURL.absoluteString
        let metadata = try await discoverAuthorizationServerMetadata(
            server,
            skipIssuerValidation: skipIssuerMetadataValidation,
            httpClient: httpClient
        )
        return MCPOAuthServerInfo(
            authorizationServerURL: server,
            authorizationServerMetadata: metadata,
            resourceMetadata: resourceMetadata
        )
    }

    // MARK: - Client metadata and registration

    /// The provider's client metadata with the defaults the flow relies on:
    /// `grant_types` `authorization_code` + `refresh_token` (SEP-2207) and
    /// `application_type` from the redirect URIs (SEP-837). Values the
    /// provider set are kept.
    public static func resolveClientMetadata(_ provider: any MCPOAuthClientProvider) -> MCPOAuthClientMetadata {
        var metadata = provider.clientMetadata
        if metadata.grantTypes == nil { metadata.grantTypes = ["authorization_code", "refresh_token"] }
        if metadata.applicationType == nil { metadata.applicationType = applicationType(for: metadata.redirectURIs) }
        return metadata
    }

    static func applicationType(for redirectURIs: [String]) -> String {
        for raw in redirectURIs {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { continue }
            if scheme != "http" && scheme != "https" { return "native" }
            if isLoopbackHost(url.host) { return "native" }
        }
        return "web"
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func isHTTPSURLWithPath(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !url.path.isEmpty && url.path != "/"
    }

    /// RFC 7591 dynamic client registration.
    public static func registerClient(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        clientMetadata: MCPOAuthClientMetadata,
        scope: String?,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthClientInformation {
        let endpoint: URL
        if let metadata {
            guard let registration = metadata.registrationEndpoint, let url = URL(string: registration) else {
                throw MCPAuthError.incompatibleServer("does not support dynamic client registration")
            }
            endpoint = url
        } else {
            guard let url = URL(string: "/register", relativeTo: URL(string: authorizationServerURL))?.absoluteURL else {
                throw MCPAuthError.incompatibleServer("invalid authorization server URL \(authorizationServerURL)")
            }
            endpoint = url
        }
        var submitted = clientMetadata
        if let scope { submitted.scope = scope }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let response = try await MCPAuthHTTP.send(MCPAuthHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: try encoder.encode(submitted)
        ), using: httpClient)
        guard response.isSuccess else {
            throw MCPAuthError.registrationRejected(status: response.status, body: response.text)
        }
        do {
            var information = try JSONDecoder().decode(MCPOAuthClientInformation.self, from: response.body)
            // Only the client stamps the issuer.
            information.issuer = nil
            return information
        } catch {
            throw MCPAuthError.requestFailed("Invalid client registration response: \(error)")
        }
    }

    // MARK: - Authorization request

    /// Build the authorization URL with a fresh PKCE challenge.
    public static func startAuthorization(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        client: MCPOAuthClientInformation,
        redirectURI: URL,
        scope: String?,
        state: String?,
        resource: String?
    ) throws -> (authorizationURL: URL, codeVerifier: String) {
        let endpoint: URL
        if let metadata {
            guard metadata.responseTypesSupported.contains("code") else {
                throw MCPAuthError.incompatibleServer("does not support response type code")
            }
            if let methods = metadata.codeChallengeMethodsSupported, !methods.contains("S256") {
                throw MCPAuthError.incompatibleServer("does not support code challenge method S256")
            }
            guard let url = URL(string: metadata.authorizationEndpoint) else {
                throw MCPAuthError.incompatibleServer("invalid authorization endpoint \(metadata.authorizationEndpoint)")
            }
            endpoint = url
        } else {
            guard let url = URL(string: "/authorize", relativeTo: URL(string: authorizationServerURL))?.absoluteURL else {
                throw MCPAuthError.incompatibleServer("invalid authorization server URL \(authorizationServerURL)")
            }
            endpoint = url
        }
        let pkce = PKCE.random()
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MCPAuthError.incompatibleServer("invalid authorization endpoint \(endpoint.absoluteString)")
        }
        var items = (components.queryItems ?? []).filter {
            !["response_type", "client_id", "code_challenge", "code_challenge_method", "redirect_uri", "state", "scope", "resource"]
                .contains($0.name)
        }
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "client_id", value: client.clientID))
        items.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        items.append(URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString))
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        if scope?.split(separator: " ").contains("offline_access") == true {
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        components.percentEncodedQuery = items.map { item in
            "\(MCPAuthHTTP.formEncode(item.name))=\(MCPAuthHTTP.formEncode(item.value ?? ""))"
        }.joined(separator: "&")
        guard let url = components.url else {
            throw MCPAuthError.incompatibleServer("could not build the authorization URL")
        }
        return (url, pkce.verifier)
    }

    // MARK: - Token requests

    /// Exchange an authorization code (after checking `iss` per RFC 9207).
    public static func exchangeAuthorization(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        client: MCPOAuthClientInformation,
        code: String,
        codeVerifier: String,
        redirectURI: URL,
        resource: String?,
        iss: String? = nil,
        validateIssuer: Bool = false,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthTokens {
        if validateIssuer {
            try validateAuthorizationResponseIssuer(
                iss: iss,
                expectedIssuer: metadata?.issuer,
                issParameterSupported: metadata?.authorizationResponseIssParameterSupported == true
            )
        }
        return try await tokenRequest(
            authorizationServerURL: authorizationServerURL,
            metadata: metadata,
            client: client,
            parameters: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("code_verifier", codeVerifier),
                ("redirect_uri", redirectURI.absoluteString),
            ],
            resource: resource,
            httpClient: httpClient
        )
    }

    /// Refresh. A response without a new refresh token keeps the old one.
    public static func refreshAuthorization(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        client: MCPOAuthClientInformation,
        refreshToken: String,
        resource: String?,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthTokens {
        var tokens = try await tokenRequest(
            authorizationServerURL: authorizationServerURL,
            metadata: metadata,
            client: client,
            parameters: [("grant_type", "refresh_token"), ("refresh_token", refreshToken)],
            resource: resource,
            httpClient: httpClient
        )
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        return tokens
    }

    /// The token endpoint authentication method: the one assigned at
    /// registration when the server supports it, else `client_secret_basic`,
    /// `client_secret_post`, then `none`.
    public static func selectClientAuthMethod(client: MCPOAuthClientInformation, supportedMethods: [String]) -> String {
        let known = ["client_secret_basic", "client_secret_post", "none"]
        let hasSecret = client.clientSecret != nil
        if let assigned = client.tokenEndpointAuthMethod, known.contains(assigned),
           supportedMethods.isEmpty || supportedMethods.contains(assigned) {
            return assigned
        }
        if supportedMethods.isEmpty { return hasSecret ? "client_secret_basic" : "none" }
        if hasSecret && supportedMethods.contains("client_secret_basic") { return "client_secret_basic" }
        if hasSecret && supportedMethods.contains("client_secret_post") { return "client_secret_post" }
        if supportedMethods.contains("none") { return "none" }
        return hasSecret ? "client_secret_post" : "none"
    }

    /// Refuse non-TLS token endpoints, except loopback hosts.
    public static func assertSecureTokenEndpoint(_ url: URL) throws {
        if url.scheme?.lowercased() != "https" && !isLoopbackHost(url.host) {
            throw MCPAuthError.insecureTokenEndpoint(url.absoluteString)
        }
    }

    private static func tokenRequest(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        client: MCPOAuthClientInformation,
        parameters: [(String, String)],
        resource: String?,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthTokens {
        let endpoint: URL
        if let metadata, let url = URL(string: metadata.tokenEndpoint) {
            endpoint = url
        } else if let url = URL(string: "/token", relativeTo: URL(string: authorizationServerURL))?.absoluteURL {
            endpoint = url
        } else {
            throw MCPAuthError.incompatibleServer("invalid token endpoint")
        }
        try assertSecureTokenEndpoint(endpoint)
        var form = parameters
        if let resource { form.append(("resource", resource)) }
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"]
        let method = selectClientAuthMethod(client: client, supportedMethods: metadata?.tokenEndpointAuthMethodsSupported ?? [])
        switch method {
        case "client_secret_basic":
            guard let secret = client.clientSecret else {
                throw MCPAuthError.providerMisconfigured("client_secret_basic authentication requires a client_secret")
            }
            let credentials = "\(basicEncode(client.clientID)):\(basicEncode(secret))"
            headers["Authorization"] = "Basic " + Data(credentials.utf8).base64EncodedString()
        case "client_secret_post":
            form.append(("client_id", client.clientID))
            if let secret = client.clientSecret { form.append(("client_secret", secret)) }
        default:
            form.append(("client_id", client.clientID))
        }
        let response = try await MCPAuthHTTP.send(MCPAuthHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: headers,
            body: MCPAuthHTTP.formBody(form)
        ), using: httpClient)
        guard response.isSuccess else {
            throw MCPAuthError.oauth(parseErrorResponse(response))
        }
        if let tokens = try? JSONDecoder().decode(MCPOAuthTokens.self, from: response.body) {
            var result = tokens
            result.issuer = nil
            result.expiresAt = tokens.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            return result
        }
        // Some servers answer errors with HTTP 200.
        if let json = try? JSONDecoder().decode(JSONValue.self, from: response.body), json["error"] != nil {
            throw MCPAuthError.oauth(parseErrorResponse(response))
        }
        throw MCPAuthError.requestFailed("Invalid token response: \(response.text.prefix(500))")
    }

    /// RFC 6749 §2.3.1: client credentials are form-encoded before Basic.
    private static func basicEncode(_ value: String) -> String {
        MCPAuthHTTP.formEncode(value)
    }

    static func parseErrorResponse(_ response: MCPAuthHTTPResponse) -> MCPOAuthErrorResponse {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: response.body),
           case .string(let code)? = json["error"] {
            return MCPOAuthErrorResponse(
                code: code,
                description: json["error_description"]?.mcpString,
                uri: json["error_uri"]?.mcpString,
                status: response.status
            )
        }
        return MCPOAuthErrorResponse(
            code: MCPOAuthErrorResponse.serverError,
            description: "HTTP \(response.status): \(response.text.prefix(500))",
            status: response.status
        )
    }
}
