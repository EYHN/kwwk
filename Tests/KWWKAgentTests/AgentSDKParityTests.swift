import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Agent SDK parity — summary, maxTurns, hooks, runOnce")
struct AgentSDKParityTests {

    // MARK: - Item 1: agentEnd summary

    @Test("agentEnd carries aggregated usage, cost, turns, duration, stop reason")
    func agentEndSummary() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        // Two turns: first one is a tool call, second is the final reply.
        let first = AssistantMessage(
            content: [
                fauxText("calling"),
                fauxToolCall(name: "calculate", arguments: ["expression": "1+1"], id: "c1"),
            ],
            api: registration.getModel().api,
            provider: registration.getModel().provider,
            model: registration.getModel().id,
            usage: Usage(input: 100, output: 20, cacheRead: 5, cacheWrite: 3, totalTokens: 128),
            stopReason: .toolUse
        )
        let second = AssistantMessage(
            content: [fauxText("done")],
            api: registration.getModel().api,
            provider: registration.getModel().provider,
            model: registration.getModel().id,
            usage: Usage(input: 200, output: 40, cacheRead: 10, cacheWrite: 0, totalTokens: 250),
            stopReason: .stop
        )
        registration.setResponses([.message(first), .message(second)])

        let agent = Agent(initialState: AgentInitialState(
            model: registration.getModel(),
            tools: [makeCalculateTool()]
        ))

        let collector = SummaryCollector()
        _ = agent.subscribe { event, _ in
            if case .agentEnd(_, let summary) = event {
                await collector.set(summary)
            }
        }

        try await agent.prompt("hi")

        let summary = await collector.snapshot()
        // FauxProvider reimputes usage internally, so we validate the
        // aggregation logic by comparing the summary against the sum
        // of whatever usage actually landed on the state's assistant
        // messages — that's the contract callers care about.
        var expectedInput = 0, expectedOutput = 0, expectedCacheR = 0
        var expectedCacheW = 0, expectedTotal = 0
        for msg in agent.state.messages {
            if case .assistant(let a) = msg {
                expectedInput += a.usage.input
                expectedOutput += a.usage.output
                expectedCacheR += a.usage.cacheRead
                expectedCacheW += a.usage.cacheWrite
                expectedTotal += a.usage.totalTokens
            }
        }

