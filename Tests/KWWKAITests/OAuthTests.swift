import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
        url: URL, method: String, headers: [String: String], body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        lock.withLock { lastRequest = (url, method, headers, body) }
        let response = HTTPURLResponse(
            url: url, statusCode: responseStatus, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        let bodyData = responseBody
        let stream = AsyncThrowingStream<Data, Error> { cont in
            Task {
                cont.yield(bodyData)
                cont.finish()
            }
        }
        return (response, stream)
    }
}

@Suite("OAuth credentials + store")
struct OAuthStoreTests {
    @Test("default store is in-memory and does not reopen credentials") func defaultStoreIsMemoryOnly() async throws {
        let a = OAuthStore()
        #expect(await a.isPersistent == false)
        try await a.set(
            OAuthCredentials(access: "A", refresh: "R", expires: 10),
            for: "test"
        )
        #expect(await a.get("test")?.access == "A")

        let b = OAuthStore()
        #expect(await b.isPersistent == false)
        #expect(await b.get("test") == nil)
    }

    @Test("store persists credentials across instances") func persist() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = try OAuthStore(url: tmp)
        try await a.set(
            OAuthCredentials(access: "A", refresh: "R", expires: 10, extras: ["projectId": .string("p-1")]),
            for: "test"
        )

        // Re-open from disk.
        let b = try OAuthStore(url: tmp)
        let loaded = await b.get("test")
        #expect(loaded?.access == "A")
        #expect(loaded?.refresh == "R")
        #expect(loaded?.expires == 10)
        #expect(loaded?.extras["projectId"] == .string("p-1"))
    }

    @Test("a hand-edited store entry without `extras` still decodes")
    func missingExtrasTolerated() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // One entry omits `extras` entirely — the whole store must still
        // load (a strict decode would silently drop every login).
        let raw = """
        {"a": {"access": "ka", "refresh": "", "expires": 10},
         "b": {"access": "kb", "refresh": "", "expires": 10, "extras": {"x": "y"}}}
        """
        try Data(raw.utf8).write(to: tmp)

        let store = try OAuthStore(url: tmp)
        #expect(await store.get("a")?.extras == [:])
        #expect(await store.get("b")?.extras["x"] == .string("y"))
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

@Suite("OAuth refresh — Kimi For Coding")
struct KimiCodingOAuthTests {
    @Test("form POST with grant_type=refresh_token + X-Msh device headers")
    func kimiRefresh() async throws {
        let body = #"""
        {"access_token":"kimi-new","refresh_token":"kimi-refresh-2","expires_in":3600}
        """#
        let client = StubResponseClient(body: Data(body.utf8))
        let updated = try await KimiCodingOAuthProvider(deviceId: "test-device").refresh(
            OAuthCredentials(access: "old", refresh: "kimi-refresh-1", expires: 0),
            using: client
        )
        #expect(updated.access == "kimi-new")
        #expect(updated.refresh == "kimi-refresh-2")
        // Refreshed ~5 minutes before the hour-long expiry.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        #expect(updated.expires > now + 50 * 60 * 1000)
        #expect(updated.expires <= now + 60 * 60 * 1000)

        let req = client.lastRequest!
        #expect(req.method == "POST")
        #expect(req.url.absoluteString == "https://auth.kimi.com/api/oauth/token")
        let form = String(data: req.body ?? Data(), encoding: .utf8) ?? ""
        #expect(form.contains("grant_type=refresh_token"))
        #expect(form.contains("refresh_token=kimi-refresh-1"))
        #expect(form.contains("client_id=\(KimiOAuth.clientID)"))
        #expect(req.headers["X-Msh-Platform"] == "kimi_cli")
        #expect(req.headers["X-Msh-Device-Id"] == "test-device")
        #expect(req.headers["User-Agent"]?.hasPrefix("KimiCLI/") == true)
    }

    @Test("keeps the old refresh token when the server omits a new one")
    func kimiRefreshKeepsOldToken() async throws {
        let body = #"{"access_token":"kimi-new","expires_in":3600}"#
        let client = StubResponseClient(body: Data(body.utf8))
        let updated = try await KimiCodingOAuthProvider(deviceId: "test-device").refresh(
            OAuthCredentials(access: "old", refresh: "keep-me", expires: 0),
            using: client
        )
        #expect(updated.refresh == "keep-me")
    }

    @Test("kimi-coding is a default OAuthManager provider")
    func kimiInDefaultProviders() {
        #expect(OAuthManager.defaultProviders().contains { $0.id == "kimi-coding" })
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

        let store = try OAuthStore(url: tmp)
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

    @Test("throws when no credentials are stored") func missingCreds() async throws {
        let store = try OAuthStore(url: FileManager.default.temporaryDirectory
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

        let store = try OAuthStore(url: tmp)
        try await store.set(
            OAuthCredentials(access: "static", refresh: "r", expires: Int64.max / 2),
            for: "anthropic"
        )
        let manager = OAuthManager(store: store, providers: [AnthropicOAuthProvider()])
        let resolver = manager.resolver()
        let model = Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        let auth = try await resolver(model, nil)
        #expect(auth?.token == "static")
        #expect(auth?.scheme == .bearer)
        let unknown = Model(id: "unknown", api: "unknown", provider: "unknown-xyz")
        #expect(try await resolver(unknown, nil) == nil)
    }

    @Test("resolver() includes GitHub Copilot endpoint as baseURL") func resolverPreservesCopilotEndpoint() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let endpoint = "https://api.business.githubcopilot.com"
        let store = try OAuthStore(url: tmp)
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

        let auth = try await resolver(model, nil)
        #expect(auth?.token == "session-token")
        #expect(auth?.scheme == .bearer)
        #expect(auth?.baseURL == endpoint)
    }
}
