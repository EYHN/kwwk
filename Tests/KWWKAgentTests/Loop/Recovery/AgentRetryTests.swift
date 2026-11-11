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
                "",
                stopReason: .error,
                errorMessage: "HTTP 429: rate limit exceeded"
            )),
            .message(fauxAssistantMessage(
                "",
                stopReason: .error,
                errorMessage: "HTTP 503: service unavailable"
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        // Shrink the 1-second base delay so the test runs fast. With
        // base=10ms the two retries sleep 7–10ms and 15–20ms with jitter.
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
        #expect((7...10).contains(entries[0].delayMs))
        #expect(entries[0].reason.contains("429"))
        #expect(entries[1].attempt == 1)
        #expect((15...20).contains(entries[1].delayMs))
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
                "",
                stopReason: .error,
                errorMessage: "HTTP 400: invalid request body"
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

        // 8 attempts allowed — queue 8 retryable failures.
        let failure: FauxResponseStep = .message(fauxAssistantMessage(
            "",
            stopReason: .error,
            errorMessage: "HTTP 504: gateway timeout"
        ))
        registration.setResponses(Array(repeating: failure, count: 8))

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 5

        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }

        try await agent.prompt("hi")

        // 7 retries scheduled (attempts 0..6); the 8th attempt runs but
        // does not schedule another retry — it falls through to replay.
        let entries = await recorder.snapshot()
        #expect(entries.count == 7)
        #expect(entries.map(\.attempt) == [0, 1, 2, 3, 4, 5, 6])
        for (entry, upperBound) in zip(entries, [UInt64(5), 10, 20, 40, 80, 160, 320]) {
            #expect(entry.delayMs >= UInt64(Double(upperBound) * 0.75))
            #expect(entry.delayMs <= upperBound)
        }

        if case .assistant(let msg) = agent.state.messages.last {
            #expect(msg.stopReason == .error)
            #expect(msg.errorMessage?.contains("504") == true)
        } else {
            Issue.record("expected assistant error after exhausted retries")
        }
    }

    @Test("a failed credential source ends the run at once, not after the retry budget")
    func credentialSourceErrorFailsFast() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("never reached"))])

        // The message alone would sniff as retryable ("connected…"), which
        // is exactly the trap: the error's type must win over its text.
        struct Refusal: LocalizedError {
            var errorDescription: String? {
                "This Agent is set to an 'openai-codex' model, but the Team has not connected an openai-codex login."
            }
        }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 10
        agent.authResolver = { _, _ in
            throw OAuthCredentialSourceError(providerId: "openai-codex", underlying: Refusal())
        }

        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }

        try await agent.prompt("hi")

        #expect(await recorder.snapshot().isEmpty)
        // The run ends in the error state with the authority's copy intact —
        // this is what the host renders as the agent's failure status.
        if case .assistant(let msg) = agent.state.messages.last {
            #expect(msg.stopReason == .error)
            #expect(msg.errorMessage?.contains("openai-codex") == true)
        } else {
            Issue.record("expected the credential failure to surface immediately")
        }
    }

    @Test("a main agent whose stream is interrupted after partial text retries from scratch")
    func mainAgentReplaysInterruptedPartialOutput() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage(
                "half an answer",
                stopReason: .error,
                errorMessage: "Upstream response stream was interrupted"
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 5
        let recorder = RetryEventRecorder()
        let rewinds = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            switch event {
            case .streamRetry(let attempt, let delayMs, let reason):
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            case .streamRewind:
                await rewinds.record(attempt: 0, delayMs: 0, reason: "rewind")
            default:
                break
            }
        }

        try await agent.prompt("hi")

        let entries = await recorder.snapshot()
        #expect(entries.count == 1)
        #expect(entries.first?.reason.contains("interrupted") == true)
        #expect(await rewinds.snapshot().count == 1)
        // The interrupted attempt is discarded, not kept beside the answer.
        #expect(agent.state.messages.count == 2)
        if case .assistant(let msg) = agent.state.messages.last {
            #expect(msg.stopReason == .stop)
            let text = msg.content.compactMap { b -> String? in
                if case .text(let t) = b { return t.text } else { return nil }
            }.joined()
            #expect(text == "done")
        } else {
            Issue.record("expected the replayed answer")
        }
    }

    @Test("output already on an irreversible sink is not replayed")
    func irreversibleSinkKeepsPartialOutputFinal() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage(
                "half an answer",
                stopReason: .error,
                errorMessage: "Upstream response stream was interrupted"
            )),
            .message(fauxAssistantMessage("never reached")),
        ])

        var options = AgentOptions(
            initialState: AgentInitialState(model: registration.getModel())
        )
        options.streamsToIrreversibleSink = true
        let agent = Agent(options: options)
        agent.retryBaseDelayMs = 5
        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }

        try await agent.prompt("hi")

        #expect(await recorder.snapshot().isEmpty)
        if case .assistant(let msg) = agent.state.messages.last {
            #expect(msg.stopReason == .error)
        } else {
            Issue.record("expected the interrupted attempt to surface")
        }
    }

    @Test("an irreversible sink still retries a thinking-only or empty attempt")
    func irreversibleSinkRetriesWhenNothingStreamed() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage(
                "",
                stopReason: .error,
                errorMessage: "Upstream response stream was interrupted"
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.streamsToIrreversibleSink = true
        agent.retryBaseDelayMs = 5
        try await agent.prompt("hi")
        if case .assistant(let msg) = agent.state.messages.last {
            #expect(msg.stopReason == .stop)
        } else {
            Issue.record("expected the retried answer")
        }
    }

    @Test("partial output followed by a permanent error is not retried")
    func permanentErrorAfterPartialOutputIsFinal() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage(
                "half an answer",
                stopReason: .error,
                errorMessage: "HTTP 400: invalid request body"
            )),
            .message(fauxAssistantMessage("never reached")),
        ])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 5
        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }

        try await agent.prompt("hi")
        #expect(await recorder.snapshot().isEmpty)
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
