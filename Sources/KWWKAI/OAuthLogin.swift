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
