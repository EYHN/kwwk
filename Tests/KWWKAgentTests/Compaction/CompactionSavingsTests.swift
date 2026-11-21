import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("Compaction savings")
struct CompactionSavingsTests {
    static let model = Model(id: "savings", api: "test", provider: "test", contextWindow: 1_000_000, maxTokens: 4_000)

    @Test("the summary request is uncached and old tool results in its input are cleared")
    func summaryRequestUncachedAndPruned() async throws {
        let capture = SavingsCapture()
        let old = "make: building\n" + String(repeating: "OLD_TOOL_OUTPUT\n", count: 200)
        var messages: [Message] = [
            .user(UserMessage(text: "build it")),
            call("old", ["command": "make"]),
            result("old", old),
            call("err", ["command": "false"]),
            result("err", "ERROR_OUTPUT " + String(repeating: "e", count: 2_000), isError: true),
        ]
        // Over 60k tokens of later conversation, all summarized as well.
        messages += (0..<30).flatMap { index -> [Message] in [
            .user(UserMessage(text: "request \(index) " + String(repeating: "data ", count: 2_000))),
            assistant("answer \(index)"),
        ] }
        _ = try await AgentContextCompactor.compactMessages(
            messages: messages,
            model: Self.model,
            sessionId: nil,
            config: AgentContextCompactionConfig(keepRecentTokens: 40, useNativeCompaction: false),
            streamFn: { model, context, options in
                await capture.keep(context: context, options: options)
                return Self.reply("summary", model: model)
            }
        ).get()
        #expect(await capture.options.allSatisfy { $0?.cacheRetention == CacheRetention.none })
        let prompt = await capture.prompts.joined()
        #expect(prompt.contains("returned 3215 chars; first line: make: building]"))
        #expect(!prompt.contains("OLD_TOOL_OUTPUT"))
        #expect(prompt.contains("ERROR_OUTPUT"))
    }

    @Test("a non-authentication native failure falls back to the summary and is reported as verbose")
    func nativeFailureFallsBack() async throws {
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: Self.model, verboseEnabled: true, messages: history()),
            streamFn: { model, _, _ in Self.reply("local summary", model: model) }
        ))
        let verbose = SavingsCapture()
        let unsubscribe = agent.subscribe { event, _ in
            if case .verbose(let event) = event { await verbose.note(event.message) }
        }
        defer { unsubscribe() }
        let config = AgentContextCompactionConfig(
            keepRecentTokens: 40,
            summaryRetryPolicy: .init(maxAttempts: 1, baseDelayMs: 0),
            nativeCompaction: { _, _, _, _ in throw ProviderFailure(message: "no compaction", httpStatus: 400) }
        )
        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: nil, config: config)
        guard case .compacted = outcome else { Issue.record("expected compaction: \(outcome)"); return }
        guard case .user(let recap) = agent.state.messages[0] else { Issue.record("missing recap"); return }
        #expect(recap.nativeCompaction == nil)
        #expect(recap.content.contains { block in
            if case .text(let text) = block { return text.text.contains("local summary") }
            return false
        })
        #expect(await verbose.prompts.contains { $0.contains("native compaction failed") })
    }

    @Test("native compaction usage reaches the agent's compaction usage")
    func nativeUsageIsRecorded() async throws {
        let usage = Usage(input: 3, output: 5_000, cacheRead: 200_000, cacheWrite: 1_000, totalTokens: 206_003)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: Self.model, messages: history()),
            streamFn: { _, _, _ in throw ProviderFailure(message: "summary must not run") }
        ))
        let config = AgentContextCompactionConfig(keepRecentTokens: 40, nativeCompaction: { model, context, _, _ in
            NativeCompactionResult(
                summary: "native summary",
                payload: .init(model: model, items: [["type": "compaction"]], fallbackMessages: context.messages),
                usage: usage
            )
        })
        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: nil, config: config)
        guard case .compacted = outcome else { Issue.record("expected compaction: \(outcome)"); return }
        #expect(agent.takeCompactionUsage() == usage)
    }

    @Test("a request on a cold cache compacts first, by summary", arguments: [(400_000 as Int64, true), (200_000, false)])
    func coldCacheCompactsFirst(idleMs: Int64, compacts: Bool) async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "cold-window", contextWindow: 2_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let then = Timestamp.now() - idleMs
        func reply(_ text: String, usage: Usage = Usage(), at time: Int64) -> Message {
            .assistant(AssistantMessage(content: [.text(TextContent(text: text))], api: model.api,
                                        provider: model.provider, model: model.id, usage: usage, timestamp: time))
        }
        // 1,200 of 2,000 tokens: past 2/3 of the 0.75 threshold, short of it.
        let history: [Message] = [
            .user(UserMessage(text: "please add feature X", timestamp: then - 2)),
            reply("working on it", at: then - 1),
            .user(UserMessage(text: "any update?", timestamp: then - 1)),
            reply("step one done", usage: Usage(input: 1_200, output: 1), at: then),
        ]
        let summaries = SavingsCapture()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: model, messages: history),
            streamFn: { model, context, options in
                if context.systemPrompt?.contains("durable working-state summary") == true {
                    await summaries.keep(context: context, options: options)
                    return Self.reply("cold summary", model: model)
                }
                return Self.reply("done", model: model)
            },
            autoCompact: AgentAutoCompactOptions(config: .init(nativeCompaction: { _, _, _, _ in
                Issue.record("native compaction must not run on a cold cache")
                return nil
            }), coldCacheIdle: 330)
        ))
        try await agent.prompt("continue")
        #expect(await summaries.options.isEmpty == !compacts)
        #expect(agent.state.messages.contains { message in
            if case .user(let user) = message { return user.source == .compaction }
            return false
        } == compacts)
    }

    private func history() -> [Message] {
        (0..<3).flatMap { index in [
            Message.user(UserMessage(text: "request \(index) " + String(repeating: "data ", count: 100))),
            assistant("answer \(index)"),
        ] }
    }

    private func assistant(_ text: String) -> Message {
        .assistant(AssistantMessage(content: [.text(TextContent(text: text))], api: Self.model.api,
                                    provider: Self.model.provider, model: Self.model.id))
    }

    private func call(_ id: String, _ arguments: [String: JSONValue]) -> Message {
        .assistant(AssistantMessage(content: [.toolCall(ToolCall(id: id, name: "bash", arguments: .object(arguments)))],
                                    api: Self.model.api, provider: Self.model.provider, model: Self.model.id,
                                    stopReason: .toolUse))
    }

    private func result(_ id: String, _ text: String, isError: Bool = false) -> Message {
        .toolResult(ToolResultMessage(toolCallId: id, toolName: "bash",
                                      content: [.text(TextContent(text: text))], isError: isError))
    }

    private static func reply(_ text: String, model: Model) -> AssistantMessageStream {
        let stream = AssistantMessageStream()
        stream.end(AssistantMessage(content: [.text(TextContent(text: text))], api: model.api,
                                    provider: model.provider, model: model.id))
        return stream
    }
}

private actor SavingsCapture {
    var options: [StreamOptions?] = []
    var prompts: [String] = []

    func note(_ text: String) { prompts.append(text) }

    func keep(context: Context, options: StreamOptions?) {
        self.options.append(options)
        for case .user(let user) in context.messages {
            for case .text(let text) in user.content { prompts.append(text.text) }
        }
    }
}
