import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("Compaction request policy")
struct CompactionRequestTests {
    // pi #6647 / omp oneshot retry: callers can disable retries, and an
    // exhausted logical call never multiplies attempts through nested loops.
    @Test(arguments: [1, 3], [false, true])
    func oneRetryOwner(maxAttempts: Int, native: Bool) async throws {
        let attempts = CompactionAttempts()
        let original = history()
        let agent = Agent(options: AgentOptions(initialState: AgentInitialState(model: Self.model, messages: original),
            streamFn: { _, _, _ in
                _ = await attempts.next()
                throw ProviderFailure(message: "terminated")
            }))
        var config = AgentContextCompactionConfig(keepRecentTokens: 40,
            summaryRetryPolicy: .init(maxAttempts: maxAttempts, baseDelayMs: 0))
        if native {
            config.nativeCompaction = { _, _, _, _ in
                _ = await attempts.next()
                throw ProviderFailure(message: "terminated", httpStatus: 503)
            }
        }
        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: nil, config: config)
        guard case .failed = outcome else { Issue.record("Expected exhausted compaction"); return }
        #expect(await attempts.count == maxAttempts)
        #expect(agent.state.messages == original)
    }

    @Test func anthropicBelowTriggerUsesLocalSummary() async throws {
        var model = Self.model
        model.api = "anthropic-messages"
        model.provider = "anthropic"
        model.id = "claude-opus-4-8"
        let config = AgentContextCompactionConfig(keepRecentTokens: 40,
            nativeCompaction: { _, _, _, _ in Issue.record("Native request below trigger floor"); return nil })
        let result = await AgentContextCompactor.compactMessages(messages: history(), model: model,
            sessionId: nil, config: config, streamFn: { model, _, _ in
                let stream = AssistantMessageStream()
                stream.end(AssistantMessage(content: [.text(TextContent(text: "local summary"))],
                    api: model.api, provider: model.provider, model: model.id))
                return stream
            })
        _ = try result.get()
    }

    static let model = Model(id: "compaction-test", api: "test", provider: "test",
                             contextWindow: 100_000, maxTokens: 4_000)

    @Test("local summary retries both terminal and thrown transient failures")
    func summaryRetries() async throws {
        let attempts = CompactionAttempts()
        let summary = try await AgentContextCompactor.summarizeTranscript(
            messages: [.user(UserMessage(text: "work"))], model: Self.model, sessionId: nil,
            config: .init(summaryRetryPolicy: .init(baseDelayMs: 0)), streamFn: { model, _, _ in
                let count = await attempts.next()
                if count == 1 { throw ProviderFailure(message: "HTTP 503 unavailable", httpStatus: 503) }
                let stream = AssistantMessageStream()
                stream.end(AssistantMessage(content: count == 2 ? [] : [.text(TextContent(text: "summary"))],
                    api: model.api, provider: model.provider, model: model.id,
                    stopReason: count == 2 ? .error : .stop,
                    errorMessage: count == 2 ? "Anthropic returned status 529: overloaded" : nil))
                return stream
            })
        #expect(summary == "summary")
        #expect(await attempts.count == 3)
    }

    @Test("permanent errors and truncated summaries are not retried")
    func permanentErrors() async throws {
        for reason in ["HTTP 400 invalid input with artifact 503", "HTTP 401 connection unauthorized", "context length exceeded"] {
            let attempts = CompactionAttempts()
            await #expect(throws: (any Error).self) {
                try await ProviderRetryPolicy(baseDelayMs: 0).run(cancellation: nil) { () async throws -> String in
                    _ = await attempts.next()
                    throw ProviderFailure(message: reason)
                }
            }
            #expect(await attempts.count == 1)
        }
        let attempts = CompactionAttempts()
        await #expect(throws: (any Error).self) {
            try await ProviderRetryPolicy(baseDelayMs: 0).run(cancellation: nil) { () async throws -> String in
                _ = await attempts.next()
                throw AgentContextCompactionError.summaryTruncated
            }
        }
        #expect(await attempts.count == 1)
    }

    @Test("cancellation stops retry backoff before another request")
    func cancelledRetry() async throws {
        let cancellation = CancellationHandle()
        let attempts = CompactionAttempts()
        let task = Task {
            try await ProviderRetryPolicy(baseDelayMs: 1_000).run(cancellation: cancellation) { () async throws -> String in
                _ = await attempts.next()
                throw ProviderFailure(message: "overloaded", httpStatus: 529)
            }
        }
        while await attempts.count == 0 { await Task.yield() }
        cancellation.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await attempts.count == 1)
    }

    @Test("native compaction retries, preserves tail and survives session persistence")
    func nativePersistence() async throws {
        let attempts = CompactionAttempts()
        let messages = history()
        let config = AgentContextCompactionConfig(keepRecentTokens: 40, summaryRetryPolicy: .init(baseDelayMs: 0),
            nativeCompaction: { model, context, _, _ in
                if await attempts.next() == 1 { throw ProviderFailure(message: "unavailable", httpStatus: 503) }
                #expect(context.messages.count < messages.count)
                return NativeCompactionResult(summary: "native summary", payload: .init(model: model,
                    items: [["type": "compaction", "encrypted_content": "opaque"]], fallbackMessages: context.messages))
            })
        let result = try await AgentContextCompactor.compactMessages(messages: messages, model: Self.model,
            sessionId: nil, config: config, streamFn: { _, _, _ in
                Issue.record("local summary must not run")
                throw ProviderFailure(message: "unexpected local call")
            }).get()
        #expect(await attempts.count == 2)
        #expect(result.messages.last == messages.last)
        guard case .user(let recap) = result.messages[0] else { Issue.record("missing recap"); return }
        #expect(recap.nativeCompaction != nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let id = UUID().uuidString
        try await store.appendCompaction(id: id, cwd: "/tmp", replacementMessages: result.messages,
            messagesCompacted: result.messagesCompacted, firstKeptMessageIndex: result.firstKeptMessageIndex, reason: .compact)
        let restored = try await store.load(id: id)
        guard case .user(let loaded) = restored.messages[0] else { Issue.record("missing restored recap"); return }
        #expect(loaded.nativeCompaction == recap.nativeCompaction)
        var other = Self.model
        other.provider = "other"
        #expect(TransformMessages.expandNativeCompaction(restored.messages, model: other) == messages)
    }

    @Test("custom stream alone never falls through to a registered native provider")
    func customStreamUsesLocal() async throws {
        let calls = CompactionAttempts()
        let result = await AgentContextCompactor.compactMessages(messages: history(), model: Self.model,
            sessionId: nil, config: .init(keepRecentTokens: 40), streamFn: { model, _, _ in
                _ = await calls.next()
                let stream = AssistantMessageStream()
                stream.end(AssistantMessage(content: [.text(TextContent(text: "summary"))],
                    api: model.api, provider: model.provider, model: model.id))
                return stream
            })
        _ = try result.get()
        #expect(await calls.count > 0)
    }

    @Test("default Agent routes manual compaction to its registered native provider")
    func defaultAgentNativeRouting() async throws {
        let provider = NativeTestProvider()
        var model = Self.model
        model.provider = UUID().uuidString
        await APIRegistry.shared.register(provider, scope: model.provider)
        let agent = Agent(initialState: AgentInitialState(model: model, messages: history()))
        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: nil,
            config: .init(keepRecentTokens: 40, summaryRetryPolicy: .init(baseDelayMs: 0)))
        await APIRegistry.shared.unregisterScope(model.provider)
        guard case .compacted = outcome else { Issue.record("native compaction failed: \(outcome)"); return }
        #expect(await provider.calls.count == 1)
        guard case .user(let recap) = agent.state.messages[0] else { Issue.record("missing recap"); return }
        #expect(recap.nativeCompaction != nil)
    }

    @Test("native retry exhaustion leaves the Agent transcript unchanged")
    func nativeFailurePreservesContext() async throws {
        let attempts = CompactionAttempts()
        let original = history()
        let agent = Agent(initialState: AgentInitialState(model: Self.model, messages: original))
        let config = AgentContextCompactionConfig(keepRecentTokens: 40, summaryRetryPolicy: .init(baseDelayMs: 0),
            nativeCompaction: { _, _, _, _ in
                _ = await attempts.next()
                throw ProviderFailure(message: "overloaded", httpStatus: 529)
            })
        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: nil, config: config)
        guard case .failed = outcome else { Issue.record("expected failure"); return }
        #expect(await attempts.count == config.summaryRetryPolicy.maxAttempts)
        #expect(agent.state.messages == original)
    }

    @Test("a separate summary model keeps native compaction off")
    func separateModelUsesLocal() async throws {
        var summaryModel = Self.model
        summaryModel.id = "other-summary-model"
        let config = AgentContextCompactionConfig(keepRecentTokens: 40,
            nativeCompaction: { _, _, _, _ in Issue.record("native path must not run"); return nil })
        let result = await AgentContextCompactor.compactMessages(messages: history(), model: Self.model,
            compactionModel: summaryModel, sessionId: nil, config: config,
            streamFn: { model, _, _ in
                #expect(model.id == "other-summary-model")
                let stream = AssistantMessageStream()
                stream.end(AssistantMessage(content: [.text(TextContent(text: "local summary"))],
                    api: model.api, provider: model.provider, model: model.id))
                return stream
            })
        _ = try result.get()
    }

    @Test("foreign native history compacts with only a recap and unanswered tail", arguments: [0, 1, 3])
    func foreignRecap(tailCount: Int) async throws {
        let original = history().map { message -> Message in
            guard case .user(var user) = message else { return message }
            user.content.append(.text(TextContent(text: String(repeating: "A", count: 32_000))))
            return .user(user)
        }
        var recap = UserMessage(text: "<previous-session-summary>Native history</previous-session-summary>", source: .compaction)
        recap.nativeCompaction = .init(model: Self.model,
            items: [["type": "compaction", "encrypted_content": "opaque"]], fallbackMessages: original)
        var model = Self.model
        model.provider = "different"
        model.contextWindow = 16_000
        let tail = (0..<tailCount).map { Message.user(UserMessage(text: "unanswered \($0)")) }
        #expect(ContextTokenEstimator.estimate(messages: [.user(recap)] + tail, model: model).effective > model.contextWindow)
        let attempts = CompactionAttempts()
        let result = try await AgentContextCompactor.compactMessages(
            messages: [.user(recap)] + tail, model: model, sessionId: nil,
            config: .init(keepRecentTokens: 40, useNativeCompaction: false), targetTokens: 4_000,
            streamFn: { model, context, _ in
                _ = await attempts.next()
                let transcript = String(decoding: try JSONEncoder().encode(context.messages), as: UTF8.self)
                #expect(transcript.contains("request 0"))
                let stream = AssistantMessageStream()
                stream.end(AssistantMessage(content: [.text(TextContent(text: "portable history"))],
                    api: model.api, provider: model.provider, model: model.id))
                return stream
            }).get()
        #expect(await attempts.count == 1)
        #expect(result.firstKeptMessageIndex == 1)
        #expect(result.messagesCompacted == 1)
        #expect(Array(result.messages.dropFirst()) == tail)
        #expect(result.tokensAfter! <= 4_000)
        guard case .user(let saved) = result.messages[0] else { Issue.record("missing recap"); return }
        #expect(saved.nativeCompaction == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try await store.appendCompaction(id: "foreign", cwd: "/tmp", replacementMessages: result.messages,
            messagesCompacted: result.messagesCompacted, firstKeptMessageIndex: result.firstKeptMessageIndex, reason: .compact)
        let restored = try await store.load(id: "foreign")
        #expect(restored.messages == result.messages)
    }

    @Test("native image estimates do not depend on base64 length")
    func nativeImageEstimate() {
        func estimate(_ count: Int) -> Int {
            var recap = UserMessage(text: "summary", source: .compaction)
            recap.nativeCompaction = .init(model: Self.model, items: [
                ["type": "message", "role": "user", "content": [
                    ["type": "input_image", "image_url": .string("data:image/png;base64," + String(repeating: "A", count: count))]
                ]], ["type": "compaction", "encrypted_content": "opaque"]
            ])
            return ContextTokenEstimator.estimate(message: .user(recap))
        }
        #expect(estimate(10) == estimate(1_000_000))
        #expect(estimate(1_000_000) < 2_000)
    }

    @Test("fallback persistence recursively redacts hidden goal continuations")
    func redactNativeFallback() throws {
        let hidden = Message.user(UserMessage(text: goalContinuationMarker + " PRIVATE_OBJECTIVE"))
        var inner = UserMessage(text: "inner", source: .compaction)
        inner.nativeCompaction = .init(model: Self.model, items: [], fallbackMessages: [hidden])
        var outer = UserMessage(text: "outer", source: .compaction)
        outer.nativeCompaction = .init(model: Self.model,
            items: [["type": "compaction", "encrypted_content": "opaque"]], fallbackMessages: [.user(inner)])
        let redacted = redactedForPersistence(.user(outer))
        let json = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
        #expect(!json.contains("PRIVATE_OBJECTIVE"))
        #expect(json.contains("redacted goal continuation"))
        #expect(json.contains("opaque"))
        #expect(String(decoding: try JSONEncoder().encode(outer), as: UTF8.self).contains("PRIVATE_OBJECTIVE"))
    }

    @Test("Anthropic native requests honor summary budget and redact hidden inputs", arguments: [0, 1_024])
    func nativeSummaryBudget(cap: Int) async throws {
        let model = Model(id: "claude-sonnet-4-6", api: "anthropic-messages", provider: "anthropic",
            contextWindow: 200_000, maxTokens: 64_000)
        let attempts = CompactionAttempts()
        let config = AgentContextCompactionConfig(keepRecentTokens: 40, summaryMaxTokens: cap,
            nativeCompaction: { model, context, _, options in
                _ = await attempts.next()
                let expected = cap > 0 ? cap : 1_800
                #expect(options?.maxTokens == expected)
                let encoded = try AnthropicProvider.encodeBody(model: model, context: context, options: options)
                let body = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
                #expect(body["max_tokens"] == .int(expected))
                #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_OBJECTIVE"))
                return NativeCompactionResult(summary: "summary", payload: .init(model: model,
                    items: [["type": "compaction", "content": "summary"]]))
            })
        let messages: [Message] = [
            .user(UserMessage(text: String(repeating: "A", count: 240_000))),
            .assistant(AssistantMessage(content: [.text(TextContent(text: "done"))],
                api: model.api, provider: model.provider, model: model.id)),
            .user(UserMessage(text: goalContinuationMarker + " PRIVATE_OBJECTIVE")),
            .user(UserMessage(text: "next"))
        ]
        _ = try await AgentContextCompactor.compactMessages(messages: messages, model: model,
            sessionId: nil, config: config).get()
        #expect(await attempts.count == 1)
    }

    private func history() -> [Message] {
        (0..<3).flatMap { index in
            [Message.user(UserMessage(text: "request \(index) " + String(repeating: "data ", count: 100))),
             .assistant(AssistantMessage(content: [.text(TextContent(text: "answer \(index)"))],
                api: Self.model.api, provider: Self.model.provider, model: Self.model.id))]
        }
    }
}

private actor CompactionAttempts {
    var count = 0
    func next() -> Int { count += 1; return count }
}

private final class NativeTestProvider: NativeCompactionProvider, Sendable {
    let api = "test"
    let calls = CompactionAttempts()
    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        Issue.record("local provider call must not run")
        let stream = AssistantMessageStream()
        stream.end(AssistantMessage(content: [], api: api, provider: model.provider, model: model.id, stopReason: .error))
        return stream
    }
    func compact(model: Model, context: Context, instructions: String,
                 options: StreamOptions?) async throws -> NativeCompactionResult? {
        _ = await calls.next()
        return NativeCompactionResult(summary: "native summary", payload: .init(model: model,
            items: [["type": "compaction", "encrypted_content": "opaque"]], fallbackMessages: context.messages))
    }
}
