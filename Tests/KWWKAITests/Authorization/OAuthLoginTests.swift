import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

@Suite("PKCE")
struct PKCETests {
    @Test("verifier/challenge are base64url (no +/= padding)")
    func encoding() {
        let pkce = PKCE.random()
        for c in pkce.verifier + pkce.challenge {
            #expect(c != "+" && c != "/" && c != "=")
        }
        // Verifier is 32 random bytes → 43 base64url chars.
        #expect(pkce.verifier.count == 43)
        // SHA256 hex is 32 bytes → 43 base64url chars.
        #expect(pkce.challenge.count == 43)
    }

    @Test("random() yields a fresh verifier each call")
    func fresh() {
        let a = PKCE.random().verifier
        let b = PKCE.random().verifier
        #expect(a != b)
    }

    @Test("randomHex returns the requested byte length in hex")
    func hex() {
        let s = PKCE.randomHex(bytes: 16)
        #expect(s.count == 32)
        for c in s {
            #expect(c.isHexDigit)
        }
    }
}

@Suite("OAuth callback server")
struct OAuthCallbackServerTests {
    @Test("captures code + state from a real localhost GET")
    func receivesCallback() async throws {
        // Pick a port unlikely to collide on CI.
        let port: UInt16 = 53980
        let server = try OAuthCallbackServer(port: port)
        // Drive the client after the server is listening.
        Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let url = URL(string: "http://localhost:\(port)/callback?code=abc&state=xyz")!
            _ = try? await URLSession.shared.data(from: url)
        }
        let params = try await server.waitForCallback()
        #expect(params["code"] == "abc")
        #expect(params["state"] == "xyz")
    }

    @Test("a callback landing before waitForCallback is buffered, not dropped")
    func earlyCallbackBuffered() async throws {
        // Regression: a GET arriving between the port bind and the
        // continuation registration used to resolve into the void, leaving
        // waitForCallback to throw "already resolved" (seen on Linux CI,
        // where the test-driven callback outpaced the wait).
        let port: UInt16 = 53985
        let server = try OAuthCallbackServer(port: port)
        try server.start()
        // Complete the callback request fully before anyone waits.
        let url = URL(string: "http://localhost:\(port)/callback?code=early")!
        _ = try await URLSession.shared.data(from: url)
        let params = try await server.waitForCallback()
        #expect(params["code"] == "early")
    }

    @Test("port 0 binds any free port, and the redirect URI names the one it got")
    func ephemeralPort() async throws {
        let server = try OAuthCallbackServer(port: 0, path: "/authorize", redirectHost: "127.0.0.1")
        try await server.listen()
        defer { server.stop() }
        let redirect = try #require(URLComponents(string: server.redirectURI))
        #expect(redirect.host == "127.0.0.1")
        #expect(redirect.path == "/authorize")
        let port = try #require(redirect.port)
        #expect(port > 1023)

        async let wait: [String: String] = server.waitForCallback()
        // A request with no payload is answered and the flow keeps waiting:
        // a probe must not end a sign-in the user is still completing.
        let (_, probe) = try await URLSession.shared.data(from: URL(string: server.redirectURI)!)
        #expect((probe as? HTTPURLResponse)?.statusCode == 404)

        // Trae's page comes back with `authCodeInfo` where an OAuth redirect
        // has `code`.
        var page = redirect
        page.queryItems = [
            URLQueryItem(name: "authCodeInfo", value: #"{"AuthCode":"code-1"}"#),
            URLQueryItem(name: "loginTraceID", value: "trace-1"),
        ]
        let (_, answer) = try await URLSession.shared.data(from: try #require(page.url))
        #expect((answer as? HTTPURLResponse)?.statusCode == 200)
        let params = try await wait
        #expect(params["authCodeInfo"] == #"{"AuthCode":"code-1"}"#)
        #expect(params["loginTraceID"] == "trace-1")
        // The address stays the one the page was given after the port is released.
        #expect(server.redirectURI == redirect.string)
    }

    @Test("a page that asks before it reports back is told it may")
    func preflight() async throws {
        let server = try OAuthCallbackServer(port: 0)
        try await server.listen()
        defer { server.stop() }
        var request = URLRequest(url: URL(string: server.redirectURI)!)
        request.httpMethod = "OPTIONS"
        let (_, response) = try await URLSession.shared.data(for: request)
        let answer = try #require(response as? HTTPURLResponse)
        #expect(answer.statusCode == 204)
        #expect(answer.value(forHTTPHeaderField: "access-control-allow-origin") == "*")
    }

    @Test("cancel() unblocks waitForCallback with a CancellationError")
    func cancelUnblocks() async throws {
        let server = try OAuthCallbackServer(port: 53981)
        async let wait: [String: String] = server.waitForCallback()
        try? await Task.sleep(nanoseconds: 20_000_000)
        server.cancel()
        do {
            _ = try await wait
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

@Suite("OAuth login — shape")
struct OAuthLoginShapeTests {
    /// We can't mock the HTTP for the authorization phase (it requires user
    /// action in a browser), but we can verify the URLs we instruct the
    /// browser to visit have the right parameters.
    @Test("redirect URI uses the port we opened") func redirectURI() throws {
        let server = try OAuthCallbackServer(port: 53982)
        defer { server.stop() }
        #expect(server.redirectURI == "http://localhost:53982/callback")
    }

    @Test("GitHub's page is opened with the code in the link, and reported as not holding it")
    func copilotVerificationURLCarriesCode() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"AB12-CD34","verification_uri":"https://github.com/login/device","interval":0}"#
        ))
        client.queue.append((status: 200, body: #"{"access_token":"ghp_access"}"#))
        client.queue.append((
            status: 200,
            body: #"{"token":"session-xyz","expires_at":1900000000,"endpoints":{"api":"https://api.githubcopilot.com"}}"#
        ))
        let opened = LockedBox<[URL]>([])
        let announced = LockedBox<[OAuthLogin.DeviceCode]>([])
        _ = try await OAuthLogin.loginGitHubCopilot(
            clientID: "test-client",
            callbacks: OAuthLogin.Callbacks(
                onAuthURL: { url in opened.set(opened.get() + [url]) }, onProgress: { _ in },
                onDeviceCode: { code in announced.set(announced.get() + [code]) }
            ),
            client: client,
            pollSleep: { _ in }
        )
        #expect(opened.get().map(\.absoluteString) == ["https://github.com/login/device?user_code=AB12-CD34"])
        // GitHub's page ignores the code in the link: the host must show or
        // copy it.
        #expect(announced.get().map(\.code) == ["AB12-CD34"])
        #expect(announced.get().map(\.pageHoldsCode) == [false])
    }

    @Test("device-flow keeps the longer interval GitHub asks for after slow_down")
    func copilotDeviceFlowSlowDown() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://github.com/login/device","interval":5}"#
        ))
        // GitHub's own answer: the error, and the interval it now holds the code to.
        client.queue.append((
            status: 200,
            body: #"{"error":"slow_down","error_description":"Too many requests have been made in the same timeframe.","interval":10}"#
        ))
        client.queue.append((status: 200, body: #"{"error":"authorization_pending"}"#))
        // A second one that names no interval still adds RFC 8628's 5 s.
        client.queue.append((status: 200, body: #"{"error":"slow_down"}"#))
        client.queue.append((status: 200, body: #"{"access_token":"ghp_access"}"#))
        client.queue.append((
            status: 200,
            body: #"{"token":"session-xyz","expires_at":1900000000,"endpoints":{"api":"https://api.githubcopilot.com"}}"#
        ))

        let waits = LockedBox<[Int]>([])
        let creds = try await OAuthLogin.loginGitHubCopilot(
            clientID: "test-client",
            callbacks: OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in }),
            client: client,
            pollSleep: { seconds in waits.set(waits.get() + [seconds]) }
        )
        #expect(creds.refresh == "ghp_access")
        // One wait per poll: the raise holds for every poll after it.
        #expect(waits.get() == [5, 10, 10, 15])
    }

    @Test("device-flow rides a poll hiccup, and fails after five in a row instead of waiting out the timeout")
    func copilotDeviceFlowPollMisses() async throws {
        let device = (
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://github.com/login/device","interval":0}"#
        )
        let callbacks = OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in })

        // A proxy's page between two answers is asked again.
        let hiccup = SequentialStubClient()
        hiccup.queue.append(device)
        hiccup.queue.append((status: 200, body: "<html>proxy</html>"))
        hiccup.queue.append((status: 502, body: "<html>bad gateway</html>"))
        hiccup.queue.append((status: 200, body: #"{"access_token":"ghp_access"}"#))
        hiccup.queue.append((
            status: 200,
            body: #"{"token":"session-xyz","expires_at":1900000000,"endpoints":{"api":"https://api.githubcopilot.com"}}"#
        ))
        let creds = try await OAuthLogin.loginGitHubCopilot(
            clientID: "test-client", callbacks: callbacks, client: hiccup, pollSleep: { _ in }
        )
        #expect(creds.refresh == "ghp_access")

        // An OAuth error on a 400, as RFC 8628 sends it, is an answer: any
        // number of them is still the user taking their time.
        let pending = SequentialStubClient()
        pending.queue.append(device)
        for _ in 0..<6 { pending.queue.append((status: 400, body: #"{"error":"authorization_pending"}"#)) }
        pending.queue.append((status: 200, body: #"{"access_token":"ghp_access"}"#))
        pending.queue.append((
            status: 200,
            body: #"{"token":"session-xyz","expires_at":1900000000,"endpoints":{"api":"https://api.githubcopilot.com"}}"#
        ))
        let waited = try await OAuthLogin.loginGitHubCopilot(
            clientID: "test-client", callbacks: callbacks, client: pending, pollSleep: { _ in }
        )
        #expect(waited.refresh == "ghp_access")

        // Five in a row is not a hiccup.
        let down = SequentialStubClient()
        down.queue.append(device)
        for _ in 0..<5 { down.queue.append((status: 502, body: "<html>bad gateway</html>")) }
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginGitHubCopilot(
                clientID: "test-client", callbacks: callbacks, client: down, pollSleep: { _ in }
            )
        }
        #expect(down.recorded.count == 6)
    }

    @Test("device-flow polls with device_code + grant_type")
    func copilotDeviceFlowShape() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://github.com/login/device","interval":0}"#
        ))
        client.queue.append((
            status: 200,
            body: #"{"access_token":"ghp_access","scope":"read:user","token_type":"bearer"}"#
        ))
        client.queue.append((
            status: 200,
            body: #"{"token":"session-xyz","expires_at":1900000000,"endpoints":{"api":"https://api.githubcopilot.com"}}"#
        ))

        let creds = try await OAuthLogin.loginGitHubCopilot(
            clientID: "test-client",
            callbacks: OAuthLogin.Callbacks(
                onAuthURL: { _ in },
                onProgress: { _ in }
            ),
            client: client
        )
        #expect(creds.access == "session-xyz")
        #expect(creds.refresh == "ghp_access")

        // First call: device code request.
        #expect(client.recorded[0].url.absoluteString.contains("login/device/code"))
        // Second call: token poll.
        let pollBody = String(data: client.recorded[1].body ?? Data(), encoding: .utf8) ?? ""
        #expect(pollBody.contains("device_code=DC"))
        #expect(pollBody.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    @Test("kimi device flow rides authorization_pending and returns both tokens")
    func kimiDeviceFlowShape() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC-1234","verification_uri":"https://auth.kimi.com/device","verification_uri_complete":"https://auth.kimi.com/device?code=UC-1234","interval":0,"expires_in":900}"#
        ))
        client.queue.append((
            status: 400,
            body: #"{"error":"authorization_pending"}"#
        ))
        client.queue.append((
            status: 200,
            body: #"{"access_token":"kimi-access","refresh_token":"kimi-refresh","expires_in":3600}"#
        ))

        let authURL = CapturedURL()
        let creds = try await OAuthLogin.loginKimiCoding(
            clientID: "test-client",
            identity: .host(deviceId: "test-device"),
            callbacks: OAuthLogin.Callbacks(
                onAuthURL: { authURL.set($0) },
                onProgress: { _ in }
            ),
            client: client
        )
        #expect(creds.access == "kimi-access")
        #expect(creds.refresh == "kimi-refresh")
        // The complete verification URL (with the embedded code) is preferred.
        #expect(authURL.get()?.absoluteString == "https://auth.kimi.com/device?code=UC-1234")

        // First call: device authorization request with the fingerprint headers.
        let device = client.recorded[0]
        #expect(device.url.absoluteString == "https://auth.kimi.com/api/oauth/device_authorization")
        let deviceBody = String(data: device.body ?? Data(), encoding: .utf8) ?? ""
        #expect(deviceBody == "client_id=test-client")
        #expect(device.headers["X-Msh-Platform"] == "kimi_cli")
        #expect(device.headers["X-Msh-Device-Id"] == "test-device")
        #expect(device.headers["User-Agent"]?.hasPrefix("KimiCLI/") == true)

        // Polls carry device_code + the device-code grant; the pending
        // response is retried rather than surfaced.
        #expect(client.recorded.count == 3)
        for poll in client.recorded[1...] {
            #expect(poll.url.absoluteString == "https://auth.kimi.com/api/oauth/token")
            let body = String(data: poll.body ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("device_code=DC"))
            #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
        }
    }

    @Test("kimi device flow rides a transient non-JSON HTTP error")
    func kimiDeviceFlowTransientError() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://auth.kimi.com/device","interval":0,"expires_in":900}"#
        ))
        // A gateway blip with an HTML body must be retried, not surfaced.
        client.queue.append((status: 502, body: "<html>bad gateway</html>"))
        client.queue.append((
            status: 200,
            body: #"{"access_token":"kimi-access","refresh_token":"kimi-refresh","expires_in":3600}"#
        ))
        let creds = try await OAuthLogin.loginKimiCoding(
            clientID: "test-client",
            identity: .host(deviceId: "test-device"),
            callbacks: OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in }),
            client: client
        )
        #expect(creds.access == "kimi-access")
        #expect(client.recorded.count == 3)
    }

    @Test("kimi device flow aborts after 3 consecutive hard HTTP errors")
    func kimiDeviceFlowConsecutiveErrors() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://auth.kimi.com/device","interval":0,"expires_in":900}"#
        ))
        for _ in 0..<3 {
            client.queue.append((status: 502, body: "<html>bad gateway</html>"))
        }
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginKimiCoding(
                clientID: "test-client",
                identity: .host(deviceId: "test-device"),
                callbacks: OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in }),
                client: client
            )
        }
        #expect(client.recorded.count == 4)
    }

    @Test("kimi device flow surfaces access_denied instead of polling forever")
    func kimiDeviceFlowDenied() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://auth.kimi.com/device","interval":0,"expires_in":900}"#
        ))
        client.queue.append((
            status: 400,
            body: #"{"error":"access_denied"}"#
        ))
        await #expect(throws: OAuthLoginError.cancelled) {
            _ = try await OAuthLogin.loginKimiCoding(
                clientID: "test-client",
                identity: .host(deviceId: "test-device"),
                callbacks: OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in }),
                client: client
            )
        }
    }

    @Test("kimi token response without a refresh token is rejected")
    func kimiDeviceFlowMissingRefresh() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://auth.kimi.com/device","interval":0,"expires_in":900}"#
        ))
        client.queue.append((
            status: 200,
            body: #"{"access_token":"kimi-access","expires_in":3600}"#
        ))
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginKimiCoding(
                clientID: "test-client",
                identity: .host(deviceId: "test-device"),
                callbacks: OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in }),
                client: client
            )
        }
    }

    @Test("xai device flow rides authorization_pending and returns both tokens")
    func xaiDeviceFlowShape() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC-1234","verification_uri":"https://auth.x.ai/activate","verification_uri_complete":"https://auth.x.ai/activate?code=UC-1234","interval":0,"expires_in":900}"#
        ))
        client.queue.append((
            status: 400,
            body: #"{"error":"authorization_pending"}"#
        ))
        client.queue.append((
            status: 200,
            body: #"{"access_token":"xai-access","refresh_token":"xai-refresh","expires_in":3600}"#
        ))

        let authURL = CapturedURL()
        let creds = try await OAuthLogin.loginXai(
            clientID: "test-client",
            callbacks: OAuthLogin.Callbacks(
                onAuthURL: { authURL.set($0) },
                onProgress: { _ in }
            ),
            client: client
        )
        #expect(creds.access == "xai-access")
        #expect(creds.refresh == "xai-refresh")
        // The complete verification URL (with the embedded code) is preferred.
        #expect(authURL.get()?.absoluteString == "https://auth.x.ai/activate?code=UC-1234")

        // First call: device authorization request with client id + scope.
        let device = client.recorded[0]
        #expect(device.url.absoluteString == "https://auth.x.ai/oauth2/device/code")
        let deviceBody = String(data: device.body ?? Data(), encoding: .utf8) ?? ""
        #expect(deviceBody.contains("client_id=test-client"))
        #expect(deviceBody.contains("scope="))
        #expect(deviceBody.contains("grok-cli%3Aaccess"))

        // Polls carry device_code + the device-code grant; the pending
        // response is retried rather than surfaced.
        #expect(client.recorded.count == 3)
        for poll in client.recorded[1...] {
            #expect(poll.url.absoluteString == "https://auth.x.ai/oauth2/token")
            let body = String(data: poll.body ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("device_code=DC"))
            #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
        }
    }

    @Test("xai device flow surfaces authorization_denied instead of polling forever")
    func xaiDeviceFlowDenied() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://auth.x.ai/activate","interval":0,"expires_in":900}"#
        ))
        client.queue.append((
            status: 400,
            body: #"{"error":"authorization_denied"}"#
        ))
        await #expect(throws: OAuthLoginError.cancelled) {
            _ = try await OAuthLogin.loginXai(
                clientID: "test-client",
                callbacks: OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in }),
                client: client
            )
        }
    }

    @Test("xai token response without a refresh token is rejected")
    func xaiDeviceFlowMissingRefresh() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://auth.x.ai/activate","interval":0,"expires_in":900}"#
        ))
        client.queue.append((
            status: 200,
            body: #"{"access_token":"xai-access","expires_in":3600}"#
        ))
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginXai(
                clientID: "test-client",
                callbacks: OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in }),
                client: client
            )
        }
    }

    @Test("xai device flow rejects a non-https verification URI")
    func xaiDeviceFlowInsecureVerifyURI() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"device_code":"DC","user_code":"UC","verification_uri":"javascript:alert(1)","interval":0,"expires_in":900}"#
        ))
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginXai(
                clientID: "test-client",
                callbacks: OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in }),
                client: client
            )
        }
    }

    // MARK: - OpenRouter

    /// Drive the local callback once the flow's server is up. `onAuthURL`
    /// fires just before `waitForCallback` binds the port, so retry the GET
    /// until it lands.
    private func fireCallback(port: UInt16, query: String) {
        Task.detached {
            let cb = URL(string: "http://localhost:\(port)/callback?\(query)")!
            for _ in 0..<50 {
                if (try? await URLSession.shared.data(from: cb)) != nil { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    @Test("openrouter login exchanges the callback code for a permanent key")
    func openRouterLoginFlow() async throws {
        let client = SequentialStubClient()
        client.queue.append((status: 200, body: #"{"key":"sk-or-v1-minted"}"#))
        let port: UInt16 = 53983
        let authURL = CapturedURL()
        let creds = try await OAuthLogin.loginOpenRouter(
            port: port,
            callbacks: OAuthLogin.Callbacks(
                onAuthURL: { url in
                    authURL.set(url)
                    self.fireCallback(port: port, query: "code=OR-CODE")
                },
                onProgress: { _ in },
                loopback: OAuthLogin.nioLoopback
            ),
            client: client
        )
        // OpenRouter mints a permanent key — sentinel credentials shape.
        #expect(creds.access == "sk-or-v1-minted")
        #expect(creds.refresh == "")
        #expect(creds.expires == .max)

        // Authorize URL carries the callback + PKCE challenge.
        let auth = try #require(authURL.get())
        let comps = try #require(URLComponents(url: auth, resolvingAgainstBaseURL: false))
        #expect(comps.host == "openrouter.ai")
        #expect(comps.path == "/auth")
        let query = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["callback_url"] == "http://localhost:\(port)/callback")
        #expect(query["code_challenge"]?.isEmpty == false)
        #expect(query["code_challenge_method"] == "S256")

        // Exchange request: keys endpoint, JSON body with code + verifier.
        #expect(client.recorded.count == 1)
        let exchange = client.recorded[0]
        #expect(exchange.url.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
        let body = try JSONSerialization.jsonObject(with: exchange.body ?? Data()) as? [String: Any]
        #expect(body?["code"] as? String == "OR-CODE")
        #expect((body?["code_verifier"] as? String)?.isEmpty == false)
        #expect(body?["code_challenge_method"] as? String == "S256")
    }

    @Test("openrouter exchange response without a key is rejected")
    func openRouterMissingKey() async throws {
        let client = SequentialStubClient()
        client.queue.append((status: 200, body: #"{}"#))
        let port: UInt16 = 53984
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginOpenRouter(
                port: port,
                callbacks: OAuthLogin.Callbacks(
                    onAuthURL: { _ in self.fireCallback(port: port, query: "code=OR-CODE") },
                    onProgress: { _ in },
                    loopback: OAuthLogin.nioLoopback
                ),
                client: client
            )
        }
    }

    // MARK: - Z.AI

    /// ZCode's flow as zcode.z.ai opened it on 2026-10-15, cut to the fields
    /// that are read.
    private static let zcodeInit =
        #"{"code":0,"data":{"flow_id":"f1","poll_token":"pt","authorize_url":"https://chat.z.ai/api/oauth/authorize?client_id=client_P8X5CMWmlaRO9gyO-KSqtg&redirect_uri=https://zcode.z.ai/api/v1/oauth/cli/callback/zai&state=s1&response_type=code","expires_at":4102444800,"poll_interval_sec":2}}"#

    /// The flow opened, polled once while the browser is still out, then
    /// ready with Z.ai's access token.
    private static let zcodeSignedIn: [(status: Int, body: String)] = [
        (200, Self.zcodeInit),
        (200, #"{"code":0,"data":{"status":"pending"}}"#),
        (200, #"{"code":0,"data":{"status":"ready","token":"zcode-session","zai":{"access_token":"oauth-tok"},"user":{"user_id":"u7","email":"e@x.ai"}}}"#),
    ]

    private func zaiCallbacks(
        opened: CapturedURL = CapturedURL(),
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) -> OAuthLogin.Callbacks {
        OAuthLogin.Callbacks(onAuthURL: { url in opened.set(url) }, onProgress: progress)
    }

    @Test("zai login polls ZCode's flow and provisions a durable id.secret key")
    func zaiLoginFlow() async throws {
        let client = SequentialStubClient()
        client.queue.append(contentsOf: Self.zcodeSignedIn)
        // business login (envelope code 200)
        client.queue.append((
            status: 200,
            body: #"{"code":200,"success":true,"data":{"access_token":"biz-tok"}}"#
        ))
        // customer info → default org/project
        client.queue.append((
            status: 200,
            body: #"{"code":200,"data":{"organizations":[{"organizationId":"org-1","isDefault":true,"projects":[{"projectId":"proj-1","isDefault":true}]}]}}"#
        ))
        // api key list (empty → create)
        client.queue.append((status: 200, body: #"{"code":200,"data":[]}"#))
        // create
        client.queue.append((status: 200, body: #"{"code":200,"data":{"apiKey":"ak-123"}}"#))
        // copy → full secret
        client.queue.append((status: 200, body: #"{"code":200,"data":{"secretKey":"sk-456"}}"#))
        // the key's subscriptions → a valid GLM Coding Plan
        client.queue.append((status: 200, body: Self.zaiLitePlan))

        let opened = CapturedURL()
        let waits = LockedBox<[Int]>([])
        let creds = try await OAuthLogin.loginZai(
            callbacks: zaiCallbacks(opened: opened),
            client: client,
            pollSleep: { seconds in waits.set(waits.get() + [seconds]) }
        )
        #expect(creds.access == "ak-123.sk-456")
        #expect(creds.refresh == "")
        #expect(creds.expires == .max)

        // The flow is opened with a bearer only this poller knows, as ZCode.
        let start = client.recorded[0]
        #expect(start.method == "POST")
        #expect(start.url.absoluteString == "https://zcode.z.ai/api/v1/oauth/cli/init")
        let startBody = try JSONSerialization.jsonObject(with: start.body ?? Data()) as? [String: Any]
        #expect(startBody?["provider"] as? String == "zai")
        let bearer = try #require(start.headers["authorization"])
        #expect(bearer.hasPrefix("Bearer ") && bearer.count == 7 + 64)
        #expect(start.headers["user-agent"] == "ZCode/3.14.3")
        let device = try #require(start.headers["x-device-mid"])

        // The page is the flow's, sent back to ZCode's own page, not to a
        // loopback (Z.ai refuses those for this client).
        let page = try #require(opened.get())
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(page.host == "chat.z.ai")
        #expect(query["client_id"] == "client_P8X5CMWmlaRO9gyO-KSqtg")
        #expect(query["state"] == "s1")
        #expect(query["redirect_uri"] == "https://zcode.z.ai/app/oauth/login?redirect=zcode://oauth/callback&app_version=3.14.3")

        // Polled at the flow's interval, with the same bearer and machine.
        #expect(waits.get() == [2, 2])
        for poll in client.recorded[1...2] {
            #expect(poll.method == "GET")
            #expect(poll.url.absoluteString == "https://zcode.z.ai/api/v1/oauth/cli/poll/f1")
            #expect(poll.headers["authorization"] == bearer)
            #expect(poll.headers["x-device-mid"] == device)
        }

        // Then business login → customer → list → create → copy →
        // subscriptions, with the biz bearer on the provisioning calls.
        #expect(client.recorded.count == 9)
        let login = client.recorded[3]
        #expect(login.url.absoluteString == "https://api.z.ai/api/auth/z/login")
        let loginBody = try JSONSerialization.jsonObject(with: login.body ?? Data()) as? [String: Any]
        #expect(loginBody?["token"] as? String == "oauth-tok")

        let customer = client.recorded[4]
        #expect(customer.url.absoluteString.hasSuffix("api/biz/customer/getCustomerInfo"))
        #expect(customer.headers["authorization"] == "Bearer biz-tok")

        let list = client.recorded[5]
        #expect(list.method == "GET")
        #expect(list.url.absoluteString.hasSuffix("organization/org-1/projects/proj-1/api_keys"))

        let create = client.recorded[6]
        #expect(create.method == "POST")
        let createBody = try JSONSerialization.jsonObject(with: create.body ?? Data()) as? [String: Any]
        #expect(createBody?["name"] as? String == "kwwk")

        let copy = client.recorded[7]
        #expect(copy.url.absoluteString.hasSuffix("api_keys/copy/ak-123"))

        // The plan is asked with the minted key itself, bare (no `Bearer`),
        // as ZCode and magpie's zcode plugin ask it.
        let plan = client.recorded[8]
        #expect(plan.method == "GET")
        #expect(plan.url.absoluteString == "https://api.z.ai/api/biz/subscription/list")
        #expect(plan.headers["authorization"] == "ak-123.sk-456")
    }

    @Test("BigModel (智谱) signs in through the same flow, on its own page and business API")
    func zaiChinaLoginFlow() async throws {
        let client = SequentialStubClient()
        // The flow as zcode.z.ai opened it for BigModel on 2026-10-15.
        client.queue.append((200, #"{"code":0,"data":{"flow_id":"f2","authorize_url":"https://bigmodel.cn/login?appId=zcode&redirect=https://zcode.z.ai/api/v1/oauth/cli/callback/bigmodel&state=s2","expires_at":4102444800,"poll_interval_sec":2}}"#))
        // BigModel's token spelled the camel way.
        client.queue.append((200, #"{"code":0,"data":{"status":"ready","bigmodel":{"accessToken":"bm-tok"}}}"#))
        client.queue.append((200, #"{"code":200,"data":{"organizations":[{"organizationId":"org-1","projects":[{"projectId":"proj-1"}]}]}}"#))
        client.queue.append((200, #"{"code":200,"data":[{"name":"kwwk","apiKey":"ak-cn"}]}"#))
        client.queue.append((200, #"{"code":200,"data":{"secretKey":"sk-cn"}}"#))
        client.queue.append((200, Self.zaiLitePlan))

        let opened = CapturedURL()
        let creds = try await OAuthLogin.loginZai(
            site: .china, callbacks: zaiCallbacks(opened: opened), client: client, pollSleep: { _ in }
        )
        #expect(creds.access == "ak-cn.sk-cn")
        #expect(creds.refresh == "")

        let startBody = try JSONSerialization.jsonObject(with: client.recorded[0].body ?? Data()) as? [String: Any]
        #expect(startBody?["provider"] as? String == "bigmodel")

        // BigModel's login page names the way back `redirect`.
        let page = try #require(opened.get())
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(page.host == "bigmodel.cn")
        #expect(query["appId"] == "zcode")
        #expect(query["state"] == "s2")
        #expect(query["redirect"] == "https://zcode.z.ai/app/oauth/login?redirect=zcode://oauth/callback&app_version=3.14.3")
        #expect(query["redirect_uri"] == nil)

        // No business login: BigModel's token goes to its business API bare.
        #expect(client.recorded.count == 6)
        let customer = client.recorded[2]
        #expect(customer.url.absoluteString == "https://bigmodel.cn/api/biz/customer/getCustomerInfo")
        #expect(customer.headers["authorization"] == "bm-tok")
        #expect(client.recorded[3].url.absoluteString == "https://bigmodel.cn/api/biz/v1/organization/org-1/projects/proj-1/api_keys")
        #expect(client.recorded[4].url.absoluteString.hasSuffix("api_keys/copy/ak-cn"))
        // The plan is asked where BigModel serves it, with the key bare.
        let plan = client.recorded[5]
        #expect(plan.url.absoluteString == "https://open.bigmodel.cn/api/biz/subscription/list")
        #expect(plan.headers["authorization"] == "ak-cn.sk-cn")
    }

    @Test("a BigModel account with no plan is sent to BigModel to subscribe")
    func zaiChinaNoPlan() async throws {
        let client = SequentialStubClient()
        client.queue.append((200, #"{"code":0,"data":{"flow_id":"f2","authorize_url":"https://bigmodel.cn/login?appId=zcode&redirect=x&state=s2"}}"#))
        client.queue.append((200, #"{"code":0,"data":{"status":"ready","bigmodel":{"access_token":"bm-tok"}}}"#))
        client.queue.append((200, #"{"code":200,"data":{"organizations":[{"organizationId":"o","projects":[{"projectId":"p"}]}]}}"#))
        client.queue.append((200, #"{"code":200,"data":[{"name":"kwwk","apiKey":"ak"}]}"#))
        client.queue.append((200, #"{"code":200,"data":{"secretKey":"sk"}}"#))
        client.queue.append((200, #"{"code":200,"data":[]}"#))
        do {
            _ = try await OAuthLogin.loginZai(site: .china, callbacks: zaiCallbacks(), client: client, pollSleep: { _ in })
            Issue.record("a planless account signed in")
        } catch {
            #expect(error.localizedDescription.contains("BigModel account has no GLM Coding Plan"))
            #expect(error.localizedDescription.contains("bigmodel.cn/glm-coding"))
        }
    }

    @Test("zai poll rides out a hiccup, and a declined sign-in or a refused flow ends it", arguments: [
        ([(status: 503, body: "busy"), (200, #"{"code":0,"data":{"status":"failed"}}"#)], "declined"),
        ([(status: 404, body: #"{"code":404,"msg":"flow not found"}"#)], "404"),
    ] as [([(status: Int, body: String)], String)])
    func zaiPollEnds(polls: [(status: Int, body: String)], says: String) async throws {
        let client = SequentialStubClient()
        client.queue.append((200, Self.zcodeInit))
        client.queue.append(contentsOf: polls)
        do {
            _ = try await OAuthLogin.loginZai(callbacks: zaiCallbacks(), client: client, pollSleep: { _ in })
            Issue.record("the sign-in finished")
        } catch {
            #expect("\(error)".contains(says) || error.localizedDescription.contains(says), "\(error)")
        }
        #expect(client.recorded.count == 1 + polls.count)
    }

    @Test("a zai flow past its deadline times the sign-in out")
    func zaiPollDeadline() async throws {
        let client = SequentialStubClient()
        client.queue.append((200, #"{"code":0,"data":{"flow_id":"f1","authorize_url":"https://chat.z.ai/api/oauth/authorize?state=s","expires_at":1000000000,"poll_interval_sec":1}}"#))
        await #expect(throws: OAuthLoginError.timedOut) {
            _ = try await OAuthLogin.loginZai(callbacks: zaiCallbacks(), client: client, pollSleep: { _ in })
        }
    }

    @Test("zai login reuses an existing kwwk-named key instead of creating one")
    func zaiLoginReusesKey() async throws {
        let client = SequentialStubClient()
        client.queue.append(contentsOf: Self.zcodeSignedIn)
        client.queue.append((
            status: 200,
            body: #"{"code":200,"data":{"access_token":"biz-tok"}}"#
        ))
        client.queue.append((
            status: 200,
            body: #"{"code":200,"data":{"organizations":[{"organizationId":"org-1","projects":[{"projectId":"proj-1"}]}]}}"#
        ))
        // List already carries the kwwk key (secret masked) — no create call.
        client.queue.append((
            status: 200,
            body: #"{"code":200,"data":[{"name":"kwwk","apiKey":"ak-9"},{"name":"zcode-api-key","apiKey":"ak-other"}]}"#
        ))
        client.queue.append((status: 200, body: #"{"code":200,"data":{"secretKey":"sk-full"}}"#))
        client.queue.append((status: 200, body: Self.zaiLitePlan))

        let creds = try await OAuthLogin.loginZai(callbacks: zaiCallbacks(), client: client, pollSleep: { _ in })
        #expect(creds.access == "ak-9.sk-full")
        #expect(client.recorded.count == 8)
        #expect(client.recorded[6].url.absoluteString.hasSuffix("api_keys/copy/ak-9"))
    }

    @Test("zai envelope failure surfaces the server message")
    func zaiEnvelopeFailure() async throws {
        let client = SequentialStubClient()
        client.queue.append((status: 200, body: #"{"code":500,"msg":"boom"}"#))
        do {
            _ = try await OAuthLogin.loginZai(callbacks: zaiCallbacks(), client: client, pollSleep: { _ in })
            Issue.record("the sign-in finished")
        } catch {
            #expect(error.localizedDescription.contains("boom"))
        }
        #expect(client.recorded.count == 1)
    }

    /// `/api/biz/subscription/list` as api.z.ai answered a Coding Plan key
    /// on 2026-10-12, cut to the fields that are read.
    private static let zaiLitePlan =
        #"{"code":200,"msg":"Operation successful","data":[{"productName":"GLM Coding Lite","status":"VALID","valid":"2027-06-17 10:55:21-2028-06-17 10:55:21","autoRenew":1,"nextRenewTime":"2027-06-17"}],"success":true}"#

    /// Runs the sign-in over `customer` and a key list, up to the plan read.
    private func zaiLogin(
        customer: String,
        keys: String = #"{"code":200,"data":[{"name":"kwwk","apiKey":"ak-9"}]}"#,
        tail: [(status: Int, body: String)],
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> (OAuthCredentials, SequentialStubClient) {
        let client = SequentialStubClient()
        client.queue.append(contentsOf: Self.zcodeSignedIn)
        client.queue.append((status: 200, body: #"{"code":200,"data":{"access_token":"biz-tok"}}"#))
        client.queue.append((status: 200, body: customer))
        client.queue.append((status: 200, body: keys))
        client.queue.append(contentsOf: tail)
        let creds = try await OAuthLogin.loginZai(
            callbacks: zaiCallbacks(progress: progress), client: client, pollSleep: { _ in }
        )
        return (creds, client)
    }

    private static let zaiOneProject =
        #"{"code":200,"data":{"organizations":[{"organizationId":"org-1","projects":[{"projectId":"proj-1"}]}]}}"#

    // The account of magpie's zcode_test.go: another organization listed
    // ahead of 默认机构, whose first project is a team's coding plan
    // (projectType 2). The key belongs in 默认机构 / 默认项目.
    @Test("zai login mints the key in the default organization's own project, past a team's")
    func zaiLoginDefaultProject() async throws {
        let customer = #"""
        {"code":200,"data":{"organizations":[
          {"organizationId":"o0","organizationName":"other","projects":[{"projectId":"p0","projectName":"x","projectType":"1"}]},
          {"organizationId":"o1","organizationName":"默认机构","projects":[
            {"projectId":"p9","projectName":"api","projectType":"2"},
            {"projectId":"p1","projectName":"默认项目","projectType":"1"}]}]}}
        """#
        let (creds, client) = try await zaiLogin(
            customer: customer,
            tail: [(200, #"{"code":200,"data":{"secretKey":"sk"}}"#), (200, Self.zaiLitePlan)]
        )
        #expect(creds.access == "ak-9.sk")
        #expect(client.recorded[5].url.absoluteString.hasSuffix("organization/o1/projects/p1/api_keys"))
    }

    @Test("zai default project skips team projects and organizations that hold only them")
    func zaiDefaultProjectRules() {
        // A team project typed as a number, as magpie's zcode_team_test.go has it.
        let teamOnly: [String: Any] = [
            "organizationId": "team", "organizationName": "默认机构",
            "projects": [["projectId": "tp0", "projectType": 2], ["projectId": "tp1", "projectType": "2"]],
        ]
        let own: [String: Any] = [
            "organizationId": "o1", "organizationName": "mine",
            "projects": [["projectId": "tp", "projectType": "2"], ["projectId": "p1", "projectType": "1"]],
        ]
        let picked = OAuthLogin.zaiDefaultProject([teamOnly, own])
        #expect(picked?.organization == "o1")
        #expect(picked?.project == "p1")
        #expect(OAuthLogin.zaiDefaultProject([teamOnly]) == nil)
    }

    @Test("zai login makes the key when the listed one names no key id")
    func zaiLoginSkipsKeyWithoutId() async throws {
        let (creds, client) = try await zaiLogin(
            customer: Self.zaiOneProject,
            keys: #"{"code":200,"data":[{"name":"kwwk","apiKey":""}]}"#,
            tail: [
                (200, #"{"code":200,"data":{"apiKey":"ak-new"}}"#),
                (200, #"{"code":200,"data":{"secretKey":"sk"}}"#),
                (200, Self.zaiLitePlan),
            ]
        )
        #expect(creds.access == "ak-new.sk")
        #expect(client.recorded[6].method == "POST")
    }

    // Without a plan the coding endpoint answers every request 1113, so the
    // sign-in says so instead of keeping a key that cannot be used (magpie's
    // zcode plugin, signedIn: "this Z.ai account has no GLM Coding Plan…").
    @Test("zai login refuses an account whose subscriptions hold no valid Coding Plan")
    func zaiLoginNoPlan() async throws {
        let lists = [#"{"code":200,"data":[]}"#, #"{"code":200,"data":[{"productName":"GLM Coding Lite","status":"EXPIRED"}]}"#]
        for list in lists {
            do {
                _ = try await zaiLogin(
                    customer: Self.zaiOneProject,
                    tail: [(200, #"{"code":200,"data":{"secretKey":"sk"}}"#), (200, list)]
                )
                Issue.record("a planless account signed in")
            } catch let error as OAuthError {
                #expect(error.localizedDescription.contains("no GLM Coding Plan"))
                #expect(error.localizedDescription.contains("z.ai/subscribe"))
            }
        }
    }

    @Test("zai login keeps the key when the subscriptions cannot be read, and names the plan when they can")
    func zaiLoginPlanRead() async throws {
        let unreadable = [(status: 500, body: ""), (status: 200, body: "<html>"), (status: 200, body: #"{"code":500,"msg":"boom"}"#)]
        for unread in unreadable {
            let (creds, _) = try await zaiLogin(
                customer: Self.zaiOneProject,
                tail: [(200, #"{"code":200,"data":{"secretKey":"sk"}}"#), unread]
            )
            #expect(creds.access == "ak-9.sk")
        }
        let said = CapturedLines()
        _ = try await zaiLogin(
            customer: Self.zaiOneProject,
            tail: [(200, #"{"code":200,"data":{"secretKey":"sk"}}"#), (200, Self.zaiLitePlan)],
            progress: { said.add($0) }
        )
        #expect(said.all().contains("signed in to GLM Coding Lite"))
    }
}

/// Thread-safe line capture for @Sendable progress assertions.
private final class CapturedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    func all() -> [String] { lock.withLock { lines } }
}

/// Thread-safe URL capture for @Sendable callback assertions.
private final class CapturedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ u: URL) { lock.withLock { url = u } }
    func get() -> URL? { lock.withLock { url } }
}

// MARK: - Stub helpers

final class SequentialStubClient: HTTPClient, @unchecked Sendable {
    var queue: [(status: Int, body: String)] = []
    var recorded: [(url: URL, method: String, headers: [String: String], body: Data?)] = []

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        recorded.append((url, method, headers, body))
        let next = queue.removeFirst()
        let response = HTTPURLResponse(
            url: url, statusCode: next.status, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        let bodyData = Data(next.body.utf8)
        let stream = AsyncThrowingStream<Data, Error> { cont in
            Task {
                cont.yield(bodyData)
                cont.finish()
            }
        }
        return (response, stream)
    }
}
