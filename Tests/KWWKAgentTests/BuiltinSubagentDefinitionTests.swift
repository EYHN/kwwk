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

        let explore = SubagentDefinition.explore(tools: .standard)
        #expect(explore.name == "explore")
        #expect(explore.tools == .readOnly)
        #expect(explore.prompt.contains("read-only code exploration"))
        #expect(explore.prompt.contains("Do not edit"))

        let plan = SubagentDefinition.plan(tools: .standard)
        #expect(plan.name == "plan")
        #expect(plan.tools == .readOnly)
        #expect(plan.prompt.contains("read-only implementation planner"))

        let testRunner = SubagentDefinition.testRunner(tools: .standard)
        #expect(testRunner.tools == [.read, .grep, .find, .ls, .bash, .job])
        #expect(testRunner.bashCommandPolicy == .buildAndTestOnly)
    }

    @Test("builtins respect selection and available tools")
    func builtinsRespectSelection() {
        let readOnly = SubagentDefinition.builtins(
            for: .readOnly,
            selection: [.general, .explore]
        )
        #expect(readOnly.map(\.name) == ["explore", "general"])
        #expect(readOnly.first { $0.name == "general" }?.tools == nil)

        let selected = SubagentDefinition.builtins(
            for: .standard,
            selection: [.plan]
        )
        #expect(selected.map(\.name) == ["plan"])
    }

    @Test("builtin selection parses CLI names")
    func selectionParsing() {
        #expect(BuiltinSubagentSelection.parseList("general,Explore") == [.general, .explore])
        #expect(BuiltinSubagentSelection.parseList("none") == BuiltinSubagentSelection.none)
        #expect(BuiltinSubagentSelection.parseList("all") == .all)
        #expect(BuiltinSubagentSelection.parseList("test-runner") == .testRunner)
        #expect(BuiltinSubagentSelection.parseList("read-only") == .readOnly)
        #expect(BuiltinSubagentSelection.parseList("bad") == nil)
    }

    @Test("builtin selection validates every token before applying all")
    func selectionValidatesBeforeApplyingAll() {
        #expect(BuiltinSubagentSelection.parseList("all,typo") == nil)
        #expect(BuiltinSubagentSelection.parseList("typo,all") == nil)
        #expect(BuiltinSubagentSelection.parseList("default,typo") == nil)
        #expect(BuiltinSubagentSelection.parseList("all,plan") == .all)
        #expect(BuiltinSubagentSelection.parseList("general,ALL,explore") == .all)
        #expect(BuiltinSubagentSelection.parseList("defaults,plan") == .all)
    }

    @Test("builtin negative selections must appear alone")
    func negativeSelectionMustAppearAlone() {
        for alias in ["none", "off", "false", "0"] {
            #expect(BuiltinSubagentSelection.parseList(alias) == BuiltinSubagentSelection.none)
            #expect(BuiltinSubagentSelection.parseList("\(alias),general") == nil)
            #expect(BuiltinSubagentSelection.parseList("general,\(alias)") == nil)
            #expect(BuiltinSubagentSelection.parseList("all,\(alias)") == nil)
            #expect(BuiltinSubagentSelection.parseList("\(alias),all") == nil)
        }
    }

    @Test("CodingAgentConfig helper installs builtins")
    func configHelper() {
        let base = CodingAgentConfig(
            model: .init(id: "m", name: "m", api: "a", provider: "p"),
            cwd: "/tmp",
            tools: .standard,
            bashEnvironment: testBashEnvironment
        )

        let configured = base.withBuiltinSubagents(.general.union(.plan))
        #expect(configured.subagents.map { $0.name } == ["plan", "general"])
        #expect(base.subagents.isEmpty)
    }
}
