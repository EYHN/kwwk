import Testing
@testable import KWWKCli
@testable import KWWKAgent

@Suite("Thinking command")
struct ThinkingCommandTests {
    @Test("max and xhigh remain distinct parseable levels")
    func parsesExtendedLevels() {
        #expect(parseThinkingLevel("max") == .max)
        #expect(parseThinkingLevel("xhigh") == .xhigh)
        #expect(parseThinkingLevel("x-high") == .xhigh)
    }
}
