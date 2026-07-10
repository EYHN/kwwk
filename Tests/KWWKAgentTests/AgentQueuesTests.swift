import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Agent queues and hooks")
struct AgentQueuesTests {

    @Test("runtime asides do not enter the editable steering queue")
    func runtimeAsideIsNotEditableSteering() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))

        agent.aside("background completion")

        #expect(agent.hasQueuedMessages())
        #expect(agent.queuedSteeringCount() == 0)
        #expect(agent.queuedSteeringMessages().isEmpty)
        #expect(agent.popLastSteeringMessage() == nil)
    }

    @Test("a competing continue cannot drain runtime aside before owning the run")
    func continueRunOwnershipPreservesRuntimeAside() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let gate = QueueOwnershipGate()
        let witness = Holder<[Message]>()
        faux.setResponses([
            .factory { context, _, _, _ in
                await witness.set(context.messages)
                return fauxAssistantMessage("done")
            }
        ])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                messages: [.assistant(fauxAssistantMessage("prior"))]
            ),
            userPromptSubmit: { _, _ in
                await gate.enterAndWait()
                return nil
            }
        ))
        agent.aside("runtime survives")

        let prompt = Task { try await agent.prompt("new user prompt") }
        await gate.waitUntilEntered()
        await #expect(throws: AgentError.alreadyRunning) {
            try await agent.continue()
        }
        #expect(agent.hasQueuedMessages())

        await gate.release()
        try await prompt.value

        let seen = await witness.value ?? []
        let runtimeCopies = seen.filter { message in
            guard case .user(let user) = message, user.source == .runtime,
                  case .text(let text) = user.content.first else { return false }
            return text.text == "runtime survives"
        }
        #expect(runtimeCopies.count == 1)
    }

    @Test("maintenance excludes prompts and resumes queued input after explicit settlement")
    func maintenanceOwnershipPreservesQueuedPrompt() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("queued prompt handled"))])

        let gate = QueueOwnershipGate()
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))

        let maintenance = Task {
            try await agent.withMaintenance {
                await gate.enterAndWait()
            }
        }
        await gate.waitUntilEntered()

        await #expect(throws: AgentError.alreadyRunning) {
            try await agent.prompt("racing direct prompt")
        }
        agent.steer("preserved while compacting")
        await gate.release()
        try await maintenance.value

        // The maintenance caller owns durable/UI settlement. Releasing the
        // mutation lock alone must not start the queued turn ahead of it.
        #expect(agent.queuedSteeringCount() == 1)
        #expect(agent.state.messages.isEmpty)
        agent.resumeQueuedWork()

        for _ in 0..<200 {
            if agent.state.messages.contains(where: { message in
                guard case .assistant(let assistant) = message else { return false }
                return assistant.content.contains { block in
                    if case .text(let text) = block {
                        return text.text == "queued prompt handled"
                    }
                    return false
                }
            }) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await agent.waitForIdle()

        let preserved = agent.state.messages.filter { message in
            guard case .user(let user) = message else { return false }
            return user.content.contains { block in
                if case .text(let text) = block {
                    return text.text == "preserved while compacting"
                }
                return false
            }
        }
        #expect(preserved.count == 1)
        #expect(agent.state.messages.contains(where: { message in
            guard case .assistant(let assistant) = message else { return false }
            return assistant.content.contains { block in
                if case .text(let text) = block {
                    return text.text == "queued prompt handled"
                }
                return false
            }
        }))
    }

    @Test("retired session agents cannot be revived by stale wake tasks")
    func retiredAgentRejectsFutureRuns() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                messages: [.assistant(fauxAssistantMessage("prior"))]
            ),
            sessionId: "retired-session"
        ))
        agent.aside("late background completion")
        agent.retire()

        #expect(!agent.hasQueuedMessages())
        await #expect(throws: AgentError.alreadyRunning) {
            try await agent.continue()
        }
        await #expect(throws: AgentError.alreadyRunning) {
            try await agent.prompt("late user task")
        }
        #expect(agent.state.messages.count == 1)
    }

    @Test("reset clears transcript, runtime state, and queues")
    func resetClearsState() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("hi"))])

        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        try await agent.prompt("hello")
        agent.steer(.user(UserMessage(text: "steer")))
        agent.followUp(.user(UserMessage(text: "follow")))
        #expect(agent.state.messages.count == 2)
        #expect(agent.hasQueuedMessages() == true)

        agent.reset()
        #expect(agent.state.messages.isEmpty)
        #expect(agent.hasQueuedMessages() == false)
    }

    @Test("follow-up drains after the agent would otherwise stop")
    func followUpDrains() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        // Two responses: one for the prompt, one for the follow-up.
        faux.setResponses([
            .message(fauxAssistantMessage("first")),
            .message(fauxAssistantMessage("second")),
        ])

        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        agent.followUp(.user(UserMessage(text: "round two")))
        try await agent.prompt("hello")

        // Expect user/assistant × 2 turns = 4 messages.
        #expect(agent.state.messages.count == 4)
        if case .user(let u) = agent.state.messages[2] {
            if case .text(let t) = u.content.first { #expect(t.text == "round two") }
        } else { Issue.record("expected user follow-up second") }
    }

    @Test("beforeToolCall can block execution")
    func beforeHookBlocks() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(name: "noop", arguments: .object([:]), id: "t1")],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("after-block")),
        ])

        let tool = AgentTool(
            name: "noop",
            label: "noop",
            description: "no-op",
            parameters: .object(["type": .string("object")]),
            execute: { _, _, _, _ in
                AgentToolResult(content: [.text(TextContent(text: "should not run"))])
            }
        )

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
            beforeToolCall: { _, _ in BeforeToolCallResult(block: true, reason: "denied by policy") }
        ))
        try await agent.prompt("call it")

        // The tool result should be the blocked-reason, not the tool output.
        let toolResult = agent.state.messages.first { $0.role == .toolResult }
        #expect(toolResult != nil)
        if case .toolResult(let tr) = toolResult! {
            let text = tr.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text } else { return nil }
            }.joined()
            #expect(text == "denied by policy")
            #expect(tr.isError == true)
        }
    }

    @Test("afterToolCall can override result content")
    func afterHookOverrides() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(name: "noop", arguments: .object([:]), id: "t1")],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let tool = AgentTool(
            name: "noop",
            label: "noop",
            description: "no-op",
            parameters: .object(["type": .string("object")]),
            execute: { _, _, _, _ in
                AgentToolResult(content: [.text(TextContent(text: "raw"))])
            }
        )

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
            afterToolCall: { _, _ in
                AfterToolCallResult(content: [.text(TextContent(text: "overridden"))])
            }
        ))
        try await agent.prompt("call it")

        let toolResult = agent.state.messages.first { $0.role == .toolResult }
        if case .toolResult(let tr) = toolResult! {
            let text = tr.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text } else { return nil }
            }.joined()
            #expect(text == "overridden")
        }
    }

    @Test("convertToLlm filters the message list before streaming")
    func convertToLlmFilters() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let witness = Holder<[Message]>()
        faux.setResponses([
            .factory { ctx, _, _, _ in
                await witness.set(ctx.messages)
                return fauxAssistantMessage("ok")
            }
        ])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            convertToLlm: { messages in
                // Drop user messages entirely.
                messages.filter { $0.role != .user }
            }
        ))
        try await agent.prompt("hi")
        let seen = await witness.value ?? []
        #expect(seen.isEmpty)
    }

    @Test("transformContext runs before convertToLlm")
    func transformContextOrdering() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let witness = Holder<[Message]>()
        faux.setResponses([
            .factory { ctx, _, _, _ in
                await witness.set(ctx.messages)
                return fauxAssistantMessage("ok")
            }
        ])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            convertToLlm: { messages in messages },
            transformContext: { messages, _ in
                // Inject a synthetic prelude user message.
                var out = messages
                out.insert(.user(UserMessage(text: "PRELUDE")), at: 0)
                return out
            }
        ))
        try await agent.prompt("hi")
        let seen = await witness.value ?? []
        #expect(seen.count == 2)
        if case .user(let u) = seen.first {
            if case .text(let t) = u.content.first { #expect(t.text == "PRELUDE") }
        } else {
            Issue.record("expected PRELUDE prepended")
        }
    }
}

actor _Holder<T> {
    var value: T?
    func set(_ v: T) { value = v }
}

private actor QueueOwnershipGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
