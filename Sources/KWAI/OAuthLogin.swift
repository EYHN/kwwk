import Foundation

/// Whole-flow orchestrator: build the authorize URL, bring up a local
/// callback server, launch the user's browser, exchange the received code
/// for tokens. Returns persistable `OAuthCredentials`.
///
/// Each provider gets a static factory because the URLs, scopes, and
/// redirect ports differ.
public enum OAuthLogin {

    /// Hooks the orchestrator calls as the flow progresses. Defaults print to
    /// stderr; GUI apps can plug their own handlers to render progress.
    public struct Callbacks: Sendable {
        public var onAuthURL: @Sendable (URL) -> Void
        public var onProgress: @Sendable (String) -> Void
        public var onPrompt: @Sendable (String) async throws -> String

        public init(
            onAuthURL: @escaping @Sendable (URL) -> Void = Self.defaultAuthURL,
            onProgress: @escaping @Sendable (String) -> Void = Self.defaultProgress,
            onPrompt: @escaping @Sendable (String) async throws -> String = Self.defaultPrompt
        ) {
            self.onAuthURL = onAuthURL
            self.onProgress = onProgress
            self.onPrompt = onPrompt
        }

        public static let defaultAuthURL: @Sendable (URL) -> Void = { url in
            let msg = "open in your browser:\n  \(url.absoluteString)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            Browser.open(url)
        }

        public static let defaultProgress: @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("\(msg)\n".utf8))
        }

        public static let defaultPrompt: @Sendable (String) async throws -> String = { question in
            FileHandle.standardError.write(Data("\(question) ".utf8))
            guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw OAuthError.transport("no terminal input")
            }
            return line
        }
    }

    // MARK: - Anthropic

    public static func loginAnthropic(
        callbacks: Callbacks = Callbacks(),
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        #if canImport(Network)
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
        #else
        throw OAuthError.transport("Network.framework not available on this platform")
        #endif
    }

    // MARK: - OpenAI Codex

    public static func loginOpenAICodex(
        callbacks: Callbacks = Callbacks(),
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        #if canImport(Network)
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
        #else
        throw OAuthError.transport("Network.framework not available")
        #endif
    }

    // MARK: - Google (Gemini CLI)

    public static func loginGeminiCLI(
        callbacks: Callbacks = Callbacks(),
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        #if canImport(Network)
        let port: UInt16 = 8085
        let server = try OAuthCallbackServer(port: port, path: "/oauth2callback")
        defer { server.stop() }

        let clientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
        let clientSecret = "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"
        let state = PKCE.randomHex()
        let scopes = [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile",
        ].joined(separator: " ")

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: server.redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        callbacks.onAuthURL(comps.url!)
        callbacks.onProgress("waiting for Google callback on \(server.redirectURI)…")

        let params = try await server.waitForCallback()
        guard let code = params["code"] else {
            throw OAuthError.invalidResponse("google callback had no code")
        }
        if params["state"] != state {
            throw OAuthError.invalidResponse("google OAuth state mismatch")
        }

        callbacks.onProgress("exchanging authorization code…")
        let form = OAuth.urlEncodedForm([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": server.redirectURI,
        ])
        let (response, body) = try await client.request(
            url: URL(string: "https://oauth2.googleapis.com/token")!,
            method: "POST",
            headers: [
                "content-type": "application/x-www-form-urlencoded",
                "accept": "application/json",
            ],
            body: Data(form.utf8)
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("google exchange \(response.statusCode): \(String(data: body, encoding: .utf8) ?? "")")
        }
        let json = try OAuth.decodeTokenResponse(body)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? "",
            expires: now + Int64(json.expiresIn * 1000) - 5 * 60 * 1000,
            extras: [:]
        )
        #else
        throw OAuthError.transport("Network.framework not available")
        #endif
    }

    // MARK: - GitHub Copilot (device flow)
    //
    // Copilot uses GitHub's device-authorization grant: we POST to
    // `/login/device/code`, show the user the one-time `user_code`, and
    // poll `/login/oauth/access_token` until the user enters the code in
    // their browser. No callback server.

    public static func loginGitHubCopilot(
        clientID: String = "Iv1.b507a08c87ecfe98",
        callbacks: Callbacks = Callbacks(),
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

// MARK: - Browser launcher

public enum Browser {
    /// Best-effort URL opener. On macOS runs `/usr/bin/open`; falls back to
    /// stderr-printing so the user can click manually.
    public static func open(_ url: URL) {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        do { try process.run() } catch {
            FileHandle.standardError.write(Data(
                "unable to launch browser: \(error). URL:\n  \(url.absoluteString)\n".utf8
            ))
        }
        #else
        FileHandle.standardError.write(Data(
            "please open manually:\n  \(url.absoluteString)\n".utf8
        ))
        #endif
    }
}
