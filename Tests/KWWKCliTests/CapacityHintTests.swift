import Testing
@testable import KWWKAgent
@testable import KWWKCli

@Suite("formatCapacityHint")
struct CapacityHintTests {
    @Test("empty when we have no usage or no window")
    func empty() {
        #expect(formatCapacityHint(
            usage: AgentContextUsage(tokens: 0, window: 200_000),
            threshold: 0.75
        ) == "")
        #expect(formatCapacityHint(
            usage: AgentContextUsage(tokens: 10, window: 0),
            threshold: 0.75
        ) == "")
    }

    @Test("dimmed ratio under threshold")
    func underThreshold() {
        let hint = formatCapacityHint(
            usage: AgentContextUsage(tokens: 50_000, window: 200_000),
            threshold: 0.75
        )
        #expect(hint.contains("25% ctx"))
    }

    @Test("highlighted and threshold hint at or above threshold")
    func aboveThreshold() {
        let hint = formatCapacityHint(
            usage: AgentContextUsage(tokens: 160_000, window: 200_000),
            threshold: 0.75
        )
        #expect(hint.contains("80% ctx"))
        #expect(hint.contains("auto-compact at 75%"))
    }
}
