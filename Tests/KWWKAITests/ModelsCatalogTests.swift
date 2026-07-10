import Foundation
import Testing
@testable import KWWKAI

@Suite("Models catalog")
struct ModelsCatalogTests {
    @Test("loads providers and at least a few hundred models from the JSON bundle")
    func loadsCatalog() {
        let providers = ModelsCatalog.providers
        #expect(providers.count >= 15)
        #expect(providers.contains("anthropic"))
        #expect(providers.contains("openai"))
        #expect(providers.contains("google"))
        #expect(providers.contains("google-vertex"))
        #expect(providers.contains("amazon-bedrock"))
        #expect(!providers.contains("google-gemini-cli"))
        #expect(!providers.contains("google-antigravity"))

        let total = ModelsCatalog.all.count
        #expect(total >= 500)   // pi ships 900+; allow headroom for future trims
    }

    @Test("lookup returns a fully-decoded Model")
    func lookup() throws {
        let sonnet = ModelsCatalog.model(provider: "anthropic", id: "claude-sonnet-4-5")
            ?? ModelsCatalog.model(provider: "anthropic", id: "claude-sonnet-4-5-20250929")
        #expect(sonnet != nil)
        #expect(sonnet?.api == "anthropic-messages")
        #expect(sonnet?.provider == "anthropic")
        #expect(sonnet?.contextWindow ?? 0 >= 100_000)
    }

    @Test("models(for:) returns a sorted list for a known provider")
    func modelsForProvider() {
        let anthropic = ModelsCatalog.models(for: "anthropic")
        #expect(anthropic.count >= 5)
        // Sorted by id.
        let ids = anthropic.map(\.id)
        #expect(ids == ids.sorted())
    }

    @Test("missing provider returns empty list")
    func missingProvider() {
        #expect(ModelsCatalog.models(for: "does-not-exist").isEmpty)
    }

    @Test("decodes per-model compat blocks")
    func compatDecoded() {
        // pi ships `compat.forceAdaptiveThinking` on the Opus 4.6 family.
        let opus = ModelsCatalog.models(for: "anthropic").first { $0.id.contains("opus-4-6") }
        #expect(opus?.compat?.forceAdaptiveThinking == true)

        // At least a meaningful number of models carry a compat block.
        let withCompat = ModelsCatalog.all.filter { $0.compat != nil }
        #expect(withCompat.count >= 100)
    }

    @Test("decodes thinkingLevelMap incl. explicit-null entries")
    func thinkingLevelMapDecoded() {
        // New catalogs expose max as a distinct level on Opus 4.6.
        let bedrock = ModelsCatalog.models(for: "amazon-bedrock").first { $0.id.contains("opus-4-6") }
        if let map = bedrock?.thinkingLevelMap, let max = map["max"] {
            #expect(max == "max")
        } else {
            Issue.record("expected Bedrock Opus 4.6 to declare max thinking")
        }
        let withMap = ModelsCatalog.all.filter { $0.thinkingLevelMap != nil }
        #expect(withMap.count >= 100)
    }

    @Test("thinking-level helpers clamp and resolve via the map")
    func thinkingHelpers() {
        // A non-reasoning model only supports `.off`.
        if let nonReasoning = ModelsCatalog.all.first(where: { !$0.reasoning }) {
            #expect(supportedThinkingLevels(nonReasoning) == [.off])
            #expect(resolveThinkingLevel(nonReasoning, .high) == nil)
        }
        // Bedrock Opus 4.6 supports max but not native xhigh. Upstream clamping
        // searches upward first, preserving old xhigh callers by routing them
        // to the new max level.
        if let bedrock = ModelsCatalog.models(for: "amazon-bedrock").first(where: { $0.id.contains("opus-4-6") }) {
            #expect(resolveThinkingLevel(bedrock, .max) == "max")
            #expect(resolveThinkingLevel(bedrock, .xhigh) == "max")
        } else {
            Issue.record("expected Bedrock Opus 4.6 in the catalog")
        }
    }

    @Test("cost values are parsed as Doubles (per 1M tokens)")
    func costDecoded() {
        let models = ModelsCatalog.all.filter { $0.cost.input > 0 }
        #expect(!models.isEmpty)
        // A sanity bound: per-1M prices are well under $100.
        for m in models {
            #expect(m.cost.input < 500)
            #expect(m.cost.output < 1000)
        }

        let tiered = ModelsCatalog.all.filter { !($0.cost.tiers ?? []).isEmpty }
        #expect(!tiered.isEmpty)
        #expect(
            ModelsCatalog.model(provider: "openai", id: "gpt-5.4")?
                .cost.tiers?.first?.inputTokensAbove == 272_000
        )
        #expect(tiered.allSatisfy { model in
            model.cost.tiers?.allSatisfy { $0.inputTokensAbove > 0 } == true
        })
    }
}
