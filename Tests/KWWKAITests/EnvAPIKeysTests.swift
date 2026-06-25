import Foundation
import Testing
@testable import KWWKAI

@Suite("Env API keys")
struct EnvAPIKeysTests {
    @Test("resolves provider keys from an injected environment")
    func resolvesKeys() {
        let env = [
            "OPENROUTER_API_KEY": "or-123",
            "GROQ_API_KEY": "gq-456",
            "ANTHROPIC_API_KEY": "an-789",
        ]
        #expect(EnvAPIKeys.apiKey(for: "openrouter", env: env) == "or-123")
        #expect(EnvAPIKeys.apiKey(for: "groq", env: env) == "gq-456")
        #expect(EnvAPIKeys.apiKey(for: "anthropic", env: env) == "an-789")
        #expect(EnvAPIKeys.apiKey(for: "deepseek", env: env) == nil)
    }

    @Test("ANTHROPIC_OAUTH_TOKEN takes precedence over ANTHROPIC_API_KEY")
    func anthropicPrecedence() {
        let env = ["ANTHROPIC_OAUTH_TOKEN": "oauth-tok", "ANTHROPIC_API_KEY": "key"]
        #expect(EnvAPIKeys.apiKey(for: "anthropic", env: env) == "oauth-tok")
    }

    @Test("empty env vars are treated as absent")
    func emptyIsAbsent() {
        #expect(EnvAPIKeys.apiKey(for: "xai", env: ["XAI_API_KEY": ""]) == nil)
        #expect(EnvAPIKeys.foundEnvVars(for: "xai", env: ["XAI_API_KEY": ""]).isEmpty)
    }

    @Test("configuredProviders returns set providers in priority order")
    func configuredOrder() {
        let env = ["GROQ_API_KEY": "g", "ANTHROPIC_API_KEY": "a", "DEEPSEEK_API_KEY": "d"]
        let providers = EnvAPIKeys.configuredProviders(env: env)
        #expect(providers == ["anthropic", "deepseek", "groq"])
    }

    @Test("amazon-bedrock surfaces when ambient AWS keys are present")
    func bedrockDetection() {
        let withKeys = ["AWS_ACCESS_KEY_ID": "AKIA", "AWS_SECRET_ACCESS_KEY": "secret"]
        #expect(EnvAPIKeys.hasBedrockKeys(env: withKeys))
        #expect(EnvAPIKeys.configuredProviders(env: withKeys).contains("amazon-bedrock"))
        // Partial creds don't count.
        #expect(!EnvAPIKeys.hasBedrockKeys(env: ["AWS_ACCESS_KEY_ID": "AKIA"]))
        #expect(!EnvAPIKeys.configuredProviders(env: [:]).contains("amazon-bedrock"))
    }

    @Test("covers the full pi provider env map")
    func mapCoverage() {
        // Spot-check the breadth ported from pi env-api-keys.ts.
        for p in ["openrouter", "mistral", "deepseek", "groq", "xai", "together",
                  "fireworks", "cerebras", "moonshotai", "nvidia", "huggingface",
                  "vercel-ai-gateway", "kimi-coding", "zai", "minimax"] {
            #expect(EnvAPIKeys.envVars[p] != nil, "missing env var mapping for \(p)")
        }
    }
}
