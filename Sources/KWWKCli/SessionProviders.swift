import Foundation
import KWWKAI

/// One logged-in provider's session-scoped routing template. `/model` uses
/// `template` to stamp correct wire routing (api / provider scope / baseURL /
/// headers) onto any catalog model the user switches to, and lists that
/// provider's catalog under `catalogProvider` / `displayName`.
struct ProviderSlot: Sendable {
    /// The OAuth-store key this provider was logged in under
    /// (`anthropic`, `openai-codex`, `github-copilot`, `anthropic-api-key`, …),
    /// or a synthetic `env:<provider>` marker for environment-key auth.
    let storeId: String
    /// The `ModelsCatalog.byProvider` key whose models this slot lists.
    let catalogProvider: String
    /// Human label shown as the group header in the `/model` picker.
    let displayName: String
    /// The default model built at registration time — carries the resolved
    /// wire `api`, provider scope, session `baseURL`, and headers that every
    /// model under this provider must route through.
    let template: Model
}

/// Mutable, session-scoped set of logged-in providers. Shared by `/model`
/// (reads, to list + route across providers), `/login` (appends a freshly
/// authenticated provider), and `/logout` (removes one). Reference type so a
/// single instance is observed by every slash handler.
@MainActor
final class SessionProviders {
    private(set) var slots: [ProviderSlot]

    /// The session's logged-out invariant: no provider slot is registered.
    /// Single predicate shared by the prompt gate, `/goal`, `/model`, and the
    /// goal-continuation loop so they can never drift onto different
    /// definitions of "logged out".
    var isLoggedOut: Bool { slots.isEmpty }

    init(_ slots: [ProviderSlot] = []) {
        self.slots = slots
    }

    /// Add or replace the slot for a provider (re-login overwrites its
    /// template), keeping priority order stable by de-duplicating on storeId.
    func upsert(_ slot: ProviderSlot) {
        slots.removeAll { $0.storeId == slot.storeId }
        slots.append(slot)
    }

    func remove(storeId: String) {
        slots.removeAll { $0.storeId == storeId }
    }

    func slot(forStoreId storeId: String) -> ProviderSlot? {
        slots.first { $0.storeId == storeId }
    }
}

/// Thread-safe, mutable map of per-provider auth resolvers keyed by
/// `model.provider` scope. The agent holds one **stable** closure
/// (`delegatingResolver()`) that reads through here, so `/login` can install a
/// newly-authenticated provider's resolver mid-session and its tokens resolve
/// on the next request — no agent rebuild. Static api-key providers have no
/// entry; `resolve` returns nil and the provider falls back to its baked key.
actor SessionAuthResolvers {
    private var map: [String: @Sendable (Model, String?) async throws -> ResolvedProviderAuth?]

    init(_ initial: [String: @Sendable (Model, String?) async throws -> ResolvedProviderAuth?] = [:]) {
        self.map = initial
    }

    func set(scope: String, _ resolver: @escaping @Sendable (Model, String?) async throws -> ResolvedProviderAuth?) {
        map[scope] = resolver
    }

    func remove(scope: String) {
        map.removeValue(forKey: scope)
    }

    func resolve(_ model: Model, _ sessionId: String?) async throws -> ResolvedProviderAuth? {
        guard let r = map[model.provider] else { return nil }
        return try await r(model, sessionId)
    }

    /// One stable delegating closure to hand the agent. It closes over this
    /// actor, so later `set` / `remove` calls are visible without swapping the
    /// agent's `authResolver`.
    nonisolated func delegatingResolver() -> @Sendable (Model, String?) async throws -> ResolvedProviderAuth? {
        { model, sid in try await self.resolve(model, sid) }
    }
}
