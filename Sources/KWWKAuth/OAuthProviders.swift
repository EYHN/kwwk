import Foundation

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
        let (response, responseBody) = try await OAuthRefreshError.request(provider: id) {
            try await client.request(
                url: tokenURL, method: "POST",
                headers: [
                    "content-type": "application/x-www-form-urlencoded",
                    "accept": "application/json",
                ],
                body: Data(form.utf8)
            )
        }
        try OAuthRefreshError.check(provider: id, response: response, body: responseBody)
        let json = try OAuthRefreshError.decodeToken(provider: id, responseBody)
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
    public static func extractAccountId(fromJWT token: String) -> String? {
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
           let id = claim["chatgpt_account_id"] as? String, !id.isEmpty {
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
        let (response, body) = try await OAuthRefreshError.request(provider: id) {
            try await client.request(
                url: refreshURL, method: "POST",
                headers: [
                    "authorization": "Bearer \(credentials.refresh)",
                    "content-type": "application/json",
                ],
                body: Data("{}".utf8)
            )
        }
        try OAuthRefreshError.check(provider: id, response: response, body: body)
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let access = obj["accessToken"] as? String, !access.isEmpty else {
            throw OAuthRefreshError(
                providerId: id, kind: .unavailable, status: response.statusCode,
                detail: "cursor refresh missing accessToken"
            )
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

// MARK: - Devin
//
// Devin's browser sign-in (`OAuthLogin.loginDevin`) yields a long-lived
// session token with no refresh token, stored with `refresh == ""`. The
// manager therefore never calls `refresh` (an expired refresh-less entry
// surfaces `OAuthError.expired`); the provider exists so `apiKey(for:)`
// recognizes the id.

public struct DevinOAuthProvider: OAuthProvider {
    public let id = "devin"
    public let name = "Devin"

    public init() {}

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        throw OAuthError.refreshFailed("devin session tokens cannot be refreshed; run /login devin again")
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
    /// The fingerprint sent when the credentials don't name their own device
    /// id. Nil uses this machine's, with the id persisted at
    /// `~/.kwwk/kimi-device-id`.
    public let identity: KimiDeviceIdentity?

    public init(
        tokenURL: URL = URL(string: "https://auth.kimi.com/api/oauth/token")!,
        clientID: String = KimiOAuth.clientID,
        identity: KimiDeviceIdentity? = nil
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.identity = identity
    }

    /// Kept for callers that only pin the id.
    public init(
        tokenURL: URL = URL(string: "https://auth.kimi.com/api/oauth/token")!,
        clientID: String = KimiOAuth.clientID,
        deviceId: String?
    ) {
        self.init(tokenURL: tokenURL, clientID: clientID, identity: deviceId.map { .host(deviceId: $0) })
    }

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        // Kimi binds the grant to the device id it was approved on, so the
        // id the login recorded wins over this provider's default; a login
        // that recorded none gets the default written back, so every later
        // refresh — wherever it runs — sends the same one.
        var identity = identity ?? .host()
        if case .string(let recorded)? = credentials.extras["deviceId"], !recorded.isEmpty {
            identity.deviceId = recorded
        }
        let form = OAuth.urlEncodedForm([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refresh,
            "client_id": clientID,
        ])
        var headers = KimiOAuth.commonHeaders(identity: identity)
        headers["content-type"] = "application/x-www-form-urlencoded"
        headers["accept"] = "application/json"
        let (response, body) = try await OAuthRefreshError.request(provider: id) {
            try await client.request(url: tokenURL, method: "POST", headers: headers, body: Data(form.utf8))
        }
        try OAuthRefreshError.check(provider: id, response: response, body: body)
        let json = try OAuthRefreshError.decodeToken(provider: id, body)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var extras = credentials.extras
        extras["deviceId"] = .string(identity.deviceId)
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - 5 * 60 * 1000,
            extras: extras
        )
    }
}

/// The device fingerprint Kimi's endpoints check on every login and refresh
/// (`X-Msh-Device-*`). A refresh must present the device id its login did.
public struct KimiDeviceIdentity: Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var deviceModel: String
    public var osVersion: String

    public init(deviceId: String, deviceName: String, deviceModel: String, osVersion: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }

    /// This machine: its host name, OS and CPU, and `deviceId` — or, when
    /// nil, the id persisted at `~/.kwwk/kimi-device-id`.
    public static func host(deviceId: String? = nil) -> KimiDeviceIdentity {
        KimiDeviceIdentity(
            deviceId: deviceId ?? KimiOAuth.persistentDeviceId(),
            deviceName: ProcessInfo.processInfo.hostName,
            deviceModel: KimiOAuth.deviceModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
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
        commonHeaders(identity: .host(deviceId: deviceId))
    }

    /// Headers for Kimi OAuth endpoints, carrying `identity`.
    public static func commonHeaders(identity: KimiDeviceIdentity) -> [String: String] {
        [
            "User-Agent": "KimiCLI/\(cliVersion)",
            "X-Msh-Platform": "kimi_cli",
            "X-Msh-Version": cliVersion,
            "X-Msh-Device-Name": sanitized(identity.deviceName),
            "X-Msh-Device-Model": sanitized(identity.deviceModel),
            "X-Msh-Os-Version": sanitized(identity.osVersion),
            "X-Msh-Device-Id": sanitized(identity.deviceId),
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

    static func deviceModel() -> String {
        #if os(macOS)
        let system = "macOS"
        #elseif os(iOS)
        let system = "iOS"
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
    package static func persistentDeviceId(
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

// MARK: - xAI Grok (SuperGrok / X Premium subscription)
//
// xAI's subscription auth is an OAuth device-authorization grant against
// `auth.x.ai` (see `OAuthLogin.loginXai`), the same flow the official Grok
// CLI uses. Refresh is a standard `grant_type=refresh_token` form POST to the
// token endpoint; the resulting access token authenticates `api.x.ai`
// requests as a Bearer key.

public struct XaiOAuthProvider: OAuthProvider {
    public let id = "xai"
    public let name = "xAI (Grok subscription)"
    public let tokenURL: URL
    public let clientID: String

    public init(
        tokenURL: URL = XaiOAuth.tokenURL,
        clientID: String = XaiOAuth.clientID
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
        let (response, body) = try await OAuthRefreshError.request(provider: id) {
            try await client.request(
                url: tokenURL, method: "POST",
                headers: [
                    "content-type": "application/x-www-form-urlencoded",
                    "accept": "application/json",
                ],
                body: Data(form.utf8)
            )
        }
        try OAuthRefreshError.check(provider: id, response: response, body: body)
        let json = try OAuthRefreshError.decodeToken(provider: id, body)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: json.accessToken,
            // xAI may omit refresh_token when the token isn't rotated.
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - 5 * 60 * 1000,
            extras: credentials.extras
        )
    }
}

/// Constants shared by the xAI device-flow login and the refresh provider.
/// Client id and scope mirror the official Grok CLI (same values pi and
/// oh-my-pi ship); the `grok-cli:access` scope is what unlocks subscription
/// inference.
public enum XaiOAuth {
    public static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let scope = "openid profile email offline_access grok-cli:access api:access"
    public static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    public static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
}

/// Constants for the OpenRouter PKCE callback login (mirrors pi's
/// `openrouter.ts`). The code exchange mints a permanent API key, so there
/// is no refresh provider — the key persists in the sentinel credentials
/// shape the API-key form uses.
public enum OpenRouterOAuth {
    public static let authorizeURL = URL(string: "https://openrouter.ai/auth")!
    public static let keysURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    public static let callbackPort: UInt16 = 53693
}

/// Constants for the Devin browser sign-in (mirrors oh-my-pi's
/// `compat/rules/auth/devin.kdl`).
public enum DevinOAuth {
    public static let authorizeURL = URL(string: "https://app.devin.ai/auth/cli/continue")!
    public static let tokenURL = URL(string: "https://api.devin.ai/auth/cli/token")!
    public static let callbackPort: UInt16 = 59653
    public static let callbackHost = "127.0.0.1"
    public static let callbackPath = "/callback"
    public static let apiEndpoint = "https://api.devin.ai"
    public static let enterpriseURL = "https://app.devin.ai"
    /// Expiry used when the session token carries no JWT `exp` (one year).
    public static let fallbackLifetimeMs: Int64 = 31_536_000_000
}

/// Constants for the Z.AI GLM Coding Plan browser sign-in (mirrors
/// oh-my-pi's `zai.ts`, which itself mirrors ZCode's desktop flow). The
/// flow provisions a durable `id.secret` API key, so there is no refresh
/// provider here either.
public enum ZaiOAuth {
    public static let clientID = "client_P8X5CMWmlaRO9gyO-KSqtg"
    public static let authorizeURL = URL(string: "https://chat.z.ai/api/oauth/authorize")!
    public static let tokenURL = URL(string: "https://zcode.z.ai/api/v1/oauth/token")!
    public static let bizBaseURL = URL(string: "https://api.z.ai")!
    /// Business-login endpoint: exchanges the OAuth access token for the biz
    /// bearer the provisioning APIs require.
    public static let businessLoginURL = URL(string: "https://api.z.ai/api/auth/z/login")!
    /// Name of the provisioned key — kwwk-owned, so sign-in never mutates
    /// ZCode's own `zcode-api-key` entry.
    public static let keyName = "kwwk"
    /// Fixed port matching the redirect URI ZCode's client id expects.
    public static let callbackPort: UInt16 = 54548
}

// MARK: - Helpers

package enum OAuth {
    /// Decode a JWT's `exp` claim (Unix seconds) into an expiry in Unix
    /// milliseconds, subtracting a 5-minute safety margin so callers refresh
    /// slightly early. Returns nil for non-JWT / unparseable tokens.
    package static func jwtExpiryMillis(_ token: String) -> Int64? {
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

    package struct TokenResponse: Decodable {
        package let accessToken: String
        package let refreshToken: String?
        package let expiresIn: Int
        package let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }

        /// `expires_in` is optional per RFC 6749 §4.2.2 and xAI omits it when
        /// the lifetime is the default; fall back to one hour rather than
        /// failing the whole token decode.
        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decode(String.self, forKey: .accessToken)
            refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
            expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 3600
            scope = try c.decodeIfPresent(String.self, forKey: .scope)
        }
    }

    package static func decodeTokenResponse(_ data: Data) throws -> TokenResponse {
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw OAuthError.invalidResponse("could not decode OAuth token response: \(body)")
        }
    }

    package static func urlEncodedForm(_ params: [String: String]) -> String {
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
