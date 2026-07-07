import Foundation
import KWWKAI

/// Listener invoked for every `AgentEvent`. Async listeners are awaited in
/// subscription order before the agent returns to idle, matching pi-agent-core.
public typealias AgentListener = @Sendable (AgentEvent, CancellationHandle?) async -> Void

/// Handle returned from `subscribe`. Call to unsubscribe.
public typealias Unsubscribe = @Sendable () -> Void

public struct AgentInitialState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var thinkingDisplay: ThinkingDisplay
    public var verboseEnabled: Bool
    public var tools: [AgentTool]
    public var messages: [Message]

    public init(
        systemPrompt: String = "",
        model: Model,
        thinkingLevel: ThinkingLevel = .off,
        thinkingDisplay: ThinkingDisplay = .collapsed,
        verboseEnabled: Bool = false,
        tools: [AgentTool] = [],
        messages: [Message] = []
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.thinkingDisplay = thinkingDisplay
        self.verboseEnabled = verboseEnabled
        self.tools = tools
        self.messages = messages
    }
}

public enum AgentError: Error, Equatable {
    case noMessagesToContinue
    case cannotContinueFromRole(String)
    case alreadyRunning
    case listenerOutsideActiveRun
    case maxRetriesExceeded
    case aborted
}

public struct AgentAutoCompactOptions: Sendable {
    public var threshold: Double?
    public var config: AgentContextCompactionConfig
    public var backgroundManager: BackgroundTaskManager?

    public init(
        threshold: Double? = 0.75,
        config: AgentContextCompactionConfig = .init(),
        backgroundManager: BackgroundTaskManager? = nil
    ) {
        self.threshold = threshold
        self.config = config
        self.backgroundManager = backgroundManager
    }
}

public struct AgentOptions: Sendable {
    public var initialState: AgentInitialState
    public var streamFn: StreamFn?
    public var toolExecution: ToolExecutionMode
    public var toolChoice: ToolChoice?
    public var parallelToolCalls: Bool?
    public var steeringMode: QueueMode
    public var followUpMode: QueueMode
    public var sessionId: String?
    /// Workspace root forwarded to server-driven providers (Cursor). Nil =
    /// don't report one.
    public var cwd: String?
    public var thinkingBudgets: ThinkingBudgets?
    public var maxRetryDelayMs: Int?
    /// Hard cap on assistant turns per run. Nil = unlimited.
    public var maxTurns: Int?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var userPromptSubmit: UserPromptSubmitHook?
    public var convertToLlm: ConvertToLlmHook?
    public var transformContext: TransformContextHook?
    public var betweenTurns: BetweenTurnsHook?
    /// Automatic context compaction. Disabled by default so SDK callers do
    /// not trigger extra model calls or transcript rewrites unless requested.
    public var autoCompact: AgentAutoCompactOptions?
    public var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?

    public init(
        initialState: AgentInitialState,
        streamFn: StreamFn? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        steeringMode: QueueMode = .oneAtATime,
        followUpMode: QueueMode = .oneAtATime,
        sessionId: String? = nil,
        cwd: String? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        maxRetryDelayMs: Int? = nil,
        maxTurns: Int? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        userPromptSubmit: UserPromptSubmitHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        transformContext: TransformContextHook? = nil,
        betweenTurns: BetweenTurnsHook? = nil,
        autoCompact: AgentAutoCompactOptions? = nil,
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil
    ) {
        self.initialState = initialState
        self.streamFn = streamFn
        self.toolExecution = toolExecution
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.sessionId = sessionId
        self.cwd = cwd
        self.thinkingBudgets = thinkingBudgets
        self.maxRetryDelayMs = maxRetryDelayMs
        self.maxTurns = maxTurns
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.userPromptSubmit = userPromptSubmit
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.betweenTurns = betweenTurns
        self.autoCompact = autoCompact
        self.authResolver = authResolver
    }
}

/// Stateful agent that drives turn/tool loops against an LLM. Mirrors
/// pi-agent-core's `Agent` class but with Swift-native concurrency semantics.
public final class Agent: @unchecked Sendable {
    public let state: AgentState
    private let streamFn: StreamFn

