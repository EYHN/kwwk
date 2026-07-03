import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Agent stream retry")
struct AgentRetryTests {
    @Test("emits streamRetry events with exponential backoff before the retry attempt")
    func emitsRetryEvents() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        // Two retryable failures, then success on the third attempt.
        registration.setResponses([
            .message(fauxAssistantMessage(
                "", stopReason: .error, errorMessage: "HTTP 429: rate limit exceeded"
            )),
            .message(fauxAssistantMessage(
                "", stopReason: .error, errorMessage: "HTTP 503: service unavailable"
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        // Shrink the 1-second base delay so the test runs fast. With
        // base=10ms the two retries sleep 10ms and 20ms.
        agent.retryBaseDelayMs = 10

        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }

        try await agent.prompt("hi")

        let entries = await recorder.snapshot()
        #expect(entries.count == 2)
        #expect(entries[0].attempt == 0)
        #expect(entries[0].delayMs == 10)
        #expect(entries[0].reason.contains("429"))
        #expect(entries[1].attempt == 1)
        #expect(entries[1].delayMs == 20)
        #expect(entries[1].reason.contains("503"))

        // Agent should have recovered — final assistant message is the success.
        #expect(agent.state.messages.count == 2)
        if case .assistant(let msg) = agent.state.messages[1] {
            #expect(msg.stopReason == .stop)
            let text = msg.content.compactMap { b -> String? in
                if case .text(let t) = b { return t.text } else { return nil }
            }.joined()
            #expect(text.contains("done"))
        } else {
            Issue.record("expected assistant reply after retries")
        }
    }

    @Test("no streamRetry events emitted on happy path")
    func quietOnSuccess() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("ok"))])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 10

        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }

        try await agent.prompt("hi")
        #expect(await recorder.snapshot().isEmpty)
    }

    @Test("non-retryable errors do not emit streamRetry and surface through messageEnd")
    func nonRetryableIsQuiet() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage(
                "", stopReason: .error, errorMessage: "HTTP 400: invalid request body"
            )),
        ])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 10

        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }

        try await agent.prompt("hi")
        #expect(await recorder.snapshot().isEmpty)
        // The error message is preserved on the final assistant turn so the
        // TUI's messageEnd renderer can show it as `✗ <err>`.
        if case .assistant(let msg) = agent.state.messages.last {
            #expect(msg.stopReason == .error)
            #expect(msg.errorMessage?.contains("400") == true)
        } else {
            Issue.record("expected assistant error message")
        }
    }

    @Test("gives up after maxRetries and lets the final error surface")
    func exhaustsRetries() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        // 5 attempts allowed — queue 5 retryable failures.
        let failure: FauxResponseStep = .message(fauxAssistantMessage(
            "", stopReason: .error, errorMessage: "HTTP 504: gateway timeout"
        ))
        registration.setResponses([failure, failure, failure, failure, failure])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 5

        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }

        try await agent.prompt("hi")

        // 4 retries scheduled (attempts 0..3); the 5th attempt runs but
        // does not schedule another retry — it falls through to replay.
        let entries = await recorder.snapshot()
        #expect(entries.count == 4)
        #expect(entries.map(\.attempt) == [0, 1, 2, 3])
        #expect(entries.map(\.delayMs) == [5, 10, 20, 40])

        if case .assistant(let msg) = agent.state.messages.last {
            #expect(msg.stopReason == .error)
            #expect(msg.errorMessage?.contains("504") == true)
        } else {
            Issue.record("expected assistant error after exhausted retries")
        }
    }
}

@Suite("Retry error classification")
struct RetryClassificationTests {
    @Test("POSIX socket deaths are retryable")
    func posixSocketErrors() {
        // The exact shape of the user-reported subagent failure.
        #expect(AgentLoop.isRetryableError(
            "WebSocket stream failed: Error Domain=NSPOSIXErrorDomain Code=57 \"Socket is not connected\""
        ))
        #expect(AgentLoop.isRetryableError(
            "Error Domain=NSPOSIXErrorDomain Code=54 \"Connection reset by peer\""
        ))
        #expect(AgentLoop.isRetryableError("The network connection was lost."))
        #expect(AgentLoop.isRetryableError("WebSocket stream closed before response.completed"))
        #expect(AgentLoop.isRetryableError(
            "WebSocket connection keepalive failed: no inbound traffic for 60s"
        ))
    }

    @Test("timeouts and retryable statuses are retryable")
    func transientStatuses() {
        #expect(AgentLoop.isRetryableError("The request timed out."))
        #expect(AgentLoop.isRetryableError("HTTP 429: rate limit exceeded"))
        #expect(AgentLoop.isRetryableError("HTTP 503: service unavailable"))
        #expect(AgentLoop.isRetryableError("HTTP 529: overloaded"))
    }

    @Test("validation and auth failures are not retryable")
    func permanentFailures() {
        #expect(!AgentLoop.isRetryableError("HTTP 400: invalid request body"))
        #expect(!AgentLoop.isRetryableError("HTTP 401: unauthorized"))
        #expect(!AgentLoop.isRetryableError("model not found"))
        // Validation short-circuit wins even when the message also
        // mentions a transport-ish word.
        #expect(!AgentLoop.isRetryableError("invalid connection parameters"))
        // ...but a timeout wins over everything.
        #expect(AgentLoop.isRetryableError("invalid state: request timed out"))
    }

    @Test("in-flight session conflict is not retryable")
    func busySessionNotRetryable() {
        #expect(!AgentLoop.isRetryableError(
            "OpenAI Responses WebSocket session already has an in-flight response for this sessionId. Use a distinct sessionId for parallel runs."
        ))
    }
}

actor RetryEventRecorder {
    struct Entry: Sendable {
        var attempt: Int
        var delayMs: UInt64
        var reason: String
    }
    var entries: [Entry] = []
    func record(attempt: Int, delayMs: UInt64, reason: String) {
        entries.append(Entry(attempt: attempt, delayMs: delayMs, reason: reason))
    }
    func snapshot() -> [Entry] { entries }
}
