import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Compaction recap budget")
struct CompactionRecapBudgetTests {
    @Test("all recap sections share one hard token budget")
    func rendererBoundsCombinedSections() {
        var facts = CompactionFileFacts()
        facts.readPaths.insert("/tmp/read.swift")
        facts.modifiedPaths.insert("/tmp/modified.swift")
        let result = CompactionRecapRenderer.render(
            historySummary: String(repeating: "history & <state> ", count: 500),
            turnPrefixSummary: String(repeating: "active prefix ", count: 300),
            facts: facts,
            previousRecapForFacts: nil,
            runningTasks: String(repeating: "running task details ", count: 300),
            maxTokens: 400
        )

        #expect(ContextTokenEstimator.estimate(text: result.text) <= 400)
        #expect(result.text.contains("<history>"))
        #expect(result.text.contains("<current-turn-prefix>"))
        #expect(result.text.contains("<file-operations>"))
        #expect(result.text.contains("<running-background-tasks>"))
        #expect(result.hasRunningTasksLedger)
    }

    @Test("an impossible target fails before paying for a summary")
    func impossibleTargetSkipsSummaryRequest() async throws {
        let model = Model(
            id: "impossible-recap",
            api: "faux",
            provider: "faux",
            contextWindow: 1_000,
            maxTokens: 200
        )
        let calls = SummaryCallCounter()
        let result = await AgentContextCompactor.compactContext(
            context: AgentContext(
                systemPrompt: "system",
                messages: conversation(model: model),
                tools: []
            ),
            model: model,
            sessionId: "impossible-recap",
            config: AgentContextCompactionConfig(minMessages: 1),
            targetTokens: 100,
            respectMinimumMessages: false,
            streamFn: { model, _, _ in
                await calls.increment()
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "should not run"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        )

        guard case .failure(.failed(let reason)) = result else {
            Issue.record("expected an impossible reduction failure")
            return
        }
        #expect(reason.contains("is too small for the minimum"))
        // "recovery target of <target> tokens is too small for the minimum
        // <minimum>-token recap" — the reported minimum must itself exceed the
        // target that just failed, or the message is self-contradictory and a
        // retry at the reported value fails again.
        let numbers = reason.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let target = try #require(numbers.first)
        let minimum = try #require(numbers.last)
        #expect(minimum > target)
        #expect(await calls.value == 0)
    }

    @Test("oversized model output is bounded before the replacement is measured")
    func oversizedSummaryIsBounded() async throws {
        let model = Model(
            id: "bounded-recap",
            api: "faux",
            provider: "faux",
            contextWindow: 4_000,
            maxTokens: 500
        )
        let calls = SummaryCallCounter()
        let result = await AgentContextCompactor.compactContext(
            context: AgentContext(
                systemPrompt: "system",
                messages: conversation(model: model),
                tools: []
            ),
            model: model,
            sessionId: "bounded-recap",
            config: AgentContextCompactionConfig(
                minMessages: 1,
                summaryWordTarget: 900,
                strategy: .legacyFullSummary,
                keepRecentTokens: 300,
                maxSummaryAttempts: 2
            ),
            targetTokens: 1_200,
            respectMinimumMessages: false,
            streamFn: { model, _, _ in
                await calls.increment()
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(
                        text: "## Goal\n" + String(repeating: "oversized summary state ", count: 2_000)
                    ))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        )

        let compacted = try result.get()
        #expect(try #require(compacted.tokensAfter) <= 1_200)
        let recap = try #require(compacted.messages.first)
        #expect(ContextTokenEstimator.estimate(message: recap) <= 306)
        #expect(await calls.value == 1)
    }

    @Test("a recovery target does not silently lower an explicit generation cap")
    func recoveryKeepsExplicitSummaryCap() async throws {
        let model = Model(
            id: "explicit-summary-cap",
            api: "faux",
            provider: "faux",
            contextWindow: 4_000,
            maxTokens: 1_000
        )
        let capture = SummaryMaxTokenCapture()
        let result = await AgentContextCompactor.compactContext(
            context: AgentContext(
                systemPrompt: "system",
                messages: conversation(model: model),
                tools: []
            ),
            model: model,
            sessionId: "explicit-summary-cap",
            config: AgentContextCompactionConfig(
                minMessages: 1,
                strategy: .legacyFullSummary,
                summaryMaxTokens: 4_096
            ),
            targetTokens: 1_200,
            respectMinimumMessages: false,
            streamFn: { model, _, options in
                await capture.record(options?.maxTokens)
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "bounded summary"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        )

        _ = try result.get()
        #expect(await capture.value == 1_000)
    }

    private func conversation(model: Model) -> [Message] {
        let payload = String(repeating: "conversation payload ", count: 30)
        return [
            .user(UserMessage(text: "old request \(payload)")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "old response \(payload)"))],
                api: model.api,
                provider: model.provider,
                model: model.id
            )),
            .user(UserMessage(text: "latest request \(payload)")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "latest response \(payload)"))],
                api: model.api,
                provider: model.provider,
                model: model.id
            )),
        ]
    }
}

private actor SummaryCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor SummaryMaxTokenCapture {
    private(set) var value: Int?

    func record(_ value: Int?) {
        self.value = value
    }
}
