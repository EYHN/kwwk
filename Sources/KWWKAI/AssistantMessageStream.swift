import Foundation

/// An async sequence of `AssistantMessageEvent` values that also exposes the
/// final settled `AssistantMessage` via `result()`. The stream never throws
/// from iteration — errors are encoded as `.error(...)` events and reflected
/// in the final message's `stopReason`.
///
/// This is the **consumer** surface. It is single-consumer: exactly one task
/// should iterate it (and optionally await `result()`). Producers push events
/// through the paired `Continuation` obtained from `makeStream()`; providers
/// inside this module push directly. Iteration and `result()` are
/// cancellation-aware — cancelling the consuming task resumes them promptly
/// (iteration ends, `result()` returns an aborted message).
public final class AssistantMessageStream: AsyncSequence, Sendable {
    public typealias Element = AssistantMessageEvent

    let state = StreamState()

    init() {}

    /// Create a consumer stream paired with a producer `Continuation`. External
    /// providers use this to feed events without exposing `push`/`end` on the
    /// consumer object handed to callers.
    public static func makeStream() -> (stream: AssistantMessageStream, continuation: Continuation) {
        let stream = AssistantMessageStream()
        return (stream, Continuation(state: stream.state))
    }

    // MARK: - Producer API (internal — in-module providers push directly)

    /// Push an event into the stream. Safe to call from any task.
    func push(_ event: AssistantMessageEvent) {
        state.push(event)
    }

    /// Mark the stream as finished and record the final settled message.
    /// Further `push` calls after `end` are ignored.
    func end(_ message: AssistantMessage) {
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

    /// Producer handle for an `AssistantMessageStream`. Obtained from
    /// `makeStream()`; hands events and the final message to the paired
    /// consumer stream.
    public struct Continuation: Sendable {
        let state: StreamState

        /// Push an event into the stream. Safe to call from any task.
        public func push(_ event: AssistantMessageEvent) {
            state.push(event)
        }

        /// Mark the stream finished and record the final settled message.
        /// Further `push` calls are ignored.
        public func end(_ message: AssistantMessage) {
            state.end(message)
        }
    }
}

/// Thread-safe queue + awaiters for `AssistantMessageStream`.
public final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [AssistantMessageEvent] = []
    private var eventWaiters: [(id: UUID, cont: CheckedContinuation<AssistantMessageEvent?, Never>)] = []
    private var resultWaiters: [(id: UUID, cont: CheckedContinuation<AssistantMessage, Never>)] = []
    private var ended = false
    private var finalMessage: AssistantMessage?
    private var latestPartial: AssistantMessage?

    // Called under the state lock. A thrown error must not erase prior output.
    private func settleFailure(_ input: AssistantMessage) -> AssistantMessage {
        guard input.stopReason == .error || input.stopReason == .aborted else { return input }
        var message = input
        if message.content.isEmpty, let partial = latestPartial {
            message.content = partial.content
            message.usage = partial.usage
            message.responseId = message.responseId ?? partial.responseId
        }
        if message.stopReason == .error, message.failure == nil {
            message.failure = ProviderFailure(message: message.errorMessage ?? "Unknown provider error")
        }
        message.errorMessage = message.errorMessage ?? message.failure?.message
        return message
    }

    func push(_ event: AssistantMessageEvent) {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        var event = event
        switch event {
        case .start(let partial), .textStart(_, let partial), .textDelta(_, _, let partial),
             .textEnd(_, _, let partial), .thinkingStart(_, let partial), .thinkingDelta(_, _, let partial),
             .thinkingEnd(_, _, let partial), .toolCallStart(_, let partial), .toolCallDelta(_, _, let partial),
             .toolCallEnd(_, _, let partial):
            latestPartial = partial
        case .error(let reason, let message): event = .error(reason: reason, error: settleFailure(message))
        case .done: break
        }
        if let waiter = eventWaiters.first {
            eventWaiters.removeFirst()
            lock.unlock()
            waiter.cont.resume(returning: event)
            return
        }
        buffer.append(event)
        lock.unlock()
    }

    func end(_ message: AssistantMessage) {
        let eventWaitersToNotify: [(id: UUID, cont: CheckedContinuation<AssistantMessageEvent?, Never>)]
        let resultWaitersToNotify: [(id: UUID, cont: CheckedContinuation<AssistantMessage, Never>)]
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        ended = true
        let message = settleFailure(message)
        finalMessage = message
        eventWaitersToNotify = eventWaiters
        eventWaiters.removeAll()
        resultWaitersToNotify = resultWaiters
        resultWaiters.removeAll()
        lock.unlock()
        for w in eventWaitersToNotify { w.cont.resume(returning: nil) }
        for w in resultWaitersToNotify { w.cont.resume(returning: message) }
    }

    func nextEvent() async -> AssistantMessageEvent? {
        let id = UUID()
        return await withTaskCancellationHandler {
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
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(returning: nil)
                    return
                }
                eventWaiters.append((id: id, cont: cont))
                lock.unlock()
            }
        } onCancel: {
            // End iteration promptly on consumer-task cancellation. Whichever of
            // this and a concurrent `push`/`end` removes the waiter first owns
            // the resume, so there is no double-resume.
            lock.lock()
            guard let index = eventWaiters.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                return
            }
            let waiter = eventWaiters.remove(at: index)
            lock.unlock()
            waiter.cont.resume(returning: nil)
        }
    }

    func awaitResult() async -> AssistantMessage {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<AssistantMessage, Never>) in
                lock.lock()
                if let message = finalMessage {
                    lock.unlock()
                    cont.resume(returning: message)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(returning: Self.cancelledResult())
                    return
                }
                resultWaiters.append((id: id, cont: cont))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            guard let index = resultWaiters.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                return
            }
            let waiter = resultWaiters.remove(at: index)
            lock.unlock()
            waiter.cont.resume(returning: Self.cancelledResult())
        }
    }

    /// Placeholder returned to a consumer that cancels its own `result()` await
    /// before the producer settled the stream.
    private static func cancelledResult() -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: "",
            provider: "",
            model: "",
            usage: Usage(),
            stopReason: .aborted,
            errorMessage: "Consumer cancelled before result settled",
            timestamp: Timestamp.now()
        )
    }
}
