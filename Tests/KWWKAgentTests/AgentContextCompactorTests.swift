import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Agent context compactor")
struct AgentContextCompactorTests {
    @Test("renderForSummary emits structured JSONL and caps verbose tool output")
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

        #expect(rendered.contains(#""role":"user""#))
        #expect(rendered.contains("inspect the log"))
        #expect(rendered.contains(#""id":"tool-1""#))
        #expect(rendered.contains(#""name":"read_log""#))
        #expect(rendered.contains("middle elided"))
        #expect(rendered.contains("original UTF-8 bytes: 20"))
        #expect(rendered.contains("private reasoning"))
    }

    @Test("shakeToolOutputs collapses oversized results, keeps small ones, is idempotent")
    func shakeToolOutputsTrimsHeavyResults() {
        let big = String(repeating: "x", count: 5000)
        let messages: [Message] = [
            .user(UserMessage(text: "run the thing")),
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: "big", name: "bash", arguments: .object([:])))],
                api: "faux", provider: "faux", model: "faux"
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "big",
                toolName: "bash",
                content: [.text(TextContent(text: big))],
                isError: false
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "small",
                toolName: "read",
                content: [.text(TextContent(text: "tiny output"))]
            )),
        ]

        let beforeChars = toolResultChars(messages)
        let (trimmed, elided) = AgentContextCompactor.shakeToolOutputs(messages, keepingUnder: 1000)

        // Only the oversized result was collapsed.
        #expect(elided == 1)
        // The big result's text is now a short placeholder; metadata preserved.
        guard case .toolResult(let bigResult) = trimmed[2] else {
            Issue.record("expected tool result at index 2")
            return
        }
        #expect(bigResult.toolName == "bash")
        #expect(bigResult.toolCallId == "big")
        #expect(bigResult.content.count == 1)
        if case .text(let t) = bigResult.content.first {
            #expect(t.text.hasPrefix("[tool result elided to reclaim context"))
            #expect(t.text.contains("5000 chars"))
        } else {
            Issue.record("expected a placeholder text block")
        }
        // The small result is untouched.
        #expect(trimmed[3] == messages[3])

        // Token/char footprint drops after the trim.
        let afterChars = toolResultChars(trimmed)
        #expect(afterChars < beforeChars)

        // Idempotent: a second pass elides nothing and changes nothing.
        let (again, elidedAgain) = AgentContextCompactor.shakeToolOutputs(trimmed, keepingUnder: 1000)
        #expect(elidedAgain == 0)
        #expect(again == trimmed)
    }

    @Test("shakeToolOutputs keeps image blocks while collapsing oversized text")
    func shakeToolOutputsKeepsImages() {
        let big = String(repeating: "y", count: 4000)
        let messages: [Message] = [
            .toolResult(ToolResultMessage(
                toolCallId: "shot",
                toolName: "screenshot",
                content: [
                    .text(TextContent(text: big)),
                    .image(ImageContent(data: "AAAA", mimeType: "image/png")),
                ]
            )),
        ]

        let (trimmed, elided) = AgentContextCompactor.shakeToolOutputs(messages, keepingUnder: 1000)
        #expect(elided == 1)
        guard case .toolResult(let result) = trimmed[0] else {
            Issue.record("expected tool result")
            return
        }
        // One placeholder text block + the preserved image.
        #expect(result.content.count == 2)
        var hasImage = false
        for block in result.content {
            if case .image(let image) = block {
                hasImage = true
                #expect(image.data == "AAAA")
            }
        }
        #expect(hasImage)
    }

    private func toolResultChars(_ messages: [Message]) -> Int {
        messages.reduce(0) { total, message in
            guard case .toolResult(let result) = message else { return total }
            return total + result.content.reduce(0) { sub, block in
                if case .text(let t) = block { return sub + t.text.count }
                return sub
            }
        }
    }

    @Test("compactAgent summarizes and replaces the transcript")
    func compactAgentReplacesTranscript() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("summary of prior work"))])

        let originalMessages = conversation(model: faux.getModel())
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: originalMessages
        ))

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "compact-test"
        )

        #expect(outcome == .compacted(messagesCompacted: 2, hasRunningTasksLedger: false))
        #expect(agent.state.messages.count == 3)
        #expect(text(from: agent.state.messages.first).contains("<previous-session-summary>"))
        #expect(text(from: agent.state.messages.first).contains("summary of prior work"))
        #expect(agent.state.messages.suffix(2) == originalMessages.suffix(2))
    }

    @Test("inline compaction only fires above the threshold")
    func inlineCompactionUsesThreshold() async {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "small-window", contextWindow: 2_000)
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
            usage: Usage(input: 1_600, output: 1)
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
        #expect(replacedMessages.count == 4)
        #expect(text(from: replacedMessages.first).contains("inline summary"))
        #expect(replacedMessages.suffix(3) == messages.suffix(3))
    }

    @Test("inline compaction threshold includes system prompt tokens")
    func inlineCompactionMeasuresFullContext() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "system-heavy-window", contextWindow: 2_000)
        ]))
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("system-aware summary"))])

        let model = faux.getModel()
        let messages = conversation(model: model)
        let systemPrompt = String(repeating: "large system contract ", count: 400)
        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: model,
            messages: messages
        ))
        let context = AgentContext(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: []
        )

        #expect(!AgentContextCompactor.shouldCompact(
            messages: messages,
            model: model,
            threshold: 0.75
        ))
        #expect(AgentContextCompactor.shouldCompact(
            context: context,
            model: model,
            threshold: 0.75
        ))

        let replacement = await AgentContextCompactor.compactInlineIfNeeded(
            agent: agent,
            context: context,
            threshold: 0.75,
            sessionId: "system-aware-inline"
        )

        let compacted = try #require(replacement)
        #expect(text(from: compacted.messages.first).contains("system-aware summary"))
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
                await capture.record(context: context, options: options)
                let (stream, continuation) = AssistantMessageStream.makeStream()
                continuation.end(AssistantMessage(
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

        #expect(outcome == .compacted(messagesCompacted: 2, hasRunningTasksLedger: false))
        #expect(text(from: agent.state.messages.first).contains("custom stream summary"))
        let snapshot = await capture.snapshot()
        #expect(snapshot.sessionId?.hasPrefix("hook-session::kwwk-compaction-summary::") == true)
        #expect(snapshot.sessionId != "hook-session")
        #expect(snapshot.temperature == nil)
        #expect(snapshot.maxTokens == nil)
        #expect(snapshot.disablesTools)
        #expect(snapshot.disablesParallelTools)
        #expect(snapshot.prompt.contains("feature REDACTED"))
        #expect(snapshot.prompt.contains("converted marker"))
        #expect(!snapshot.prompt.contains("feature X"))
    }

    @Test("a dedicated compaction model handles summary auth and streaming without changing the main model")
    func dedicatedCompactionModelRoutesOnlySummaryRequest() async {
        let mainModel = Model(
            id: "main-model",
            api: "main-api",
            provider: "main-provider",
            contextWindow: 8_000,
            maxTokens: 1_000
        )
        let summaryModel = Model(
            id: "summary-model",
            api: "summary-api",
            provider: "summary-provider",
            contextWindow: 2_000,
            maxTokens: 192
        )
        let capture = CompactionModelRoutingCapture()
        let original = conversation(model: mainModel)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: mainModel, messages: original),
            streamFn: { model, _, options in
                await capture.recordStream(model: model, maxTokens: options?.maxTokens)
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "summary from dedicated model"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            },
            compactionModel: summaryModel,
            authResolver: { model, sessionId in
                await capture.recordAuth(model: model, sessionId: sessionId)
                return ResolvedProviderAuth(token: "summary-token", scheme: .bearer)
            }
        ))

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "dedicated-model-session"
        )
        let snapshot = await capture.snapshot()

        #expect(outcome == .compacted(messagesCompacted: 2, hasRunningTasksLedger: false))
        #expect(snapshot.streamModelIds == [summaryModel.id])
        #expect(snapshot.authModelIds == [summaryModel.id])
        #expect(snapshot.authSessionIds == ["dedicated-model-session"])
        #expect(snapshot.maxTokens.count == 1)
        #expect(snapshot.maxTokens[0] == nil)
        #expect(agent.state.model.id == mainModel.id)
        #expect(agent.state.model.provider == mainModel.provider)
        #expect(agent.compactionModel?.id == summaryModel.id)
        #expect(text(from: agent.state.messages.first).contains("summary from dedicated model"))
    }

    @Test("nil compaction model follows a runtime main-model switch")
    func nilCompactionModelFollowsCurrentModel() async {
        let initialModel = Model(
            id: "initial-main",
            api: "initial-api",
            provider: "initial-provider",
            contextWindow: 8_000,
            maxTokens: 1_000
        )
        let switchedModel = Model(
            id: "switched-main",
            api: "switched-api",
            provider: "switched-provider",
            contextWindow: 8_000,
            maxTokens: 300
        )
        let capture = CompactionModelRoutingCapture()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: initialModel,
                messages: conversation(model: initialModel)
            ),
            streamFn: { model, _, options in
                await capture.recordStream(model: model, maxTokens: options?.maxTokens)
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "summary after switch"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        ))
        agent.state.model = switchedModel

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "follow-current-model"
        )
        let snapshot = await capture.snapshot()

        #expect(outcome == .compacted(messagesCompacted: 2, hasRunningTasksLedger: false))
        #expect(agent.compactionModel == nil)
        #expect(snapshot.streamModelIds == [switchedModel.id])
        #expect(snapshot.maxTokens.count == 1)
        #expect(snapshot.maxTokens[0] == nil)
        #expect(agent.state.model.id == switchedModel.id)
    }

    @Test("Codex compaction preserves the max-output-token wire omission sentinel")
    func codexCompactionOmitsMaxTokensOption() async {
        let mainModel = Model(
            id: "main-model",
            api: "main-api",
            provider: "main-provider",
            contextWindow: 8_000,
            maxTokens: 1_000
        )
        let codexModel = Model(
            id: "gpt-codex",
            api: "chatgpt-codex",
            provider: "chatgpt-codex",
            contextWindow: 272_000,
            maxTokens: 0
        )
        let capture = CompactionModelRoutingCapture()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: mainModel,
                messages: conversation(model: mainModel)
            ),
            streamFn: { model, _, options in
                await capture.recordStream(model: model, maxTokens: options?.maxTokens)
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "Codex summary"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            },
            compactionModel: codexModel
        ))

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "codex-summary",
            config: AgentContextCompactionConfig(summaryMaxTokens: 4_096)
        )
        let snapshot = await capture.snapshot()

        #expect(outcome == .compacted(messagesCompacted: 2, hasRunningTasksLedger: false))
        #expect(snapshot.streamModelIds == [codexModel.id])
        #expect(snapshot.maxTokens.count == 1)
        #expect(snapshot.maxTokens[0] == nil)
        #expect(CompactionSummaryGenerator.outputTokenReserve(
            model: codexModel,
            config: AgentContextCompactionConfig(summaryMaxTokens: 4_096)
        ) == codexModel.contextWindow / 4)
    }

    @Test("incremental compaction updates the prior summary instead of resummarizing it as chat")
    func compactAgentUsesIncrementalSummaryPrompt() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let capture = SummaryStreamCapture()
        let model = faux.getModel()
        let recap = Message.user(UserMessage(
            text: """
            <previous-session-summary>
            <kwwk-compaction version="2">
            <history>prior durable &amp; state</history>
            <current-turn-prefix>prior active &lt;prefix&gt;</current-turn-prefix>
            <file-operations>
            <read path="/tmp/carried.swift" />
            </file-operations>
            </kwwk-compaction>
            </previous-session-summary>
            """,
            source: .compaction
        ))
        let messages: [Message] = [
            recap,
            .user(UserMessage(text: "older update")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "older result"))],
                api: model.api, provider: model.provider, model: model.id
            )),
            .user(UserMessage(text: "latest exact request")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "latest exact response"))],
                api: model.api, provider: model.provider, model: model.id
            )),
        ]
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: model, messages: messages),
            streamFn: { model, context, options in
                await capture.record(context: context, options: options)
                let (stream, continuation) = AssistantMessageStream.makeStream()
                continuation.end(fauxAssistantMessage("updated summary"))
                return stream
            }
        ))

        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: "incremental")
        let snapshot = await capture.snapshot()

        #expect(outcome == .compacted(messagesCompacted: 3, hasRunningTasksLedger: false))
        #expect(snapshot.prompt.contains("prior_summary_json_string"))
        #expect(snapshot.prompt.contains("prior durable & state"))
        #expect(snapshot.prompt.contains("## Previously Compacted Active-Turn Prefix"))
        #expect(snapshot.prompt.contains("prior active <prefix>"))
        #expect(snapshot.prompt.contains("older update"))
        #expect(!snapshot.prompt.contains("latest exact request"))
        #expect(!snapshot.prompt.contains("<kwwk-compaction"))
        #expect(!snapshot.prompt.contains("<file-operations>"))
        let replacementRecap = text(from: agent.state.messages.first)
        #expect(replacementRecap.contains(#"<read path="/tmp/carried.swift" />"#))
        #expect(agent.state.messages.suffix(2) == messages.suffix(2))
    }

    @Test("repeated active-turn compaction keeps one canonical recap envelope")
    func repeatedActiveTurnCompactionStaysCanonical() async throws {
        let model = Model(
            id: "canonical-recap",
            api: "faux",
            provider: "faux",
            contextWindow: 8_000,
            maxTokens: 1_000
        )
        let capture = CanonicalRecapCapture(responses: [
            "updated prefix one & <state>",
            "updated prefix two & <state>",
        ])
        let initialRecap = Message.user(UserMessage(
            text: """
            <previous-session-summary>
            <kwwk-compaction version="2">
            <history>prior &amp; durable &lt;state&gt;</history>
            <current-turn-prefix>initial &amp; prefix</current-turn-prefix>
            <file-operations>
            <modified path="/tmp/a&amp;b.swift" />
            </file-operations>
            </kwwk-compaction>
            </previous-session-summary>
            """,
            source: .compaction
        ))
        let config = AgentContextCompactionConfig(minMessages: 1, keepRecentTokens: 20)

        func toolGroup(_ id: String) -> [Message] {
            let call = ToolCall(id: id, name: "bash", arguments: ["command": "work"])
            return [
                .assistant(AssistantMessage(
                    content: [.toolCall(call)],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: .toolUse
                )),
                .toolResult(ToolResultMessage(
                    toolCallId: call.id,
                    toolName: call.name,
                    content: [.text(TextContent(
                        text: "RESULT-\(id)-" + String(repeating: "x", count: 5_000)
                    ))]
                )),
            ]
        }

        func compact(_ messages: [Message]) async throws -> AgentContextCompactionResult {
            let result = await AgentContextCompactor.compactContext(
                context: AgentContext(systemPrompt: "", messages: messages, tools: []),
                model: model,
                sessionId: "canonical-recap",
                config: config,
                streamFn: { model, context, _ in
                    let summary = await capture.recordAndNextResponse(context: context)
                    let pair = AssistantMessageStream.makeStream()
                    pair.continuation.end(AssistantMessage(
                        content: [.text(TextContent(text: summary))],
                        api: model.api,
                        provider: model.provider,
                        model: model.id
                    ))
                    return pair.stream
                }
            )
            return try result.get()
        }

        let first = try await compact([initialRecap] + toolGroup("first"))
        let firstRecap = text(from: first.messages.first)
        let second = try await compact(first.messages + toolGroup("second"))
        let secondRecap = text(from: second.messages.first)
        let prompts = await capture.promptsSnapshot()

        #expect(prompts.count == 2)
        #expect(prompts[0].contains("prior_prefix_summary_json_string"))
        #expect(prompts[0].contains("initial & prefix"))
        #expect(prompts[1].contains("updated prefix one & <state>"))
        #expect(prompts.allSatisfy { !$0.contains("<kwwk-compaction") })
        #expect(prompts.allSatisfy { !$0.contains("<file-operations>") })

        #expect(secondRecap.components(separatedBy: "<kwwk-compaction").count - 1 == 1)
        #expect(secondRecap.components(separatedBy: "<file-operations>").count - 1 == 1)
        #expect(!secondRecap.contains("&lt;kwwk-compaction"))
        #expect(!secondRecap.contains("&amp;amp;"))
        #expect(secondRecap.contains("prior &amp; durable &lt;state&gt;"))
        #expect(secondRecap.contains("updated prefix two &amp; &lt;state&gt;"))
        #expect(secondRecap.contains(#"<modified path="/tmp/a&amp;b.swift" />"#))
        #expect(secondRecap.utf8.count <= firstRecap.utf8.count + 32)
    }

    @Test("hidden goal continuations are redacted before summary serialization")
    func compactionRedactsHiddenGoalContinuation() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let model = faux.getModel()
        let capture = SummaryStreamCapture()
        let secretObjective = "PRIVATE-GOAL-OBJECTIVE"
        let messages: [Message] = [
            .user(UserMessage(text: """
            \(goalContinuationMarker)
            <objective>\(secretObjective)</objective>
            """)),
            .assistant(fauxAssistantMessage("worked on the goal")),
            .user(UserMessage(text: "latest request")),
            .assistant(fauxAssistantMessage("latest response")),
        ]
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: model, messages: messages),
            streamFn: { _, context, options in
                await capture.record(context: context, options: options)
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(fauxAssistantMessage("safe summary"))
                return pair.stream
            }
        ))

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "goal-redaction"
        )
        let snapshot = await capture.snapshot()

        #expect(outcome == .compacted(messagesCompacted: 2, hasRunningTasksLedger: false))
        #expect(!snapshot.prompt.contains(secretObjective))
        #expect(snapshot.prompt.contains("redacted goal continuation"))
    }

    @Test("a length-truncated summary never replaces the transcript")
    func truncatedSummaryDoesNotCommit() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let model = faux.getModel()
        let original = conversation(model: model)
        faux.setResponses([.message(AssistantMessage(
            content: [.text(TextContent(text: "partial summary"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .length
        ))])
        let agent = Agent(initialState: AgentInitialState(model: model, messages: original))

        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: "truncated")

        #expect(outcome == .failed("summary exceeded its output budget"))
        #expect(agent.state.messages == original)
    }

    @Test("recovery targets include the system prompt and tool-independent overhead")
    func recoveryTargetUsesFullContext() async {
        let model = Model(
            id: "full-context-budget",
            api: "faux",
            provider: "faux",
            contextWindow: 8_000,
            maxTokens: 1_000
        )
        let messages = conversation(model: model)
        let context = AgentContext(
            systemPrompt: String(repeating: "system-overhead ", count: 300),
            messages: messages,
            tools: []
        )

        let result = await AgentContextCompactor.compactContext(
            context: context,
            model: model,
            sessionId: "full-context-budget",
            config: AgentContextCompactionConfig(minMessages: 1),
            targetTokens: 400,
            streamFn: { model, _, _ in
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "## Goal\nsmall recap"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        )

        guard case .failure(.failed(let reason)) = result else {
            Issue.record("expected fixed context overhead to make the target unreachable")
            return
        }
        #expect(reason.contains("recovery target of 400 tokens is too small"))
        #expect(context.messages == messages)
    }

    @Test("successful file operations are carried outside the model summary")
    func compactionCarriesDeterministicFileFacts() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let model = faux.getModel()
        faux.setResponses([.message(fauxAssistantMessage("model summary"))])
        let write = ToolCall(
            id: "write-1",
            name: "write",
            arguments: .object(["path": .string("/tmp/a&b.swift"), "content": .string("x")])
        )
        let messages: [Message] = [
            .user(UserMessage(text: "make the change")),
            .assistant(AssistantMessage(
                content: [.toolCall(write)],
                api: model.api, provider: model.provider, model: model.id,
                stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(
                toolCallId: write.id,
                toolName: write.name,
                content: [.text(TextContent(text: "written"))]
            )),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "change complete"))],
                api: model.api, provider: model.provider, model: model.id
            )),
            .user(UserMessage(text: "what next?")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "run tests"))],
                api: model.api, provider: model.provider, model: model.id
            )),
        ]
        let agent = Agent(initialState: AgentInitialState(model: model, messages: messages))

        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: "facts")
        let recap = text(from: agent.state.messages.first)

        #expect(outcome == .compacted(messagesCompacted: 4, hasRunningTasksLedger: false))
        #expect(recap.contains("<file-operations>"))
        #expect(recap.contains(#"<modified path="/tmp/a&amp;b.swift" />"#))
        #expect(agent.state.messages.suffix(2) == messages.suffix(2))
    }

    @Test("an oversized current turn gets a separate prefix summary and raw suffix")
    func oversizedTurnGetsSplitSummary() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let model = faux.getModel()
        faux.setResponses([
            .message(fauxAssistantMessage("long-term history summary")),
            .message(fauxAssistantMessage("current turn prefix summary")),
        ])
        let call = ToolCall(
            id: "read-1",
            name: "read",
            arguments: .object(["path": .string("/tmp/large.log")])
        )
        let messages: [Message] = [
            .user(UserMessage(text: "old request")),
            .assistant(fauxAssistantMessage("old result")),
            .user(UserMessage(text: "inspect the large log")),
            .assistant(AssistantMessage(
                content: [.toolCall(call)],
                api: model.api, provider: model.provider, model: model.id,
                stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(
                toolCallId: call.id,
                toolName: call.name,
                content: [.text(TextContent(text: String(repeating: "x", count: 500)))]
            )),
            .assistant(fauxAssistantMessage("suffix remains exact")),
        ]
        let agent = Agent(initialState: AgentInitialState(model: model, messages: messages))

        let outcome = await AgentContextCompactor.compactAgent(
            agent: agent,
            sessionId: "split",
            config: AgentContextCompactionConfig(minMessages: 1, keepRecentTokens: 20)
        )
        let recap = text(from: agent.state.messages.first)

        #expect(outcome == .compacted(messagesCompacted: 5, hasRunningTasksLedger: false))
        #expect(recap.contains("long-term history summary"))
        #expect(recap.contains("<current-turn-prefix>"))
        #expect(recap.contains("current turn prefix summary"))
        #expect(agent.state.messages.count == 2)
        #expect(agent.state.messages.last == messages.last)
    }

    @Test("a concurrent context mutation prevents a stale summary commit")
    func concurrentMutationRejectsStaleCommit() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let model = faux.getModel()
        let gate = SummaryGate()
        let original = conversation(model: model)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: model, messages: original),
            streamFn: { _, _, _ in
                await gate.enterAndWait()
                let (stream, continuation) = AssistantMessageStream.makeStream()
                continuation.end(fauxAssistantMessage("stale summary"))
                return stream
            }
        ))

        let task = Task {
            await AgentContextCompactor.compactAgent(agent: agent, sessionId: "cas")
        }
        try await gate.waitUntilEntered()
        let concurrent = Message.user(UserMessage(text: "arrived during compaction"))
        agent.state.messages.append(concurrent)
        await gate.release()
        let outcome = await task.value

        #expect(outcome == .failed("context changed while compaction was running"))
        #expect(agent.state.messages == original + [concurrent])
    }

    @Test("a concurrent system-prompt change prevents a stale summary commit")
    func concurrentPromptChangeRejectsStaleCommit() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let model = faux.getModel()
        let gate = SummaryGate()
        let original = conversation(model: model)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                systemPrompt: "old system prompt",
                model: model,
                messages: original
            ),
            streamFn: { _, _, _ in
                await gate.enterAndWait()
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(fauxAssistantMessage("stale summary"))
                return pair.stream
            }
        ))

        let task = Task {
            await AgentContextCompactor.compactAgent(agent: agent, sessionId: "system-cas")
        }
        try await gate.waitUntilEntered()
        agent.state.systemPrompt = "new system prompt"
        await gate.release()
        let outcome = await task.value

        #expect(outcome == .failed("context changed while compaction was running"))
        #expect(agent.state.systemPrompt == "new system prompt")
        #expect(agent.state.messages == original)
    }

    @Test("agent defaults to auto compaction before the next provider request")
    func agentDefaultsToAutoCompaction() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "auto-window", contextWindow: 2_000)
        ]))
        defer { faux.unregister() }

        let model = faux.getModel()
        let highUsage = AssistantMessage(
            content: [.text(TextContent(text: "final answer"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 1_600, output: 1)
        )
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: model,
                messages: conversation(model: model)
            ),
            streamFn: { model, context, _ in
                let message = context.systemPrompt?.contains("durable working-state summary") == true
                    ? fauxAssistantMessage("built-in summary")
                    : highUsage
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(message)
                return pair.stream
            }
        ))
        #expect(agent.autoCompact?.threshold == 0.75)
        let events = CompactEventLog()
        let unsubscribe = agent.subscribe { event, _ in
            await events.record(event)
        }
        defer { unsubscribe() }

        try await agent.prompt("establish high provider usage")
        try await agent.prompt("please do the task")

        let snapshot = await events.snapshot()
        #expect(snapshot.starts == 1)
        #expect(snapshot.compacted == 1)
        #expect(text(from: snapshot.agentEndMessages.first).contains("built-in summary"))
        #expect(agent.state.messages.count == 3)
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
    private var temperature: Double?
    private var maxTokens: Int?
    private var disablesTools = false
    private var disablesParallelTools = false

    func record(context: Context, options: StreamOptions?) {
        self.prompt = context.messages.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            return user.content.compactMap { block -> String? in
                guard case .text(let text) = block else { return nil }
                return text.text
            }.joined(separator: "\n")
        }.joined(separator: "\n")
        self.sessionId = options?.sessionId
        self.temperature = options?.temperature
        self.maxTokens = options?.maxTokens
        self.disablesTools = options?.toolChoice == ToolChoice.none
        self.disablesParallelTools = options?.parallelToolCalls == false
    }

    func snapshot() -> (
        prompt: String,
        sessionId: String?,
        temperature: Double?,
        maxTokens: Int?,
        disablesTools: Bool,
        disablesParallelTools: Bool
    ) {
        (prompt, sessionId, temperature, maxTokens, disablesTools, disablesParallelTools)
    }
}

