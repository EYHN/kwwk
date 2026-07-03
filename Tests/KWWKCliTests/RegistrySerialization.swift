import Foundation

/// Cross-suite serialization for tests that mutate `APIRegistry.shared`.
/// `.serialized` only orders the tests WITHIN one suite; suites still run in
/// parallel, so two suites touching the same registry scope (e.g. the
/// "openrouter" scope used by both MultiProviderAuthTests and
/// LoginLogoutModalTests) would otherwise race on register/unregister. Hold
/// the lock for the whole test body — registration, assertions, and the
/// trailing unregister — never just a slice of it.
actor SharedAPIRegistryLock {
    static let shared = SharedAPIRegistryLock()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Run `body` while holding the shared-registry lock. Inherits the caller's
/// isolation (via `#isolation`) so `@MainActor` test bodies can capture their
/// main-actor state without hopping executors.
func withSharedAPIRegistry<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> sending T
) async rethrows -> sending T {
    await SharedAPIRegistryLock.shared.acquire()
    do {
        let result = try await body()
        await SharedAPIRegistryLock.shared.release()
        return result
    } catch {
        await SharedAPIRegistryLock.shared.release()
        throw error
    }
}
