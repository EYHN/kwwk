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
}