private actor CanonicalRecapCapture {
    private let responses: [String]
    private var prompts: [String] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func recordAndNextResponse(context: Context) -> String {
        let prompt = context.messages.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            return user.content.compactMap { block -> String? in
                guard case .text(let text) = block else { return nil }
                return text.text
            }.joined(separator: "\n")
        }.joined(separator: "\n")
        prompts.append(prompt)
        return responses[min(prompts.count - 1, responses.count - 1)]
    }

    func promptsSnapshot() -> [String] {
        prompts
    }
}

private actor CompactionModelRoutingCapture {
    private var streamModelIds: [String] = []
    private var authModelIds: [String] = []
    private var authSessionIds: [String?] = []
    private var maxTokens: [Int?] = []

    func recordStream(model: Model, maxTokens: Int?) {
        streamModelIds.append(model.id)
        self.maxTokens.append(maxTokens)
    }

    func recordAuth(model: Model, sessionId: String?) {
        authModelIds.append(model.id)
        authSessionIds.append(sessionId)
    }

    func snapshot() -> (
        streamModelIds: [String],
        authModelIds: [String],
        authSessionIds: [String?],
        maxTokens: [Int?]
    ) {
        (streamModelIds, authModelIds, authSessionIds, maxTokens)
    }
}

private actor SummaryGate {
    private var entered = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SummaryGateError.timeout
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum SummaryGateError: Error {
    case timeout
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
