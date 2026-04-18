import Foundation

/// An async sequence of `AssistantMessageEvent` values that also exposes the
/// final settled `AssistantMessage` via `result()`. The stream never throws
/// from iteration — errors are encoded as `.error(...)` events and reflected
/// in the final message's `stopReason`.
public final class AssistantMessageStream: AsyncSequence, Sendable {
    public typealias Element = AssistantMessageEvent

    private let state = StreamState()

    public init() {}

    // MARK: - Producer API

    /// Push an event into the stream. Safe to call from any task.
    public func push(_ event: AssistantMessageEvent) {
        state.push(event)
    }

    /// Mark the stream as finished and record the final settled message.
    /// Further `push` calls after `end` are ignored.
    public func end(_ message: AssistantMessage) {
        state.end(message)
    }

    // MARK: - Consumer API

    /// Await the final settled assistant message for this run.
    public func result() async -> AssistantMessage {
        await state.awaitResult()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(state: state)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let state: StreamState
        public mutating func next() async -> AssistantMessageEvent? {
            await state.nextEvent()
        }
    }
}

/// Thread-safe queue + awaiters for `AssistantMessageStream`.
public final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [AssistantMessageEvent] = []
    private var eventWaiters: [CheckedContinuation<AssistantMessageEvent?, Never>] = []
    private var resultWaiters: [CheckedContinuation<AssistantMessage, Never>] = []
    private var ended = false
    private var finalMessage: AssistantMessage?

    func push(_ event: AssistantMessageEvent) {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        if let waiter = eventWaiters.first {
            eventWaiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: event)
            return
        }
        buffer.append(event)
        lock.unlock()
    }

    func end(_ message: AssistantMessage) {
        let eventWaitersToNotify: [CheckedContinuation<AssistantMessageEvent?, Never>]
        let resultWaitersToNotify: [CheckedContinuation<AssistantMessage, Never>]
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        ended = true
        finalMessage = message
        eventWaitersToNotify = eventWaiters
        eventWaiters.removeAll()
        resultWaitersToNotify = resultWaiters
        resultWaiters.removeAll()
        lock.unlock()
        for w in eventWaitersToNotify { w.resume(returning: nil) }
        for w in resultWaitersToNotify { w.resume(returning: message) }
    }

    func nextEvent() async -> AssistantMessageEvent? {
        await withCheckedContinuation { (cont: CheckedContinuation<AssistantMessageEvent?, Never>) in
            lock.lock()
            if !buffer.isEmpty {
                let event = buffer.removeFirst()
                lock.unlock()
                cont.resume(returning: event)
                return
            }
            if ended {
                lock.unlock()
                cont.resume(returning: nil)
                return
            }
            eventWaiters.append(cont)
            lock.unlock()
        }
    }

    func awaitResult() async -> AssistantMessage {
        await withCheckedContinuation { (cont: CheckedContinuation<AssistantMessage, Never>) in
            lock.lock()
            if let message = finalMessage {
                lock.unlock()
                cont.resume(returning: message)
                return
            }
            resultWaiters.append(cont)
            lock.unlock()
        }
    }
}
