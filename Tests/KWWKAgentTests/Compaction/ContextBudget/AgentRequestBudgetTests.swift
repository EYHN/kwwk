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

    private func model(_ provider: String, _ configure: (inout ModelCompat) -> Void = { _ in }) -> Model {
        var compat = ModelCompat()
        configure(&compat)
        return Model(
            id: "m",
            api: "openai-completions",
            provider: provider,
            baseURL: "https://relay.example/llm",
            contextWindow: 200_000,
            maxTokens: 64_000,
            compat: compat == ModelCompat() ? nil : compat
        )
    }

    @Test("unset controls keep each provider name's reserve")
    func reserveDefaultsByProviderName() {
        // OpenRouter sends no automatic limit and reserves 15%; every other
        // name reserves the limit it sends.
        #expect(AgentRequestBudget.outputReserveTokens(for: model("openrouter")) == 30_000)
        #expect(AgentRequestBudget.inputTokens(for: model("openrouter")) == 170_000)
        for label in ["anthropic", "openai", "some-relay"] {
            #expect(AgentRequestBudget.outputReserveTokens(for: model(label)) == 64_000)
            #expect(AgentRequestBudget.inputTokens(for: model(label)) == 136_000)
        }
    }

    @Test("the output-limit and reserve controls win under any provider name")
    func reserveControls() {
        for label in ["openrouter", "anthropic", "openai", "some-relay"] {
            // No automatic limit, small reserve: what OpenRouter's name gets.
            let small = model(label) {
                $0.omitsAutomaticOutputLimit = true
                $0.usesSmallAnswerReserve = true
            }
            #expect(AgentRequestBudget.outputReserveTokens(for: small) == 30_000)
            #expect(AgentRequestBudget.inputTokens(for: small) == 170_000)

            // No automatic limit, a quarter of the window.
            let quarter = model(label) {
                $0.omitsAutomaticOutputLimit = true
                $0.usesSmallAnswerReserve = false
            }
            #expect(AgentRequestBudget.outputReserveTokens(for: quarter) == 50_000)

            // An automatic limit on the wire is the reserve, whatever the
            // reserve control says.
            let sent = model(label) {
                $0.omitsAutomaticOutputLimit = false
                $0.usesSmallAnswerReserve = true
            }
            #expect(AgentRequestBudget.outputReserveTokens(for: sent) == 64_000)
        }
    }

    @Test("a relay's name with OpenRouter's controls budgets as OpenRouter does")
    func relayBudgetsAsOpenRouter() {
        for window in [17_000, 32_768, 100_000, 200_000, 1_000_000] {
            var named = model("openrouter")
            var explicit = model("airbuild") {
                $0.omitsAutomaticOutputLimit = true
                $0.usesSmallAnswerReserve = true
            }
            var like = model("airbuild") { $0.behavesLikeProvider = "openrouter" }
            var bare = model("airbuild")
            named.contextWindow = window
            explicit.contextWindow = window
            like.contextWindow = window
            bare.contextWindow = window
            let reserve = AgentRequestBudget.outputReserveTokens(for: named)
            let input = AgentRequestBudget.inputTokens(for: named)
            #expect(AgentRequestBudget.outputReserveTokens(for: explicit) == reserve)
            #expect(AgentRequestBudget.inputTokens(for: explicit) == input)
            #expect(AgentRequestBudget.outputReserveTokens(for: like) == reserve)
            #expect(AgentRequestBudget.inputTokens(for: like) == input)
            // Without them the relay's name reserves the limit it sends.
            #expect(AgentRequestBudget.outputReserveTokens(for: bare)
                == OutputTokenPolicy.automaticLimit(for: bare))
        }
    }
}
