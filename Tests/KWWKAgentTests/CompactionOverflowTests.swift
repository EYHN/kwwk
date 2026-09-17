import Foundation
import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Summary provider overflow recovery")
struct CompactionOverflowTests {
    private let model = Model(id: "summary-overflow", api: "faux", provider: "faux",
                              contextWindow: 40_000, maxTokens: 1_000)

    private var config: AgentContextCompactionConfig {
        .init(minMessages: 1, keepRecentTokens: 1, messageTextByteLimit: 200_000,
              summaryRetryPolicy: .init(baseDelayMs: 0))
    }

    @Test("rejected summaries shrink and preserve ordered history", arguments: [false, true], [false, true])
    func shrinksRejectedWindow(thrown: Bool, nested: Bool) async {
        let markers = (0..<12).map { "HISTORY-\($0)-END" }
        let messages = markers.map {
            Message.user(UserMessage(text: $0 + String(repeating: " payload", count: 1_000)))
        } + [.user(UserMessage(text: "retained tail"))]
        let log = OverflowLog()
        let result = await compact(messages, log: log, limit: 9_000, thrown: thrown, nested: nested)
        guard case .success = result else {
            Issue.record("Expected recovery, got \(result)")
            return
        }
        let calls = await log.calls
        #expect(calls.contains { !$0.accepted })
        let accepted = calls.filter(\.accepted)
        #expect(accepted.count > 1)
        let combined = accepted.map(\.text).joined()
        for marker in markers {
            #expect(combined.components(separatedBy: marker).count == 2)
        }
        for call in accepted.dropFirst() {
            #expect(call.text.contains("durable-summary"))
        }
        #expect(accepted.allSatisfy { $0.tokens <= 9_000 })
    }

    @Test("an indivisible oversized message is bounded on retry")
    func shrinksSingleMessage() async {
        let log = OverflowLog()
        let result = await compact([
            .user(UserMessage(text: String(repeating: " payload", count: 14_000))),
            .user(UserMessage(text: "retained tail")),
        ], log: log, limit: 9_000)
        guard case .success = result else {
            Issue.record("Expected bounded single-message recovery, got \(result)")
            return
        }
        let calls = await log.calls
        #expect(calls.count > 1)
        #expect(calls.last?.accepted == true)
        #expect(calls.last!.tokens < calls.first!.tokens)
    }

    @Test("non-overflow errors do not shrink", arguments: [
        "Anthropic stop reason: refusal", "request timed out", "HTTP 429 rate limit: input tokens exceed quota",
    ])
    func nonOverflowIsTerminal(reason: String) async {
        let log = OverflowLog()
        let result = await compact([
            .user(UserMessage(text: String(repeating: " payload", count: 10_000))),
            .user(UserMessage(text: "tail")),
        ], log: log, limit: 0, reason: reason)
        guard case .failure = result else { Issue.record("Expected failure"); return }
        let calls = await log.calls
        #expect(calls.count == (reason.contains("refusal") ? 1 : 5))
        #expect(calls.allSatisfy { $0.text == calls.first?.text })
    }

    @Test("persistent overflow stops at the minimum budget")
    func stopsAtFloor() async {
        let log = OverflowLog()
        let result = await compact([
            .user(UserMessage(text: String(repeating: " payload", count: 14_000))),
            .user(UserMessage(text: "tail")),
        ], log: log, limit: 0)
        guard case .failure = result else { Issue.record("Expected terminal overflow"); return }
        let calls = await log.calls
        #expect(calls.count > 1 && calls.count < 8)
        for (previous, next) in zip(calls, calls.dropFirst()) {
            #expect(next.tokens < previous.tokens)
        }
    }

    @Test("cancellation after a provider rejection prevents another summary request")
    func cancellationStopsRecovery() async {
        let log = OverflowLog()
        let cancellation = CancellationHandle()
        let result = await compact([
            .user(UserMessage(text: String(repeating: " payload", count: 14_000))),
            .user(UserMessage(text: "tail")),
        ], log: log, limit: 0, cancelOnResponse: cancellation)
        guard case .failure = result else { Issue.record("Expected cancellation"); return }
        #expect(await log.calls.count == 1)
    }

    private func compact(
        _ messages: [Message], log: OverflowLog, limit: Int, thrown: Bool = false, nested: Bool = false,
        reason: String = "This model's maximum prompt length is 500000 but the request contains 536700 tokens.",
        cancelOnResponse: CancellationHandle? = nil
    ) async -> Result<AgentContextCompactionResult, AgentContextCompactionFailure> {
        // Completed turns may be evicted; unanswered user messages must stay.
        let history = messages.dropLast().flatMap { message in
            [message, .assistant(AssistantMessage(
                content: [.text(TextContent(text: "completed"))],
                api: model.api, provider: model.provider, model: model.id
            ))]
        } + messages.suffix(1)
        return await AgentContextCompactor.compactContext(
            context: AgentContext(systemPrompt: "", messages: history, tools: []),
            model: model, sessionId: "overflow-test", config: config,
            streamFn: { model, context, _ in
                let text = context.messages.compactMap { message -> String? in
                    guard case .user(let user) = message else { return nil }
                    return user.content.compactMap { block -> String? in
                        guard case .text(let text) = block else { return nil }
                        return text.text
                    }.joined()
                }.joined()
                let tokens = ContextTokenEstimator.estimate(text: text)
                let accepted = tokens <= limit
                await log.append(text: text, tokens: tokens, accepted: accepted)
                cancelOnResponse?.cancel()
                let failure: ProviderFailure? = !accepted && nested ? ProviderFailure.payload(.object([
                    "error": .object(["message": .string("Provider returned error"), "code": .int(400),
                                      "metadata": .object(["raw": .string(reason)])]),
                ])) : nil
                if !accepted && thrown {
                    if let failure { throw failure }
                    throw OverflowError(reason: reason)
                }
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: accepted ? [.text(TextContent(text: "durable-summary"))] : [],
                    api: model.api, provider: model.provider, model: model.id,
                    stopReason: accepted ? .stop : .error,
                    errorMessage: accepted ? nil : (failure?.message ?? reason),
                    failure: failure
                ))
                return pair.stream
            },
            cancellation: cancelOnResponse
        )
    }
}

private struct OverflowError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

private actor OverflowLog {
    struct Call: Sendable { let text: String; let tokens: Int; let accepted: Bool }
    var calls: [Call] = []
    func append(text: String, tokens: Int, accepted: Bool) {
        calls.append(Call(text: text, tokens: tokens, accepted: accepted))
    }
}
