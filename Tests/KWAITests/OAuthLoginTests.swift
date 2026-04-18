import Foundation
import Testing
@testable import KWAI

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
                onProgress: { _ in },
                onPrompt: { _ in "" }
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
}

// MARK: - Stub helpers

final class SequentialStubClient: HTTPClient, @unchecked Sendable {
    var queue: [(status: Int, body: String)] = []
    var recorded: [(url: URL, method: String, headers: [String: String], body: Data?)] = []

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        recorded.append((url, method, headers, body))
        let next = queue.removeFirst()
        let response = HTTPURLResponse(
            url: url, statusCode: next.status, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        let bytes = Array(next.body.utf8)
        let stream = AsyncThrowingStream<UInt8, Error> { cont in
            Task {
                for b in bytes { cont.yield(b) }
                cont.finish()
            }
        }
        return (response, stream)
    }
}
