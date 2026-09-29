import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// Some models fill every optional field — with `""`, whitespace, or `null` —
/// instead of leaving it out. The subagent and task tools give those calls the
/// meaning of the call without the field.
@Suite("Blank optional arguments")
struct BlankOptionalArgumentTests {
    @Test("an opted-in tool drops blank optional arguments and keeps required ones")
    func normalizationDropsOnlyBlankOptionals() {
        var tool = AgentTool(
            name: "probe",
            label: "probe",
            description: "probe",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "required_text": .object(["type": .string("string")]),
                    "count": .object(["type": .string("integer")]),
                    "flag": .object(["type": .string("boolean")]),
                    "note": .object(["type": .string("string")]),
                    "items": .object(["type": .string("array")]),
                ]),
                "required": .array([.string("required_text")]),
            ]),
            execute: { _, _, _, _ in AgentToolResult(content: []) }
        )
        let args: JSONValue = .object([
            "required_text": .string(""),
            "count": .string(""),
            "flag": .null,
            "note": .string("  \n"),
            "items": .array([]),
        ])

        #expect(tool.normalizingBlankOptionalArguments(args) == args)
        tool.omitsBlankOptionalArguments = true
        #expect(tool.normalizingBlankOptionalArguments(args) == .object([
            "required_text": .string(""),
            "items": .array([]),
        ]))
    }

    @Test("agent, agent_send, and agent_history accept blank optionals through the agent loop")
    func subagentToolsAcceptBlankOptionals() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            // Parent launches with every optional argument blank.
            .message(blankCall("agent", [
                "description": .string("blank args"),
                "prompt": .string("do the blank test"),
                "subagent_type": .string("mini"),
                "name": .string(""),
                "model": .string(""),
                "timeout": .string(""),
                "run_in_background": .string(""),
            ])),
            .message(blankYield("first")),
            // Then resumes it the same way.
            .message(blankCall("agent_send", [
                "agent_id": .string("mini-1"),
                "message": .string("once more"),
                "timeout": .null,
                "run_in_background": .string(" "),
            ])),
            .message(blankYield("second")),
            // Then reads it with every paging field blank.
            .message(blankCall("agent_history", [
                "agent_id": .string("mini-1"),
                "task_id": .string(""),
                "tool_call": .string(""),
                "offset": .string(""),
                "limit": .null,
                "tail": .string(""),
            ])),
            // And lists children with blank ids.
            .message(blankCall("agent_history", [
                "agent_id": .string(""),
                "task_id": .null,
            ])),
            .message(fauxAssistantMessage("done")),
        ])
        let toolset = createSubagentToolset(
            cwd: FileManager.default.currentDirectoryPath,
            model: faux.getModel(),
            childTools: .readOnly,
            subagents: [SubagentDefinition(
                name: "mini",
                description: "Blank-argument test child.",
                prompt: "Complete the test and use the required yield tool.",
                tools: .readOnly
            )],
            sessionId: "blank-parent",
            bashEnvironment: testBashEnvironment
        )
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: toolset.tools)
        ))
        defer { agent.retire() }
        try await agent.prompt("run the blank-argument calls")

        let results = toolResults(agent)
        #expect(results.count == 4)
        for result in results {
            #expect(!result.isError, "\(result.toolName) failed: \(text(result))")
        }
        #expect(text(results[0]).contains("Subagent mini-1 (mini) completed."))
        #expect(text(results[1]).contains("second"))
        #expect(text(results[2]).contains("# mini-1 · mini · completed"))
        #expect(text(results[3]).contains("| mini-1 | mini | completed |"))
    }

    @Test("task tools accept blank optionals through the agent loop")
    func taskToolsAcceptBlankOptionals() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(blankCall("task_list", [
                "include_all": .string(""),
                "offset": .string(""),
                "limit": .string(" "),
            ])),
            .message(blankCall("task_poll", [
                "task_ids": .string(""),
                "timeout_seconds": .string(""),
            ])),
            .message(fauxAssistantMessage("done")),
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tools = createTaskTools(
            manager: manager,
            sessionId: "blank-tasks",
            deliveryConsumer: BackgroundTaskDeliveryConsumer(sessionId: "blank-tasks")
        )
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: tools)
        ))
        defer { agent.retire() }
        try await agent.prompt("run the blank-argument task calls")

        let results = toolResults(agent)
        #expect(results.count == 2)
        for result in results {
            #expect(!result.isError, "\(result.toolName) failed: \(text(result))")
        }
        #expect(text(results[0]).contains("No queued, running, or recent background tasks."))
    }
}

private func blankCall(_ name: String, _ arguments: [String: JSONValue]) -> AssistantMessage {
    fauxAssistantMessage(
        blocks: [fauxToolCall(name: name, arguments: .object(arguments), id: UUID().uuidString)],
        stopReason: .toolUse
    )
}

private func blankYield(_ result: String) -> AssistantMessage {
    blankCall("subagent_yield", [
        "status": .string("complete"),
        "result": .string(result),
    ])
}

private func toolResults(_ agent: Agent) -> [ToolResultMessage] {
    agent.state.messages.compactMap { message in
        if case .toolResult(let result) = message { return result }
        return nil
    }
}

private func text(_ result: ToolResultMessage) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
}
