import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("Fallback run cost")
struct FallbackRunCostTests {
    @Test func retainsServedModelCost() async throws {
        let model = try #require(ModelsCatalog.model(provider: "anthropic", id: "claude-fable-5"))
        let served = try #require(ModelsCatalog.model(provider: "anthropic", id: "claude-opus-4-8"))
        var usage = Usage(input: 100, output: 20, totalTokens: 120)
        usage.cost = calculateCost(model: served, usage: usage)
        let message = AssistantMessage(content: [.text(TextContent(text: "done"))], api: model.api,
                                       provider: model.provider, model: model.id, responseModel: served.id, usage: usage)
        let recorder = FallbackCostRecorder()
        try await AgentLoop.run(
            prompts: [.user(UserMessage(text: "hello"))],
            context: AgentContext(systemPrompt: "", messages: [], tools: []),
            config: AgentLoopConfig(model: model),
            emit: { await recorder.record($0) }, cancellation: nil,
            streamFn: { _, _, _ in
                let stream = AssistantMessageStream()
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
                return stream
            }
        )
        #expect(await recorder.cost == usage.cost)
    }
}

private actor FallbackCostRecorder {
    var cost: Cost?
    func record(_ event: AgentEvent) {
        if case .agentEnd(_, let summary) = event { cost = summary.cost }
    }
}
