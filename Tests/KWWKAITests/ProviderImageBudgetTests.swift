import Foundation
import Testing
@testable import KWWKAI

@Suite("Provider image budget")
struct ProviderImageBudgetTests {
    @Test("provider limits match OMP policy and the KWWK Codex scope")
    func providerLimits() {
        let expectedLimits = [
            "anthropic": 90,
            "amazon-bedrock": 90,
            "openai": 200,
            "openai-codex": 200,
            "chatgpt-codex": 200,
            "google": 200,
            "google-vertex": 200,
            "google-gemini-cli": 200,
            "openrouter": 90,
            "umans": 10,
        ]

        for (provider, expectedLimit) in expectedLimits {
            #expect(ProviderImageBudget.limit(for: provider) == expectedLimit)
        }
        #expect(ProviderImageBudget.limit(for: "some-new-provider") == 5)
    }

    @Test("drops the oldest images while preserving text and stored context")
    func dropsOldestImages() {
        let context = Context(messages: (0..<8).map { index in
            .user(UserMessage(content: [
                .text(TextContent(text: "text-\(index)")),
                image("image-\(index)"),
            ]))
        })

        let clamped = ProviderImageBudget.clamp(context, for: visionModel(provider: "unknown"))

        #expect(imageData(in: clamped) == (3..<8).map { "image-\($0)" })
        #expect(textData(in: clamped) == (0..<8).map { "text-\($0)" })
        #expect(imageData(in: context) == (0..<8).map { "image-\($0)" })
    }

    @Test("keeps an image-only tool result meaningful when its image is dropped")
    func preservesImageOnlyToolResultMeaning() {
        let context = Context(messages: (0..<6).map { index in
            .toolResult(ToolResultMessage(
                toolCallId: "call-\(index)",
                toolName: "inspect_image",
                content: [toolResultImage("image-\(index)")]
            ))
        })

        let clamped = ProviderImageBudget.clamp(context, for: visionModel(provider: "unknown"))

        #expect(imageData(in: clamped) == (1..<6).map { "image-\($0)" })
        guard case .toolResult(let first) = clamped.messages[0] else {
            Issue.record("expected a tool result")
            return
        }
        #expect(first.content == [
            .text(TextContent(text: "[image omitted: provider image limit]")),
        ])
    }

    @Test("keeps an image-only user message meaningful when its image is dropped")
    func preservesImageOnlyUserMessageMeaning() {
        let context = Context(messages: (0..<6).map { index in
            .user(UserMessage(content: [image("image-\(index)")]))
        })

        let clamped = ProviderImageBudget.clamp(context, for: visionModel(provider: "unknown"))

        #expect(imageData(in: clamped) == (1..<6).map { "image-\($0)" })
        guard case .user(let first) = clamped.messages[0] else {
            Issue.record("expected a user message")
            return
        }
        #expect(first.content == [
            .text(TextContent(text: "[image omitted: provider image limit]")),
        ])
    }

    @Test("does not clamp images for a text-only model")
    func textOnlyModelIsUnchanged() {
        let context = Context(messages: [
            .user(UserMessage(content: (0..<6).map { image("image-\($0)") })),
        ])
        let model = Model(
            id: "text-only",
            api: "provider-image-budget-test",
            provider: "unknown",
            input: [.text]
        )

        #expect(ProviderImageBudget.clamp(context, for: model) == context)
    }

    @Test("recomputes the transient view when the active model changes")
    func modelSwitchRecomputesBudget() {
        let context = Context(messages: [
            .user(UserMessage(content: (0..<6).map { image("image-\($0)") })),
        ])

        let unknownView = ProviderImageBudget.clamp(
            context,
            for: visionModel(provider: "unknown")
        )
        let openAIView = ProviderImageBudget.clamp(
            context,
            for: visionModel(provider: "openai")
        )

        #expect(imageData(in: unknownView) == (1..<6).map { "image-\($0)" })
        #expect(imageData(in: openAIView) == (0..<6).map { "image-\($0)" })
        #expect(imageData(in: context) == (0..<6).map { "image-\($0)" })
    }

    @Test("top-level stream clamps the context before provider dispatch")
    func streamClampsBeforeDispatch() async throws {
        let provider = RecordingImageContextProvider()
        let registry = APIRegistry()
        await registry.register(provider, scope: "unknown")
        let context = Context(messages: [
            .user(UserMessage(content: (0..<6).map { image("image-\($0)") })),
        ])

        _ = try await stream(
            model: visionModel(provider: "unknown"),
            context: context,
            registry: registry
        )

        let received = try #require(provider.receivedContext)
        #expect(imageData(in: received) == (1..<6).map { "image-\($0)" })
        #expect(imageData(in: context) == (0..<6).map { "image-\($0)" })
    }

    private func visionModel(provider: String) -> Model {
        Model(
            id: "vision",
            api: "provider-image-budget-test",
            provider: provider,
            input: [.text, .image]
        )
    }

    private func image(_ data: String) -> UserBlock {
        .image(ImageContent(data: data, mimeType: "image/png"))
    }

    private func toolResultImage(_ data: String) -> ToolResultBlock {
        .image(ImageContent(data: data, mimeType: "image/png"))
    }

    private func imageData(in context: Context) -> [String] {
        context.messages.flatMap { message -> [String] in
            switch message {
            case .user(let user):
                return user.content.compactMap { block in
                    if case .image(let image) = block { return image.data }
                    return nil
                }
            case .toolResult(let result):
                return result.content.compactMap { block in
                    if case .image(let image) = block { return image.data }
                    return nil
                }
            case .assistant:
                return []
            }
        }
    }

    private func textData(in context: Context) -> [String] {
        context.messages.flatMap { message -> [String] in
            switch message {
            case .user(let user):
                return user.content.compactMap { block in
                    if case .text(let text) = block { return text.text }
                    return nil
                }
            case .toolResult(let result):
                return result.content.compactMap { block in
                    if case .text(let text) = block { return text.text }
                    return nil
                }
            case .assistant:
                return []
            }
        }
    }
}

private final class RecordingImageContextProvider: APIProvider, @unchecked Sendable {
    let api = "provider-image-budget-test"

    private let lock = NSLock()
    private var context: Context?

    var receivedContext: Context? {
        lock.withLock { context }
    }

    func stream(
        model: Model,
        context: Context,
        options: StreamOptions?
    ) -> AssistantMessageStream {
        lock.withLock { self.context = context }
        return AssistantMessageStream()
    }
}
