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
        // amazon-bedrock Opus 4.6 maps xhigh -> "max".
        let bedrock = ModelsCatalog.models(for: "amazon-bedrock").first { $0.id.contains("opus-4-6") }
        if let map = bedrock?.thinkingLevelMap, let xhigh = map["xhigh"] {
            #expect(xhigh == "max")
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
        // Bedrock Opus 4.6: requesting xhigh resolves to the mapped "max".
        if let bedrock = ModelsCatalog.models(for: "amazon-bedrock").first(where: { $0.id.contains("opus-4-6") }),
           bedrock.thinkingLevelMap?["xhigh"] != nil {
            #expect(resolveThinkingLevel(bedrock, .xhigh) == "max")
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
    }
}
