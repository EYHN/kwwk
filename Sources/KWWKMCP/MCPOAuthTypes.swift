import Foundation

// Wire types of the MCP authorization flow (MCP 2025-11-25 "Authorization",
// RFC 6749, RFC 7591, RFC 8414, RFC 9728). Field names follow the wire
// format; unknown fields are kept in `extra` where the document is stored
// back (client information, tokens) so a round trip loses nothing.

/// RFC 9728 OAuth 2.0 Protected Resource Metadata.
public struct MCPProtectedResourceMetadata: Sendable, Hashable, Codable {
    public var resource: String
    public var authorizationServers: [String]?
    public var scopesSupported: [String]?
    public var bearerMethodsSupported: [String]?
    public var resourceName: String?
    public var resourceDocumentation: String?

    public init(
        resource: String,
        authorizationServers: [String]? = nil,
        scopesSupported: [String]? = nil,
        bearerMethodsSupported: [String]? = nil,
        resourceName: String? = nil,
        resourceDocumentation: String? = nil
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
        self.bearerMethodsSupported = bearerMethodsSupported
        self.resourceName = resourceName
        self.resourceDocumentation = resourceDocumentation
    }

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case bearerMethodsSupported = "bearer_methods_supported"
        case resourceName = "resource_name"
        case resourceDocumentation = "resource_documentation"
    }
}

/// RFC 8414 Authorization Server Metadata (or the OIDC Discovery document,
/// which carries the same fields).
public struct MCPAuthorizationServerMetadata: Sendable, Hashable, Codable {
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var registrationEndpoint: String?
    public var revocationEndpoint: String?
    public var scopesSupported: [String]?
    public var responseTypesSupported: [String]
    public var grantTypesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?
    public var tokenEndpointAuthMethodsSupported: [String]?
    public var clientIDMetadataDocumentSupported: Bool?
    public var authorizationResponseIssParameterSupported: Bool?

    public init(
        issuer: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        registrationEndpoint: String? = nil,
        revocationEndpoint: String? = nil,
        scopesSupported: [String]? = nil,
        responseTypesSupported: [String] = ["code"],
        grantTypesSupported: [String]? = nil,
        codeChallengeMethodsSupported: [String]? = nil,
        tokenEndpointAuthMethodsSupported: [String]? = nil,
        clientIDMetadataDocumentSupported: Bool? = nil,
        authorizationResponseIssParameterSupported: Bool? = nil
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.scopesSupported = scopesSupported
        self.responseTypesSupported = responseTypesSupported
        self.grantTypesSupported = grantTypesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.tokenEndpointAuthMethodsSupported = tokenEndpointAuthMethodsSupported
        self.clientIDMetadataDocumentSupported = clientIDMetadataDocumentSupported
        self.authorizationResponseIssParameterSupported = authorizationResponseIssParameterSupported
    }

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case scopesSupported = "scopes_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case clientIDMetadataDocumentSupported = "client_id_metadata_document_supported"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issuer = try c.decode(String.self, forKey: .issuer)
        authorizationEndpoint = try c.decode(String.self, forKey: .authorizationEndpoint)
        tokenEndpoint = try c.decode(String.self, forKey: .tokenEndpoint)
        registrationEndpoint = try c.decodeIfPresent(String.self, forKey: .registrationEndpoint)
        revocationEndpoint = try c.decodeIfPresent(String.self, forKey: .revocationEndpoint)
        scopesSupported = try c.decodeIfPresent([String].self, forKey: .scopesSupported)
        // OIDC providers always publish it; RFC 8414 makes it required. Be
        // lenient with documents that omit it and assume the code flow.
        responseTypesSupported = try c.decodeIfPresent([String].self, forKey: .responseTypesSupported) ?? ["code"]
        grantTypesSupported = try c.decodeIfPresent([String].self, forKey: .grantTypesSupported)
        codeChallengeMethodsSupported = try c.decodeIfPresent([String].self, forKey: .codeChallengeMethodsSupported)
        tokenEndpointAuthMethodsSupported = try c.decodeIfPresent([String].self, forKey: .tokenEndpointAuthMethodsSupported)
        // Only a literal boolean counts.
        clientIDMetadataDocumentSupported = try? c.decodeIfPresent(Bool.self, forKey: .clientIDMetadataDocumentSupported)
        authorizationResponseIssParameterSupported = try? c.decodeIfPresent(
            Bool.self, forKey: .authorizationResponseIssParameterSupported
        )
    }
}

