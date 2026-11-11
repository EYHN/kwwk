import Foundation

/// What an account's gate last listed for it, kept for ten minutes. A host
/// resolves its provider on every session and every model switch, and a
/// gate's list of models does not change that often.
final class AccountListingCache<Listing: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: (listing: Listing, at: Date)] = [:]
    private let lifetime: TimeInterval = 10 * 60

    func listing(for account: String) -> Listing? {
        lock.withLock {
            guard let entry = kept[account], Date().timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.listing
        }
    }

    func keep(_ listing: Listing, for account: String) {
        lock.withLock { kept[account] = (listing, Date()) }
    }
}
