import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Tool-call transcript ordering")
struct ToolCallTranscriptTests {

    /// Regression test: AgentLoop must append the assistant-turn message to
    /// its in-loop context BEFORE tool execution, so the next request body
    /// carries `[user, assistant(toolCall), toolResult]` — the order
    /// OpenAI Responses and Anthropic Messages both require. Without this
    /// the tool executes but replays produce only `[user, toolResult]` and
    /// strict providers reject with "no tool call found for function call
    /// output".
    @Test("assistant tool_call is replayed before its tool_result on the next turn")
    func toolCallPrecedesResult() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(name: "capture_ctx", arguments: [:], id: "call_AAA")
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("acknowledged")),
        ])

        // Tool captures the agent's transcript at execution time — that's
        // the same transcript that becomes the next turn's request body.
        let captured = MessagesBox()
        let tool = AgentTool(
            name: "capture_ctx",
            label: "capture",
            description: "records the transcript we see",
            parameters: .object(["type": .string("object")]),
            execute: { _, _, _, _ in
                AgentToolResult(content: [.text(TextContent(text: "ok"))])
            }
        )
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel(), tools: [tool]))
        _ = agent.subscribe { event, _ in
            if case .turnEnd = event {
                await captured.record(agent.state.messages)
            }
        }
        try await agent.prompt("kick")

        // After the first turn_end, the transcript must already include the
        // assistant message with the tool_call, so that when the agent loops
        // back for turn 2, the request body is [user, assistant(tc),
        // toolResult].
        let firstTurn = await captured.first()
        #expect(firstTurn != nil)
        guard let messages = firstTurn else { return }
        // Order: user, assistant(tc), toolResult (the tool_result may land
        // just before or after turn_end depending on scheduling; we tolerate
        // either by checking the assistant(tc) comes before the toolResult
        // when both are present).
        let userIdx = messages.firstIndex { if case .user = $0 { return true } else { return false } }
        let assistantIdx = messages.firstIndex {
            if case .assistant(let a) = $0 {
                return a.content.contains { if case .toolCall = $0 { return true } else { return false } }
            }
            return false
        }
        let toolResultIdx = messages.firstIndex { if case .toolResult = $0 { return true } else { return false } }
        #expect(userIdx != nil)
        #expect(assistantIdx != nil)
        #expect(toolResultIdx != nil)
        if let u = userIdx, let a = assistantIdx, let tr = toolResultIdx {
            #expect(u < a)
            #expect(a < tr)
        }
    }
}

/// Helper to pull messages out of an async subscriber into a sync test.
actor MessagesBox {
    private var history: [[Message]] = []
    func record(_ msgs: [Message]) { history.append(msgs) }
    func first() -> [Message]? { history.first }
}

@Suite("Parallel tool execution")
struct ParallelToolsTests {

