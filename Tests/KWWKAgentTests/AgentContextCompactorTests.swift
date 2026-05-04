import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Agent context compactor")
struct AgentContextCompactorTests {
    @Test("renderForSummary caps verbose tool output")
    func renderForSummaryCapsToolOutput() {
        let messages: [Message] = [
            .user(UserMessage(text: "inspect the log")),
            .assistant(AssistantMessage(
                content: [
                    .thinking(ThinkingContent(thinking: "private reasoning")),
                    .toolCall(ToolCall(id: "tool-1", name: "read_log", arguments: .object([:])))
                ],
                api: "faux",
                provider: "faux",
                model: "faux"
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "tool-1",
                toolName: "read_log",
                content: [.text(TextContent(text: String(repeating: "x", count: 20)))]
            )),
        ]

        let rendered = AgentContextCompactor.renderForSummary(
            messages,
            toolOutputCharacterLimit: 8
        )

        #expect(rendered.contains("User:\ninspect the log"))
        #expect(rendered.contains("<tool-call name=\"read_log\" />"))
        #expect(rendered.contains("... [12 chars elided]"))
        #expect(!rendered.contains("private reasoning"))
    }

    @Test("compactAgent summarizes and replaces the transcript")
    func compactAgentReplacesTranscript() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("summary of prior work"))])

        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: conversation(model: faux.getModel())
        ))

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "compact-test"
        )

        #expect(outcome == .compacted(messagesCompacted: 4, hasRunningTasksLedger: false))
        #expect(agent.state.messages.count == 1)
        #expect(text(from: agent.state.messages.first).contains("<previous-session-summary>"))
        #expect(text(from: agent.state.messages.first).contains("summary of prior work"))
    }

    @Test("inline compaction only fires above the threshold")
    func inlineCompactionUsesThreshold() async {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "small-window", contextWindow: 100)
        ]))
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("inline summary"))])

        let model = faux.getModel()
        var messages = conversation(model: model)
        let highUsage = AssistantMessage(
            content: [.text(TextContent(text: "large turn"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 80, output: 1)
        )
        messages.append(.assistant(highUsage))

        let agent = Agent(initialState: AgentInitialState(
            model: model,
            messages: messages
        ))
        let context = AgentContext(systemPrompt: "", messages: messages, tools: [])

        let replaced = await AgentContextCompactor.compactInlineIfNeeded(
            agent: agent,
            context: context,
            threshold: 0.75,
            sessionId: "inline-test"
        )

        let replacedMessages = replaced?.messages ?? []
        #expect(replacedMessages.count == 1)
        #expect(text(from: replacedMessages.first).contains("inline summary"))
    }

    @Test("compactAgent uses the agent stream function and context hooks")
    func compactAgentUsesAgentStreamAndHooks() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let model = faux.getModel()
        let capture = SummaryStreamCapture()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: model,
                messages: conversation(model: model)
            ),
            streamFn: { model, context, options in
                await capture.record(context: context, sessionId: options?.sessionId)
                let stream = AssistantMessageStream()
                stream.end(AssistantMessage(
                    content: [.text(TextContent(text: "custom stream summary"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return stream
            },
            convertToLlm: { messages in
                messages + [.user(UserMessage(text: "converted marker"))]
            },
            transformContext: { messages, _ in
                rewriteText(in: messages, replacing: "feature X", with: "feature REDACTED")
            }
        ))

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "hook-session"
        )

        #expect(outcome == .compacted(messagesCompacted: 4, hasRunningTasksLedger: false))
        #expect(text(from: agent.state.messages.first).contains("custom stream summary"))
        let snapshot = await capture.snapshot()
        #expect(snapshot.sessionId == "hook-session")
        #expect(snapshot.prompt.contains("feature REDACTED"))
        #expect(snapshot.prompt.contains("converted marker"))
        #expect(!snapshot.prompt.contains("feature X"))
    }

    @Test("agent auto compacts between turns and emits compact events")
    func agentAutoCompactsAndEmitsEvents() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "auto-window", contextWindow: 5)
        ]))
        defer { faux.unregister() }

        let model = faux.getModel()
        let highUsage = AssistantMessage(
            content: [.text(TextContent(text: "final answer"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 80, output: 1)
        )
        faux.setResponses([
            .message(highUsage),
            .message(fauxAssistantMessage("built-in summary")),
        ])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: model,
                messages: conversation(model: model)
            ),
            autoCompact: AgentAutoCompactOptions(
                threshold: 0.1,
                config: AgentContextCompactionConfig(minMessages: 1)
            )
        ))
        let events = CompactEventLog()
        let unsubscribe = agent.subscribe { event, _ in
            await events.record(event)
        }
        defer { unsubscribe() }

        try await agent.prompt("please do the task")

        let snapshot = await events.snapshot()
        #expect(snapshot.starts == 1)
        #expect(snapshot.compacted == 1)
        #expect(text(from: snapshot.agentEndMessages.first).contains("built-in summary"))
        #expect(agent.state.messages.count == 1)
        #expect(text(from: agent.state.messages.first).contains("built-in summary"))
    }

    @Test("compactAgent refuses tiny transcripts")
    func compactAgentRefusesTinyTranscript() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: [.user(UserMessage(text: "hi"))]
        ))

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "tiny"
        )

        #expect(outcome == .refusedTooFewMessages(count: 1))
        #expect(agent.state.messages.count == 1)
    }

    private func conversation(model: Model) -> [Message] {
        [
            .user(UserMessage(text: "please add feature X")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "working on it"))],
                api: model.api,
                provider: model.provider,
                model: model.id
            )),
            .user(UserMessage(text: "any update?")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "step one done"))],
                api: model.api,
                provider: model.provider,
                model: model.id
            )),
        ]
    }

    private func text(from message: Message?) -> String {
        guard case .user(let user) = message else { return "" }
        return user.content.compactMap { block in
            guard case .text(let text) = block else { return nil }
            return text.text
        }.joined(separator: "\n")
    }
}

