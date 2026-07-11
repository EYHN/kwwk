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

    @Test("OpenRouter reserve floor never swallows a small context window")
    func openRouterSmallWindowReserve() {
        var model = Model(
            id: "small",
            api: "openai-completions",
            provider: "openrouter",
            contextWindow: 17_000,
            maxTokens: 0
        )
        // Uncapped, the 16_384 floor would leave 616 input tokens here.
        #expect(AgentRequestBudget.outputReserveTokens(for: model) == 4_250)
        #expect(AgentRequestBudget.inputTokens(for: model) == 12_750)

        model.contextWindow = 32_768
        #expect(AgentRequestBudget.outputReserveTokens(for: model) == 8_192)

        // Big windows keep the full floor once a quarter of the window
        // clears it.
        model.contextWindow = 100_000
        #expect(AgentRequestBudget.outputReserveTokens(for: model) == 16_384)
    }
}