/// RFC 7591 client metadata, as registered (or as published at a client ID
/// metadata document URL).
public struct MCPOAuthClientMetadata: Sendable, Hashable, Codable {
    public var redirectURIs: [String]
    public var clientName: String?
    public var clientURI: String?
    public var logoURI: String?
    public var scope: String?
    public var grantTypes: [String]?
    public var responseTypes: [String]?
    public var tokenEndpointAuthMethod: String?
    /// OIDC `application_type` (`native` or `web`).
    public var applicationType: String?
    public var softwareID: String?
    public var softwareVersion: String?

    public init(
        redirectURIs: [String],
        clientName: String? = nil,
        clientURI: String? = nil,
        logoURI: String? = nil,
        scope: String? = nil,
        grantTypes: [String]? = nil,
        responseTypes: [String]? = ["code"],
        tokenEndpointAuthMethod: String? = "none",
        applicationType: String? = nil,
        softwareID: String? = nil,
        softwareVersion: String? = nil
    ) {
        self.redirectURIs = redirectURIs
        self.clientName = clientName
        self.clientURI = clientURI
        self.logoURI = logoURI
        self.scope = scope
        self.grantTypes = grantTypes
        self.responseTypes = responseTypes
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
        self.applicationType = applicationType
        self.softwareID = softwareID
        self.softwareVersion = softwareVersion
    }

    enum CodingKeys: String, CodingKey {
        case redirectURIs = "redirect_uris"
        case clientName = "client_name"
        case clientURI = "client_uri"
        case logoURI = "logo_uri"
        case scope
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case applicationType = "application_type"
        case softwareID = "software_id"
        case softwareVersion = "software_version"
    }
}

/// What the client knows about its registration with one authorization
/// server: the client ID (and secret) plus what the server echoed back.
public struct MCPOAuthClientInformation: Sendable, Hashable, Codable {
    public var clientID: String
    public var clientSecret: String?
    public var clientIDIssuedAt: Int?
    public var clientSecretExpiresAt: Int?
    /// The method the server assigned at registration, if it said.
    public var tokenEndpointAuthMethod: String?
    /// SEP-2352 binding: the issuer this client ID belongs to. Set by
    /// `MCPOAuth.auth`; providers store it as part of the value.
    public var issuer: String?

    public init(
        clientID: String,
        clientSecret: String? = nil,
        clientIDIssuedAt: Int? = nil,
        clientSecretExpiresAt: Int? = nil,
        tokenEndpointAuthMethod: String? = nil,
        issuer: String? = nil
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.clientIDIssuedAt = clientIDIssuedAt
        self.clientSecretExpiresAt = clientSecretExpiresAt
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
        self.issuer = issuer
    }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case clientIDIssuedAt = "client_id_issued_at"
        case clientSecretExpiresAt = "client_secret_expires_at"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case issuer
    }
}

/// An OAuth token response (RFC 6749 §5.1), as stored.
public struct MCPOAuthTokens: Sendable, Hashable, Codable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: Int?
    public var refreshToken: String?
    public var scope: String?
    public var idToken: String?
    /// When the access token expires, computed from `expires_in` when the
    /// tokens were received. Not part of the wire format.
    public var expiresAt: Date?
    /// SEP-2352 binding: the issuer that minted these tokens.
    public var issuer: String?

    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        expiresIn: Int? = nil,
        refreshToken: String? = nil,
        scope: String? = nil,
        idToken: String? = nil,
        expiresAt: Date? = nil,
        issuer: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.issuer = issuer
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case idToken = "id_token"
        case expiresAt = "expires_at"
        case issuer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        // Some servers send `expires_in` as a string.
        if let seconds = try? c.decodeIfPresent(Int.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .expiresIn) {
            expiresIn = Int(text)
        } else {
            expiresIn = nil
        }
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        idToken = try c.decodeIfPresent(String.self, forKey: .idToken)
        expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer)
    }
}