    /// In parallel mode, two concurrently-dispatched tool calls should overlap
    /// in wall-clock time. We prove overlap by recording start/end events and
    /// asserting that `t2` starts before `t1` ends (and vice versa).
    @Test("parallel mode executes tool calls concurrently")
    func parallelOverlaps() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(name: "slow", arguments: ["id": "a"], id: "a"),
                    fauxToolCall(name: "slow", arguments: ["id": "b"], id: "b"),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let recorder = TimelineRecorder()
        let tool = AgentTool(
            name: "slow",
            label: "slow",
            description: "sleeps 60ms",
            parameters: .object(["type": .string("object")]),
            execute: { id, _, _, _ in
                await recorder.mark("\(id)-start")
                try? await Task.sleep(nanoseconds: 60_000_000)
                await recorder.mark("\(id)-end")
                return AgentToolResult(content: [.text(TextContent(text: "ok"))])
            }
        )

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
            toolExecution: .parallel
        ))

        try await agent.prompt("run both")

        let events = await recorder.events
        let aStart = events.firstIndex(of: "a-start")
        let bStart = events.firstIndex(of: "b-start")
        let aEnd = events.firstIndex(of: "a-end")
        let bEnd = events.firstIndex(of: "b-end")
        #expect(aStart != nil)
        #expect(bStart != nil)
        #expect(aEnd != nil)
        #expect(bEnd != nil)
        if let aStart, let bStart, let aEnd, let bEnd {
            #expect(aStart < bEnd, "a did not start before b ended; not actually parallel")
            #expect(bStart < aEnd, "b did not start before a ended; not actually parallel")
        }
    }

    @Test("sequential mode runs tool calls one at a time")
    func sequentialIsSequential() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(name: "slow", arguments: ["id": "a"], id: "a"),
                    fauxToolCall(name: "slow", arguments: ["id": "b"], id: "b"),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let recorder = TimelineRecorder()
        let tool = AgentTool(
            name: "slow",
            label: "slow",
            description: "sleeps 30ms",
            parameters: .object(["type": .string("object")]),
            execute: { id, _, _, _ in
                await recorder.mark("\(id)-start")
                try? await Task.sleep(nanoseconds: 30_000_000)
                await recorder.mark("\(id)-end")
                return AgentToolResult(content: [.text(TextContent(text: "ok"))])
            }
        )

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
            toolExecution: .sequential
        ))
        try await agent.prompt("run both")

        let events = await recorder.events
        // Strict ordering: a-start, a-end, b-start, b-end.
        #expect(events == ["a-start", "a-end", "b-start", "b-end"])
    }

    @Test("parallel mode still emits tool results in source order")
    func preservesSourceOrder() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(name: "delay", arguments: ["ms": 80], id: "slow"),
                    fauxToolCall(name: "delay", arguments: ["ms": 10], id: "fast"),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let tool = AgentTool(
            name: "delay",
            label: "delay",
            description: "sleeps then returns its id",
            parameters: .object(["type": .string("object")]),
            execute: { id, args, _, _ in
                var ms = 0
                if case .object(let obj) = args {
                    if case .int(let v) = obj["ms"] ?? .null { ms = v }
                }
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                return AgentToolResult(content: [.text(TextContent(text: id))])
            }
        )

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
            toolExecution: .parallel
        ))
        try await agent.prompt("race")

        // Tool results should appear in source order (slow, fast), not
        // completion order (fast, slow).
        let results = agent.state.messages.compactMap { msg -> String? in
            if case .toolResult(let tr) = msg {
                return tr.content.compactMap { b in
                    if case .text(let t) = b { return t.text } else { return nil }
                }.joined()
            }
            return nil
        }
        #expect(results == ["slow", "fast"])
    }

    @Test("parallel mode publishes schema rejection before a slow sibling finishes")
    func publishesImmediateSchemaRejectionWithoutWaitAllDelay() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(
                        name: "limited_slow",
                        arguments: ["value": .string("valid")],
                        id: "slow"
                    ),
                    fauxToolCall(
                        name: "limited_slow",
                        arguments: ["value": .bool(true)],
                        id: "rejected"
                    ),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let timeline = TimelineRecorder()
        let tool = AgentTool(
            name: "limited_slow",
            label: "limited slow",
            description: "slow typed call",
            parameters: [
                "type": "object",
                "properties": ["value": ["type": "string"]],
                "required": ["value"],
                "additionalProperties": false,
            ],
            execute: { _, _, _, _ in
                await timeline.mark("slow-body-start")
                try? await Task.sleep(nanoseconds: 150_000_000)
                await timeline.mark("slow-body-finished")
                return AgentToolResult(content: [.text(TextContent(text: "slow"))])
            }
        )
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
            toolExecution: .parallel
        ))
        _ = agent.subscribe { event, _ in
            if case .toolExecutionEnd(let id, _, _, _) = event {
                await timeline.mark("\(id)-published")
            }
        }

        try await agent.prompt("run one and reject one")

        let events = await timeline.events
        guard let rejection = events.firstIndex(of: "rejected-published"),
              let slowFinished = events.firstIndex(of: "slow-body-finished") else {
            Issue.record("expected rejection and slow-body timeline events")
            return
        }
        #expect(rejection < slowFinished)
        let results = agent.state.messages.compactMap { message -> ToolResultMessage? in
            guard case .toolResult(let result) = message else { return nil }
            return result
        }
        #expect(results.map(\.toolCallId) == ["slow", "rejected"])
        #expect(results.last?.isError == true)
    }
}

actor TimelineRecorder {
    var events: [String] = []
    func mark(_ s: String) { events.append(s) }
}
