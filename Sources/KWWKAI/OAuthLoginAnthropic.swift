import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The Anthropic sign-in stays beside the NIO callback server it binds; the
// other provider flows live in `KWWKAuth` with an injectable loopback.
extension OAuthLogin {
    // MARK: - Anthropic

    public static func loginAnthropic(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let port: UInt16 = 53692
        let server = try OAuthCallbackServer(port: port)
        defer { server.stop() }

        let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
        let redirect = server.redirectURI
        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.verifier),
        ]

        callbacks.onAuthURL(comps.url!)
        callbacks.onProgress("waiting for Anthropic callback on \(redirect)…")

        let params = try await server.waitForCallback()
        guard let code = params["code"] else {
            throw OAuthError.invalidResponse("anthropic callback had no code")
        }
        let state = params["state"]
        if let state, state != pkce.verifier {
            throw OAuthError.invalidResponse("anthropic OAuth state mismatch")
        }

        callbacks.onProgress("exchanging authorization code…")
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "code": code,
            "state": state ?? pkce.verifier,
            "redirect_uri": redirect,
            "code_verifier": pkce.verifier,
        ]
        let response = try await postJSON(
            url: URL(string: "https://platform.claude.com/v1/oauth/token")!,
            body: body,
            client: client
        )
        return credentials(from: response, fallbackRefresh: nil)
    }
}
