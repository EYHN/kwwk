import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Whole-flow orchestrator: build the authorize URL, bring up a local
/// callback server, launch the user's browser, exchange the received code
/// for tokens. Returns persistable `OAuthCredentials`.
///
/// Each provider gets a static factory because the URLs, scopes, and
/// redirect ports differ.
public enum OAuthLogin {

    /// Hooks the orchestrator calls as the flow progresses. Both are required:
    /// the SDK does not print to stderr or launch a browser on its own — the
    /// embedding app decides how to surface the auth URL and progress (the
    /// kwwk CLI supplies terminal implementations in `Login.swift`).
    public struct Callbacks: Sendable {
        public var onAuthURL: @Sendable (URL) -> Void
        public var onProgress: @Sendable (String) -> Void

        public init(
            onAuthURL: @escaping @Sendable (URL) -> Void,
            onProgress: @escaping @Sendable (String) -> Void
        ) {
            self.onAuthURL = onAuthURL
            self.onProgress = onProgress
        }
    }

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

    // MARK: - OpenAI Codex

    public static func loginOpenAICodex(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let state = PKCE.randomHex()
        let port: UInt16 = 1455
        let server = try OAuthCallbackServer(port: port, path: "/auth/callback")
        defer { server.stop() }

        var comps = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: "app_EMoamEEZ73f0CkXaXp7hrann"),
            URLQueryItem(name: "redirect_uri", value: server.redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        callbacks.onAuthURL(comps.url!)
        callbacks.onProgress("waiting for ChatGPT callback on \(server.redirectURI)…")

        let params = try await server.waitForCallback()
        guard let code = params["code"] else {
            throw OAuthError.invalidResponse("codex callback had no code")
        }
        if params["state"] != state {
            throw OAuthError.invalidResponse("codex OAuth state mismatch")
        }

        callbacks.onProgress("exchanging authorization code…")
        let form = OAuth.urlEncodedForm([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "redirect_uri": server.redirectURI,
            "code_verifier": pkce.verifier,
        ])
        let (response, body) = try await client.request(
            url: URL(string: "https://auth.openai.com/oauth/token")!,
            method: "POST",
            headers: [
                "content-type": "application/x-www-form-urlencoded",
                "accept": "application/json",
            ],
            body: Data(form.utf8)
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("codex exchange \(response.statusCode): \(String(data: body, encoding: .utf8) ?? "")")
        }
        let json = try OAuth.decodeTokenResponse(body)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var extras: [String: JSONValue] = [:]
        if let accountId = OpenAICodexOAuthProvider.extractAccountId(fromJWT: json.accessToken) {
            extras["accountId"] = .string(accountId)
        }
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? "",
            expires: now + Int64(json.expiresIn * 1000) - 5 * 60 * 1000,
            extras: extras
        )
    }

    // MARK: - Cursor (browser PKCE poll flow)
    //
    // Cursor's CLI login: generate a PKCE verifier/challenge and a session
    // uuid, open `cursor.com/loginDeepControl` in the browser, then poll
    // `api2.cursor.sh/auth/poll?uuid=&verifier=` with exponential backoff until
    // it returns the access/refresh tokens. No local callback server. Mirrors
    // oh-my-pi's `loginCursor`.

    public static func loginCursor(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let uuid = UUID().uuidString.lowercased()

        var comps = URLComponents(string: "https://cursor.com/loginDeepControl")!
        comps.queryItems = [
            URLQueryItem(name: "challenge", value: pkce.challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli"),
        ]
        callbacks.onAuthURL(comps.url!)
        callbacks.onProgress("waiting for Cursor browser authentication…")

        // Poll with exponential backoff (1s → 10s, ×1.2), up to 150 attempts.
        // A 404 means "still pending"; 3 consecutive hard errors aborts.
        var delayMs: UInt64 = 1000
        let maxDelayMs: UInt64 = 10_000
        var consecutiveErrors = 0

        for _ in 0..<150 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)

            var poll = URLComponents(string: "https://api2.cursor.sh/auth/poll")!
            poll.queryItems = [
                URLQueryItem(name: "uuid", value: uuid),
                URLQueryItem(name: "verifier", value: pkce.verifier),
            ]
            do {
                let (response, body) = try await client.request(
                    url: poll.url!, method: "GET",
                    headers: ["accept": "application/json"], body: nil
                )
                if response.statusCode == 404 {
                    consecutiveErrors = 0
                    delayMs = min(delayMs * 12 / 10, maxDelayMs)
                    continue
                }
                if response.statusCode >= 400 {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        throw OAuthError.refreshFailed("cursor poll \(response.statusCode)")
                    }
                    delayMs = min(delayMs * 12 / 10, maxDelayMs)
                    continue
                }
                guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let access = obj["accessToken"] as? String, !access.isEmpty else {
                    // 200 with no token yet — keep polling.
                    consecutiveErrors = 0
                    delayMs = min(delayMs * 12 / 10, maxDelayMs)
                    continue
                }
                let refresh = obj["refreshToken"] as? String ?? ""
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                return OAuthCredentials(
                    access: access,
                    refresh: refresh.isEmpty ? access : refresh,
                    expires: OAuth.jwtExpiryMillis(access) ?? (now + 60 * 60 * 1000)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OAuthError {
                throw error
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw OAuthError.transport("cursor auth polling failed: \(error.localizedDescription)")
                }
            }
        }
        throw OAuthError.transport("cursor authentication timed out")
    }

    // MARK: - GitHub Copilot (device flow)
    //
    // Copilot uses GitHub's device-authorization grant: we POST to
    // `/login/device/code`, show the user the one-time `user_code`, and
    // poll `/login/oauth/access_token` until the user enters the code in
    // their browser. No callback server.

    public static func loginGitHubCopilot(
        clientID: String = "Iv1.b507a08c87ecfe98",
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        callbacks.onProgress("requesting GitHub device code…")
        let (deviceResponse, deviceBody) = try await client.request(
            url: URL(string: "https://github.com/login/device/code")!,
            method: "POST",
            headers: [
                "accept": "application/json",
                "content-type": "application/x-www-form-urlencoded",
            ],
            body: Data(OAuth.urlEncodedForm([
                "client_id": clientID,
                "scope": "read:user",
            ]).utf8)
        )
        if deviceResponse.statusCode >= 400 {
            throw OAuthError.refreshFailed("copilot device code \(deviceResponse.statusCode): \(String(data: deviceBody, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: deviceBody) as? [String: Any],
              let userCode = obj["user_code"] as? String,
              let deviceCode = obj["device_code"] as? String,
              let verifyURLString = obj["verification_uri"] as? String,
              let verifyURL = URL(string: verifyURLString) else {
            throw OAuthError.invalidResponse("copilot device code response")
        }
        let interval = (obj["interval"] as? Int) ?? 5

        callbacks.onAuthURL(verifyURL)
        callbacks.onProgress("enter code in your browser: \(userCode)")

        // Poll for the access token.
        let pollURL = URL(string: "https://github.com/login/oauth/access_token")!
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let (pollResponse, pollBody) = try await client.request(
                url: pollURL,
                method: "POST",
                headers: [
                    "accept": "application/json",
                    "content-type": "application/x-www-form-urlencoded",
                ],
                body: Data(OAuth.urlEncodedForm([
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]).utf8)
            )
            if pollResponse.statusCode >= 400 {
                continue
            }
            guard let polled = try JSONSerialization.jsonObject(with: pollBody) as? [String: Any] else {
                continue
            }
            if let err = polled["error"] as? String {
                if err == "authorization_pending" { continue }
                if err == "slow_down" {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 2 * 1_000_000_000)
                    continue
                }
                throw OAuthError.refreshFailed("copilot device flow: \(err)")
            }
            if let pat = polled["access_token"] as? String {
                // Immediately exchange the PAT for a session token so the
                // stored creds are ready to use.
                let provider = GitHubCopilotOAuthProvider()
                let base = OAuthCredentials(access: "", refresh: pat, expires: 0, extras: [:])
                return try await provider.refresh(base, using: client)
            }
        }
        throw OAuthError.transport("copilot device flow timed out")
    }

    // MARK: - Kimi For Coding (device flow)
    //
    // Kimi's coding plan uses an OAuth device-authorization grant against
    // `auth.kimi.com`: POST `/api/oauth/device_authorization` for a one-time
    // user code, hand the verification URL to the browser, and poll
    // `/api/oauth/token` until the user approves. Mirrors oh-my-pi's
    // `loginKimi`. Every request carries the `X-Msh-*` device headers.

    public static func loginKimiCoding(
        clientID: String = KimiOAuth.clientID,
        host: URL = KimiOAuth.host,
        // Injectable for tests; the default persists one at
        // `~/.kwwk/kimi-device-id`.
        deviceId: String? = nil,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        var headers = KimiOAuth.commonHeaders(deviceId: deviceId)
        headers["accept"] = "application/json"
        headers["content-type"] = "application/x-www-form-urlencoded"

        callbacks.onProgress("requesting Kimi device code…")
        let (deviceResponse, deviceBody) = try await client.request(
            url: host.appendingPathComponent("api/oauth/device_authorization"),
            method: "POST",
            headers: headers,
            body: Data(OAuth.urlEncodedForm(["client_id": clientID]).utf8)
        )
        if deviceResponse.statusCode >= 400 {
            throw OAuthError.refreshFailed("kimi device code \(deviceResponse.statusCode): \(String(data: deviceBody, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: deviceBody) as? [String: Any],
              let userCode = obj["user_code"] as? String,
              let deviceCode = obj["device_code"] as? String,
              let verifyURLString = (obj["verification_uri_complete"] as? String)
                ?? (obj["verification_uri"] as? String),
              let verifyURL = URL(string: verifyURLString) else {
            throw OAuthError.invalidResponse("kimi device code response")
        }
        var intervalSec = (obj["interval"] as? Int).flatMap { $0 >= 0 ? $0 : nil } ?? 5
        let expiresInSec = (obj["expires_in"] as? Int) ?? 15 * 60

        callbacks.onAuthURL(verifyURL)
        callbacks.onProgress("enter code in your browser: \(userCode)")

        // Poll for the token until the user approves (or the code expires).
        // Transient HTTP failures with non-JSON bodies (gateway errors, …)
        // are retried; only 3 consecutive ones abort the flow, so a blip
        // can't kill an authorization the user is mid-way through.
        let pollURL = host.appendingPathComponent("api/oauth/token")
        let deadline = Date().addingTimeInterval(TimeInterval(expiresInSec))
        var consecutiveErrors = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(intervalSec) * 1_000_000_000)
            let (pollResponse, pollBody) = try await client.request(
                url: pollURL,
                method: "POST",
                headers: headers,
                body: Data(OAuth.urlEncodedForm([
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]).utf8)
            )
            guard let polled = try? JSONSerialization.jsonObject(with: pollBody) as? [String: Any] else {
                if pollResponse.statusCode >= 400 {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        throw OAuthError.refreshFailed("kimi device flow: HTTP \(pollResponse.statusCode)")
                    }
                }
                continue
            }
            consecutiveErrors = 0
            if let err = polled["error"] as? String {
                switch err {
                case "authorization_pending":
                    continue
                case "slow_down":
                    intervalSec += 5
                    if let serverInterval = polled["interval"] as? Int, serverInterval > intervalSec {
                        intervalSec = serverInterval
                    }
                    continue
                case "expired_token":
                    throw OAuthError.refreshFailed("kimi device authorization expired")
                case "access_denied":
                    throw OAuthError.refreshFailed("kimi device authorization denied")
                default:
                    let description = (polled["error_description"] as? String).map { ": \($0)" } ?? ""
                    throw OAuthError.refreshFailed("kimi device flow: \(err)\(description)")
                }
            }
            if pollResponse.statusCode < 400, let access = polled["access_token"] as? String {
                guard let refresh = polled["refresh_token"] as? String, !refresh.isEmpty else {
                    throw OAuthError.invalidResponse("kimi token response missing refresh token")
                }
                let expiresIn = (polled["expires_in"] as? Int) ?? 15 * 60
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                return OAuthCredentials(
                    access: access,
                    refresh: refresh,
                    expires: now + Int64(expiresIn) * 1000 - 5 * 60 * 1000
                )
            }
        }
        throw OAuthError.transport("kimi device flow timed out")
    }

    // MARK: - xAI Grok (device flow)
    //
    // xAI's subscription auth is an RFC 8628 device-authorization grant
    // against `auth.x.ai`: POST `/oauth2/device/code` for a one-time user
    // code, hand the verification URL to the browser, and poll
    // `/oauth2/token` until the user approves. Same client id + scope as the
    // official Grok CLI (and pi / oh-my-pi). The resulting Bearer token
    // authenticates `api.x.ai` requests directly.

    public static func loginXai(
        clientID: String = XaiOAuth.clientID,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let headers = [
            "accept": "application/json",
            "content-type": "application/x-www-form-urlencoded",
        ]

        callbacks.onProgress("requesting xAI device code…")
        let (deviceResponse, deviceBody) = try await client.request(
            url: XaiOAuth.deviceCodeURL,
            method: "POST",
            headers: headers,
            body: Data(OAuth.urlEncodedForm([
                "client_id": clientID,
                "scope": XaiOAuth.scope,
            ]).utf8)
        )
        if deviceResponse.statusCode >= 400 {
            throw OAuthError.refreshFailed("xai device code \(deviceResponse.statusCode): \(String(data: deviceBody, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: deviceBody) as? [String: Any],
              let userCode = obj["user_code"] as? String,
              let deviceCode = obj["device_code"] as? String,
              let verifyURLString = (obj["verification_uri_complete"] as? String)
                ?? (obj["verification_uri"] as? String),
              let verifyURL = URL(string: verifyURLString),
              // The verification URI is handed to the browser; refuse anything
              // a malicious response could use to make `open` launch a
              // non-https handler.
              verifyURL.scheme == "https" else {
            throw OAuthError.invalidResponse("xai device code response")
        }
        // RFC 8628 allows interval 0 (no minimum wait); reject only negative
        // or malformed values.
        var intervalSec = (obj["interval"] as? Int).flatMap { $0 >= 0 ? $0 : nil } ?? 5
        let expiresInSec = (obj["expires_in"] as? Int) ?? 15 * 60

        callbacks.onAuthURL(verifyURL)
        callbacks.onProgress("enter code in your browser: \(userCode)")

        // Poll for the token until the user approves (or the code expires).
        // Transient HTTP failures with non-JSON bodies (gateway errors, …)
        // are retried; only 3 consecutive ones abort the flow.
        let deadline = Date().addingTimeInterval(TimeInterval(expiresInSec))
        var consecutiveErrors = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(intervalSec) * 1_000_000_000)
            let (pollResponse, pollBody) = try await client.request(
                url: XaiOAuth.tokenURL,
                method: "POST",
                headers: headers,
                body: Data(OAuth.urlEncodedForm([
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]).utf8)
            )
            guard let polled = try? JSONSerialization.jsonObject(with: pollBody) as? [String: Any] else {
                if pollResponse.statusCode >= 400 {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        throw OAuthError.refreshFailed("xai device flow: HTTP \(pollResponse.statusCode)")
                    }
                }
                continue
            }
            consecutiveErrors = 0
            if let err = polled["error"] as? String {
                switch err {
                case "authorization_pending":
                    continue
                case "slow_down":
                    intervalSec += 5
                    if let serverInterval = polled["interval"] as? Int, serverInterval > intervalSec {
                        intervalSec = serverInterval
                    }
                    continue
                case "expired_token":
                    throw OAuthError.refreshFailed("xai device authorization expired")
                case "access_denied", "authorization_denied":
                    throw OAuthError.refreshFailed("xai device authorization denied")
                default:
                    let description = (polled["error_description"] as? String).map { ": \($0)" } ?? ""
                    throw OAuthError.refreshFailed("xai device flow: \(err)\(description)")
                }
            }
            if pollResponse.statusCode < 400, let access = polled["access_token"] as? String {
                // `offline_access` is in the requested scope, so the initial
                // grant must carry a refresh token — without one the login
                // would silently die at first expiry.
                guard let refresh = polled["refresh_token"] as? String, !refresh.isEmpty else {
                    throw OAuthError.invalidResponse("xai token response missing refresh token")
                }
                let expiresIn = (polled["expires_in"] as? Int) ?? 3600
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                return OAuthCredentials(
                    access: access,
                    refresh: refresh,
                    expires: now + Int64(expiresIn) * 1000 - 5 * 60 * 1000
                )
            }
        }
        throw OAuthError.transport("xai device flow timed out")
    }

    // MARK: - OpenRouter (PKCE callback flow)
    //
    // OpenRouter's OAuth exchanges the authorization code for a permanent,
    // user-controlled API key rather than an expiring token pair (mirrors
    // pi's `openrouter.ts`). The minted key persists in the same sentinel
    // credentials shape as the API-key login form (`refresh: ""`,
    // `expires: .max`), so the stored `openrouter` registration path is
    // unchanged.

    public static func loginOpenRouter(
        port: UInt16 = OpenRouterOAuth.callbackPort,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let server = try OAuthCallbackServer(port: port)
        defer { server.stop() }

        var comps = URLComponents(url: OpenRouterOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "callback_url", value: server.redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        callbacks.onAuthURL(comps.url!)
        callbacks.onProgress("waiting for OpenRouter callback on \(server.redirectURI)…")

        let params = try await server.waitForCallback()
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("openrouter callback had no code")
        }

        callbacks.onProgress("exchanging authorization code for an API key…")
        let (response, responseBody) = try await client.request(
            url: OpenRouterOAuth.keysURL,
            method: "POST",
            headers: ["content-type": "application/json", "accept": "application/json"],
            body: try JSONSerialization.data(withJSONObject: [
                "code": code,
                "code_verifier": pkce.verifier,
                "code_challenge_method": "S256",
            ])
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("openrouter key exchange \(response.statusCode): \(String(data: responseBody, encoding: .utf8) ?? "")")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let key = obj["key"] as? String, !key.isEmpty else {
            throw OAuthError.invalidResponse("openrouter key exchange response carried no key")
        }
        return OAuthCredentials(access: key, refresh: "", expires: .max)
    }

    // MARK: - Z.AI GLM Coding Plan (browser sign-in)
    //
    // Ported from oh-my-pi's `zai.ts` (ZCode's desktop "Individual Plan"
    // flow): an authorization-code grant (no PKCE) against chat.z.ai, a JSON
    // token exchange on zcode.z.ai that yields a short-lived OAuth access
    // token, then a business-API sequence on api.z.ai that provisions a
    // durable `id.secret` API key. The minted key persists in the sentinel
    // credentials shape (refresh "", expires .max) so the stored `zai`
    // registration consumes it exactly like a hand-entered key.

    public static func loginZai(
        clientID: String = ZaiOAuth.clientID,
        port: UInt16 = ZaiOAuth.callbackPort,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let state = PKCE.randomHex()
        let server = try OAuthCallbackServer(port: port)
        defer { server.stop() }
        let redirect = server.redirectURI

        var comps = URLComponents(url: ZaiOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "state", value: state),
        ]
        callbacks.onAuthURL(comps.url!)
        callbacks.onProgress("waiting for Z.AI callback on \(redirect)…")

        let params = try await server.waitForCallback()
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("zai callback had no code")
        }
        if let callbackState = params["state"], callbackState != state {
            throw OAuthError.invalidResponse("zai OAuth state mismatch")
        }

        // Token exchange — non-standard JSON body (no grant_type or PKCE);
        // matches ZCode verbatim.
        callbacks.onProgress("exchanging authorization code…")
        let exchange = try zaiUnwrap(
            try await zaiJSON(
                url: ZaiOAuth.tokenURL, method: "POST",
                body: ["provider": "zai", "code": code, "redirect_uri": redirect, "state": state],
                bearer: nil, client: client
            ),
            operation: "token exchange"
        )
        guard let zaiObj = (exchange as? [String: Any])?["zai"] as? [String: Any],
              let oauthToken = zaiString(zaiObj["access_token"]) else {
            throw OAuthError.invalidResponse("zai token response missing access token")
        }

        // Business login: the biz APIs reject the raw OAuth token; exchange
        // it for a biz bearer first.
        callbacks.onProgress("provisioning Z.AI API key…")
        let login = try zaiUnwrap(
            try await zaiJSON(
                url: ZaiOAuth.businessLoginURL, method: "POST",
                body: ["token": oauthToken], bearer: nil, client: client
            ),
            operation: "business login"
        )
        let loginObj = login as? [String: Any]
        guard let bizToken = zaiString(loginObj?["access_token"]) ?? zaiString(loginObj?["accessToken"]) else {
            throw OAuthError.invalidResponse("zai business login returned no access token")
        }

        // Resolve the default organization/project, then find-or-create the
        // kwwk-named key under it.
        let customer = try zaiUnwrap(
            try await zaiJSON(
                url: ZaiOAuth.bizBaseURL.appendingPathComponent("api/biz/customer/getCustomerInfo"),
                method: "GET", body: nil, bearer: bizToken, client: client
            ),
            operation: "customer lookup"
        )
        let orgs = (customer as? [String: Any])?["organizations"] as? [[String: Any]] ?? []
        let org = orgs.first { ($0["isDefault"] as? Bool) == true } ?? orgs.first
        let projects = org?["projects"] as? [[String: Any]] ?? []
        let project = projects.first { ($0["isDefault"] as? Bool) == true } ?? projects.first
        guard let organizationId = zaiString(org?["organizationId"]),
              let projectId = zaiString(project?["projectId"]) else {
            throw OAuthError.invalidResponse("zai key provisioning: no organization/project on account")
        }

        let keysURL = ZaiOAuth.bizBaseURL
            .appendingPathComponent("api/biz/v1/organization/\(organizationId)/projects/\(projectId)/api_keys")
        let listed = try zaiUnwrap(
            try await zaiJSON(url: keysURL, method: "GET", body: nil, bearer: bizToken, client: client),
            operation: "api key list"
        )
        let record: [String: Any]?
        if let existing = zaiKeyArray(listed).first(where: { ($0["name"] as? String) == ZaiOAuth.keyName }) {
            record = existing
        } else {
            record = try zaiUnwrap(
                try await zaiJSON(
                    url: keysURL, method: "POST",
                    body: ["name": ZaiOAuth.keyName], bearer: bizToken, client: client
                ),
                operation: "api key create"
            ) as? [String: Any]
        }
        guard let apiKey = zaiString(record?["apiKey"]) else {
            throw OAuthError.invalidResponse("zai key provisioning returned no apiKey")
        }

        // Always fetch the secret via the copy endpoint: list entries mask it
        // (`*****abcd`) and the create response's inline secret is not
        // reliable across account states, whereas copy returns it in full.
        let copied = try zaiUnwrap(
            try await zaiJSON(
                url: keysURL.appendingPathComponent("copy/\(apiKey)"),
                method: "GET", body: nil, bearer: bizToken, client: client
            ),
            operation: "api key copy"
        )
        guard let secretKey = zaiString((copied as? [String: Any])?["secretKey"]) else {
            throw OAuthError.invalidResponse("zai key provisioning returned no secretKey")
        }

        return OAuthCredentials(access: "\(apiKey).\(secretKey)", refresh: "", expires: .max)
    }

    // MARK: - Z.AI helpers

    /// One JSON round-trip: optional JSON body, optional bearer, ≥400 throws
    /// with the response text, empty bodies come back nil.
    private static func zaiJSON(
        url: URL,
        method: String,
        body: [String: Any]?,
        bearer: String?,
        client: HTTPClient
    ) async throws -> Any? {
        var headers = ["accept": "application/json"]
        if body != nil { headers["content-type"] = "application/json" }
        if let bearer { headers["authorization"] = "Bearer \(bearer)" }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (response, responseBody) = try await client.request(
            url: url, method: method, headers: headers, body: data
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("zai \(url.lastPathComponent) \(response.statusCode): \(String(data: responseBody, encoding: .utf8) ?? "")")
        }
        guard !responseBody.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: responseBody)
    }

    /// Z.AI's `{code, msg, data, success}` envelope: the OAuth token endpoint
    /// signals success with `code: 0`, the biz endpoints with `code: 200` /
    /// `success: true`. Accept both; surface `msg` on failure. Bodies without
    /// a status wrapper pass through unchanged.
    private static func zaiUnwrap(_ body: Any?, operation: String) throws -> Any? {
        guard let obj = body as? [String: Any],
              obj["code"] != nil || obj["success"] != nil else {
            return body
        }
        let success: Bool = {
            if let flag = obj["success"] as? Bool, flag == false { return false }
            switch obj["code"] {
            case nil, is NSNull: return true
            case let n as NSNumber: return n.intValue == 0 || n.intValue == 200
            case let s as String: return s == "0" || s == "200"
            default: return false
            }
        }()
        guard success else {
            let msg = (obj["msg"] as? String) ?? "code \(obj["code"] ?? "?")"
            throw OAuthError.refreshFailed("zai \(operation) failed: \(msg)")
        }
        return obj.keys.contains("data") ? obj["data"] : obj
    }

    /// Non-empty trimmed string, or nil.
    private static func zaiString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Coerce an api_keys list response (bare array or common wrapper
    /// shapes) to an array of records.
    private static func zaiKeyArray(_ value: Any?) -> [[String: Any]] {
        if let arr = value as? [[String: Any]] { return arr }
        if let obj = value as? [String: Any] {
            for field in ["list", "keys", "apiKeys", "records"] {
                if let arr = obj[field] as? [[String: Any]] { return arr }
            }
        }
        return []
    }

    // MARK: - JSON helpers

    private static func postJSON(
        url: URL,
        body: [String: Any],
        client: HTTPClient
    ) async throws -> OAuth.TokenResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        let (response, responseBody) = try await client.request(
            url: url, method: "POST",
            headers: ["content-type": "application/json", "accept": "application/json"],
            body: data
        )
        if response.statusCode >= 400 {
            let text = String(data: responseBody, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("\(url.host ?? "oauth") \(response.statusCode): \(text)")
        }
        return try OAuth.decodeTokenResponse(responseBody)
    }

    private static func credentials(
        from response: OAuth.TokenResponse,
        fallbackRefresh: String?
    ) -> OAuthCredentials {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: response.accessToken,
            refresh: response.refreshToken ?? fallbackRefresh ?? "",
            expires: now + Int64(response.expiresIn * 1000) - 5 * 60 * 1000,
            extras: [:]
        )
    }
}