private actor CompactEventLog {
    private var starts = 0
    private var compacted = 0
    private var agentEndMessages: [Message] = []

    func record(_ event: AgentEvent) {
        switch event {
        case .compactStart:
            starts += 1
        case .compactEnd(let outcome):
            if case .compacted = outcome {
                compacted += 1
            }
        case .agentEnd(let messages, _):
            agentEndMessages = messages
        default:
            break
        }
    }

    func snapshot() -> (starts: Int, compacted: Int, agentEndMessages: [Message]) {
        (starts, compacted, agentEndMessages)
    }
}

private actor SummaryStreamCapture {
    private var prompt = ""
    private var sessionId: String?

    func record(context: Context, sessionId: String?) {
        self.prompt = context.messages.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            return user.content.compactMap { block -> String? in
                guard case .text(let text) = block else { return nil }
                return text.text
            }.joined(separator: "\n")
        }.joined(separator: "\n")
        self.sessionId = sessionId
    }

    func snapshot() -> (prompt: String, sessionId: String?) {
        (prompt, sessionId)
    }
}

private func rewriteText(in messages: [Message], replacing old: String, with new: String) -> [Message] {
    messages.map { message in
        switch message {
        case .user(var user):
            user.content = user.content.map { block in
                switch block {
                case .text(var text):
                    text.text = text.text.replacingOccurrences(of: old, with: new)
                    return .text(text)
                case .image:
                    return block
                }
            }
            return .user(user)

        case .assistant(var assistant):
            assistant.content = assistant.content.map { block in
                switch block {
                case .text(var text):
                    text.text = text.text.replacingOccurrences(of: old, with: new)
                    return .text(text)
                case .thinking, .toolCall:
                    return block
                }
            }
            return .assistant(assistant)

        case .toolResult(var result):
            result.content = result.content.map { block in
                switch block {
                case .text(var text):
                    text.text = text.text.replacingOccurrences(of: old, with: new)
                    return .text(text)
                case .image:
                    return block
                }
            }
            return .toolResult(result)
        }
    }
}
