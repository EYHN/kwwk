import Foundation
import KWAI

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

    func hasItems() -> Bool {
        lock.withLock { !messages.isEmpty }
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
