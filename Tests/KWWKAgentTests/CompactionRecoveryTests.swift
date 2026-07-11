import Foundation
import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Context compaction recovery")
struct CompactionRecoveryTests {
    @Test("preflight compacts old history while retaining the submitted prompt")
    func preflightPreservesPendingPrompt() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "preflight-model", contextWindow: 4_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let summaryModel = Model(
            id: "large-window-summarizer",
            api: "summary-api",
            provider: "summary-provider",
            contextWindow: 100_000,
            maxTokens: 1_000
        )
        let router = RecoveryStreamRouter(mode: .succeed)
        let old = String(repeating: "o", count: 800)
        let pending = "PENDING-EXACT-" + String(repeating: "p", count: 5_200)
        let initial: [Message] = [
            .user(UserMessage(text: "old-1 \(old)")),
            assistant("old-2 \(old)", model: model),
            .user(UserMessage(text: "old-3 \(old)")),
            assistant("old-4 \(old)", model: model),
        ]
        let agent = makeAgent(
            model: model,
            initial: initial,
            router: router,
            threshold: 0.5,
            compactionModel: summaryModel
        )

        try await agent.prompt(pending)

        let snapshot = await router.snapshot()
        let mainContext = try #require(snapshot.mainContexts.first)
        #expect(snapshot.summaryCalls == 1)
        #expect(snapshot.summaryModels == [summaryModel.id])
        #expect(snapshot.mainModels == [model.id])
        #expect(snapshot.mainContexts.count == 1)
        #expect(!snapshot.summaryPrompts.joined().contains("PENDING-EXACT-"))
        #expect(contextText(mainContext).contains(pending))
        #expect(contextText(mainContext).contains("<previous-session-summary>"))
        #expect(agent.state.messages.contains(where: { userText($0) == pending }))
    }

    @Test("automatic recovery bypasses the manual minimum for a short oversized transcript")
    func shortOversizedTranscriptCompactsWithDefaultMinimum() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "short-oversized", contextWindow: 4_000, maxTokens: 500)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .succeed)
        let payload = String(repeating: "large history ", count: 350)
        let initial: [Message] = [
            .user(UserMessage(text: "old request \(payload)")),
            assistant("old response \(payload)", model: model),
        ]
        let agent = makeAgent(
            model: model,
            initial: initial,
            router: router,
            threshold: 0.4,
            compactionConfig: AgentContextCompactionConfig()
        )

        try await agent.prompt("new request")

        let snapshot = await router.snapshot()
        let mainContext = try #require(snapshot.mainContexts.first)
        #expect(snapshot.summaryCalls > 0)
        #expect(contextText(mainContext).contains("<previous-session-summary>"))
        #expect(contextText(mainContext).contains("new request"))
    }

    @Test("a compactStart listener cannot be overwritten before the compaction CAS")
    func compactStartMutationIsPreserved() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "compact-start-cas", contextWindow: 4_000, maxTokens: 500)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .succeed)
        let events = RecoveryEventLog()
        let once = OneShotFlag()
        let payload = String(repeating: "history ", count: 300)
        let marker = "listener mutation survives"
        let agent = makeAgent(
            model: model,
            initial: [
                .user(UserMessage(text: "old request \(payload)")),
                assistant("old response \(payload)", model: model),
            ],
            router: router,
            threshold: 0.25
        )
        let unsubscribe = agent.subscribe { event, _ in
            await events.record(event)
            if case .compactStart = event, await once.take() {
                agent.state.messages.append(.user(UserMessage(text: marker)))
            }
        }
        defer { unsubscribe() }

        try await agent.prompt("continue")

        let routerSnapshot = await router.snapshot()
        let eventSnapshot = await events.snapshot()
        #expect(routerSnapshot.summaryCalls == 0)
        #expect(routerSnapshot.mainContexts.count == 1)
        #expect(eventSnapshot.compactStarts == 1)
        #expect(eventSnapshot.compactSuccesses == 0)
        #expect(agent.state.messages.contains(where: { userText($0) == marker }))
    }

    @Test("cancelling request preflight keeps the submitted prompt")
    func cancelledPreflightKeepsSubmittedPrompt() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "cancel-preflight", contextWindow: 4_000, maxTokens: 500)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .succeed)
        let once = OneShotFlag()
        let payload = String(repeating: "history ", count: 300)
        let submitted = "prompt must survive cancelled preflight"
        let agent = makeAgent(
            model: model,
            initial: [
                .user(UserMessage(text: "old request \(payload)")),
                assistant("old response \(payload)", model: model),
            ],
            router: router,
            threshold: 0.25
        )
        let unsubscribe = agent.subscribe { event, _ in
            if case .compactStart = event, await once.take() {
                agent.abort()
            }
        }
        defer { unsubscribe() }

        try await agent.prompt(submitted)

        let snapshot = await router.snapshot()
        let promptIndex = try #require(agent.state.messages.firstIndex(where: {
            userText($0) == submitted
        }))
        let terminalIndex = try #require(agent.state.messages.lastIndex(where: {
            assistantStopReason($0) == .aborted
        }))
        #expect(promptIndex < terminalIndex)
        #expect(snapshot.summaryCalls == 0)
        #expect(snapshot.mainContexts.isEmpty)
    }

    @Test("a failed summary is attempted once at a provider boundary")
    func failedSummaryDoesNotRepeatAtSameBoundary() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "single-failed-preflight", contextWindow: 4_000, maxTokens: 500)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .summaryFailure)
        let events = RecoveryEventLog()
        let payload = String(repeating: "history ", count: 300)
        let agent = makeAgent(
            model: model,
            initial: [
                .user(UserMessage(text: "old request \(payload)")),
                assistant("old response \(payload)", model: model),
            ],
            router: router,
            threshold: 0.25
        )
        let unsubscribe = agent.subscribe { event, _ in await events.record(event) }
        defer { unsubscribe() }

        try await agent.prompt("continue after a non-blocking summary failure")

        let snapshot = await router.snapshot()
        let eventSnapshot = await events.snapshot()
        #expect(snapshot.summaryCalls == 1)
        #expect(snapshot.mainContexts.count == 1)
        #expect(eventSnapshot.compactStarts == 1)
        #expect(eventSnapshot.compactEnds == 1)
        #expect(eventSnapshot.compactSuccesses == 0)
    }

    @Test("provider input overflow compacts and rebuilds the request exactly once")
    func overflowCompactsAndRetriesOnce() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "overflow-model", contextWindow: 4_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .overflowThenSucceed)
        let events = RecoveryEventLog()
        let initial = shortHistory(model: model)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                systemPrompt: "main-system",
                model: model,
                messages: initial
            ),
            streamFn: recoveryStream(router: router)
        ))
        #expect(agent.autoCompact?.threshold == 0.75)
        let unsubscribe = agent.subscribe { event, _ in await events.record(event) }
        defer { unsubscribe() }

        try await agent.prompt("retry this exact request")

        let snapshot = await router.snapshot()
        let eventSnapshot = await events.snapshot()
        try #require(snapshot.mainContexts.count == 2)
        let initialContext = snapshot.mainContexts[0]
        let recoveredContext = snapshot.mainContexts[1]
        #expect(snapshot.summaryCalls == 1)
        #expect(!contextText(initialContext).contains("<previous-session-summary>"))
        #expect(contextText(recoveredContext).contains("<previous-session-summary>"))
        #expect(contextText(recoveredContext).contains("retry this exact request"))
        #expect(eventSnapshot.compactStarts == 1)
        #expect(eventSnapshot.compactSuccesses == 1)
        #expect(agent.state.messages.compactMap(assistantError).isEmpty)
        #expect(agent.state.messages.compactMap(assistantTextValue).contains("provider success"))
    }

    @Test("explicitly disabling auto compact also disables overflow recovery")
    func disabledAutoCompactDoesNotRecoverOverflow() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "disabled-overflow-model", contextWindow: 4_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .overflowThenSucceed)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                systemPrompt: "main-system",
                model: model,
                messages: shortHistory(model: model)
            ),
            streamFn: recoveryStream(router: router),
            autoCompact: nil
        ))

        try await agent.prompt("surface this overflow")

        let snapshot = await router.snapshot()
        #expect(snapshot.mainContexts.count == 1)
        #expect(snapshot.summaryCalls == 0)
        #expect(agent.state.messages.compactMap(assistantError).contains(where: {
            $0.contains("context_length_exceeded")
        }))
    }

    @Test("overflow recovery summarizes with the dedicated model and retries with the main model")
    func overflowUsesDedicatedCompactionModel() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "overflow-main-model", contextWindow: 4_000)
        ]))
        defer { faux.unregister() }
        let mainModel = faux.getModel()
        let summaryModel = Model(
            id: "overflow-summary-model",
            api: "summary-api",
            provider: "summary-provider",
            contextWindow: 2_000,
            maxTokens: 256
        )
        let router = RecoveryStreamRouter(mode: .overflowThenSucceed)
        let agent = makeAgent(
            model: mainModel,
            initial: shortHistory(model: mainModel),
            router: router,
            threshold: 0.9,
            compactionModel: summaryModel
        )

        try await agent.prompt("recover with a separate summarizer")

        let snapshot = await router.snapshot()
        #expect(snapshot.summaryModels == [summaryModel.id])
        #expect(snapshot.mainModels == [mainModel.id, mainModel.id])
        #expect(agent.state.model.id == mainModel.id)
        #expect(agent.compactionModel?.id == summaryModel.id)
    }

    @Test("a directly thrown provider overflow compacts and retries once")
    func thrownOverflowCompactsAndRetriesOnce() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "thrown-overflow-model", contextWindow: 4_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .throwOverflowThenSucceed)
        let agent = makeAgent(
            model: model,
            initial: shortHistory(model: model),
            router: router,
            threshold: 0.9
        )

        try await agent.prompt("retry a thrown overflow")

        let snapshot = await router.snapshot()
        try #require(snapshot.mainContexts.count == 2)
        let initialContext = snapshot.mainContexts[0]
        let recoveredContext = snapshot.mainContexts[1]
        #expect(snapshot.summaryCalls == 1)
        #expect(!contextText(initialContext).contains("<previous-session-summary>"))
        #expect(contextText(recoveredContext).contains("<previous-session-summary>"))
        #expect(agent.state.messages.compactMap(assistantError).isEmpty)
        #expect(agent.state.messages.compactMap(assistantTextValue).contains("provider success"))
    }

    @Test("a second input overflow is surfaced once without a recovery loop")
    func repeatedOverflowStopsAfterOneRecovery() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "repeated-overflow-model", contextWindow: 4_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .alwaysOverflow)
        let agent = makeAgent(
            model: model,
            initial: shortHistory(model: model),
            router: router,
            threshold: 0.9
        )

        try await agent.prompt("still too large")

        let snapshot = await router.snapshot()
        let errors = agent.state.messages.compactMap(assistantError)
        let error = try #require(errors.first)
        try #require(snapshot.mainContexts.count == 2)
        let initialContext = snapshot.mainContexts[0]
        let recoveredContext = snapshot.mainContexts[1]
        #expect(snapshot.summaryCalls == 1)
        #expect(errors.count == 1)
        #expect(error.contains("context_length_exceeded"))
        #expect(!contextText(initialContext).contains("<previous-session-summary>"))
        #expect(contextText(recoveredContext).contains("<previous-session-summary>"))
    }

    @Test("an irreducible oversized prompt is retained but never sent")
    func irreduciblePreflightBlocksProviderRequest() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "irreducible-model", contextWindow: 1_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .succeed)
        let agent = makeAgent(
            model: model,
            initial: shortHistory(model: model),
            router: router,
            threshold: 0.5
        )
        let oversized = "IRREDUCIBLE-" + String(repeating: "z", count: 10_000)

        try await agent.prompt(oversized)

        let snapshot = await router.snapshot()
        #expect(snapshot.mainContexts.isEmpty)
        #expect(agent.state.messages.contains(where: { userText($0) == oversized }))
        #expect(agent.state.messages.compactMap(assistantError).contains(where: {
            $0.contains("token input budget even after compaction")
        }))
    }

    @Test("an oversized first prompt reports an irreducible input budget")
    func irreducibleFirstPromptHasPreciseFailure() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(
                id: "irreducible-first-prompt",
                contextWindow: 1_000,
                maxTokens: 200
            )
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .succeed)
        let agent = makeAgent(
            model: model,
            initial: [],
            router: router,
            threshold: 0.5
        )
        let oversized = "FIRST-IRREDUCIBLE-" + String(repeating: "z", count: 10_000)

        try await agent.prompt(oversized)

        let snapshot = await router.snapshot()
        #expect(snapshot.mainContexts.isEmpty)
        #expect(agent.state.messages.contains(where: { userText($0) == oversized }))
        #expect(agent.state.messages.compactMap(assistantError).contains(where: {
            $0.contains("input budget even after compaction")
        }))
    }

    @Test("all queued unanswered prompts stay verbatim when their batch is irreducible")
    func irreducibleQueuedPromptsAreNeverSummarized() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(
                id: "irreducible-queued-prompts",
                contextWindow: 1_000,
                maxTokens: 200
            )
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .succeed)
        let firstPending = "FIRST-PENDING-EXACT-" + String(repeating: "a", count: 4_000)
        let secondPending = "SECOND-PENDING-EXACT-" + String(repeating: "b", count: 4_000)
        let agent = makeAgent(
            model: model,
            initial: [
                .user(UserMessage(text: "old request")),
                assistant("old response", model: model),
                .user(UserMessage(text: firstPending)),
                .user(UserMessage(text: secondPending)),
            ],
            router: router,
            threshold: 0.25
        )

        try await agent.continue()

        let snapshot = await router.snapshot()
        #expect(snapshot.mainContexts.isEmpty)
        #expect(!snapshot.summaryPrompts.joined().contains("FIRST-PENDING-EXACT-"))
        #expect(!snapshot.summaryPrompts.joined().contains("SECOND-PENDING-EXACT-"))
        #expect(agent.state.messages.contains(where: { userText($0) == firstPending }))
        #expect(agent.state.messages.contains(where: { userText($0) == secondPending }))
    }

    @Test("the output-reserved input budget blocks even above a high trigger threshold")
    func inputBudgetPrecedesHighThreshold() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(
                id: "high-threshold-budget",
                contextWindow: 4_000,
                maxTokens: 1_000
            )
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .succeed)
        let agent = makeAgent(
            model: model,
            initial: shortHistory(model: model),
            router: router,
            threshold: 0.95
        )
        let oversized = String(repeating: "z", count: 12_000)

        try await agent.prompt(oversized)

        let snapshot = await router.snapshot()
        #expect(snapshot.mainContexts.isEmpty)
        #expect(snapshot.summaryCalls > 0)
        #expect(agent.state.messages.contains(where: { userText($0) == oversized }))
    }

    @Test("cancelling the real overflow compactor aborts instead of persisting the overflow")
    func realOverflowCompactionCancellationAborts() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "real-cancel-overflow", contextWindow: 4_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let router = RecoveryStreamRouter(mode: .overflowThenSucceed)
        let once = OneShotFlag()
        let agent = makeAgent(
            model: model,
            initial: shortHistory(model: model),
            router: router,
            threshold: 0.99
        )
        let unsubscribe = agent.subscribe { event, _ in
            if case .compactStart = event, await once.take() {
                agent.abort()
            }
        }
        defer { unsubscribe() }

        try await agent.prompt("cancel recovery")

        let snapshot = await router.snapshot()
        #expect(snapshot.mainContexts.count == 1)
        #expect(snapshot.summaryCalls == 0)
        #expect(agent.state.messages.compactMap(assistantError).isEmpty)
        #expect(agent.state.messages.compactMap(assistantStopReason).last == .aborted)
    }

    @Test("overflow phrases are not treated as transient transport failures")
    func overflowClassificationPrecedesRetry() {
        #expect(ContextLimitClassifier.isInputOverflow("context_length_exceeded"))
        #expect(ContextLimitClassifier.isInputOverflow("maximum context length is 128000"))
        #expect(ContextLimitClassifier.isInputOverflow(
            "prompt is too long: 213799 tokens > 200000 maximum"
        ))
        #expect(ContextLimitClassifier.isInputOverflow(
            "The input token count (1195854) exceeds the maximum number of tokens allowed (1048576)."
        ))
        #expect(!ContextLimitClassifier.isInputOverflow("input token rate exceeded for this minute"))
        #expect(!ContextLimitClassifier.isInputOverflow("max_tokens output limit reached"))
        #expect(!ContextLimitClassifier.isInputOverflow("output token count exceeds max_tokens"))
        #expect(!AgentLoop.isRetryableError("context_length_exceeded"))
    }

    @Test("overflow recovery propagates cancellation and aborted compaction failures")
    func overflowRecoveryPropagatesCancellation() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let model = faux.getModel()

        for failure in OverflowCompactionCancellation.allCases {
            let config = AgentLoopConfig(
                model: model,
                contextCompaction: { _, trigger, _ in
                    guard case .providerOverflow = trigger else { return nil }
                    switch failure {
                    case .cancellationError:
                        throw CancellationError()
                    case .compactionCancelled:
                        throw AgentContextCompactionError.cancelled
                    case .agentAborted:
                        throw AgentError.aborted
                    }
                }
            )
            let streamFn: StreamFn = { model, _, _ in
                let overflow = AssistantMessage(
                    content: [],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: .error,
                    errorMessage: "prompt is too long for this model"
                )
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(overflow)
                return pair.stream
            }

            await #expect(throws: AgentError.aborted) {
                try await AgentLoop.run(
                    prompts: [.user(UserMessage(text: "overflow"))],
                    context: AgentContext(systemPrompt: "", messages: [], tools: []),
                    config: config,
                    emit: { _ in },
                    cancellation: nil,
                    streamFn: streamFn
                )
            }
        }
    }

    private func makeAgent(
        model: Model,
        initial: [Message],
        router: RecoveryStreamRouter,
        threshold: Double,
        compactionConfig: AgentContextCompactionConfig = .init(minMessages: 1),
        compactionModel: Model? = nil
    ) -> Agent {
        Agent(options: AgentOptions(
            initialState: AgentInitialState(
                systemPrompt: "main-system",
                model: model,
                messages: initial
            ),
            streamFn: recoveryStream(router: router),
            autoCompact: AgentAutoCompactOptions(
                threshold: threshold,
                config: compactionConfig
            ),
            compactionModel: compactionModel
        ))
    }

    private func recoveryStream(router: RecoveryStreamRouter) -> StreamFn {
        { model, context, _ in
            let message = try await router.response(model: model, context: context)
            let pair = AssistantMessageStream.makeStream()
            pair.continuation.end(message)
            return pair.stream
        }
    }

    private func shortHistory(model: Model) -> [Message] {
        [
            .user(UserMessage(text: "old request")),
            assistant("old response", model: model),
            .user(UserMessage(text: "newer request")),
            assistant("newer response", model: model),
        ]
    }
}

