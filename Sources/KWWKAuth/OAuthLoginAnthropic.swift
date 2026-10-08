import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Claude uses the same host-supplied browser and loopback as the other
// providers. The CLI supplies NIO; an embedding app supplies its own listener.
extension OAuthLogin {
    // MARK: - Anthropic

    public static func loginAnthropic(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let provider = AnthropicOAuthProvider()
        let server = try await openLoopback(callbacks, port: 53692)
        defer { server.stop() }

        let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
        let redirect = server.redirectURI
        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.verifier),
        ]

        callbacks.onProgress("waiting for Anthropic callback on \(redirect)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "anthropic")
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("anthropic callback had no code")
        }
        guard params["state"] == pkce.verifier else {
            throw OAuthError.invalidResponse("anthropic OAuth state mismatch")
        }

        callbacks.onProgress("exchanging authorization code…")
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": provider.clientID,
            "code": code,
            "state": pkce.verifier,
            "redirect_uri": redirect,
            "code_verifier": pkce.verifier,
        ]
        let response = try await postJSON(
            url: provider.tokenURL,
            body: body,
            client: client
        )
        guard !response.accessToken.isEmpty,
              let refresh = response.refreshToken, !refresh.isEmpty else {
            throw OAuthError.invalidResponse("anthropic token response missing credentials")
        }
        return credentials(from: response, fallbackRefresh: refresh)
    }
}
