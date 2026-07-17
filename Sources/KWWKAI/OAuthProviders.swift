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

// MARK: - OpenAI Codex

public struct OpenAICodexOAuthProvider: OAuthProvider {
    public let id = "openai-codex"
    public let name = "ChatGPT Plus/Pro (Codex Subscription)"
    public let tokenURL: URL
    public let clientID: String

    public init(
        tokenURL: URL = URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann"
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
    }

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let form = OAuth.urlEncodedForm([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refresh,
            "client_id": clientID,
        ])
        let (response, responseBody) = try await client.request(
            url: tokenURL, method: "POST",
            headers: [
                "content-type": "application/x-www-form-urlencoded",
                "accept": "application/json",
            ],
            body: Data(form.utf8)
        )
        if response.statusCode >= 400 {
            let bodyText = String(data: responseBody, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("openai-codex \(response.statusCode): \(bodyText)")
        }
        let json = try OAuth.decodeTokenResponse(responseBody)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var extras = credentials.extras
        if let accountId = Self.extractAccountId(fromJWT: json.accessToken) {
            extras["accountId"] = .string(accountId)
        }
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - 5 * 60 * 1000,
            extras: extras
        )
    }

    /// Extract the ChatGPT account id from the access token JWT claim. Codex
    /// requests route by account id, so we cache it on refresh.
    static func extractAccountId(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])
        var padded = payload
        while padded.count % 4 != 0 { padded.append("=") }
        let urlSafe = padded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: urlSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Claim path used by pi: "https://api.openai.com/auth".chatgpt_account_id
        if let claim = obj["https://api.openai.com/auth"] as? [String: Any],
           let id = claim["chatgpt_account_id"] as? String {
            return id
        }
        return nil
    }
}

// MARK: - GitHub Copilot

public struct GitHubCopilotOAuthProvider: OAuthProvider {
    public let id = "github-copilot"
    public let name = "GitHub Copilot"
    public let tokenURL: URL
    public let extraHeaders: [String: String]

    public init(
        tokenURL: URL = URL(string: "https://api.github.com/copilot_internal/v2/token")!,
        extraHeaders: [String: String] = [
            "editor-version": "vscode/1.107.0",
            "editor-plugin-version": "copilot-chat/0.35.0",
            "user-agent": "GitHubCopilotChat/0.35.0",
            "copilot-integration-id": "vscode-chat",
        ]
    ) {
        self.tokenURL = tokenURL
        self.extraHeaders = extraHeaders
    }

    /// Copilot doesn't do standard OAuth token refresh — instead the stored
    /// `refresh` is a long-lived GitHub PAT that we exchange for a short
    /// session token on every request. The session token is cached as
    /// `access` until it expires.
    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        var headers: [String: String] = [
            "accept": "application/json",
            "authorization": "Bearer \(credentials.refresh)",
        ]
        for (k, v) in extraHeaders { headers[k] = v }
        let (response, body) = try await client.request(
            url: tokenURL, method: "GET", headers: headers, body: nil
        )
        if response.statusCode >= 400 {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("github-copilot \(response.statusCode): \(text)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = obj["token"] as? String else {
            throw OAuthError.invalidResponse("github-copilot response missing token")
        }
        // `expires_at` is Unix seconds. Refresh 5 minutes early.
        let expiresAtSec: Int64 = {
            if let v = obj["expires_at"] as? Int { return Int64(v) }
            if let v = obj["expires_at"] as? Int64 { return v }
            if let v = obj["expires_at"] as? Double { return Int64(v) }
            return Int64(Date().timeIntervalSince1970) + 25 * 60
        }()
        var extras = credentials.extras
        if let endpoints = obj["endpoints"] as? [String: Any],
           let api = endpoints["api"] as? String {
            extras["endpoint"] = .string(api)
        }
        return OAuthCredentials(
            access: token,
            refresh: credentials.refresh,
            expires: expiresAtSec * 1000 - 5 * 60 * 1000,
            extras: extras
        )
    }
}

// MARK: - Cursor
//
// Cursor's subscription auth is a browser PKCE poll flow (see
// `OAuthLogin.loginCursor`). Tokens are short-lived JWTs; the stored `refresh`
// is exchanged for a fresh access token at `exchange_user_api_key` (an unusual
// pattern where the refresh token rides as the bearer with an empty body).

public struct CursorOAuthProvider: OAuthProvider {
    public let id = "cursor"
    public let name = "Cursor"
    public let refreshURL: URL

    public init(
        refreshURL: URL = URL(string: "https://api2.cursor.sh/auth/exchange_user_api_key")!
    ) {
        self.refreshURL = refreshURL
    }

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let (response, body) = try await client.request(
            url: refreshURL, method: "POST",
            headers: [
                "authorization": "Bearer \(credentials.refresh)",
                "content-type": "application/json",
            ],
            body: Data("{}".utf8)
        )
        if response.statusCode >= 400 {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("cursor \(response.statusCode): \(text)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = obj["accessToken"] as? String, !access.isEmpty else {
            throw OAuthError.invalidResponse("cursor refresh missing accessToken")
        }
        let newRefresh: String = {
            if let r = obj["refreshToken"] as? String, !r.isEmpty { return r }
            return credentials.refresh
        }()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: access,
            refresh: newRefresh,
            expires: OAuth.jwtExpiryMillis(access) ?? (now + 60 * 60 * 1000),
            extras: credentials.extras
        )
    }
}