private enum RecoveryMode: Sendable {
    case succeed
    case summaryFailure
    case overflowThenSucceed
    case throwOverflowThenSucceed
    case alwaysOverflow
}

private enum OverflowCompactionCancellation: CaseIterable, Sendable {
    case cancellationError
    case compactionCancelled
    case agentAborted
}

private enum RecoveryStreamError: Error, LocalizedError {
    case promptTooLong
    case summaryUnavailable

    var errorDescription: String? {
        switch self {
        case .promptTooLong:
            "prompt is too long: 5000 tokens > 4000 maximum"
        case .summaryUnavailable:
            "summary provider unavailable"
        }
    }
}

private actor RecoveryStreamRouter {
    private let mode: RecoveryMode
    private var summaryCalls = 0
    private var summaryPrompts: [String] = []
    private var summaryModels: [String] = []
    private var mainContexts: [Context] = []
    private var mainModels: [String] = []

    init(mode: RecoveryMode) {
        self.mode = mode
    }

    func response(model: Model, context: Context) throws -> AssistantMessage {
        if context.systemPrompt?.contains("durable working-state summary") == true ||
            context.systemPrompt?.contains("evicted prefix") == true {
            summaryCalls += 1
            summaryPrompts.append(contextText(context))
            summaryModels.append(model.id)
            if case .summaryFailure = mode {
                throw RecoveryStreamError.summaryUnavailable
            }
            return AssistantMessage(
                content: [.text(TextContent(text: "## Goal\nRecovered summary \(summaryCalls)"))],
                api: model.api,
                provider: model.provider,
                model: model.id
            )
        }

        mainContexts.append(context)
        mainModels.append(model.id)
        let attempt = mainContexts.count
        let shouldOverflow: Bool
        switch mode {
        case .succeed, .summaryFailure:
            shouldOverflow = false
        case .overflowThenSucceed:
            shouldOverflow = attempt == 1
        case .throwOverflowThenSucceed:
            if attempt == 1 {
                throw RecoveryStreamError.promptTooLong
            }
            shouldOverflow = false
        case .alwaysOverflow:
            shouldOverflow = true
        }
        if shouldOverflow {
            return AssistantMessage(
                content: [],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .error,
                errorMessage: "HTTP 400 context_length_exceeded: maximum context length exceeded"
            )
        }
        return AssistantMessage(
            content: [.text(TextContent(text: "provider success"))],
            api: model.api,
            provider: model.provider,
            model: model.id
        )
    }

    func snapshot() -> (
        summaryCalls: Int,
        summaryPrompts: [String],
        summaryModels: [String],
        mainContexts: [Context],
        mainModels: [String]
    ) {
        (summaryCalls, summaryPrompts, summaryModels, mainContexts, mainModels)
    }
}

