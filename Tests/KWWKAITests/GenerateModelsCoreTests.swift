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

    @Test("drops filtered Google provider groups by default")
    func dropsFilteredGoogleProviders() throws {
        let raw = """
        export const MODELS = {
          "google": {},
          "google-vertex": {},
          "google-gemini-cli": {
            "gemini": {
              id: "gemini",
              name: "Gemini",
              api: "google-gemini",
              provider: "google-gemini-cli",
            },
          },
          "google-antigravity": {
            "ag": {
              id: "ag",
              name: "Antigravity",
              api: "google-gemini",
              provider: "google-antigravity",
            },
          },
        } as const;
        """

        let result = try GenerateModelsCore.generate(from: raw)

        #expect(result.root.keys.contains("google"))
        #expect(result.root.keys.contains("google-vertex"))
        #expect(!result.root.keys.contains("google-gemini-cli"))
        #expect(!result.root.keys.contains("google-antigravity"))
        #expect(result.dropped == [
            DroppedProvider(provider: "google-antigravity", count: 1),
            DroppedProvider(provider: "google-gemini-cli", count: 1),
        ])
    }
}
