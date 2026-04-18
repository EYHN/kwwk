import Foundation
import Testing
@testable import KWAgent
@testable import KWAI

@Suite("Agent queues and hooks")
struct AgentQueuesTests {

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