    private let lock = NSLock()
    private var listeners: [(id: UUID, handler: AgentListener)] = []
    private var activeCancellation: CancellationHandle?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Immutable session identity: one `Agent` == one session. Rotating to a
    /// new session means building a fresh `Agent`/`SessionRecorder` through the
    /// supported path (the CLI's `/new` and `/resume` re-point the recorder and
    /// clear the live context). There is deliberately no in-place setter —
    /// mutating it would leave tools, the recorder, and background attachments
    /// scoped to different ids.
    public let sessionId: String?

    /// Workspace root forwarded to server-driven providers (Cursor).
    public let cwd: String?

    // Mutable run configuration. `loopConfig()` reads these on the run's task
    // while the public setters may be invoked from any thread (steer() is
    // documented "from any thread"), so every access funnels through `lock`.
    // This is what justifies the `@unchecked Sendable` annotation — mirrors
    // AgentState, whose fields are all lock-guarded the same way.
    private var _thinkingBudgets: ThinkingBudgets?
    private var _maxRetryDelayMs: Int?
    private var _maxTurns: Int?
    private var _toolExecution: ToolExecutionMode
    private var _toolChoice: ToolChoice?
    private var _parallelToolCalls: Bool?
    private var _beforeToolCall: BeforeToolCallHook?
    private var _afterToolCall: AfterToolCallHook?
    private var _userPromptSubmit: UserPromptSubmitHook?
    private var _convertToLlm: ConvertToLlmHook?
    private var _transformContext: TransformContextHook?
    private var _betweenTurns: BetweenTurnsHook?
    private var _autoCompact: AgentAutoCompactOptions?
    private var _authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    private var _retryBaseDelayMs: UInt64 = 1_000

    public var thinkingBudgets: ThinkingBudgets? {
        get { lock.withLock { _thinkingBudgets } }
        set { lock.withLock { _thinkingBudgets = newValue } }
    }
    public var maxRetryDelayMs: Int? {
        get { lock.withLock { _maxRetryDelayMs } }
        set { lock.withLock { _maxRetryDelayMs = newValue } }
    }
    public var maxTurns: Int? {
        get { lock.withLock { _maxTurns } }
        set { lock.withLock { _maxTurns = newValue } }
    }
    public var toolExecution: ToolExecutionMode {
        get { lock.withLock { _toolExecution } }
        set { lock.withLock { _toolExecution = newValue } }
    }
    public var toolChoice: ToolChoice? {
        get { lock.withLock { _toolChoice } }
        set { lock.withLock { _toolChoice = newValue } }
    }
    public var parallelToolCalls: Bool? {
        get { lock.withLock { _parallelToolCalls } }
        set { lock.withLock { _parallelToolCalls = newValue } }
    }
    public var beforeToolCall: BeforeToolCallHook? {
        get { lock.withLock { _beforeToolCall } }
        set { lock.withLock { _beforeToolCall = newValue } }
    }
    public var afterToolCall: AfterToolCallHook? {
        get { lock.withLock { _afterToolCall } }
        set { lock.withLock { _afterToolCall = newValue } }
    }
    public var userPromptSubmit: UserPromptSubmitHook? {
        get { lock.withLock { _userPromptSubmit } }
        set { lock.withLock { _userPromptSubmit = newValue } }
    }
    public var convertToLlm: ConvertToLlmHook? {
        get { lock.withLock { _convertToLlm } }
        set { lock.withLock { _convertToLlm = newValue } }
    }
    public var transformContext: TransformContextHook? {
        get { lock.withLock { _transformContext } }
        set { lock.withLock { _transformContext = newValue } }
    }
    public var betweenTurns: BetweenTurnsHook? {
        get { lock.withLock { _betweenTurns } }
        set { lock.withLock { _betweenTurns = newValue } }
    }
    public var autoCompact: AgentAutoCompactOptions? {
        get { lock.withLock { _autoCompact } }
        set { lock.withLock { _autoCompact = newValue } }
    }
    public var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? {
        get { lock.withLock { _authResolver } }
        set { lock.withLock { _authResolver = newValue } }
    }

