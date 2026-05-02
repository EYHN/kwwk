import Foundation

/// A shareable cancellation token, analogous to the browser's `AbortSignal`.
///
/// Pi-AI passes `AbortSignal` to streaming calls so that long-running requests
/// can be cancelled from the outside. Swift has `Task.isCancelled`, but it
/// only applies to the calling task — so we model an external handle that can
/// be awaited and queried by producers and consumers alike.
public struct CancellationRegistration: Sendable {
    private let cancelHandler: @Sendable () -> Void

    init(_ cancelHandler: @escaping @Sendable () -> Void) {
        self.cancelHandler = cancelHandler
    }

    public func cancel() {
        cancelHandler()
    }
}

public final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var _reason: String?
    private var listeners: [(id: UUID, handler: @Sendable (String?) -> Void)] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return _reason
    }

    /// Cancel the handle. Subsequent calls are no-ops.
    public func cancel(reason: String? = nil) {
        let callbacks: [@Sendable (String?) -> Void]
        lock.lock()
        if _isCancelled {
            lock.unlock()
            return
        }
        _isCancelled = true
        _reason = reason
        callbacks = listeners.map(\.handler)
        listeners.removeAll()
        lock.unlock()
        for cb in callbacks {
            cb(reason)
        }
    }

    /// Register a callback that fires exactly once when the handle is cancelled.
    /// If already cancelled, fires synchronously.
    @discardableResult
    public func onCancel(_ handler: @Sendable @escaping (String?) -> Void) -> CancellationRegistration {
        let id = UUID()
        lock.lock()
        if _isCancelled {
            let r = _reason
            lock.unlock()
            handler(r)
            return CancellationRegistration {}
        }
        listeners.append((id: id, handler: handler))
        lock.unlock()
        return CancellationRegistration { [weak self] in
            self?.removeListener(id)
        }
    }

    private func removeListener(_ id: UUID) {
        lock.lock()
        listeners.removeAll { $0.id == id }
        lock.unlock()
    }

    /// Throw CancellationError if already cancelled.
    public func throwIfCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}
