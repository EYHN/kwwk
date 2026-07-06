import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// Covers the hardening added to `OAuth.swift`: corrupt-store detection,
/// atomic 0600 persistence, deduplicated concurrent refreshes, and the
/// throwing resolver's missing-vs-failed distinction.
@Suite("OAuth hardening")
struct OAuthHardeningTests {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
    }

    @Test("missing store file is a normal fresh start, not an error")
    func missingFileIsEmpty() async throws {
        let store = try OAuthStore(url: tmpURL())
        #expect(await store.all().isEmpty)
    }

    @Test("a corrupt store throws instead of silently starting empty")
    func corruptStoreThrows() throws {
        let tmp = tmpURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("{ this is not json".utf8).write(to: tmp)
        #expect(throws: OAuthError.self) {
            _ = try OAuthStore(url: tmp)
        }
    }

    @Test("persisted store file is created with 0600 permissions")
    func storeFileIs0600() async throws {
        let tmp = tmpURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try OAuthStore(url: tmp)
        try await store.set(
            OAuthCredentials(access: "a", refresh: "r", expires: 10),
            for: "x"
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    /// Refresh that suspends briefly so two concurrent callers overlap, and
    /// counts how many times it actually ran.
    final class SlowCountingProvider: OAuthProvider, @unchecked Sendable {
        let id: String
        let name = "slow"
        private let lock = NSLock()
        private var count = 0
        var refreshCount: Int { lock.withLock { count } }
        init(id: String) { self.id = id }
        func refresh(_ c: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            lock.withLock { count += 1 }
            try? await Task.sleep(nanoseconds: 50_000_000)
            return OAuthCredentials(
                access: "refreshed",
                refresh: c.refresh,
                expires: Int64(Date().timeIntervalSince1970 * 1000) + 600_000
            )
        }
    }

    @Test("concurrent apiKey() calls share one in-flight refresh")
    func concurrentRefreshDeduped() async throws {
        let tmp = tmpURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try OAuthStore(url: tmp)
        try await store.set(
            OAuthCredentials(access: "expired", refresh: "r", expires: 0),
            for: "x"
        )
        let provider = SlowCountingProvider(id: "x")
        let manager = OAuthManager(store: store, providers: [provider])

        async let first = manager.apiKey(for: "x")
        async let second = manager.apiKey(for: "x")
        let (a, b) = try await (first, second)
        #expect(a == "refreshed")
        #expect(b == "refreshed")
        // Both callers must have joined the same refresh, not launched two.
        #expect(provider.refreshCount == 1)
    }

    /// Provider whose refresh always fails, to check error propagation.
    struct FailingRefreshProvider: OAuthProvider {
        let id = "anthropic"
        let name = "failing"
        func refresh(_ c: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            throw OAuthError.refreshFailed("token revoked")
        }
    }

    @Test("resolver returns nil for a provider with no stored credentials")
    func resolverNilWhenMissing() async throws {
        let store = try OAuthStore(url: tmpURL())
        let manager = OAuthManager(store: store, providers: [FailingRefreshProvider()])
        let resolver = manager.resolver()
        let model = Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        #expect(try await resolver(model, nil) == nil)
    }

    @Test("resolver propagates a refresh failure instead of degrading to nil")
    func resolverPropagatesRefreshFailure() async throws {
        let tmp = tmpURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try OAuthStore(url: tmp)
        try await store.set(
            OAuthCredentials(access: "expired", refresh: "r", expires: 0),
            for: "anthropic"
        )
        let manager = OAuthManager(store: store, providers: [FailingRefreshProvider()])
        let resolver = manager.resolver()
        let model = Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        await #expect(throws: OAuthError.self) {
            _ = try await resolver(model, nil)
        }
    }
}
