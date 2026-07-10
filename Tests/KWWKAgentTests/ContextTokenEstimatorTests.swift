import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Context token estimator")
struct ContextTokenEstimatorTests {
    @Test("provider totalTokens wins and terminal errors are ignored")
    func providerUsageResolution() {
        let messages: [Message] = [
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: "faux",
                provider: "faux",
                model: "faux",
                usage: Usage(input: 10, output: 5, totalTokens: 120)
            )),
            .assistant(AssistantMessage(
                content: [],
                api: "faux",
                provider: "faux",
                model: "faux",
                usage: Usage(input: 999),
                stopReason: .error,
                errorMessage: "context overflow"
            )),
        ]

        let estimate = ContextTokenEstimator.estimate(messages: messages)
        let appendedErrorTokens = ContextTokenEstimator.estimate(message: messages[1])

        #expect(estimate.providerReported == 120 + appendedErrorTokens)
        #expect(estimate.effective >= 120)
    }

    @Test("provider anchors include locally estimated messages appended afterward")
    func providerUsageIncludesAppendedMessages() {
        let anchor = Message.assistant(AssistantMessage(
            content: [.text(TextContent(text: "prior answer"))],
            api: "faux",
            provider: "faux",
            model: "faux",
            usage: Usage(totalTokens: 500)
        ))
        let pending = Message.user(UserMessage(text: String(repeating: "p", count: 800)))

        let estimate = ContextTokenEstimator.estimate(messages: [anchor, pending])

        #expect(estimate.providerReported == 500 + ContextTokenEstimator.estimate(message: pending))
    }

    @Test("local estimate includes non-ASCII text and tool payloads")
    func localEstimateIncludesSemanticPayloads() {
        let plain = ContextTokenEstimator.estimate(messages: [
            .user(UserMessage(text: "hello")),
        ])
        let rich = ContextTokenEstimator.estimate(messages: [
            .user(UserMessage(text: "你好🙂")),
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(
                    id: "call-1",
                    name: "write",
                    arguments: .object(["path": .string("/tmp/文件.swift")])
                ))],
                api: "faux",
                provider: "faux",
                model: "faux"
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "call-1",
                toolName: "write",
                content: [.text(TextContent(text: "written"))],
                details: .object(["bytes": .int(7)])
            )),
        ])

        #expect(rich.locallyEstimated > plain.locallyEstimated)
    }

    @Test("full-context estimates include system instructions and tool schemas")
    func fullContextIncludesFixedPromptOverhead() {
        let model = Model(id: "fixed-overhead", api: "faux", provider: "faux")
        let messages = [Message.user(UserMessage(text: "hello"))]
        let messageOnly = ContextTokenEstimator.estimate(messages: messages, model: model)
        let tool = AgentTool(
            name: "lookup",
            label: "Lookup",
            description: String(repeating: "tool description ", count: 100),
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                ]),
            ])
        ) { _, _, _, _ in
            AgentToolResult(content: [.text(TextContent(text: "ok"))])
        }
        let context = AgentContext(
            systemPrompt: String(repeating: "system instruction ", count: 100),
            messages: messages,
            tools: [tool]
        )

        let full = ContextTokenEstimator.estimate(context: context, model: model)

        #expect(full.locallyEstimated > messageOnly.locallyEstimated)
    }

    @Test("provider usage from another model or a retained pre-compaction tail is ignored")
    func staleProviderUsageIsIgnored() {
        let active = Model(
            id: "active",
            name: "active",
            api: "faux",
            provider: "faux",
            contextWindow: 10_000
        )
        let recap = Message.user(UserMessage(
            text: "<previous-session-summary>state</previous-session-summary>",
            timestamp: 200,
            source: .compaction
        ))
        let retainedOldUsage = Message.assistant(AssistantMessage(
            content: [.text(TextContent(text: "old tail"))],
            api: "faux",
            provider: "faux",
            model: "active",
            usage: Usage(totalTokens: 9_000),
            timestamp: 100
        ))
        let wrongModelUsage = Message.assistant(AssistantMessage(
            content: [.text(TextContent(text: "other model"))],
            api: "faux",
            provider: "faux",
            model: "other",
            usage: Usage(totalTokens: 8_000),
            timestamp: 300
        ))

        let estimate = ContextTokenEstimator.estimate(
            messages: [recap, retainedOldUsage, wrongModelUsage],
            model: active
        )

        #expect(estimate.providerReported == nil)
        #expect(estimate.effective == estimate.locallyEstimated)
    }
}
