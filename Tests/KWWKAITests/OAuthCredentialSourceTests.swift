import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// Covers the consume-only path: an `OAuthManager` reading through an external
/// `OAuthCredentialSource` must never refresh and never persist — a stale
/// token is the authority's problem, and surfaces as `OAuthError.expired`.
@Suite("OAuth credential source")
struct OAuthCredentialSourceTests {

    /// Stands in for an external authority (a backend that owns refresh):
    /// serves a fixed table, writes nothing.
    final class StubSource: OAuthCredentialSource, @unchecked Sendable {
        private let lock = NSLock()
        private let table: [String: OAuthCredentials]
        init(_ table: [String: OAuthCredentials]) { self.table = table }
        func providerIds() async -> [String] { lock.withLock { Array(table.keys) } }
        func credentials(for providerId: String) async throws -> OAuthCredentials? {
            lock.withLock { table[providerId] }
        }
    }

    /// Provider whose `refresh` must never run under `.consumeOnly`. It counts
    /// the call rather than refusing it, so a regression fails on the count
    /// assertion instead of on some unrelated error.
    final class RefreshCountingProvider: OAuthProvider, @unchecked Sendable {
        let id: String
        let name = "consume-only probe"
        private let lock = NSLock()
        private var count = 0
        var refreshCount: Int { lock.withLock { count } }
        init(id: String) { self.id = id }
        func refresh(_ c: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            lock.withLock { count += 1 }
            return OAuthCredentials(access: "refreshed", refresh: c.refresh, expires: .max)
        }
    }

    private func fresh(_ access: String) -> OAuthCredentials {
        OAuthCredentials(
            access: access, refresh: "r",
            expires: Int64(Date().timeIntervalSince1970 * 1000) + 600_000
        )
    }

    @Test("consume-only serves the source's token without refreshing")
    func consumeOnlyServesSourceToken() async throws {
        let source = StubSource(["x": fresh("from-authority")])
        let provider = RefreshCountingProvider(id: "x")
        let manager = OAuthManager(source: source, providers: [provider])

        #expect(await manager.policy == .consumeOnly)
        #expect(await manager.store == nil)
        #expect(try await manager.apiKey(for: "x") == "from-authority")
        #expect(provider.refreshCount == 0)
    }

    @Test("consume-only reports an expired credential instead of refreshing it")
    func consumeOnlyRefusesToRefresh() async throws {
        let stale = OAuthCredentials(access: "stale", refresh: "r", expires: 0)
        let source = StubSource(["x": stale])
        let provider = RefreshCountingProvider(id: "x")
        let manager = OAuthManager(source: source, providers: [provider])

        let thrown = await #expect(throws: OAuthError.self) {
            _ = try await manager.apiKey(for: "x")
        }
        if case .expired(let id)? = thrown {
            #expect(id == "x")
        } else {
            Issue.record("expected .expired, got \(String(describing: thrown))")
        }
        // The whole point: the authority refreshes, we don't.
        #expect(provider.refreshCount == 0)
    }

    @Test("consume-only reports a credential the source doesn't hold as missing")
    func consumeOnlyMissing() async throws {
        let manager = OAuthManager(
            source: StubSource([:]), providers: [RefreshCountingProvider(id: "x")]
        )
        let thrown = await #expect(throws: OAuthError.self) {
            _ = try await manager.apiKey(for: "x")
        }
        if case .missing(let id)? = thrown {
            #expect(id == "x")
        } else {
            Issue.record("expected .missing, got \(String(describing: thrown))")
        }
    }

    @Test("the file store is itself a credential source")
    func storeIsASource() async throws {
        let store = OAuthStore()
        try await store.set(fresh("a"), for: "anthropic")
        try await store.set(fresh("c"), for: "cursor")

        #expect(await store.providerIds().sorted() == ["anthropic", "cursor"])
        #expect(await store.credentials(for: "anthropic")?.access == "a")
        #expect(await store.credentials(for: "nobody") == nil)

        // And it works through the existential, which is how a manager holds it.
        let source: any OAuthCredentialSource = store
        #expect(try await source.credentials(for: "cursor")?.access == "c")
    }

    @Test("a store-backed manager keeps refreshing and persisting")
    func storeBackedManagerStillRefreshes() async throws {
        let store = OAuthStore()
        try await store.set(
            OAuthCredentials(access: "stale", refresh: "r", expires: 0), for: "x"
        )
        let provider = RefreshCountingProvider(id: "x")
        let manager = OAuthManager(store: store, providers: [provider])

        #expect(await manager.policy == .automatic)
        #expect(try await manager.apiKey(for: "x") == "refreshed")
        #expect(provider.refreshCount == 1)
        #expect(await store.get("x")?.access == "refreshed")
    }

    @Test("registerAllStored wires a provider read from an external source")
    func registerAllStoredOverSource() async throws {
        let source = StubSource(["anthropic": fresh("from-authority")])
        let provider = RefreshCountingProvider(id: "anthropic")
        let manager = OAuthManager(source: source, providers: [provider])

        let resolved = try await registerAllStored(manager: manager)
        #expect(resolved.model.provider == "anthropic")
        #expect(resolved.model.api == "anthropic-messages")
        #expect(resolved.providerSlots.map(\.storeId) == ["anthropic"])

        // The session resolver reads back through the source, so requests
        // carry the authority's token — and priming never refreshed it.
        let auth = try await resolved.authResolver?(resolved.model, nil)
        #expect(auth?.token == "from-authority")
        #expect(auth?.scheme == .bearer)
        #expect(provider.refreshCount == 0)

        await APIRegistry.shared.unregisterScope("anthropic")
    }
}