/// Discovery results a provider may persist so the callback leg and later
/// runs reuse them (and so the callback is bound to the authorization server
/// the user actually approved at).
public struct MCPOAuthDiscoveryState: Sendable, Hashable, Codable {
    public var authorizationServerURL: String
    public var resourceMetadataURL: String?
    public var resourceMetadata: MCPProtectedResourceMetadata?
    public var authorizationServerMetadata: MCPAuthorizationServerMetadata?

    public init(
        authorizationServerURL: String,
        resourceMetadataURL: String? = nil,
        resourceMetadata: MCPProtectedResourceMetadata? = nil,
        authorizationServerMetadata: MCPAuthorizationServerMetadata? = nil
    ) {
        self.authorizationServerURL = authorizationServerURL
        self.resourceMetadataURL = resourceMetadataURL
        self.resourceMetadata = resourceMetadata
        self.authorizationServerMetadata = authorizationServerMetadata
    }

    enum CodingKeys: String, CodingKey {
        case authorizationServerURL = "authorization_server_url"
        case resourceMetadataURL = "resource_metadata_url"
        case resourceMetadata = "resource_metadata"
        case authorizationServerMetadata = "authorization_server_metadata"
    }
}

/// Parameters of a `WWW-Authenticate` challenge (`Bearer` or `DPoP`).
public struct MCPAuthChallenge: Sendable, Hashable {
    public var resourceMetadataURL: URL?
    public var scope: String?
    public var error: String?
    public var errorDescription: String?

    public init(
        resourceMetadataURL: URL? = nil,
        scope: String? = nil,
        error: String? = nil,
        errorDescription: String? = nil
    ) {
        self.resourceMetadataURL = resourceMetadataURL
        self.scope = scope
        self.error = error
        self.errorDescription = errorDescription
    }