private actor RecoveryEventLog {
    private var compactStarts = 0
    private var compactEnds = 0
    private var compactSuccesses = 0

    func record(_ event: AgentEvent) {
        switch event {
        case .compactStart:
            compactStarts += 1
        case .compactEnd(let outcome):
            compactEnds += 1
            if case .compacted = outcome { compactSuccesses += 1 }
        default:
            break
        }
    }

    func snapshot() -> (compactStarts: Int, compactEnds: Int, compactSuccesses: Int) {
        (compactStarts, compactEnds, compactSuccesses)
    }
}

private actor OneShotFlag {
    private var isAvailable = true

    func take() -> Bool {
        guard isAvailable else { return false }
        isAvailable = false
        return true
    }
}

private func assistant(_ text: String, model: Model) -> Message {
    .assistant(AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: model.api,
        provider: model.provider,
        model: model.id
    ))
}

private func contextText(_ context: Context) -> String {
    context.messages.map { message in
        userText(message) + assistantText(message)
    }.joined(separator: "\n")
}

private func userText(_ message: Message) -> String {
    guard case .user(let user) = message else { return "" }
    return user.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text.text
    }.joined(separator: "\n")
}

private func assistantText(_ message: Message) -> String {
    guard case .assistant(let assistant) = message else { return "" }
    return assistant.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text.text
    }.joined(separator: "\n")
}

private func assistantTextValue(_ message: Message) -> String? {
    let text = assistantText(message)
    return text.isEmpty ? nil : text
}

private func assistantError(_ message: Message) -> String? {
    guard case .assistant(let assistant) = message,
          assistant.stopReason == .error else {
        return nil
    }
    return assistant.errorMessage
}

private func assistantStopReason(_ message: Message) -> StopReason? {
    guard case .assistant(let assistant) = message else { return nil }
    return assistant.stopReason
}
