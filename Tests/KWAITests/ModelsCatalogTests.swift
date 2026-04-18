import Foundation
import Testing
@testable import KWAI

@Suite("Models catalog")
struct ModelsCatalogTests {
    @Test("loads providers and at least a few hundred models from the JSON bundle")
    func loadsCatalog() {
        let providers = ModelsCatalog.providers
        #expect(providers.count >= 15)
        #expect(providers.contains("anthropic"))
        #expect(providers.contains("openai"))
        #expect(providers.contains("google"))
        #expect(providers.contains("amazon-bedrock"))

        let total = ModelsCatalog.all.count
        #expect(total >= 500)   // pi ships ~840; allow headroom for future trims
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
