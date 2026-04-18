import Foundation
import Testing
@testable import KWAgent
@testable import KWAI

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

        let start = Date()
        try await agent.prompt("run both")
        let elapsed = Date().timeIntervalSince(start)

        // Two 60ms sleeps in parallel should finish in ~60-90ms. Sequentially
        // it'd be 120ms+. Give generous headroom for CI jitter.
        #expect(elapsed < 0.110, "elapsed was \(elapsed)s; tools did not overlap")

        let events = await recorder.events
        // Expect at least one interleaving: b-start before a-end.
        let aEnd = events.firstIndex(of: "a-end") ?? -1
        let bStart = events.firstIndex(of: "b-start") ?? -1
        #expect(bStart < aEnd, "b did not start before a ended; not actually parallel")
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
}

actor TimelineRecorder {
    var events: [String] = []
    func mark(_ s: String) { events.append(s) }
}