// MARK: - Kimi For Coding (Moonshot coding plan)
//
// Kimi's coding-plan auth is an OAuth device-authorization grant against
// `auth.kimi.com` (see `OAuthLogin.loginKimiCoding`). Refresh is a standard
// `grant_type=refresh_token` form POST to the same token endpoint. Every
// request carries the `X-Msh-*` device-identity headers the Kimi CLI sends.

public struct KimiCodingOAuthProvider: OAuthProvider {
    public let id = "kimi-coding"
    public let name = "Kimi For Coding"
    public let tokenURL: URL
    public let clientID: String
    /// Injectable for tests; the default persists one at
    /// `~/.kwwk/kimi-device-id`.
    public let deviceId: String?

    public init(
        tokenURL: URL = URL(string: "https://auth.kimi.com/api/oauth/token")!,
        clientID: String = KimiOAuth.clientID,
        deviceId: String? = nil
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.deviceId = deviceId
    }

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let form = OAuth.urlEncodedForm([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refresh,
            "client_id": clientID,
        ])
        var headers = KimiOAuth.commonHeaders(deviceId: deviceId)
        headers["content-type"] = "application/x-www-form-urlencoded"
        headers["accept"] = "application/json"
        let (response, body) = try await client.request(
            url: tokenURL, method: "POST", headers: headers, body: Data(form.utf8)
        )
        if response.statusCode >= 400 {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("kimi-coding \(response.statusCode): \(text)")
        }
        let json = try OAuth.decodeTokenResponse(body)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - 5 * 60 * 1000,
            extras: credentials.extras
        )
    }
}

/// Constants + device-identity headers shared by the Kimi device-flow login
/// and the refresh provider. Kimi's endpoints expect the CLI's `X-Msh-*`
/// fingerprint headers alongside a `KimiCLI/<version>` User-Agent (the same
/// agent string the bundled kimi-coding catalog models pin for chat requests).
public enum KimiOAuth {
    public static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    public static let host = URL(string: "https://auth.kimi.com")!
    /// Keep in sync with the `User-Agent` header on the bundled `kimi-coding`
    /// catalog models.
    static let cliVersion = "1.5"

    /// Headers for Kimi OAuth endpoints. `deviceId` is injectable for tests;
    /// the default persists a random id at `~/.kwwk/kimi-device-id` so the
    /// device fingerprint is stable across logins.
    public static func commonHeaders(deviceId: String? = nil) -> [String: String] {
        [
            "User-Agent": "KimiCLI/\(cliVersion)",
            "X-Msh-Platform": "kimi_cli",
            "X-Msh-Version": cliVersion,
            "X-Msh-Device-Name": sanitized(ProcessInfo.processInfo.hostName),
            "X-Msh-Device-Model": sanitized(deviceModel()),
            "X-Msh-Os-Version": sanitized(ProcessInfo.processInfo.operatingSystemVersionString),
            "X-Msh-Device-Id": sanitized(deviceId ?? persistentDeviceId()),
        ]
    }

    /// Header values must be printable ASCII; anything else (or an empty
    /// result) collapses to "unknown".
    private static func sanitized(_ value: String) -> String {
        let filtered = value.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value <= 0x7E }
            .map(Character.init)
        let result = String(filtered).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "unknown" : result
    }

    private static func deviceModel() -> String {
        #if os(macOS)
        let system = "macOS"
        #elseif os(Linux)
        let system = "Linux"
        #else
        let system = "unknown"
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return "\(system) \(arch)"
    }

    /// Process-stable fallback id, used only when the id file can't be
    /// written: login and refresh both go through `commonHeaders`, and Kimi
    /// may reject a refresh whose `X-Msh-Device-Id` differs from login's, so
    /// the id must at least survive the process even when it can't survive
    /// a restart.
    private static let fallbackLock = NSLock()
    nonisolated(unsafe) private static var fallbackDeviceId: String?

    /// Read (or create, 0600) the stable device id beside the OAuth store.
    /// Best-effort: an unwritable directory falls back to one id per process.
    static func persistentDeviceId(
        at url: URL = OAuthStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("kimi-device-id")
    ) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let wrote = FileManager.default.createFile(
            atPath: url.path,
            contents: Data("\(fresh)\n".utf8),
            attributes: [.posixPermissions: 0o600]
        )
        if wrote { return fresh }
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        if let cached = fallbackDeviceId { return cached }
        fallbackDeviceId = fresh
        return fresh
    }
}

// MARK: - Helpers

enum OAuth {
    /// Decode a JWT's `exp` claim (Unix seconds) into an expiry in Unix
    /// milliseconds, subtracting a 5-minute safety margin so callers refresh
    /// slightly early. Returns nil for non-JWT / unparseable tokens.
    static func jwtExpiryMillis(_ token: String) -> Int64? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let exp: Double?
        if let v = obj["exp"] as? Double { exp = v }
        else if let v = obj["exp"] as? Int { exp = Double(v) }
        else { exp = nil }
        guard let exp else { return nil }
        return Int64(exp * 1000) - 5 * 60 * 1000
    }

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    static func decodeTokenResponse(_ data: Data) throws -> TokenResponse {
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw OAuthError.invalidResponse("could not decode OAuth token response: \(body)")
        }
    }

    static func urlEncodedForm(_ params: [String: String]) -> String {
        params.keys.sorted().map { key -> String in
            let v = params[key] ?? ""
            let encKey = key.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? key
            let encVal = v.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? v
            return "\(encKey)=\(encVal)"
        }.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters. `application/x-www-form-urlencoded`
    /// wants everything outside this set percent-encoded, including colons
    /// (important for device-flow grants that carry a URN).
    private static let formAllowed: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s
    }()
}