        #expect(summary?.turns == 2)
        #expect(summary?.usage.input == expectedInput)
        #expect(summary?.usage.output == expectedOutput)
        #expect(summary?.usage.cacheRead == expectedCacheR)
        #expect(summary?.usage.cacheWrite == expectedCacheW)
        #expect(summary?.usage.totalTokens == expectedTotal)
        #expect(summary?.finalStopReason == .stop)
        #expect((summary?.durationMs ?? -1) >= 0)
        // FauxProvider's default model has zero cost — total should be 0.
        #expect(summary?.cost.total == 0)
    }

    // MARK: - Item 2: BeforeToolCallResult.modifiedArgs

    @Test("before-hook modifiedArgs rewrites the tool's input")
    func beforeHookRewritesArgs() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        // Echo tool surfaces the args it actually received.
        let received = ArgsRecorder()
        let echo = AgentTool(
            name: "echo",
            label: "Echo",
            description: "Echo args.",
            parameters: [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "required": ["text"],
            ],
            execute: { _, args, _, _ in
                await received.record(args)
                return AgentToolResult(content: [.text(TextContent(text: "ok"))])
            }
        )

        let call = AssistantMessage(
            content: [fauxToolCall(name: "echo", arguments: ["text": "original"], id: "e1")],
            api: registration.getModel().api,
            provider: registration.getModel().provider,
            model: registration.getModel().id,
            stopReason: .toolUse
        )
        registration.setResponses([.message(call), .message(fauxAssistantMessage("done"))])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: registration.getModel(), tools: [echo]),
            beforeToolCall: { _, _ in
                BeforeToolCallResult(
                    modifiedArgs: .object(["text": .string("sanitized")])
                )
            }
        ))

        try await agent.prompt("hi")

        let got = await received.snapshot()
        guard case .object(let obj) = got, case .string(let s) = obj["text"] ?? .null else {
            Issue.record("expected object args with text field")
            return
        }
        #expect(s == "sanitized")
    }

    // MARK: - Item 3: maxTurns

    @Test("maxTurns caps the loop and surfaces a synthetic error message")
    func maxTurnsCaps() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        // Queue an endless tool-call loop. Without a cap this would
        // exhaust `setResponses` — with cap=2 the loop terminates after
        // the second assistant turn.
        let call = AssistantMessage(
            content: [fauxToolCall(name: "calculate", arguments: ["expression": "1+1"], id: "c1")],
            api: registration.getModel().api,
            provider: registration.getModel().provider,
            model: registration.getModel().id,
            stopReason: .toolUse
        )
        registration.setResponses([.message(call), .message(call), .message(call), .message(call)])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: registration.getModel(),
                tools: [makeCalculateTool()]
            ),
            maxTurns: 2
        ))

        let collector = SummaryCollector()
        _ = agent.subscribe { event, _ in
            if case .agentEnd(_, let summary) = event {
                await collector.set(summary)
            }
        }

        try await agent.prompt("go forever")

        let summary = await collector.snapshot()
        #expect(summary?.turns == 2, "exactly two assistant turns should have fired")
        #expect(summary?.finalStopReason == .error)

        // Last message in state should be the synthetic "Maximum turn limit" assistant.
        if case .assistant(let last) = agent.state.messages.last {
            #expect(last.stopReason == .error)
            #expect(last.errorMessage?.contains("Maximum turn limit") == true)
            #expect(last.errorMessage?.contains("2") == true)
        } else {
            Issue.record("expected synthetic error assistant message at tail")
        }
    }

    @Test("reserved final-text turn ends before queued follow-up can replace it with a cap error")
    func finalTextTurnIsTerminal() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        let toolCall = AssistantMessage(
            content: [fauxToolCall(
                name: "calculate",
                arguments: ["expression": "1+1"],
                id: "collect-once"
            )],
            api: registration.getModel().api,
            provider: registration.getModel().provider,
            model: registration.getModel().id,
            stopReason: .toolUse
        )
        registration.setResponses([
            .message(toolCall),
            .message(fauxAssistantMessage("final synthesis")),
            .message(fauxAssistantMessage("follow-up must not run")),
        ])
        var options = AgentOptions(
            initialState: AgentInitialState(
                model: registration.getModel(),
                tools: [makeCalculateTool()]
            ),
            maxTurns: 2
        )
        options.finalTextOnlyOnLastTurn = true
        let agent = Agent(options: options)
        agent.followUp("queued while the capped run is active")

        try await agent.prompt("collect then summarize")

        #expect(registration.state.callCount == 2)
        #expect(agent.hasQueuedMessages())
        guard case .assistant(let final) = agent.state.messages.last else {
            Issue.record("expected final assistant text")
            return
        }
        #expect(final.stopReason == .stop)
        #expect(final.errorMessage == nil)
        #expect(final.content.contains { block in
            if case .text(let text) = block { return text.text == "final synthesis" }
            return false
        })
    }

    // MARK: - Item 5: UserPromptSubmit hook

    @Test("UserPromptSubmit hook can rewrite the user message before it enters context")
    func userPromptHookRewrites() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("ok"))])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: registration.getModel()),
            userPromptSubmit: { ctx, _ in
                let originalText = ctx.message.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined()
                let wrapped = UserMessage(text: "[audited] " + originalText)
                return UserPromptSubmitResult(modifiedMessage: wrapped)
            }
        ))

        try await agent.prompt("hello")

        // The transcript should carry the hook-rewritten message, not
        // the original.
        guard case .user(let u) = agent.state.messages.first else {
            Issue.record("expected user message at head")
            return
        }
        let text = u.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined()
        #expect(text == "[audited] hello")
    }

    @Test("UserPromptSubmit hook can block a message; run still ends cleanly")
    func userPromptHookBlocks() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        // Even if the model is prompted, queue one response — but the
        // hook should drop the user message so the agent enters the
        // loop with an empty transcript. Depending on provider behavior
        // the loop may still issue a request, so keep a noop response
        // at hand.
        registration.setResponses([.message(fauxAssistantMessage(""))])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: registration.getModel()),
            userPromptSubmit: { _, _ in
                UserPromptSubmitResult(block: true, reason: "policy: denied")
            }
        ))

        try await agent.prompt("attempt")

        // The blocked user message must NOT land in the transcript.
        let userMessages = agent.state.messages.filter { msg in
            if case .user = msg { return true } else { return false }
        }
        #expect(userMessages.isEmpty, "blocked prompt should be dropped, not appended")
    }

    // MARK: - Item 6: runOnce stream

    @Test("runOnce yields the full event stream and a terminal summary")
    func runOnceStreams() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("done"))])

        let options = AgentOptions(
            initialState: AgentInitialState(model: registration.getModel())
        )

        var types: [String] = []
        var lastSummary: AgentRunSummary?
        for try await event in Agent.runOnce(prompt: "hi", options: options) {
            types.append(event.type)
            if case .agentEnd(_, let summary) = event {
                lastSummary = summary
            }
        }

        #expect(types.contains("agent_start"))
        #expect(types.contains("agent_end"))
        #expect(types.last == "agent_end")
        #expect(lastSummary?.turns == 1)
        #expect(lastSummary?.finalStopReason == .stop)
    }
}

// MARK: - Test actors

actor SummaryCollector {
    var summary: AgentRunSummary?
    func set(_ s: AgentRunSummary) { summary = s }
    func snapshot() -> AgentRunSummary? { summary }
}

actor ArgsRecorder {
    var last: JSONValue = .null
    func record(_ v: JSONValue) { last = v }
    func snapshot() -> JSONValue { last }
}