// MARK: - GitHub Copilot post-login setup

extension OAuthLogin {
    /// Enable every model in `modelIds` on the Copilot account via
    /// `POST {baseURL}/models/<id>/policy` with `{state: "enabled"}`.
    /// Claude/Grok/Gemini models require this one-shot opt-in before the
    /// chat endpoints will route to them; GPT-family models don't need it
    /// but the call is idempotent so we fire for everything.
    ///
    /// Errors are swallowed per-model (best-effort): a 403 for a model the
    /// account doesn't have entitlement for shouldn't abort the whole
    /// login flow. Progress is reported through `onProgress` if set.
    public static func enableCopilotModels(
        sessionToken: String,
        baseURL: URL = URL(string: "https://api.individual.githubcopilot.com")!,
        modelIds: [String],
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async {
        let baseString: String = {
            var s = baseURL.absoluteString
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        let body = Data(#"{"state":"enabled"}"#.utf8)
        for id in modelIds {
            guard let url = URL(string: "\(baseString)/models/\(id)/policy") else { continue }
            let headers: [String: String] = [
                "content-type": "application/json",
                "authorization": "Bearer \(sessionToken)",
                "editor-version": "vscode/1.107.0",
                "editor-plugin-version": "copilot-chat/0.35.0",
                "user-agent": "GitHubCopilotChat/0.35.0",
                "copilot-integration-id": "vscode-chat",
                "openai-intent": "chat-policy",
                "x-interaction-type": "chat-policy",
            ]
            do {
                let (response, _) = try await client.request(
                    url: url, method: "POST", headers: headers, body: body
                )
                if response.statusCode >= 400 {
                    callbacks.onProgress("  · \(id): policy \(response.statusCode) (skipped)")
                } else {
                    callbacks.onProgress("  · \(id): enabled")
                }
            } catch {
                callbacks.onProgress("  · \(id): \(error.localizedDescription)")
            }
        }
    }
}