    /// Base delay (ms) used for exponential backoff between stream retries.
    /// Exposed internally so tests can shrink the 1-second default.
    internal var retryBaseDelayMs: UInt64 {
        get { lock.withLock { _retryBaseDelayMs } }
        set { lock.withLock { _retryBaseDelayMs = newValue } }
    }

    private let steeringQueue: PendingMessageQueue
    private let followUpQueue: PendingMessageQueue
    internal let backgroundAttachmentList = AgentBackgroundAttachmentList()

    public convenience init(
        initialState: AgentInitialState,
        streamFn: StreamFn? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        sessionId: String? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        maxRetryDelayMs: Int? = nil
    ) {
        self.init(options: AgentOptions(
            initialState: initialState,
            streamFn: streamFn,
            toolExecution: toolExecution,
            sessionId: sessionId,
            thinkingBudgets: thinkingBudgets,
            maxRetryDelayMs: maxRetryDelayMs
        ))
    }

    public init(options: AgentOptions) {
        self.state = AgentState(
            systemPrompt: options.initialState.systemPrompt,
            model: options.initialState.model,
            thinkingLevel: options.initialState.thinkingLevel,
            thinkingDisplay: options.initialState.thinkingDisplay,
            verboseEnabled: options.initialState.verboseEnabled,
            tools: options.initialState.tools,
            messages: options.initialState.messages
        )
        self.streamFn = options.streamFn ?? { model, context, options in
            try await KWWKAI.stream(model: model, context: context, options: options)
        }
        self.sessionId = options.sessionId
        self.cwd = options.cwd
        // Assign backing storage directly — the public accessors are
        // lock-guarded computed properties, so they can't be used until every
        // stored property is initialized.
        self._toolExecution = options.toolExecution
        self._toolChoice = options.toolChoice
        self._parallelToolCalls = options.parallelToolCalls
        self._thinkingBudgets = options.thinkingBudgets
        self._maxRetryDelayMs = options.maxRetryDelayMs
        self._maxTurns = options.maxTurns
        self._beforeToolCall = options.beforeToolCall
        self._afterToolCall = options.afterToolCall
        self._userPromptSubmit = options.userPromptSubmit
        self._convertToLlm = options.convertToLlm
        self._transformContext = options.transformContext
        self._betweenTurns = options.betweenTurns
        self._autoCompact = options.autoCompact
        self._authResolver = options.authResolver
        self.steeringQueue = PendingMessageQueue(mode: options.steeringMode)
        self.followUpQueue = PendingMessageQueue(mode: options.followUpMode)
    }

