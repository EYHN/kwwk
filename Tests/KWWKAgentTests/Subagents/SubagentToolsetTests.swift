import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("SubagentToolset")
struct SubagentToolsetTests {
    @Test("exposes agent, agent_send, and agent_history without a background manager")
    func exposesAgentTool() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let toolset = createSubagentToolset(
            cwd: "/tmp/workspace",
            model: faux.getModel(),
            bashEnvironment: [:]
        )

        #expect(toolset.tools.map(\.name) == ["agent", "agent_send", "agent_history"])
    }

    @Test("exposes the same tools when a background manager is attached")
    func addsHistoryToolWithManager() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let toolset = createSubagentToolset(
            cwd: "/tmp/workspace",
            model: faux.getModel(),
            backgroundManager: BackgroundTaskManager(),
            bashEnvironment: [:]
        )

        #expect(toolset.tools.map(\.name) == ["agent", "agent_send", "agent_history"])
    }

    @Test("defaults to the builtin subagent lineup for the child tool set")
    func defaultsToBuiltins() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let toolset = createSubagentToolset(
            cwd: "/tmp/workspace",
            model: faux.getModel(),
            childTools: .standard,
            bashEnvironment: [:]
        )
        let agentTool = try #require(toolset.tools.first { $0.name == "agent" })

        // The builtin lineup for .standard reaches the model through the
        // tool description's agent list.
        for builtin in ["explore", "plan", "code-reviewer", "test-runner", "general"] {
            #expect(agentTool.description.contains(builtin), "missing builtin \(builtin)")
        }
    }

    @Test("shared tools reach children that may mutate, never read-only ones")
    func sharedToolsReachMutatingChildren() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let seen = SharedToolNames()
        let capture: FauxResponseStep = .factory { context, _, _, _ in
            await seen.record(context.tools?.map(\.name) ?? [])
            return fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "subagent_yield",
                    arguments: .object(["status": .string("complete"), "result": .string("captured")]),
                    id: UUID().uuidString
                )],
                stopReason: .toolUse
            )
        }
        faux.setResponses([capture, capture])
        let shared = AgentTool(
            name: "host_publish",
            label: "publish",
            description: "A host tool.",
            parameters: .object(["type": .string("object")]),
            execute: { _, _, _, _ in AgentToolResult(content: [.text(TextContent(text: "ok"))]) }
        )
        let toolset = createSubagentToolset(
            cwd: FileManager.default.currentDirectoryPath,
            model: faux.getModel(),
            subagents: [
                SubagentDefinition(name: "writer", description: "Writes.", prompt: "Yield.", tools: [.read, .write]),
                SubagentDefinition(name: "reader", description: "Reads.", prompt: "Yield.", tools: .readOnly),
            ],
            bashEnvironment: testBashEnvironment,
            sharedTools: [shared]
        )
        let agentTool = try #require(toolset.tools.first { $0.name == "agent" })
        for type in ["writer", "reader"] {
            _ = try await agentTool.execute(
                "call-\(type)",
                .object([
                    "description": .string(type),
                    "prompt": .string("report your tools"),
                    "subagent_type": .string(type),
                ]),
                nil,
                nil
            )
        }

        let names = await seen.names
        #expect(names.count == 2)
        #expect(names.first?.contains("host_publish") == true)
        #expect(names.last?.contains("host_publish") == false)
    }
}

private actor SharedToolNames {
    var names: [[String]] = []
    func record(_ tools: [String]) { names.append(tools) }
}
