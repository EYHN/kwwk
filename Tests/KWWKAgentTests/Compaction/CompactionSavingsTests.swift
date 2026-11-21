import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("Compaction savings")
struct CompactionSavingsTests {
    static let model = Model(
        id: "compaction-savings",
        api: "test",
        provider: "test",
        contextWindow: 100_000,
        maxTokens: 4_000
    )

    // MARK: ToolResultPruner

    @Test("old tool results become a one-line placeholder; recent, error and exempt ones stay")
    func prunerPrunesOldResults() {
        let big = "Building for debugging...\n" + String(repeating: "x", count: 5_000)
        let messages: [Message] = [
            call("1", "bash", ["command": "swift build 2>&1 | tail -50"]),
            result("1", "bash", big),
            call("2", "bash", ["command": "false"]),
            result("2", "bash", big, isError: true),
            call("3", "bot_read_message", ["channel_id": "chat.1"]),
            result("3", "bot_read_message", big),
            call("4", "read", ["path": "/skills/x/SKILL.md"]),
            result("4", "read", big),
            call("5", "grep", ["pattern": "TODO"]),
            result("5", "grep", "short"),
            call("6", "read", ["path": "/recent.swift"]),
            result("6", "read", big),
        ]
        let policy = ToolResultPrunePolicy(protectRecentTokens: 1_000)
        let (pruned, report) = ToolResultPruner.prune(messages, policy: policy)
        #expect(report.prunedCount == 1)
        #expect(report.savedCharacters > 4_000)
        #expect(Array(pruned[2...]) == Array(messages[2...]))
        #expect(text(pruned[1]) == "[tool result cleared to save context — bash(swift build 2>&1 | tail -50) "
            + "returned 5026 chars; first line: \"Building for debugging...\". Re-run the tool if you need it.]")
        guard case .toolResult(let kept) = pruned[1], case .toolResult(let original) = messages[1] else {
            Issue.record("tool result moved"); return
        }
        #expect(kept.toolCallId == original.toolCallId)
        #expect(kept.toolName == original.toolName)
        // Deterministic and idempotent.
        #expect(ToolResultPruner.prune(messages, policy: policy).messages == pruned)
        let again = ToolResultPruner.prune(pruned, policy: policy)
        #expect(again.messages == pruned)
        #expect(again.report.prunedCount == 0)
    }

    @Test("everything within the protected window is kept verbatim")
    func prunerProtectsRecentWindow() {
        let messages: [Message] = [
            call("1", "bash", ["command": "ls\nrm"]),
            result("1", "bash", String(repeating: "line\n", count: 1_000)),
        ]
        #expect(ToolResultPruner.prune(messages).messages == messages)
        let pruned = ToolResultPruner.prune(messages, policy: .init(protectRecentTokens: 0)).messages
        #expect(text(pruned[1]).contains("bash(ls\\nrm)"))
        #expect(text(pruned[1]).contains("first line: \"line\""))
    }

    // MARK: Summary request

    @Test("the summary request is sent uncached and its input pruned")
    func summaryRequestUncachedAndPruned() async throws {
        let capture = SavingsCapture()
        let secret = "make: building\n" + String(repeating: "OLD_TOOL_OUTPUT\n", count: 200)
        var messages: [Message] = [
            .user(UserMessage(text: "build it")),
            call("old", "bash", ["command": "make"]),
            result("old", "bash", secret),
        ]
        messages += (0..<3).flatMap { index -> [Message] in [
            .user(UserMessage(text: "request \(index) " + String(repeating: "data ", count: 100))),
            assistant("answer \(index)"),
        ] }
        let config = AgentContextCompactionConfig(
            keepRecentTokens: 40,
            useNativeCompaction: false,
            summaryInputPruning: .init(protectRecentTokens: 100)
        )
        _ = try await AgentContextCompactor.compactMessages(
            messages: messages,
            model: Self.model,
            sessionId: nil,
            config: config,
            streamFn: { model, context, options in
                await capture.keep(context: context, options: options)
                return Self.reply("summary", model: model)
            }
        ).get()
        let options = try #require(await capture.options.first ?? nil)
        #expect(options.cacheRetention == CacheRetention.none)
        let prompt = await capture.prompts.joined()
        #expect(prompt.contains(ToolResultPruner.placeholderPrefix))
        #expect(prompt.contains("bash(make) returned 3215 chars; first line: \\\"make: building\\\""))
        #expect(!prompt.contains("OLD_TOOL_OUTPUT"))

        // An uncached request carries no Anthropic cache breakpoint.
        let context = try #require(await capture.contexts.first)
        let body = try AnthropicProvider.encodeBody(
            model: Model(id: "claude-sonnet-4-6", api: "anthropic-messages", provider: "anthropic"),
            context: context,
            options: options
        )
        #expect(!String(decoding: body, as: UTF8.self).contains("cache_control"))

        await capture.reset()
        var unpruned = config
        unpruned.summaryInputPruning = nil
        _ = try await AgentContextCompactor.compactMessages(
            messages: messages, model: Self.model, sessionId: nil, config: unpruned,
            streamFn: { model, context, options in
                await capture.keep(context: context, options: options)
                return Self.reply("summary", model: model)
            }
        ).get()
        #expect(await capture.prompts.joined().contains("OLD_TOOL_OUTPUT"))
    }

    // MARK: Native compaction

    @Test("a failed native compaction falls back to the summary", arguments: [400, 404, 529])
    func nativeFailureFallsBack(status: Int) async throws {
        let failures = SavingsCounter()
        let summaries = SavingsCounter()
        let config = AgentContextCompactionConfig(
            keepRecentTokens: 40,
            summaryRetryPolicy: .init(maxAttempts: 1, baseDelayMs: 0),
            nativeCompaction: { _, _, _, _ in
                throw ProviderFailure(message: "native unavailable", httpStatus: status)
            },
            onNativeCompactionFailure: { _ in Task { await failures.next() } }
        )
        let result = try await AgentContextCompactor.compactMessages(
            messages: history(),
            model: Self.model,
            sessionId: nil,
            config: config,
            streamFn: { model, _, _ in
                await summaries.next()
                return Self.reply("local summary", model: model)
            }
        ).get()
        #expect(await summaries.count > 0)
        guard case .user(let recap) = result.messages[0] else { Issue.record("missing recap"); return }
        #expect(recap.nativeCompaction == nil)
        #expect(recap.content.contains { block in
            if case .text(let text) = block { return text.text.contains("local summary") }
            return false
        })
        while await failures.count == 0 { await Task.yield() }
    }

    @Test("an authentication failure in native compaction is not hidden by a summary")
    func nativeAuthFailureThrows() async throws {
        let config = AgentContextCompactionConfig(
            keepRecentTokens: 40,
            summaryRetryPolicy: .init(maxAttempts: 1, baseDelayMs: 0),
            nativeCompaction: { _, _, _, _ in
                throw ProviderFailure(message: "unauthorized", httpStatus: 401)
            }
        )
        let result = await AgentContextCompactor.compactMessages(
            messages: history(),
            model: Self.model,
            sessionId: nil,
            config: config,
            streamFn: { _, _, _ in
                Issue.record("summary must not run")
                throw ProviderFailure(message: "unexpected")
            }
        )
        guard case .failure = result else { Issue.record("expected failure"); return }
    }

    @Test("native compaction usage reaches the agent's compaction usage")
    func nativeUsageIsRecorded() async throws {
        let usage = Usage(input: 3, output: 5_000, cacheRead: 200_000, cacheWrite: 1_000, totalTokens: 206_003)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: Self.model, messages: history()),
            streamFn: { _, _, _ in
                Issue.record("summary must not run")
                throw ProviderFailure(message: "unexpected")
            }
        ))
        let config = AgentContextCompactionConfig(
            keepRecentTokens: 40,
            nativeCompaction: { model, context, _, _ in
                NativeCompactionResult(
                    summary: "native summary",
                    payload: .init(
                        model: model,
                        items: [["type": "compaction", "encrypted_content": "opaque"]],
                        fallbackMessages: context.messages
                    ),
                    usage: usage
                )
            }
        )
        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: nil, config: config)
        guard case .compacted = outcome else { Issue.record("expected compaction: \(outcome)"); return }
        #expect(agent.takeCompactionUsage() == usage)
    }

    // Below Anthropic's 50k trigger floor a native request would answer with
    // a normal turn; a host's own name for the wire must skip it too.
    @Test(arguments: ["anthropic-messages", "airbuild-anthropic-messages-team-agent"])
    func anthropicFloorFollowsTheWire(api: String) async throws {
        var model = Self.model
        model.api = api
        model.provider = "anthropic"
        model.id = "claude-opus-4-8"
        let config = AgentContextCompactionConfig(
            keepRecentTokens: 40,
            nativeCompaction: { _, _, _, _ in Issue.record("native request below trigger floor"); return nil }
        )
        _ = try await AgentContextCompactor.compactMessages(
            messages: history(),
            model: model,
            sessionId: nil,
            config: config,
            streamFn: { model, _, _ in Self.reply("local summary", model: model) }
        ).get()
    }

    // MARK: Cold-cache compaction

    @Test("the cache counts as expired after TTL plus margin")
    func coldCacheDue() {
        let now: Int64 = 10_000_000
        func due(_ options: AgentColdCacheCompactOptions, idle: Int64, ratio: Double) -> Bool {
            options.isDue(
                messages: [.user(UserMessage(text: "hi")), .assistant(assistantMessage("a", timestamp: now - idle))],
                usage: AgentContextUsage(tokens: Int(ratio * 1_000), window: 1_000),
                autoCompactThreshold: 0.75,
                now: now
            )
        }
        let short = AgentColdCacheCompactOptions()
        #expect(due(short, idle: 331_000, ratio: 0.5))
        #expect(!due(short, idle: 329_000, ratio: 0.5))
        #expect(!due(short, idle: 331_000, ratio: 0.49))
        let long = AgentColdCacheCompactOptions(cacheRetention: .long)
        #expect(!due(long, idle: 331_000, ratio: 0.6))
        #expect(due(long, idle: 3_631_000, ratio: 0.6))
        #expect(!due(AgentColdCacheCompactOptions(cacheRetention: CacheRetention.none), idle: 99_000_000, ratio: 0.7))
        #expect(!short.isDue(
            messages: [.user(UserMessage(text: "hi"))],
            usage: AgentContextUsage(tokens: 700, window: 1_000),
            autoCompactThreshold: 0.75,
            now: now
        ))
    }

    @Test("a request on a cold cache compacts first, without native compaction",
          arguments: [(400_000 as Int64, 1_200, true), (200_000, 1_200, false), (400_000, 600, false)])
    func coldCacheCompactsFirst(idleMs: Int64, contextTokens: Int, compacts: Bool) async throws {
        let outcome = try await runColdCache(idleMs: idleMs, contextTokens: contextTokens, coldCache: .init())
        #expect(outcome.compactions == (compacts ? 1 : 0))
        #expect(outcome.summaryOptions.allSatisfy { $0?.cacheRetention == CacheRetention.none })
        #expect(outcome.summaryOptions.isEmpty == !compacts)
    }

    @Test("cold-cache compaction can be turned off")
    func coldCacheDisabled() async throws {
        let outcome = try await runColdCache(idleMs: 400_000, contextTokens: 1_200, coldCache: nil)
        #expect(outcome.compactions == 0)
    }

    @Test("a cold-cache compaction persists and resumes like any compaction")
    func coldCachePersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let outcome = try await runColdCache(idleMs: 400_000, contextTokens: 1_200, coldCache: .init())
        #expect(outcome.compactions == 1)
        let compacted = try #require(outcome.compactedMessages)
        try await store.appendCompaction(
            id: "cold",
            cwd: "/tmp",
            replacementMessages: compacted,
            messagesCompacted: 2,
            firstKeptMessageIndex: 2,
            reason: .compact
        )
        #expect(try await store.load(id: "cold").messages == compacted)
    }

    private struct ColdCacheOutcome {
        var compactions: Int
        var summaryOptions: [StreamOptions?]
        var compactedMessages: [Message]?
    }

    private func runColdCache(
        idleMs: Int64,
        contextTokens: Int,
        coldCache: AgentColdCacheCompactOptions?
    ) async throws -> ColdCacheOutcome {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "cold-window", contextWindow: 2_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let then = Timestamp.now() - idleMs
        let history: [Message] = [
            .user(UserMessage(text: "please add feature X", timestamp: then - 2)),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "working on it"))],
                api: model.api, provider: model.provider, model: model.id,
                timestamp: then - 1
            )),
            .user(UserMessage(text: "any update?", timestamp: then - 1)),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "step one done"))],
                api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: contextTokens, output: 1),
                timestamp: then
            )),
        ]
        let capture = SavingsCapture()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: model, messages: history),
            streamFn: { model, context, options in
                if context.systemPrompt?.contains("durable working-state summary") == true {
                    await capture.keep(context: context, options: options)
                    return Self.reply("cold summary", model: model)
                }
                return Self.reply("done", model: model)
            },
            autoCompact: AgentAutoCompactOptions(
                config: .init(nativeCompaction: { _, _, _, _ in
                    Issue.record("native compaction must not run on a cold cache")
                    return nil
                }),
                coldCache: coldCache
            )
        ))
        let compactions = SavingsCounter()
        let compacted = SavingsMessagesBox()
        let unsubscribe = agent.subscribe { event, _ in
            if case .compactEnd(let outcome) = event, case .compacted = outcome {
                await compactions.next()
                await compacted.set(agent.state.messages)
            }
        }
        defer { unsubscribe() }
        try await agent.prompt("continue")
        return ColdCacheOutcome(
            compactions: await compactions.count,
            summaryOptions: await capture.options,
            compactedMessages: await compacted.messages
        )
    }

    // MARK: Helpers

    private func history() -> [Message] {
        (0..<3).flatMap { index in
            [
                Message.user(UserMessage(text: "request \(index) " + String(repeating: "data ", count: 100))),
                assistant("answer \(index)"),
            ]
        }
    }

    private func assistantMessage(_ text: String, timestamp: Int64) -> AssistantMessage {
        AssistantMessage(
            content: [.text(TextContent(text: text))],
            api: Self.model.api,
            provider: Self.model.provider,
            model: Self.model.id,
            timestamp: timestamp
        )
    }

    private func assistant(_ text: String) -> Message {
        .assistant(assistantMessage(text, timestamp: Timestamp.now()))
    }

    private func call(_ id: String, _ name: String, _ arguments: [String: JSONValue]) -> Message {
        .assistant(AssistantMessage(
            content: [.toolCall(ToolCall(id: id, name: name, arguments: .object(arguments)))],
            api: Self.model.api,
            provider: Self.model.provider,
            model: Self.model.id,
            stopReason: .toolUse
        ))
    }

    private func result(_ id: String, _ name: String, _ text: String, isError: Bool = false) -> Message {
        .toolResult(ToolResultMessage(
            toolCallId: id,
            toolName: name,
            content: [.text(TextContent(text: text))],
            isError: isError
        ))
    }

    private func text(_ message: Message) -> String {
        guard case .toolResult(let result) = message else { return "" }
        return result.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
    }

    private static func reply(_ text: String, model: Model) -> AssistantMessageStream {
        let stream = AssistantMessageStream()
        stream.end(AssistantMessage(
            content: [.text(TextContent(text: text))],
            api: model.api,
            provider: model.provider,
            model: model.id
        ))
        return stream
    }
}

private actor SavingsCapture {
    var options: [StreamOptions?] = []
    var contexts: [Context] = []
    var prompts: [String] = []

    func keep(context: Context, options: StreamOptions?) {
        self.options.append(options)
        contexts.append(context)
        for case .user(let user) in context.messages {
            for case .text(let text) in user.content { prompts.append(text.text) }
        }
    }

    func reset() {
        options = []
        contexts = []
        prompts = []
    }
}

private actor SavingsCounter {
    var count = 0
    func next() { count += 1 }
}

private actor SavingsMessagesBox {
    var messages: [Message]?
    func set(_ messages: [Message]) { self.messages = messages }
}
