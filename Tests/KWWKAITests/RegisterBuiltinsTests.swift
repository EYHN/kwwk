import Foundation
import Testing
@testable import KWWKAI

// `RegisterBuiltins.swift` is the SDK-facing convenience surface documented
// in README's "The agent SDK" section — the kwwk CLI never calls it, so this
// suite is what keeps the public quick-start API exercised. Each test runs
// against a private `APIRegistry` instance: the shared registry's flat map is
// contended by env-auth tests (which register/unregister `anthropic-messages`
// concurrently), so asserting on it would be racy.

@Suite("registerBuiltins SDK surface")
struct RegisterBuiltinsTests {

    @Test("registerBuiltins registers exactly the providers given keys")
    func explicitKeys() async {
        let registry = APIRegistry()
        let sourceId = "test-builtins-\(UUID().uuidString.prefix(8))"

        let apis = await registerBuiltins(
            anthropic: "sk-ant-test-fake",
            sourceId: sourceId,
            registry: registry
        )
        #expect(apis == ["anthropic-messages"])
        #expect(await registry.provider(for: "anthropic-messages") is AnthropicProvider)
        // Nil keys register nothing.
        #expect(await registry.provider(for: "openai-responses") == nil)

        // sourceId-based cleanup removes everything the call registered.
        await registry.unregisterSource(sourceId)
        #expect(await registry.provider(for: "anthropic-messages") == nil)
    }

    @Test("registerBuiltinsFromEnvironment reads the supported env keys")
    func environmentSnapshot() async {
        let registry = APIRegistry()
        let sourceId = "test-builtins-env-\(UUID().uuidString.prefix(8))"

        // GEMINI_API_KEY is the documented fallback for the Google slot, and
        // OPENAI_API_KEY drives both OpenAI wire protocols.
        let apis = await registerBuiltinsFromEnvironment(
            env: ["GEMINI_API_KEY": "AIza-test-fake", "OPENAI_API_KEY": "sk-test-fake"],
            sourceId: sourceId,
            registry: registry
        )
        #expect(apis == ["openai-completions", "openai-responses", "google-generative-ai"])
        #expect(await registry.provider(for: "google-generative-ai") is GoogleGeminiProvider)
        #expect(await registry.provider(for: "openai-completions") is OpenAICompletionsProvider)
        #expect(await registry.provider(for: "openai-responses") is OpenAIResponsesProvider)

        // An empty snapshot registers nothing.
        let empty = await registerBuiltinsFromEnvironment(
            env: [:], sourceId: sourceId, registry: registry
        )
        #expect(empty.isEmpty)

        await registry.unregisterSource(sourceId)
        #expect(await registry.provider(for: "google-generative-ai") == nil)
    }
}
