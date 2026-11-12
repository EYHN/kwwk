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
        httpClient: any MCPAuthHTTPClient = URLSessionMCPAuthHTTPClient.shared
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
    public static func auth(
        _ provider: any MCPOAuthClientProvider,
        options: MCPOAuthOptions
    ) async throws -> MCPOAuthResult {
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

    private static func invalidate(
        _ provider: any MCPOAuthClientProvider,
        _ scope: MCPOAuthCredentialScope
    ) async throws {
        try await (provider as? any MCPOAuthCredentialInvalidation)?.invalidateCredentials(scope)
    }

    private static func authInternal(
        _ provider: any MCPOAuthClientProvider,
        options: MCPOAuthOptions
    ) async throws -> MCPOAuthResult {
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
        let resource = try await selectResource(
            serverURL: options.serverURL,
            provider: provider,
            resourceMetadata: resourceMetadata
        )

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
        if client == nil {
            guard options.interactive else { return .authorizationRequired }
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
        httpClient: any MCPAuthHTTPClient = URLSessionMCPAuthHTTPClient.shared
    ) async throws {
        let iss = callbackParameters["iss"]
        guard let code = callbackParameters["code"], !code.isEmpty else {
            var metadata = try await (provider as? any MCPOAuthDiscoveryStore)?.discoveryState()?
                .authorizationServerMetadata
            if metadata == nil {
                metadata = try? await discoverServerInfo(
                    serverURL: serverURL,
                    resourceMetadataURL: resourceMetadataURL,
                    httpClient: httpClient
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

    static func discardIfIssuerMismatch(
        _ stored: MCPOAuthClientInformation?,
        issuer: String
    ) -> MCPOAuthClientInformation? {
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
            return try await validating.validateResourceURL(
                serverURL: defaultResource,
                resource: resourceMetadata?.resource
            )?.absoluteString
        }
        guard let resourceMetadata else { return nil }
        guard let configured = URL(string: resourceMetadata.resource),
              checkResourceAllowed(requested: defaultResource, configured: configured)
        else {
            throw MCPAuthError.resourceMismatch(
                resource: resourceMetadata.resource,
                expected: defaultResource.absoluteString
            )
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
}
