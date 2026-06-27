import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli

@Suite("CLI env auth resolver")
struct AuthResolverEnvTests {
    @Test("Bedrock env auth accepts AWS_PROFILE")
    func bedrockProfileAuthIsSelectable() async {
        await APIRegistry.shared.unregister(api: "bedrock-converse-stream")

        let resolved = await resolveEnvAuth(
            modelOverride: "amazon-bedrock/amazon.nova-2-lite-v1:0",
            environment: ["AWS_PROFILE": "default"]
        )

        #expect(resolved?.model.provider == "amazon-bedrock")
        #expect(resolved?.model.api == "bedrock-converse-stream")
        #expect(await APIRegistry.shared.provider(for: "bedrock-converse-stream") is BedrockProvider)

        await APIRegistry.shared.unregister(api: "bedrock-converse-stream")
    }

    @Test("Anthropic-compatible env providers use Bearer auth")
    func anthropicCompatibleUsesBearerAuth() async {
        await APIRegistry.shared.unregister(api: "anthropic-messages")

        let resolved = await resolveEnvAuth(
            modelOverride: "vercel-ai-gateway/alibaba/qwen-3-14b",
            environment: ["AI_GATEWAY_API_KEY": "vercel-key"]
        )

        #expect(resolved?.model.provider == "vercel-ai-gateway")
        #expect(resolved?.model.api == "anthropic-messages")
        let provider = await APIRegistry.shared.provider(for: "anthropic-messages") as? AnthropicProvider
        #expect(provider?.authHeaderBuilder("abc123")["Authorization"] == "Bearer abc123")

        await APIRegistry.shared.unregister(api: "anthropic-messages")
    }
}
