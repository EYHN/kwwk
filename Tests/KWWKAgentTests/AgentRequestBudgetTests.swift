import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Agent request budgeting")
struct AgentRequestBudgetTests {
    @Test("reserves the full provider output ceiling")
    func fullModelOutputReserve() {
        let model = Model(
            id: "claude-haiku",
            api: "anthropic-messages",
            provider: "anthropic",
            contextWindow: 200_000,
            maxTokens: 64_000
        )

        #expect(AgentRequestBudget.outputReserveTokens(for: model) == 64_000)
        #expect(AgentRequestBudget.inputTokens(for: model) == 136_000)
    }

    @Test("uses proportional headroom for omission-only or invalid metadata")
    func automaticFallbackReserve() {
        var model = Model(
            id: "codex",
            api: "chatgpt-codex",
            provider: "chatgpt-codex",
            contextWindow: 200_000,
            maxTokens: 0
        )
        #expect(AgentRequestBudget.inputTokens(for: model) == 150_000)

        model.maxTokens = model.contextWindow
        #expect(AgentRequestBudget.inputTokens(for: model) == 150_000)

        model.api = "cursor-agent"
        model.maxTokens = 64_000
        #expect(AgentRequestBudget.inputTokens(for: model) == 150_000)

        model.api = "openai-completions"
        model.provider = "openrouter"
        model.maxTokens = 128_000
        #expect(AgentRequestBudget.inputTokens(for: model) == 170_000)
    }
}
