import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("Compaction request policy")
struct CompactionRequestTests {
    static let model = Model(id: "compaction-test", api: "test", provider: "test",
                             contextWindow: 100_000, maxTokens: 4_000)

    @Test("local summary retries both terminal and thrown transient failures")
    func summaryRetries() async throws {
        let attempts = CompactionAttempts()
        let summary = try await AgentContextCompactor.summarizeTranscript(
            messages: [.user(UserMessage(text: "work"))], model: Self.model, sessionId: nil,
            config: .init(retryBaseDelayMs: 0), streamFn: { model, _, _ in
                let count = await attempts.next()
                if count == 1 { throw NativeCompactionError(status: 503, message: "HTTP 503 unavailable") }
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
                try await CompactionRetry.run(config: .init(retryBaseDelayMs: 0), cancellation: nil) { () async throws -> String in
                    _ = await attempts.next()
                    throw NativeCompactionError(message: reason)
                }
            }
            #expect(await attempts.count == 1)
        }
        let attempts = CompactionAttempts()
        await #expect(throws: (any Error).self) {
            try await CompactionRetry.run(config: .init(retryBaseDelayMs: 0), cancellation: nil) { () async throws -> String in
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
            try await CompactionRetry.run(config: .init(retryBaseDelayMs: 1_000), cancellation: cancellation) { () async throws -> String in
                _ = await attempts.next()
                throw NativeCompactionError(status: 529, message: "overloaded")
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
        let config = AgentContextCompactionConfig(keepRecentTokens: 40, retryBaseDelayMs: 0,
            nativeCompaction: { model, context, _, _ in
                if await attempts.next() == 1 { throw NativeCompactionError(status: 503, message: "unavailable") }
                #expect(context.messages.count < messages.count)
                return NativeCompactionResult(summary: "native summary", payload: .init(model: model,
                    items: [["type": "compaction", "encrypted_content": "opaque"]], fallbackMessages: context.messages))
            })
        let result = try await AgentContextCompactor.compactMessages(messages: messages, model: Self.model,
            sessionId: nil, config: config, streamFn: { _, _, _ in
                Issue.record("local summary must not run")
                throw NativeCompactionError(message: "unexpected local call")
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
            config: .init(keepRecentTokens: 40, retryBaseDelayMs: 0))
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
        let config = AgentContextCompactionConfig(keepRecentTokens: 40, retryBaseDelayMs: 0,
            nativeCompaction: { _, _, _, _ in
                _ = await attempts.next()
                throw NativeCompactionError(status: 529, message: "overloaded")
            })
        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: nil, config: config)
        guard case .failed = outcome else { Issue.record("expected failure"); return }
        #expect(await attempts.count == 3)
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
