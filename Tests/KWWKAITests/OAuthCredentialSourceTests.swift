import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// Covers `OAuthManager` over an external `OAuthCredentialSource`. There is
/// no refresh-policy switch — the credentials decide: an entry with an empty
/// `refresh` is consumed as-is and its expiry is the authority's fault
/// (`OAuthError.expired`); a refresh-bearing entry refreshes normally, with
/// the rotation held in the manager while the source keeps serving the entry
/// it rotated.
@Suite("OAuth credential source")
struct OAuthCredentialSourceTests {

    /// Stands in for an external authority (a backend that owns refresh):
    /// serves a mutable table, writes nothing.
    final class StubSource: OAuthCredentialSource, @unchecked Sendable {
        private let lock = NSLock()
        private var table: [String: OAuthCredentials]
        init(_ table: [String: OAuthCredentials]) { self.table = table }
        func providerIds() async -> [String] { lock.withLock { Array(table.keys) } }
        func credentials(for providerId: String) async throws -> OAuthCredentials? {
            lock.withLock { table[providerId] }
        }
        func serve(_ credentials: OAuthCredentials?, for providerId: String) {
            lock.withLock { table[providerId] = credentials }
        }
    }

    /// Counts `refresh` calls rather than refusing them, so a regression
    /// fails on the count assertion instead of on some unrelated error.
    final class RefreshCountingProvider: OAuthProvider, @unchecked Sendable {
        let id: String
        let name = "refresh probe"
        private let lock = NSLock()
        private var count = 0
        var refreshCount: Int { lock.withLock { count } }
        init(id: String) { self.id = id }
        func refresh(_ c: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            lock.withLock { count += 1 }
            return OAuthCredentials(access: "refreshed", refresh: "rotated", expires: .max)
        }
    }

    private func fresh(_ access: String, refresh: String = "") -> OAuthCredentials {
        OAuthCredentials(
            access: access, refresh: refresh,
            expires: Int64(Date().timeIntervalSince1970 * 1000) + 600_000
        )
    }

    @Test("a fresh token from the source is served without refreshing")
    func servesSourceToken() async throws {
        let source = StubSource(["x": fresh("from-authority")])
        let provider = RefreshCountingProvider(id: "x")
        let manager = OAuthManager(source: source, providers: [provider])

        #expect(await manager.store == nil)
        #expect(try await manager.apiKey(for: "x") == "from-authority")
        #expect(provider.refreshCount == 0)
    }

    @Test("an expired entry with no refresh token is the authority's fault")
    func expiredWithoutRefreshTokenThrows() async throws {
        let stale = OAuthCredentials(access: "stale", refresh: "", expires: 0)
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
        // No refresh token means nothing to refresh with — the authority
        // serving access-only entries has kept refresh to itself.
        #expect(provider.refreshCount == 0)
    }

    @Test("a credential the source doesn't hold is missing")
    func missing() async throws {
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

    @Test("a refresh-bearing entry from a store-less source refreshes once and the rotation is held")
    func refreshBearingEntryRotatesOnceAndHolds() async throws {
        let stale = OAuthCredentials(access: "stale", refresh: "r1", expires: 0)
        let source = StubSource(["x": stale])
        let provider = RefreshCountingProvider(id: "x")
        let manager = OAuthManager(source: source, providers: [provider])

        #expect(try await manager.apiKey(for: "x") == "refreshed")
        #expect(provider.refreshCount == 1)

        // The source still serves the stale entry, but re-running the
        // rotation with its consumed refresh token would kill the login on
        // rotating providers — the held rotation answers instead.
        #expect(try await manager.apiKey(for: "x") == "refreshed")
        #expect(provider.refreshCount == 1)
        #expect(try await manager.credentials(for: "x")?.refresh == "rotated")

        // The moment the source serves something else — a new login — the
        // source wins and the held rotation is dropped.
        let relogin = fresh("relogged", refresh: "r2")
        source.serve(relogin, for: "x")
        #expect(try await manager.credentials(for: "x") == relogin)
        #expect(try await manager.apiKey(for: "x") == "relogged")
        #expect(provider.refreshCount == 1)
    }

    @Test("the file store is itself a credential source")
    func storeIsASource() async throws {
        let store = OAuthStore()
        try await store.set(fresh("a", refresh: "r"), for: "anthropic")
        try await store.set(fresh("c", refresh: "r"), for: "cursor")

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
