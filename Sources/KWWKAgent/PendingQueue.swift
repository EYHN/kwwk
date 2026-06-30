import Foundation
import KWWKAI

/// Thread-safe pending-message queue shared between the Agent and its loop.
/// Matches pi-agent-core's `PendingMessageQueue`.
final class PendingMessageQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Message] = []
    private var _mode: QueueMode

    init(mode: QueueMode) {
        self._mode = mode
    }

    var mode: QueueMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    func enqueue(_ message: Message) {
        lock.withLock { messages.append(message) }
    }

    /// Insert at the head (FIFO front). Used by the TUI's Alt+↑ dequeue-cycle:
    /// a prompt the user is cycling past is pushed back to the front so the
    /// next `popLast()` returns the prior item, rotating through the queue
    /// without dropping anything. Atomic so it can't interleave with `drain()`.
    func enqueueFront(_ message: Message) {
        lock.withLock { messages.insert(message, at: 0) }
    }

    func hasItems() -> Bool {
        lock.withLock { !messages.isEmpty }
    }

    func count() -> Int {
        lock.withLock { messages.count }
    }

    /// Read-only snapshot of the queued messages in FIFO order. Used by UI
    /// layers that want to render a preview (e.g. the status bar's "↓ N
    /// queued" indicator). Returns an `Array` copy — the underlying queue
    /// can be drained independently without invalidating the snapshot.
    func snapshot() -> [Message] {
        lock.withLock { messages }
    }

    /// Remove and return the most recently enqueued message (LIFO). Used by
    /// the TUI's "pop the last queued prompt back into the editor" affordance
    /// (Alt+↑) so the user can edit or drop a prompt they just queued.
    func popLast() -> Message? {
        lock.withLock { messages.popLast() }
    }

    func drain() -> [Message] {
        lock.withLock {
            switch _mode {
            case .all:
                let drained = messages
                messages.removeAll()
                return drained
            case .oneAtATime:
                guard let first = messages.first else { return [] }
                messages.removeFirst()
                return [first]
            }
        }
    }

    func clear() {
        lock.withLock { messages.removeAll() }
    }
}
