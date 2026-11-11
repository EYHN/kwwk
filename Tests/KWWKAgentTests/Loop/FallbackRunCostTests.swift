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
        let message = AssistantMessage(
            content: [.text(TextContent(text: "done"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            responseModel: served.id,
            usage: usage
        )
        let recorder = FallbackCostRecorder()
        try await AgentLoop.run(
            prompts: [.user(UserMessage(text: "hello"))],
            context: AgentContext(systemPrompt: "", messages: [], tools: []),
            config: AgentLoopConfig(model: model),
            emit: { await recorder.record($0) },
            cancellation: nil,
            streamFn: { _, _, _ in
                let stream = AssistantMessageStream()
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
                return stream
            }
        )
        #expect(await recorder.cost == usage.cost)
    }

    @Test func sumsProviderBilledTurnCosts() async throws {
        let model = Model(id: "deepseek/deepseek-v4.1-flash", api: "openai-completions", provider: "openrouter",
                          cost: ModelCost(input: 0.006, output: 0.5, cacheRead: 0.005, cacheWrite: 0))
        var usage = Usage(input: 100_000, output: 2_000, totalTokens: 102_000)
        usage.cost = Cost(input: 0.03, output: 0.01, total: 0.04, billed: true)
        let message = AssistantMessage(
            content: [.text(TextContent(text: "done"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: usage
        )
        let recorder = FallbackCostRecorder()
        try await AgentLoop.run(
            prompts: [.user(UserMessage(text: "hello"))],
            context: AgentContext(systemPrompt: "", messages: [], tools: []),
            config: AgentLoopConfig(model: model),
            emit: { await recorder.record($0) },
            cancellation: nil,
            streamFn: { _, _, _ in
                let stream = AssistantMessageStream()
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
                return stream
            }
        )
        #expect(await recorder.cost?.total == 0.04)
    }
}

private actor FallbackCostRecorder {
    var cost: Cost?
    func record(_ event: AgentEvent) {
        if case .agentEnd(_, let summary) = event { cost = summary.cost }
    }
}
