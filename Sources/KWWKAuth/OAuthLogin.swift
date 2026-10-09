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

    /// Hooks the orchestrator calls as the flow progresses. The SDK does not
    /// print or launch a browser on its own — the embedding app decides how.
    /// Redirect flows default to a NIO loopback listener; an app may supply
    /// its own listener and browser presenter.
    public struct Callbacks: Sendable {
        /// Called with a page the user must open, when no `browser` presenter
        /// is set. The CLI prints and opens it here. A host that sets
        /// `browser` can leave this and `onProgress` at their no-op defaults.
        public var onAuthURL: @Sendable (URL) -> Void
        public var onProgress: @Sendable (String) -> Void
        /// Called once per device flow, before its verification page opens,
        /// with the code the user confirms there.
        public var onUserCode: (@Sendable (_ code: String, _ verificationURL: URL) async -> Void)?
        /// Shows pages and runs the flow's waiting work beside them. Nil runs
        /// the work after handing the page to `onAuthURL`.
        public var browser: (any OAuthBrowserPresenter)?
        /// Builds the listener a redirect flow binds. Defaults to the shared
        /// NIO listener; tests and hosts may supply their own.
        public var loopback: OAuthLoopbackFactory

        public init(
            onAuthURL: @escaping @Sendable (URL) -> Void = { _ in },
            onProgress: @escaping @Sendable (String) -> Void = { _ in },
            onUserCode: (@Sendable (_ code: String, _ verificationURL: URL) async -> Void)? = nil,
            browser: (any OAuthBrowserPresenter)? = nil,
            loopback: @escaping OAuthLoopbackFactory = OAuthLogin.nioLoopback
        ) {
            self.onAuthURL = onAuthURL
            self.onProgress = onProgress
            self.onUserCode = onUserCode
            self.browser = browser
            self.loopback = loopback
        }
    }

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

    // MARK: - OpenAI Codex

    public static func loginOpenAICodex(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let state = PKCE.randomHex()
        // OpenAI registered exactly this redirect for the Codex CLI's client.
        let server = try await openLoopback(callbacks, port: 1455, path: "/auth/callback")
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
        callbacks.onProgress("waiting for ChatGPT callback on \(server.redirectURI)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "codex")
        guard params["state"] == state else {
            throw OAuthError.invalidResponse("codex OAuth state mismatch")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("codex callback had no code")
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
        // `offline_access` is requested; a grant without a refresh token
        // would die at its first expiry, so it is refused here.
        guard let refresh = json.refreshToken, !refresh.isEmpty else {
            throw OAuthError.invalidResponse("codex token response missing refresh token")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var extras: [String: JSONValue] = [:]
        if let accountId = OpenAICodexOAuthProvider.extractAccountId(fromJWT: json.accessToken) {
            extras["accountId"] = .string(accountId)
        }
        return OAuthCredentials(
            access: json.accessToken,
            refresh: refresh,
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
        callbacks.onProgress("waiting for Cursor browser authentication…")
        return try await present(comps.url!, callbacks: callbacks) {
            try await pollCursor(uuid: uuid, verifier: pkce.verifier, client: client)
        }
    }

    /// Polls with exponential backoff (1s → 10s, ×1.2), up to 150 attempts.
    /// A 404 — or a 200 that carries no token yet — means "still pending";
    /// 3 consecutive hard errors abort.
    private static func pollCursor(
        uuid: String,
        verifier: String,
        client: HTTPClient
    ) async throws -> OAuthCredentials {
        var delayMs: UInt64 = 1000
        let maxDelayMs: UInt64 = 10_000
        var consecutiveErrors = 0

        for _ in 0..<150 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            delayMs = min(delayMs * 12 / 10, maxDelayMs)

            var poll = URLComponents(string: "https://api2.cursor.sh/auth/poll")!
            poll.queryItems = [
                URLQueryItem(name: "uuid", value: uuid),
                URLQueryItem(name: "verifier", value: verifier),
            ]
            let response: HTTPURLResponse
            let body: Data
            do {
                (response, body) = try await client.request(
                    url: poll.url!, method: "GET",
                    headers: ["accept": "application/json"], body: nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw OAuthError.transport("cursor auth polling failed: \(error.localizedDescription)")
                }
                continue
            }
            if response.statusCode == 404 {
                consecutiveErrors = 0
                continue
            }
            if response.statusCode >= 400 {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw OAuthError.refreshFailed("cursor poll \(response.statusCode)")
                }
                continue
            }
            consecutiveErrors = 0
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let access = obj["accessToken"] as? String, !access.isEmpty else {
                continue
            }
            let refresh = obj["refreshToken"] as? String ?? ""
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            return OAuthCredentials(
                access: access,
                refresh: refresh.isEmpty ? access : refresh,
                // A token without a JWT `exp` gets an hour, minus the same
                // 5-minute margin every other expiry carries.
                expires: OAuth.jwtExpiryMillis(access) ?? (now + 55 * 60 * 1000)
            )
        }
        throw OAuthLoginError.timedOut
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

        await callbacks.onUserCode?(userCode, verifyURL)
        callbacks.onProgress("enter code in your browser: \(userCode)")
        return try await present(verifyURL, callbacks: callbacks) {
            try await pollGitHubCopilot(
                clientID: clientID, deviceCode: deviceCode, interval: interval, client: client
            )
        }
    }

    private static func pollGitHubCopilot(
        clientID: String,
        deviceCode: String,
        interval: Int,
        client: HTTPClient
    ) async throws -> OAuthCredentials {
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
    // `loginKimi`. Every request carries the `X-Msh-*` device headers, and
    // Kimi binds the grant to `X-Msh-Device-Id`: the id is returned in
    // `extras.deviceId` so whoever refreshes the login sends the same one.

    public static func loginKimiCoding(
        clientID: String = KimiOAuth.clientID,
        host: URL = KimiOAuth.host,
        // The device fingerprint. Nil uses this machine's, with the id
        // persisted at `~/.kwwk/kimi-device-id`; an app passes its own.
        identity: KimiDeviceIdentity? = nil,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let identity = identity ?? .host()
        var headers = KimiOAuth.commonHeaders(identity: identity)
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
        let grant = try DeviceGrant(deviceBody, provider: "kimi", requireHTTPS: false)

        var credentials = try await runDeviceFlow(
            grant,
            provider: "kimi",
            tokenURL: host.appendingPathComponent("api/oauth/token"),
            headers: headers,
            clientID: clientID,
            defaultTokenLifetime: 15 * 60,
            callbacks: callbacks,
            client: client
        )
        credentials.extras["deviceId"] = .string(identity.deviceId)
        return credentials
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
        // The verification URI is handed to the browser; refuse anything a
        // malicious response could use to launch a non-https handler.
        let grant = try DeviceGrant(deviceBody, provider: "xai", requireHTTPS: true)

        return try await runDeviceFlow(
            grant,
            provider: "xai",
            tokenURL: XaiOAuth.tokenURL,
            headers: headers,
            clientID: clientID,
            defaultTokenLifetime: 3600,
            callbacks: callbacks,
            client: client
        )
    }

    // MARK: - RFC 8628 device grant

    /// The device-authorization answer the user approves against.
    struct DeviceGrant: Sendable {
        let userCode: String
        let deviceCode: String
        let verificationURL: URL
        /// Seconds between polls. RFC 8628 allows 0 (no minimum wait); only
        /// negative or malformed values fall back to the default.
        let interval: Int
        let expiresIn: Int

        init(_ body: Data, provider: String, requireHTTPS: Bool) throws {
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let userCode = obj["user_code"] as? String,
                  let deviceCode = obj["device_code"] as? String,
                  let verifyURLString = (obj["verification_uri_complete"] as? String)
                    ?? (obj["verification_uri"] as? String),
                  let verifyURL = URL(string: verifyURLString),
                  !requireHTTPS || verifyURL.scheme == "https" else {
                throw OAuthError.invalidResponse("\(provider) device code response")
            }
            self.userCode = userCode
            self.deviceCode = deviceCode
            self.verificationURL = verifyURL
            self.interval = (obj["interval"] as? Int).flatMap { $0 >= 0 ? $0 : nil } ?? 5
            self.expiresIn = (obj["expires_in"] as? Int) ?? 15 * 60
        }
    }

    /// Shows the code, opens the verification page, and polls the token
    /// endpoint until the user approves, declines or the code expires.
    static func runDeviceFlow(
        _ grant: DeviceGrant,
        provider: String,
        tokenURL: URL,
        headers: [String: String],
        clientID: String,
        defaultTokenLifetime: Int,
        callbacks: Callbacks,
        client: HTTPClient
    ) async throws -> OAuthCredentials {
        await callbacks.onUserCode?(grant.userCode, grant.verificationURL)
        callbacks.onProgress("enter code in your browser: \(grant.userCode)")
        let form = Data(OAuth.urlEncodedForm([
            "client_id": clientID,
            "device_code": grant.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]).utf8)
        return try await present(grant.verificationURL, callbacks: callbacks) {
            let deadline = Date().addingTimeInterval(TimeInterval(grant.expiresIn))
            var interval = grant.interval
            // A gateway blip — a thrown request or a non-JSON error page — must
            // not kill an approval the user is halfway through; only three in a
            // row give up.
            var consecutiveErrors = 0

            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                let response: HTTPURLResponse
                let body: Data
                do {
                    (response, body) = try await client.request(
                        url: tokenURL, method: "POST", headers: headers, body: form
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        throw OAuthError.transport("\(provider) device flow: \(error.localizedDescription)")
                    }
                    continue
                }
                guard let polled = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                    if response.statusCode >= 400 {
                        consecutiveErrors += 1
                        if consecutiveErrors >= 3 {
                            throw OAuthError.refreshFailed("\(provider) device flow: HTTP \(response.statusCode)")
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
                        interval += 5
                        if let serverInterval = polled["interval"] as? Int, serverInterval > interval {
                            interval = serverInterval
                        }
                        continue
                    case "expired_token":
                        throw OAuthLoginError.timedOut
                    case "access_denied", "authorization_denied":
                        throw OAuthLoginError.cancelled
                    default:
                        let description = (polled["error_description"] as? String).map { ": \($0)" } ?? ""
                        throw OAuthLoginError.denied("\(provider) \(err)\(description)")
                    }
                }
                if response.statusCode < 400, let access = polled["access_token"] as? String {
                    // `offline_access` is in the requested scope, so the grant
                    // must carry a refresh token — without one the login would
                    // silently die at first expiry.
                    guard let refresh = polled["refresh_token"] as? String, !refresh.isEmpty else {
                        throw OAuthError.invalidResponse("\(provider) token response missing refresh token")
                    }
                    let expiresIn = (polled["expires_in"] as? Int) ?? defaultTokenLifetime
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    return OAuthCredentials(
                        access: access,
                        refresh: refresh,
                        expires: now + Int64(expiresIn) * 1000 - 5 * 60 * 1000
                    )
                }
            }
            throw OAuthLoginError.timedOut
        }
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
        let server = try await openLoopback(callbacks, port: port)
        defer { server.stop() }

        var comps = URLComponents(url: OpenRouterOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "callback_url", value: server.redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        callbacks.onProgress("waiting for OpenRouter callback on \(server.redirectURI)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "openrouter")
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

    // MARK: - Devin (browser PKCE callback flow)
    //
    // Ported from oh-my-pi's `auth/devin.kdl` (`login "oauth-code"`): a PKCE
    // authorization-code grant against app.devin.ai with a loopback callback
    // on 127.0.0.1:59653, then a JSON code exchange at api.devin.ai that
    // returns a long-lived session token. There is no refresh token — the
    // expiry comes from the token's JWT `exp` (falling back to one year) and
    // the user re-runs `/login devin` when it lapses.

    public static func loginDevin(
        port: UInt16 = DevinOAuth.callbackPort,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let state = UUID().uuidString.lowercased()
        // Devin registered the numeric loopback host, not `localhost`.
        let server = try await openLoopback(
            callbacks, host: DevinOAuth.callbackHost, port: port, path: DevinOAuth.callbackPath
        )
        defer { server.stop() }
        let redirectURI = server.redirectURI

        var comps = URLComponents(url: DevinOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        callbacks.onProgress("Sign in to Devin in your browser — waiting for the callback on \(redirectURI)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "devin")
        guard params["state"] == state else {
            throw OAuthError.invalidResponse("devin callback state mismatch")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("devin callback had no code")
        }

        callbacks.onProgress("exchanging authorization code for a Devin session token…")
        let (response, responseBody) = try await client.request(
            url: DevinOAuth.tokenURL,
            method: "POST",
            headers: ["content-type": "application/json", "accept": "application/json"],
            body: try JSONSerialization.data(withJSONObject: [
                "code": code,
                "code_verifier": pkce.verifier,
            ])
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("devin token exchange \(response.statusCode): \(String(data: responseBody, encoding: .utf8) ?? "")")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else {
            throw OAuthError.invalidResponse("devin token exchange response carried no token")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: token,
            refresh: "",
            expires: OAuth.jwtExpiryMillis(token) ?? (now + DevinOAuth.fallbackLifetimeMs - 5 * 60 * 1000),
            extras: [
                "apiEndpoint": .string(DevinOAuth.apiEndpoint),
                "enterpriseUrl": .string(DevinOAuth.enterpriseURL),
            ]
        )
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
        let server = try await openLoopback(callbacks, port: port)
        defer { server.stop() }
        let redirect = server.redirectURI

        var comps = URLComponents(url: ZaiOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "state", value: state),
        ]
        callbacks.onProgress("waiting for Z.AI callback on \(redirect)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "zai")
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
