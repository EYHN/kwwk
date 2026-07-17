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
