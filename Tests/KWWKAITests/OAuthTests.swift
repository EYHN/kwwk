import Foundation
import Testing
@testable import KWWKAI

/// Stub that returns a fixed status + JSON body for the next request and
/// captures whatever the caller sent. Used by all OAuth refresh tests.
final class StubResponseClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var responseStatus: Int
    var responseBody: Data
    var lastRequest: (url: URL, method: String, headers: [String: String], body: Data?)?

    init(status: Int = 200, body: Data = Data()) {
        self.responseStatus = status
        self.responseBody = body
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        lock.withLock { lastRequest = (url, method, headers, body) }
        let response = HTTPURLResponse(
            url: url, statusCode: responseStatus, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        let bytes = Array(responseBody)
        let stream = AsyncThrowingStream<UInt8, Error> { cont in
            Task {
                for b in bytes { cont.yield(b) }
                cont.finish()
            }
        }
        return (response, stream)
    }
}

@Suite("OAuth credentials + store")
struct OAuthStoreTests {
    @Test("store persists credentials across instances") func persist() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = OAuthStore(url: tmp)
        try await a.set(
            OAuthCredentials(access: "A", refresh: "R", expires: 10, extras: ["projectId": .string("p-1")]),
            for: "test"
        )

        // Re-open from disk.
        let b = OAuthStore(url: tmp)
        let loaded = await b.get("test")
        #expect(loaded?.access == "A")
        #expect(loaded?.refresh == "R")
        #expect(loaded?.expires == 10)
        #expect(loaded?.extras["projectId"] == .string("p-1"))
    }

    @Test("isExpired uses wall-clock milliseconds") func expiredFlag() {
        let past = OAuthCredentials(access: "a", refresh: "r", expires: 0)
        #expect(past.isExpired)
        let future = OAuthCredentials(
            access: "a", refresh: "r",
            expires: Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        )
        #expect(future.isExpired == false)
    }
}

@Suite("OAuth refresh — Anthropic")
struct AnthropicOAuthTests {
    @Test("POSTs JSON with grant_type=refresh_token") func anthropicRefresh() async throws {
        let body = """
        {"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}
        """
        let client = StubResponseClient(body: Data(body.utf8))
        let provider = AnthropicOAuthProvider()
        let updated = try await provider.refresh(
            OAuthCredentials(access: "old-access", refresh: "old-refresh", expires: 0),
            using: client
        )
        #expect(updated.access == "new-access")
        #expect(updated.refresh == "new-refresh")
        #expect(!updated.isExpired)

        let req = client.lastRequest!
        #expect(req.method == "POST")
        #expect(req.url.absoluteString.contains("platform.claude.com"))
        #expect(req.headers["content-type"] == "application/json")
        let sent = try JSONSerialization.jsonObject(with: req.body ?? Data()) as? [String: Any]
        #expect(sent?["grant_type"] as? String == "refresh_token")
        #expect(sent?["refresh_token"] as? String == "old-refresh")
        #expect(sent?["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    @Test("keeps old refresh token when server omits a new one") func keepsOldRefresh() async throws {
        let body = #"{"access_token":"new","expires_in":1800}"#
        let client = StubResponseClient(body: Data(body.utf8))
        let updated = try await AnthropicOAuthProvider().refresh(
            OAuthCredentials(access: "a", refresh: "OG", expires: 0),
            using: client
        )
        #expect(updated.refresh == "OG")
    }

    @Test("surfaces HTTP error bodies") func httpError() async {
        let client = StubResponseClient(status: 400, body: Data(#"{"error":"bad"}"#.utf8))
        await #expect(throws: Error.self) {
            _ = try await AnthropicOAuthProvider().refresh(
                OAuthCredentials(access: "a", refresh: "r", expires: 0),
                using: client
            )
        }
    }
}

@Suite("OAuth refresh — OpenAI Codex")
struct OpenAICodexOAuthTests {
    @Test("form POST + persists accountId from JWT") func codexRefresh() async throws {
        // Build a fake JWT whose payload carries the account claim.
        let payload: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-123"],
        ]
        let payloadJson = try JSONSerialization.data(withJSONObject: payload)
        let payloadB64 = payloadJson.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(payloadB64).sig"
        let body = """
        {"access_token":"\(token)","refresh_token":"nr","expires_in":3600}
        """
        let client = StubResponseClient(body: Data(body.utf8))
        let updated = try await OpenAICodexOAuthProvider().refresh(
            OAuthCredentials(access: "a", refresh: "r", expires: 0),
            using: client
        )
        #expect(updated.extras["accountId"] == .string("acct-123"))
        #expect(updated.access == token)

