import Foundation
import Testing
@testable import KWWKGenerateModelsCore

@Suite("Model catalog generator")
struct GenerateModelsCoreTests {
    @Test("converts pi-mono TypeScript catalog syntax into JSON")
    func convertsGeneratedTypeScript() throws {
        let raw = """
        import type { Model } from "./types.js";

        export const MODELS = {
          "openai": {
            "gpt-5.5": {
              id: "gpt-5.5",
              name: "GPT-5.5",
              api: "openai-responses",
              provider: "openai",
              input: ["text", "image"],
              contextWindow: 400000,
              maxTokens: 128000,
              cost: {
                input: 1.25,
                output: 10,
              },
            } satisfies Model<"openai-responses">,
          },
          "google": {},
        } as const;
        """

        let converted = try GenerateModelsCore.convert(raw)
        let data = try #require(converted.data(using: .utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let openai = try #require(root["openai"] as? [String: Any])
        let model = try #require(openai["gpt-5.5"] as? [String: Any])

        #expect(model["id"] as? String == "gpt-5.5")
        #expect(model["api"] as? String == "openai-responses")
        #expect(model["contextWindow"] as? Int == 400_000)
    }

    @Test("inlines split pi provider catalogs")
    func inlinesSplitProviderCatalogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-generate-models-\(UUID().uuidString)")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let generated = """
        import { OPENAI_MODELS } from "./providers/openai.models.ts";

        export const MODELS = {
          "openai": OPENAI_MODELS,
        } as const;
        """
        try generated.write(
            to: root.appendingPathComponent("models.generated.ts"),
            atomically: true,
            encoding: .utf8
        )

        let provider = """
        import type { Model } from "../types.ts";

        export const OPENAI_MODELS = {
          "gpt-5.5": {
            id: "gpt-5.5",
            name: "GPT-5.5",
            api: "openai-responses",
            provider: "openai",
            input: ["text", "image"],
            contextWindow: 400000,
            maxTokens: 128000,
          } satisfies Model<"openai-responses">,
        } as const;
        """
        try provider.write(
            to: providers.appendingPathComponent("openai.models.ts"),
            atomically: true,
            encoding: .utf8
        )

        let result = try GenerateModelsCore.generate(
            fromFile: root.appendingPathComponent("models.generated.ts")
        )
        let openai = try #require(result.root["openai"] as? [String: Any])
        let model = try #require(openai["gpt-5.5"] as? [String: Any])

        #expect(model["id"] as? String == "gpt-5.5")
        #expect(model["api"] as? String == "openai-responses")
        #expect(model["contextWindow"] as? Int == 400_000)
    }

    @Test("preserves providers from the source catalog")
    func preservesSourceProviders() throws {
        let raw = """
        export const MODELS = {
          "google": {},
          "google-vertex": {},
        } as const;
        """

        let result = try GenerateModelsCore.generate(from: raw)

        #expect(result.root.keys.contains("google"))
        #expect(result.root.keys.contains("google-vertex"))
        #expect(result.root.count == 2)
    }

    @Test("writes concise decimal prices")
    func writesConciseDecimalPrices() throws {
        let raw = """
        export const MODELS = {
          "openai": {
            "example": {
              id: "example",
              name: "Example",
              api: "openai-responses",
              provider: "openai",
              cost: { "input": 0.33, "output": 2.75 },
            },
          },
        } as const;
        """

        let result = try GenerateModelsCore.generate(from: raw)
        let output = try #require(String(data: result.outputData, encoding: .utf8))

        #expect(output.contains(#""input" : 0.33"#))
        #expect(!output.contains("0.33000000000000002"))
    }
}
