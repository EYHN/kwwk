import Foundation
import KWWKAI

// `ProviderSlot` and `SessionAuthResolvers` live in `KWWKAI` (see
// `StoredProviders.swift` there); this file keeps the TUI-side session state.

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