    internal func streamForCompaction(
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async throws -> AssistantMessageStream {
        try await streamFn(model, context, options)
    }

    /// Queue a message to inject after the current assistant turn finishes.
    public func steer(_ message: Message) { steeringQueue.enqueue(message) }

    /// Convenience: steer a plain-text user message.
    public func steer(_ text: String) { steer(.user(UserMessage(text: text))) }

    /// Convenience: steer a `UserMessage` without wrapping it in `.user(...)`.
    public func steer(_ message: UserMessage) { steer(.user(message)) }

    /// Queue a message to run only after the agent would otherwise stop.
    public func followUp(_ message: Message) { followUpQueue.enqueue(message) }

    /// Convenience: follow up with a plain-text user message.
    public func followUp(_ text: String) { followUp(.user(UserMessage(text: text))) }

    /// Convenience: follow up with a `UserMessage` without `.user(...)` wrapping.
    public func followUp(_ message: UserMessage) { followUp(.user(message)) }

    public func clearSteeringQueue() { steeringQueue.clear() }
    public func clearFollowUpQueue() { followUpQueue.clear() }
    public func clearAllQueues() { clearSteeringQueue(); clearFollowUpQueue() }
    public func hasQueuedMessages() -> Bool {
        steeringQueue.hasItems() || followUpQueue.hasItems()
    }

    /// Number of steering messages waiting to be injected at the next
    /// turn boundary. Exposed so UI layers can show a "↓ N queued"
    /// indicator.
    public func queuedSteeringCount() -> Int { steeringQueue.count() }

    /// Read-only snapshot of the steering queue in FIFO order. Copies the
    /// underlying array so the caller can iterate without racing a drain.
    public func queuedSteeringMessages() -> [Message] { steeringQueue.snapshot() }

    /// Remove and return the most recently queued steering message (LIFO).
    /// Returns nil when the queue is empty. Powers the TUI's Alt+↑ "edit the
    /// last queued prompt" action — the popped message goes back to the input.
    @discardableResult
    public func popLastSteeringMessage() -> Message? { steeringQueue.popLast() }

    /// Push a message back onto the front of the steering queue. Powers the
    /// TUI's Alt+↑ dequeue-cycle: when the user keeps pressing Alt+↑, the
    /// prompt currently in the editor is returned to the front so the next
    /// `popLastSteeringMessage()` surfaces the prior item, rotating through
    /// the queue without losing any prompt.
    public func pushFrontSteeringMessage(_ message: Message) {
        steeringQueue.enqueueFront(message)
    }

    public var steeringMode: QueueMode {
        get { steeringQueue.mode }
        set { steeringQueue.mode = newValue }
    }

    public var followUpMode: QueueMode {
        get { followUpQueue.mode }
        set { followUpQueue.mode = newValue }
    }

    /// Clear transcript + runtime state + queues. Safe to call between runs.
    public func reset() {
        state.messages = []
        state.setStreaming(false)
        state.setStreamingMessage(nil)
        state.clearPendingToolCalls()
        state.setErrorMessage(nil)
        clearAllQueues()
    }

    // MARK: - Subscription

    public func subscribe(_ handler: @escaping AgentListener) -> Unsubscribe {
        let id = UUID()
        lock.withLock { listeners.append((id, handler)) }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.listeners.removeAll { $0.id == id }
            }
        }
    }

    private func snapshotListeners() -> [AgentListener] {
        lock.withLock { listeners.map { $0.handler } }
    }
}

/// Tiny Sendable mutable boolean for closure capture.
final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(initial: Bool) { self.value = initial }
    /// If true, flip to false and return true. Otherwise return false.
    func swapFalse() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { value = false; return true }
        return false
    }
    func set(_ v: Bool) { lock.withLock { value = v } }
    func get() -> Bool { lock.withLock { value } }
}

extension Agent {

    // MARK: - Prompt / continue / abort / waitForIdle

    public func prompt(_ text: String, images: [ImageContent] = []) async throws {
        var blocks: [UserBlock] = [.text(TextContent(text: text))]
        for image in images { blocks.append(.image(image)) }
        let userMessage = UserMessage(content: blocks)
        try await runLifecycle { [self] cancellation, emit in
            try await AgentLoop.run(
                prompts: [.user(userMessage)],
                context: snapshotContext(),
                config: loopConfig(),
                emit: emit,
                cancellation: cancellation,
                streamFn: streamFn
            )
        }
    }

    public func `continue`() async throws {
        let messages = state.messages
        guard let last = messages.last else {
            throw AgentError.noMessagesToContinue
        }
        switch last.role {
        case .user, .toolResult:
            try await runLifecycle { [self] cancellation, emit in
                try await AgentLoop.runContinue(
                    context: snapshotContext(),
                    config: loopConfig(),
                    emit: emit,
                    cancellation: cancellation,
                    streamFn: streamFn
                )
            }
        case .assistant:
            // Drain queued messages: steering first, then follow-up.
            let queuedSteering = steeringQueue.drain()
            if !queuedSteering.isEmpty {
                try await runLifecycle { [self] cancellation, emit in
                    try await AgentLoop.run(
                        prompts: queuedSteering,
                        context: snapshotContext(),
                        config: loopConfig(skipInitialSteeringPoll: true),
                        emit: emit,
                        cancellation: cancellation,
                        streamFn: streamFn
                    )
                }
                return
            }
            let queuedFollowUps = followUpQueue.drain()
            if !queuedFollowUps.isEmpty {
                try await runLifecycle { [self] cancellation, emit in
                    try await AgentLoop.run(
                        prompts: queuedFollowUps,
                        context: snapshotContext(),
                        config: loopConfig(),
                        emit: emit,
                        cancellation: cancellation,
                        streamFn: streamFn
                    )
                }
                return
            }
            throw AgentError.cannotContinueFromRole(last.role.rawValue)
        }
    }

