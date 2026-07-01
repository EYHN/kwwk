import Foundation
import KWWKAI

/// One logged-in provider's session-scoped routing template. `/model` uses
/// `template` to stamp correct wire routing (api / provider scope / baseUrl /
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
    /// wire `api`, provider scope, session `baseUrl`, and headers that every
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
    private var map: [String: @Sendable (Model, String?) async -> ResolvedProviderAuth?]

    init(_ initial: [String: @Sendable (Model, String?) async -> ResolvedProviderAuth?] = [:]) {
        self.map = initial
    }

    func set(scope: String, _ resolver: @escaping @Sendable (Model, String?) async -> ResolvedProviderAuth?) {
        map[scope] = resolver
    }

    func remove(scope: String) {
        map.removeValue(forKey: scope)
    }

    func resolve(_ model: Model, _ sessionId: String?) async -> ResolvedProviderAuth? {
        guard let r = map[model.provider] else { return nil }
        return await r(model, sessionId)
    }

    /// One stable delegating closure to hand the agent. It closes over this
    /// actor, so later `set` / `remove` calls are visible without swapping the
    /// agent's `authResolver`.
    nonisolated func delegatingResolver() -> @Sendable (Model, String?) async -> ResolvedProviderAuth? {
        { model, sid in await self.resolve(model, sid) }
    }
}

/// Human-readable label for a stored provider id, shown in the `/model`
/// group header and `/login` / `/logout` listings.
func providerDisplayName(forStoreId storeId: String) -> String {
    switch storeId {
    case "anthropic": return "Anthropic (Claude Pro/Max)"
    case "openai-codex": return "ChatGPT Codex"
    case "github-copilot": return "GitHub Copilot"
    case "anthropic-api-key": return "Anthropic (API key)"
    case "openai-api-key": return "OpenAI (API key)"
    case "google-api-key": return "Google AI Studio"
    case "openai-compatible": return "OpenAI-compatible"
    default:
        if storeId.hasPrefix("env:") {
            return String(storeId.dropFirst(4)) + " (env)"
        }
        return storeId
    }
}
