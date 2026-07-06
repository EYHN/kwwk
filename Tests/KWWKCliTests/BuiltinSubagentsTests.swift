import Testing
@testable import KWWKAgent
@testable import KWWKCli

@Suite("CLI builtin subagents")
struct BuiltinSubagentsTests {
    @Test("read-only CLI tools get general fallback plus read-only specialists")
    func readOnlyBuiltins() {
        let agents = defaultCLISubagents(for: .readOnly)
        let names = agents.map(\.name)
        #expect(names == ["general", "explore", "plan"])
        #expect(agents.first { $0.name == "general" }?.tools == nil)
        #expect(agents.first { $0.name == "explore" }?.tools == .readOnly)
        #expect(agents.first { $0.name == "plan" }?.tools == .readOnly)
    }

    @Test("bash-enabled CLI tools keep the same default subagent set")
    func bashBuiltins() {
        let agents = defaultCLISubagents(for: .standard)
        let names = agents.map(\.name)
        #expect(names == ["general", "explore", "plan"])
        #expect(agents.first { $0.name == "general" }?.tools == nil)
    }

    @Test("CLI subagent selection can disable or narrow builtins")
    func selectedBuiltins() {
        #expect(defaultCLISubagents(for: .standard, selection: .none).isEmpty)

        let agents = defaultCLISubagents(for: .standard, selection: [.general, .plan])
        #expect(agents.map(\.name) == ["general", "plan"])
    }
}
