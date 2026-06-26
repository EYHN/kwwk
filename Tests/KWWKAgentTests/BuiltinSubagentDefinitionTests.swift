import Foundation
import Testing
@testable import KWWKAgent

@Suite("Built-in subagent definitions")
struct BuiltinSubagentDefinitionTests {
    @Test("factory definitions sanitize tool sets")
    func factoryToolSetsAreSafe() {
        let general = SubagentDefinition.general()
        #expect(general.name == "general")
        #expect(general.tools == nil)
        #expect(general.prompt.contains("general-purpose coding agent"))

        let explore = SubagentDefinition.explore(tools: .all)
        #expect(explore.name == "Explore")
        #expect(explore.tools == .readOnly)
        #expect(explore.prompt.contains("read-only code exploration"))
        #expect(explore.prompt.contains("Do not edit"))

        let plan = SubagentDefinition.plan(tools: .all)
        #expect(plan.name == "Plan")
        #expect(plan.tools == .readOnly)
        #expect(plan.prompt.contains("read-only implementation planner"))
    }

    @Test("builtins respect selection and available tools")
    func builtinsRespectSelection() {
        let readOnly = SubagentDefinition.builtins(
            for: .readOnly,
            selection: [.general, .explore]
        )
        #expect(readOnly.map(\.name) == ["general", "Explore"])
        #expect(readOnly.first { $0.name == "general" }?.tools == nil)

        let selected = SubagentDefinition.builtins(
            for: .all,
            selection: [.plan]
        )
        #expect(selected.map(\.name) == ["Plan"])
    }

    @Test("builtin selection parses CLI names")
    func selectionParsing() {
        #expect(BuiltinSubagentSelection.parseList("general,Explore") == [.general, .explore])
        #expect(BuiltinSubagentSelection.parseList("none") == BuiltinSubagentSelection.none)
        #expect(BuiltinSubagentSelection.parseList("all") == .all)
        #expect(BuiltinSubagentSelection.parseList("bad") == nil)
    }

    @Test("CodingAgentConfig helper installs builtins")
    func configHelper() {
        let base = CodingAgentConfig(
            model: .init(id: "m", name: "m", api: "a", provider: "p"),
            cwd: "/tmp",
            tools: .all,
            bashEnvironment: testBashEnvironment
        )

        let configured = base.withBuiltinSubagents(.general.union(.plan))
        #expect(configured.subagents.map { $0.name } == ["general", "Plan"])
        #expect(base.subagents.isEmpty)
    }
}
