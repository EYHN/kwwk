import Testing
@testable import KWWKAI

@Suite("Output token policy")
struct OutputTokenPolicyTests {
    @Test("OpenAI automatic limits use the shared 64k ceiling")
    func openAIAutomaticLimit() {
        let model = makeModel(
            api: "openai-responses",
            contextWindow: 400_000,
            maxTokens: 128_000
        )

        #expect(OutputTokenPolicy.automaticLimit(for: model) == 64_000)
        #expect(OutputTokenPolicy.effectiveLimit(for: model, requested: 96_000) == 64_000)
    }

    @Test("full-window catalog values are normalized before reaching the wire")
    func invalidCatalogLimit() {
        let model = makeModel(
            api: "anthropic-messages",
            contextWindow: 200_000,
            maxTokens: 200_000
        )

        #expect(OutputTokenPolicy.automaticLimit(for: model) == 50_000)
        #expect(OutputTokenPolicy.effectiveLimit(for: model, requested: 80_000) == 50_000)
    }

    @Test("both OpenRouter wire formats omit only the automatic cap")
    func openRouterOmission() {
        for api in ["openai-completions", "openai-responses"] {
            var model = makeModel(api: api, contextWindow: 200_000, maxTokens: 128_000)
            model.provider = "openrouter"
            model.baseURL = "https://openrouter.ai/api/v1"

            #expect(OutputTokenPolicy.automaticLimit(for: model) == nil)
            #expect(OutputTokenPolicy.effectiveLimit(for: model, requested: 8_192) == 8_192)
        }
    }

    @Test("Codex routes never materialize max_output_tokens")
    func codexOmission() {
        for api in ["chatgpt-codex", "openai-codex-responses"] {
            let model = makeModel(api: api, contextWindow: 200_000, maxTokens: 128_000)
            #expect(OutputTokenPolicy.automaticLimit(for: model) == nil)
            #expect(OutputTokenPolicy.effectiveLimit(for: model, requested: 8_192) == nil)
        }
    }

    @Test("explicit caps work when model metadata uses zero as an omission sentinel")
    func explicitLimitWithZeroMetadata() {
        let model = makeModel(
            api: "anthropic-messages",
            contextWindow: 200_000,
            maxTokens: 0
        )

        #expect(OutputTokenPolicy.automaticLimit(for: model) == nil)
        #expect(OutputTokenPolicy.effectiveLimit(for: model, requested: 4_096) == 4_096)
    }

    private func makeModel(
        api: String,
        contextWindow: Int,
        maxTokens: Int
    ) -> Model {
        Model(
            id: "policy-test",
            api: api,
            provider: "test",
            contextWindow: contextWindow,
            maxTokens: maxTokens
        )
    }
}
