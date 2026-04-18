import Foundation
import Testing
@testable import KWAI

@Suite("Message encoding")
struct MessageEncodingTests {

    @Test("user message with string content round-trips")
    func userRoundTrip() throws {
        let msg = Message.user(UserMessage(text: "hi", timestamp: 10))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        #expect(decoded == msg)
    }

    @Test("assistant message with mixed content blocks round-trips")
    func assistantRoundTrip() throws {
        let msg = Message.assistant(AssistantMessage(
            content: [
                .thinking(ThinkingContent(thinking: "ponder")),
                .text(TextContent(text: "answer")),
                .toolCall(ToolCall(id: "c-1", name: "noop", arguments: ["x": 1])),
            ],
            api: "faux",
            provider: "faux",
            model: "faux-1",
            stopReason: .toolUse,
            timestamp: 100
        ))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        #expect(decoded == msg)
    }

    @Test("tool result message round-trips")
    func toolResultRoundTrip() throws {
        let msg = Message.toolResult(ToolResultMessage(
            toolCallId: "c-1",
            toolName: "echo",
            content: [.text(TextContent(text: "done"))],
            isError: false,
            timestamp: 50
        ))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        #expect(decoded == msg)
    }
}

@Suite("Model cost calculation")
struct CostTests {
    @Test("calculateCost converts usage to USD according to per-1M-token pricing")
    func costCalc() {
        let model = Model(
            id: "priced",
            api: "faux",
            provider: "faux",
            cost: ModelCost(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75)
        )
        let usage = Usage(input: 1_000_000, output: 500_000, cacheRead: 250_000, cacheWrite: 100_000, totalTokens: 1_850_000)
        let cost = calculateCost(model: model, usage: usage)
        #expect(cost.input == 3.0)
        #expect(cost.output == 7.5)
        #expect(cost.cacheRead == 0.075)
        #expect(cost.cacheWrite == 0.375)
        #expect(cost.total == 10.95)
    }
}