    public func abort() {
        let cancellation = lock.withLock { activeCancellation }
        cancellation?.cancel(reason: "aborted")
    }

    public func waitForIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResume: Bool = lock.withLock {
                // activeCancellation is the authoritative flag: only non-nil while
                // a run owns the agent.
                if activeCancellation == nil { return true }
                idleWaiters.append(cont)
                return false
            }
            if shouldResume { cont.resume() }
        }
    }

    // MARK: - Internal helpers

    private func snapshotContext() -> AgentContext {
        AgentContext(
            systemPrompt: state.systemPrompt,
            messages: state.messages,
            tools: state.tools
        )
    }

    private func loopConfig(skipInitialSteeringPoll: Bool = false) -> AgentLoopConfig {
        let steering = steeringQueue
        let followUp = followUpQueue
        let skipBox = FlagBox(initial: skipInitialSteeringPoll)
        // Filter reasoning intent by the live model's capability. Non-
        // reasoning models (e.g. Copilot GPT-4.1) would otherwise receive
        // a `reasoning`/`thinking` field they don't understand — some
        // endpoints 400 on unknown params. Users set the level via
        // `/thinking`; we just gate whether to forward it.
        let effectiveReasoning: ReasoningLevel? = {
            guard state.model.reasoning, state.thinkingLevel != .off else { return nil }
            return thinkingLevelToReasoning(state.thinkingLevel)
        }()
        return AgentLoopConfig(
            model: state.model,
            reasoning: effectiveReasoning,
            thinkingBudgets: thinkingBudgets,
            sessionId: sessionId,
            cwd: cwd,
            verboseEnabled: state.verboseEnabled,
            maxRetryDelayMs: maxRetryDelayMs,
            toolExecution: toolExecution,
            toolChoice: toolChoice,
            parallelToolCalls: parallelToolCalls,
            maxTurns: maxTurns,
            retryBaseDelayMs: retryBaseDelayMs,
            getSteeringMessages: {
                if skipBox.swapFalse() { return [] }
                return steering.drain()
            },
            getFollowUpMessages: { followUp.drain() },
            authResolver: authResolver,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall,
            userPromptSubmit: userPromptSubmit,
            convertToLlm: convertToLlm,
            transformContext: transformContext,
            betweenTurns: builtInBetweenTurnsHook()
        )
    }

    private func thinkingLevelToReasoning(_ level: ThinkingLevel) -> ReasoningLevel? {
        switch level {
        case .off: return nil
        case .minimal: return .minimal
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .xhigh: return .xhigh
        }
    }

    private func runLifecycle(
        _ executor: @escaping @Sendable (_ cancellation: CancellationHandle, _ emit: @escaping AgentEventSink) async throws -> Void
    ) async throws {
        try lock.withLock { () throws -> Void in
            if activeCancellation != nil { throw AgentError.alreadyRunning }
            let handle = CancellationHandle()
            activeCancellation = handle
        }

        let cancellation = lock.withLock { activeCancellation! }
        state.setStreaming(true)
        state.setStreamingMessage(nil)
        state.setErrorMessage(nil)

        let emit: AgentEventSink = { [weak self] event in
            await self?.processEvent(event, cancellation: cancellation)
        }

        do {
            try await executor(cancellation, emit)
        } catch {
            await handleRunFailure(error: error, aborted: cancellation.isCancelled)
        }

        // finishRun — clear state and resume waiters.
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            activeCancellation = nil
            let drained = idleWaiters
            idleWaiters.removeAll()
            return drained
        }
        state.setStreaming(false)
        state.setStreamingMessage(nil)
        state.clearPendingToolCalls()
        for waiter in waiters { waiter.resume() }
    }

    private func builtInBetweenTurnsHook() -> BetweenTurnsHook? {
        let userHook = betweenTurns
        let autoCompact = autoCompact
        guard userHook != nil || autoCompact?.threshold != nil else {
            return nil
        }

        return { [weak self] context, cancellation in
            guard let self else {
                return await userHook?(context, cancellation)
            }

            var current = context
            var replaced = false

            if let autoCompact,
               let threshold = autoCompact.threshold,
               threshold > 0,
               current.messages.count >= autoCompact.config.minMessages,
               AgentContextCompactor.shouldCompact(
                    messages: current.messages,
                    model: self.state.model,
                    threshold: threshold
               ) {
                let usage = AgentContextCompactor.currentUsage(
                    messages: current.messages,
                    model: self.state.model
                )
                await self.emitSynthetic(
                    .compactStart(messagesCount: current.messages.count, usage: usage),
                    cancellation: cancellation
                )

                self.state.messages = current.messages
                let outcome = await AgentContextCompactor.compactAgent(
                    agent: self,
                    backgroundManager: autoCompact.backgroundManager,
                    sessionId: self.sessionId,
                    config: autoCompact.config,
                    ignoreStreaming: true,
                    cancellation: cancellation
                )
                await self.emitSynthetic(.compactEnd(outcome: outcome), cancellation: cancellation)

                if case .compacted = outcome {
                    current.messages = self.state.messages
                    replaced = true
                }
            }

            if let userHook, let replacement = await userHook(current, cancellation) {
                current = replacement
                replaced = true
            }

            return replaced ? current : nil
        }
    }

    private func emitSynthetic(_ event: AgentEvent, cancellation: CancellationHandle?) async {
        for listener in snapshotListeners() {
            await listener(event, cancellation)
        }
    }

    private func handleRunFailure(error: Error, aborted: Bool) async {
        let failure = AssistantMessage(
            content: [.text(TextContent(text: ""))],
            api: state.model.api,
            provider: state.model.provider,
            model: state.model.id,
            usage: Usage(),
            stopReason: aborted ? .aborted : .error,
            errorMessage: (error as? LocalizedError)?.errorDescription ?? "\(error)",
            timestamp: Timestamp.now()
        )
        state.appendMessage(.assistant(failure))
        state.setErrorMessage(failure.errorMessage)
        let cancellation = lock.withLock { activeCancellation }
        let listeners = snapshotListeners()
        // Emit the synthetic failure as a normal message pair so
        // transcript renderers show it as `✗ err` instead of silently
        // vanishing — this is the "retries exhausted via thrown error"
        // path that previously left the TUI blank.
        //
        // The summary on this path is minimal: the failure carries no
        // usage so we emit zero tokens/cost. Consumers can branch on
        // `finalStopReason == .error / .aborted` to render accordingly.
        let summary = AgentRunSummary(
            turns: 0,
            usage: Usage(),
            cost: Cost(),
            durationMs: 0,
            finalStopReason: aborted ? .aborted : .error
        )
        for listener in listeners {
            await listener(.messageStart(message: .assistant(failure)), cancellation)
            await listener(.messageEnd(message: .assistant(failure)), cancellation)
            await listener(.agentEnd(messages: [.assistant(failure)], summary: summary), cancellation)
        }
    }

    private func processEvent(_ event: AgentEvent, cancellation: CancellationHandle) async {
        switch event {
        case .messageStart(let message):
            state.setStreamingMessage(message)

        case .messageUpdate(let assistant, _):
            state.setStreamingMessage(.assistant(assistant))

        case .messageEnd(let message):
            state.setStreamingMessage(nil)
            state.appendMessage(message)

        case .toolExecutionStart(let id, _, _):
            state.insertPendingToolCall(id)

        case .toolExecutionEnd(let id, _, _, _):
            state.removePendingToolCall(id)

        case .turnEnd(let message, _):
            if case .assistant(let a) = message, let err = a.errorMessage {
                state.setErrorMessage(err)
            }

        case .agentEnd:
            state.setStreamingMessage(nil)

        default:
            break
        }

        for listener in snapshotListeners() {
            await listener(event, cancellation)
        }
    }
}