    /// Parse a `WWW-Authenticate` header value. Unknown schemes yield an
    /// empty challenge.
    public init(header: String?) {
        self.init()
        guard let header else { return }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let scheme = trimmed.split(separator: " ", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        guard scheme == "bearer" || scheme == "dpop", trimmed.contains(" ") else { return }
        if let value = Self.parameter("resource_metadata", in: trimmed) {
            resourceMetadataURL = URL(string: value)
        }
        scope = Self.parameter("scope", in: trimmed)
        error = Self.parameter("error", in: trimmed)
        errorDescription = Self.parameter("error_description", in: trimmed)
    }

    /// `name="value"` or `name=value` from an auth-param list.
    static func parameter(_ name: String, in header: String) -> String? {
        var searchStart = header.startIndex
        while let range = header.range(of: "\(name)=", range: searchStart..<header.endIndex) {
            searchStart = range.upperBound
            // The name must start a parameter: preceded by start, space or comma.
            if range.lowerBound != header.startIndex {
                let before = header[header.index(before: range.lowerBound)]
                guard before == " " || before == "," || before == "\t" else { continue }
            }
            var index = range.upperBound
            guard index < header.endIndex else { return nil }
            if header[index] == "\"" {
                index = header.index(after: index)
                var value = ""
                while index < header.endIndex, header[index] != "\"" {
                    if header[index] == "\\" {
                        index = header.index(after: index)
                        guard index < header.endIndex else { break }
                    }
                    value.append(header[index])
                    index = header.index(after: index)
                }
                return value.isEmpty ? nil : value
            }
            let end = header[index...].firstIndex { $0 == "," || $0 == " " } ?? header.endIndex
            let value = String(header[index..<end])
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// An OAuth error response (RFC 6749 §5.2).
public struct MCPOAuthErrorResponse: Error, LocalizedError, Sendable, Hashable {
    public var code: String
    public var description: String?
    public var uri: String?
    /// The HTTP status, when the error came from an HTTP response.
    public var status: Int?

    public init(code: String, description: String? = nil, uri: String? = nil, status: Int? = nil) {
        self.code = code
        self.description = description
        self.uri = uri
        self.status = status
    }

    public var errorDescription: String? {
        if let description, !description.isEmpty { return "OAuth error \(code): \(description)" }
        return "OAuth error \(code)"
    }

    public static let invalidClient = "invalid_client"
    public static let unauthorizedClient = "unauthorized_client"
    public static let invalidGrant = "invalid_grant"
    public static let serverError = "server_error"
    public static let invalidClientMetadata = "invalid_client_metadata"
}

/// Failures of the MCP authorization flow.
public enum MCPAuthError: Error, LocalizedError, Sendable, Equatable {
    /// The server needs authorization the client could not obtain without a
    /// person (no provider, no refresh possible, or the user must sign in).
    case unauthorized(String?)
    /// The server still answered 401 after the provider refreshed.
    case unauthorizedAfterRetry
    /// The server answered 403 `insufficient_scope` and step-up was not
    /// possible or did not help.
    case insufficientScope(requiredScope: String?, description: String?)
    /// An issuer did not match (RFC 8414 §3.3 metadata echo, or RFC 9207
    /// authorization response `iss`).
    case issuerMismatch(kind: String, expected: String, actual: String?)
    /// The callback leg resolved a different authorization server than the
    /// one the authorization request went to (SEP-2352).
    case authorizationServerMismatch(expected: String, actual: String)
    /// Credentials would be sent to a non-TLS token endpoint.
    case insecureTokenEndpoint(String)
    /// Dynamic client registration was refused.
    case registrationRejected(status: Int, body: String)
    /// The authorization server cannot be used (missing endpoint, no PKCE S256, ...).
    case incompatibleServer(String)
    /// The protected resource metadata names a different resource.
    case resourceMismatch(resource: String, expected: String)
    /// A required provider capability is missing (e.g. saving client
    /// information for dynamic registration).
    case providerMisconfigured(String)
    /// The token endpoint answered with an OAuth error.
    case oauth(MCPOAuthErrorResponse)
    /// A metadata or token request failed below OAuth (HTTP, decoding).
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            return message ?? "MCP server requires authorization"
        case .unauthorizedAfterRetry:
            return "MCP server rejected the credentials again after re-authentication"
        case .insufficientScope(let scope, let description):
            var text = "MCP server requires more authorization"
            if let scope, !scope.isEmpty { text += " (scope: \(scope))" }
            if let description, !description.isEmpty { text += ": \(description)" }
            return text
        case .issuerMismatch(let kind, let expected, let actual):
            return "OAuth issuer mismatch in \(kind): expected \(expected), got \(actual ?? "none")"
        case .authorizationServerMismatch(let expected, let actual):
            return "OAuth authorization server changed during the flow: expected \(expected), got \(actual)"
        case .insecureTokenEndpoint(let url):
            return "Refusing to send credentials to non-TLS token endpoint \(url)"
        case .registrationRejected(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "OAuth dynamic client registration rejected (HTTP \(status))" + (trimmed.isEmpty ? "" : ": \(trimmed)")
        case .incompatibleServer(let message):
            return "Incompatible authorization server: \(message)"
        case .resourceMismatch(let resource, let expected):
            return "Protected resource \(resource) does not match expected \(expected)"
        case .providerMisconfigured(let message):
            return message
        case .oauth(let error):
            return error.errorDescription
        case .requestFailed(let message):
            return message
        }
    }

    /// Whether this error means a person has to (re)authorize.
    public var requiresAuthorization: Bool {
        switch self {
        case .unauthorized, .unauthorizedAfterRetry, .insufficientScope: return true
        default: return false
        }
    }
}