        let req = client.lastRequest!
        #expect(req.headers["content-type"] == "application/x-www-form-urlencoded")
        #expect(String(data: req.body ?? Data(), encoding: .utf8)?.contains("grant_type=refresh_token") == true)
    }
}

@Suite("OAuth refresh — GitHub Copilot")
struct GitHubCopilotOAuthTests {
    @Test("GETs session token with Bearer and stores the endpoint") func copilotRefresh() async throws {
        let body = #"""
        {"token":"session-xyz","expires_at":1900000000,"endpoints":{"api":"https://api.githubcopilot.com"}}
        """#
        let client = StubResponseClient(body: Data(body.utf8))
        let updated = try await GitHubCopilotOAuthProvider().refresh(
            OAuthCredentials(access: "", refresh: "ghp_abc", expires: 0),
            using: client
        )
        #expect(updated.access == "session-xyz")
        // PAT stays as refresh; we never rotate it.
        #expect(updated.refresh == "ghp_abc")
        #expect(updated.extras["endpoint"] == .string("https://api.githubcopilot.com"))

        let req = client.lastRequest!
        #expect(req.method == "GET")
        #expect(req.headers["authorization"] == "Bearer ghp_abc")
        #expect(req.headers["editor-version"]?.contains("vscode") == true)
    }
}

@Suite("OAuthManager integration")
struct OAuthManagerTests {
    /// Provider that counts refresh calls so we can verify caching.
    final class CountingProvider: OAuthProvider, @unchecked Sendable {
        let id: String
        let name: String = "counting"
        var refreshCount = 0
        init(id: String) { self.id = id }
        func refresh(_ c: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            refreshCount += 1
            return OAuthCredentials(
                access: "refreshed-\(refreshCount)",
                refresh: c.refresh,
                expires: Int64(Date().timeIntervalSince1970 * 1000) + 600_000
            )
        }
    }

    @Test("refreshes expired credentials then caches them") func refreshOnDemand() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = OAuthStore(url: tmp)
        try await store.set(
            OAuthCredentials(access: "expired", refresh: "r", expires: 0),
            for: "x"
        )
        let provider = CountingProvider(id: "x")
        let manager = OAuthManager(store: store, providers: [provider])

        let first = try await manager.apiKey(for: "x")
        #expect(first == "refreshed-1")
        #expect(provider.refreshCount == 1)

        // Second call — not expired anymore, shouldn't refresh.
        let second = try await manager.apiKey(for: "x")
        #expect(second == "refreshed-1")
        #expect(provider.refreshCount == 1)
    }

    @Test("throws when no credentials are stored") func missingCreds() async {
        let store = OAuthStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json"))
        let manager = OAuthManager(store: store, providers: [AnthropicOAuthProvider()])
        await #expect(throws: Error.self) {
            _ = try await manager.apiKey(for: "anthropic")
        }
    }

    @Test("resolver() returns an agent-compatible auth closure") func resolverShape() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = OAuthStore(url: tmp)
        try await store.set(
            OAuthCredentials(access: "static", refresh: "r", expires: Int64.max / 2),
            for: "anthropic"
        )
        let manager = OAuthManager(store: store, providers: [AnthropicOAuthProvider()])
        let resolver = manager.resolver()
        let model = Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        let auth = await resolver(model, nil)
        #expect(auth?.token == "static")
        #expect(auth?.scheme == .bearer)
        let unknown = Model(id: "unknown", api: "unknown", provider: "unknown-xyz")
        #expect(await resolver(unknown, nil) == nil)
    }

    @Test("resolver() includes GitHub Copilot endpoint as baseURL") func resolverPreservesCopilotEndpoint() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let endpoint = "https://api.business.githubcopilot.com"
        let store = OAuthStore(url: tmp)
        try await store.set(
            OAuthCredentials(
                access: "session-token",
                refresh: "ghp_pat",
                expires: Int64.max / 2,
                extras: ["endpoint": .string(endpoint)]
            ),
            for: "github-copilot"
        )
        let manager = OAuthManager(store: store, providers: [GitHubCopilotOAuthProvider()])
        let resolver = manager.resolver()
        let model = Model(id: "gpt-4.1", api: "openai-completions", provider: "github-copilot")

        let auth = await resolver(model, nil)
        #expect(auth?.token == "session-token")
        #expect(auth?.scheme == .bearer)
        #expect(auth?.baseURL == endpoint)
    }
}
