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
            deviceId: "test-device",
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
            deviceId: "test-device",
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
                deviceId: "test-device",
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
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginKimiCoding(
                clientID: "test-client",
                deviceId: "test-device",
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
                deviceId: "test-device",
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
        await #expect(throws: OAuthError.self) {
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
                onProgress: { _ in }
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
                    onProgress: { _ in }
                ),
                client: client
            )
        }
    }

    // MARK: - Z.AI

    /// Echo the state from the authorize URL back through the callback so
    /// the flow's state check passes.
    private func fireZaiCallback(port: UInt16, authURL: URL, code: String) {
        let comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)
        let state = comps?.queryItems?.first { $0.name == "state" }?.value ?? ""
        fireCallback(port: port, query: "code=\(code)&state=\(state)")
    }

    @Test("zai login exchanges the code and provisions a durable id.secret key")
    func zaiLoginFlow() async throws {
        let client = SequentialStubClient()
        // 1. token exchange (envelope code 0)
        client.queue.append((
            status: 200,
            body: #"{"code":0,"msg":"ok","data":{"zai":{"access_token":"oauth-tok"},"user":{"email":"e@x.ai","id":7}}}"#
        ))
        // 2. business login (envelope code 200)
        client.queue.append((
            status: 200,
            body: #"{"code":200,"success":true,"data":{"access_token":"biz-tok"}}"#
        ))
        // 3. customer info → default org/project
        client.queue.append((
            status: 200,
            body: #"{"code":200,"data":{"organizations":[{"organizationId":"org-1","isDefault":true,"projects":[{"projectId":"proj-1","isDefault":true}]}]}}"#
        ))
        // 4. api key list (empty → create)
        client.queue.append((status: 200, body: #"{"code":200,"data":[]}"#))
        // 5. create
        client.queue.append((status: 200, body: #"{"code":200,"data":{"apiKey":"ak-123"}}"#))
        // 6. copy → full secret
        client.queue.append((status: 200, body: #"{"code":200,"data":{"secretKey":"sk-456"}}"#))

        let port: UInt16 = 54549
        let authURL = CapturedURL()
        let creds = try await OAuthLogin.loginZai(
            clientID: "test-client",
            port: port,
            callbacks: OAuthLogin.Callbacks(
                onAuthURL: { url in
                    authURL.set(url)
                    self.fireZaiCallback(port: port, authURL: url, code: "ZAI-CODE")
                },
                onProgress: { _ in }
            ),
            client: client
        )
        #expect(creds.access == "ak-123.sk-456")
        #expect(creds.refresh == "")
        #expect(creds.expires == .max)

        // Authorize URL: chat.z.ai authorize with client id + state, no PKCE.
        let auth = try #require(authURL.get())
        let comps = try #require(URLComponents(url: auth, resolvingAgainstBaseURL: false))
        #expect(comps.host == "chat.z.ai")
        let query = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == "test-client")
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "http://localhost:\(port)/callback")
        #expect(query["state"]?.isEmpty == false)
        #expect(query["code_challenge"] == nil)

        // Request sequence: exchange → business login → customer → list →
        // create → copy, with the biz bearer on the provisioning calls.
        #expect(client.recorded.count == 6)
        let exchange = client.recorded[0]
        #expect(exchange.url.absoluteString == "https://zcode.z.ai/api/v1/oauth/token")
        let exchangeBody = try JSONSerialization.jsonObject(with: exchange.body ?? Data()) as? [String: Any]
        #expect(exchangeBody?["provider"] as? String == "zai")
        #expect(exchangeBody?["code"] as? String == "ZAI-CODE")
        #expect(exchangeBody?["redirect_uri"] as? String == "http://localhost:\(port)/callback")
        #expect((exchangeBody?["state"] as? String)?.isEmpty == false)

        let login = client.recorded[1]
        #expect(login.url.absoluteString == "https://api.z.ai/api/auth/z/login")
        let loginBody = try JSONSerialization.jsonObject(with: login.body ?? Data()) as? [String: Any]
        #expect(loginBody?["token"] as? String == "oauth-tok")

        let customer = client.recorded[2]
        #expect(customer.url.absoluteString.hasSuffix("api/biz/customer/getCustomerInfo"))
        #expect(customer.headers["authorization"] == "Bearer biz-tok")

        let list = client.recorded[3]
        #expect(list.method == "GET")
        #expect(list.url.absoluteString.hasSuffix("organization/org-1/projects/proj-1/api_keys"))

        let create = client.recorded[4]
        #expect(create.method == "POST")
        let createBody = try JSONSerialization.jsonObject(with: create.body ?? Data()) as? [String: Any]
        #expect(createBody?["name"] as? String == "kwwk")

        let copy = client.recorded[5]
        #expect(copy.url.absoluteString.hasSuffix("api_keys/copy/ak-123"))
    }

    @Test("zai login reuses an existing kwwk-named key instead of creating one")
    func zaiLoginReusesKey() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"code":0,"data":{"zai":{"access_token":"oauth-tok"}}}"#
        ))
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

        let port: UInt16 = 54550
        let creds = try await OAuthLogin.loginZai(
            clientID: "test-client",
            port: port,
            callbacks: OAuthLogin.Callbacks(
                onAuthURL: { url in self.fireZaiCallback(port: port, authURL: url, code: "C") },
                onProgress: { _ in }
            ),
            client: client
        )
        #expect(creds.access == "ak-9.sk-full")
        #expect(client.recorded.count == 5)
        #expect(client.recorded[4].url.absoluteString.hasSuffix("api_keys/copy/ak-9"))
    }

    @Test("zai envelope failure surfaces the server message")
    func zaiEnvelopeFailure() async throws {
        let client = SequentialStubClient()
        client.queue.append((status: 200, body: #"{"code":500,"msg":"boom"}"#))
        let port: UInt16 = 54551
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginZai(
                clientID: "test-client",
                port: port,
                callbacks: OAuthLogin.Callbacks(
                    onAuthURL: { url in self.fireZaiCallback(port: port, authURL: url, code: "C") },
                    onProgress: { _ in }
                ),
                client: client
            )
        }
        #expect(client.recorded.count == 1)
    }

    @Test("zai callback with a mismatched state is rejected before any exchange")
    func zaiStateMismatch() async throws {
        let client = SequentialStubClient()
        let port: UInt16 = 54552
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginZai(
                clientID: "test-client",
                port: port,
                callbacks: OAuthLogin.Callbacks(
                    onAuthURL: { _ in self.fireCallback(port: port, query: "code=C&state=WRONG") },
                    onProgress: { _ in }
                ),
                client: client
            )
        }
        #expect(client.recorded.isEmpty)
    }
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
