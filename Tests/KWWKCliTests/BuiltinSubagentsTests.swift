import Testing
@testable import KWWKAgent
@testable import KWWKCli

@Suite("CLI builtin subagents")
struct BuiltinSubagentsTests {
    @Test("read-only CLI tools expose narrow specialists before general")
    func readOnlyBuiltins() {
        let agents = defaultCLISubagents(for: .readOnly)
        let names = agents.map(\.name)
        #expect(names == ["explore", "plan", "code-reviewer", "general"])
        #expect(agents.first { $0.name == "general" }?.tools == nil)
        #expect(agents.first { $0.name == "explore" }?.tools == .readOnly)
        #expect(agents.first { $0.name == "plan" }?.tools == .readOnly)
    }

    @Test("bash-enabled CLI tools expose the constrained test runner")
    func bashBuiltins() {
        let agents = defaultCLISubagents(for: .standard)
        let names = agents.map(\.name)
        #expect(names == ["explore", "plan", "code-reviewer", "test-runner", "general"])
        #expect(agents.first { $0.name == "general" }?.tools == nil)
        #expect(agents.first { $0.name == "test-runner" }?.bashCommandPolicy == .buildAndTestOnly)
    }

    @Test("CLI subagent selection can disable or narrow builtins")
    func selectedBuiltins() {
        #expect(defaultCLISubagents(for: .standard, selection: .none).isEmpty)

        let agents = defaultCLISubagents(for: .standard, selection: [.general, .plan])
        #expect(agents.map(\.name) == ["plan", "general"])
    }

    @Test("interactive CLI can default builtins to background without changing the reusable default")
    func interactiveBackgroundDefaults() {
        let reusable = defaultCLISubagents(for: .standard)
        #expect(reusable.allSatisfy { !$0.runInBackgroundByDefault })

        let interactive = defaultCLISubagents(
            for: .standard,
            runInBackgroundByDefault: true
        )
        #expect(interactive.map(\.name) == ["explore", "plan", "code-reviewer", "test-runner", "general"])
        #expect(interactive.allSatisfy { $0.runInBackgroundByDefault })
    }
}
