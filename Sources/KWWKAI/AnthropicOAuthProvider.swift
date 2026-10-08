import Foundation

// MARK: - Anthropic

public struct AnthropicOAuthProvider: OAuthProvider {
    public let id = "anthropic"
    public let name = "Anthropic (Claude Pro/Max)"
    public let tokenURL: URL
    public let clientID: String

    public init(
        tokenURL: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
        clientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
    }

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": credentials.refresh,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (response, responseBody) = try await client.request(
            url: tokenURL, method: "POST",
            headers: ["content-type": "application/json", "accept": "application/json"],
            body: bodyData
        )
        if response.statusCode >= 400 {
            let bodyText = String(data: responseBody, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("anthropic \(response.statusCode): \(bodyText)")
        }
        let json = try OAuth.decodeTokenResponse(responseBody)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - 5 * 60 * 1000,
            extras: credentials.extras
        )
    }
}
