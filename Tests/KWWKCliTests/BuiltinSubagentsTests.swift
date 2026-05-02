import Testing
@testable import KWWKAgent
@testable import KWWKCli

@Suite("CLI builtin subagents")
struct BuiltinSubagentsTests {
    @Test("read-only CLI tools get general fallback plus read-only specialists")
    func readOnlyBuiltins() {
        let agents = defaultCLISubagents(for: .readOnly)
        let names = agents.map(\.name)
        #expect(names == ["general", "Explore", "Plan"])
        #expect(agents.first { $0.name == "general" }?.tools == nil)
        #expect(agents.first { $0.name == "Explore" }?.tools == .readOnly)
        #expect(agents.first { $0.name == "Plan" }?.tools == .readOnly)
    }

    @Test("bash-enabled CLI tools keep the same default subagent set")
    func bashBuiltins() {
        let agents = defaultCLISubagents(for: .all)
        let names = agents.map(\.name)
        #expect(names == ["general", "Explore", "Plan"])
        #expect(agents.first { $0.name == "general" }?.tools == nil)
    }

    @Test("CLI subagent selection can disable or narrow builtins")
    func selectedBuiltins() {
        #expect(defaultCLISubagents(for: .all, selection: .none).isEmpty)

        let agents = defaultCLISubagents(for: .all, selection: [.general, .plan])
        #expect(agents.map(\.name) == ["general", "Plan"])
    }
}
