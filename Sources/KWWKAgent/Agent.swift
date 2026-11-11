import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// Listener invoked for every `AgentEvent`. Async listeners are awaited in
/// subscription order before the agent returns to idle, matching pi-agent-core.
public typealias AgentListener = @Sendable (AgentEvent, CancellationHandle?) async -> Void

/// Handle returned from `subscribe`. Call to unsubscribe.
public typealias Unsubscribe = @Sendable () -> Void

/// Stateful agent that drives turn/tool loops against an LLM. Mirrors
/// pi-agent-core's `Agent` class but with Swift-native concurrency semantics.
public final class Agent: Sendable {
    public let state: AgentState
    private let streamFn: StreamFn
    private let usesCustomStream: Bool

    /// Run ownership, listeners, and the mutable run configuration, all
    /// guarded by one lock so multi-field checks (e.g. acquire-run) stay atomic.
    private struct LockedState {
        var listeners: [(id: UUID, handler: AgentListener)] = []
        var activeCancellation: CancellationHandle?
        /// Exclusive non-generation work (currently manual context compaction).
        /// A maintenance owner and a model run are mutually exclusive. Keeping
        /// this beside `activeCancellation` makes the check-and-acquire atomic,
        /// rather than relying on the UI's eventually-consistent streaming flag.
        var maintenanceCancellation: CancellationHandle?
        /// Permanently closes this Agent instance to new runs. Session rotation
        /// uses this before detaching bridges so already-scheduled wake tasks can
        /// never revive the outgoing session.
        var retired = false
        var idleWaiters: [CheckedContinuation<Void, Never>] = []

        // Mutable run configuration. `loopConfig()` reads these on the run's task
        // while the public setters may be invoked from any thread (steer() is
        // documented "from any thread"), so every access funnels through
        // `lockedState` — mirrors AgentState, whose fields are all guarded the
        // same way.
        var thinkingBudgets: ThinkingBudgets?
        var maxRetryDelayMs: Int?
        var maxTurns: Int?
        var toolExecution: ToolExecutionMode
        var toolChoice: ToolChoice?
        var parallelToolCalls: Bool?
        var beforeToolCall: BeforeToolCallHook?
        var afterToolCall: AfterToolCallHook?
        var userPromptSubmit: UserPromptSubmitHook?
        var convertToLlm: ConvertToLlmHook?
        var transformContext: TransformContextHook?
        var betweenTurns: BetweenTurnsHook?
        var beforeRunEnd: BeforeRunEndHook?
        var autoCompact: AgentAutoCompactOptions?
        var idleCompact: AgentIdleCompactOptions?
        var compactionModel: Model?
        var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
        var retryBaseDelayMs: UInt64 = 1_000
        var streamsToIrreversibleSink = false
    }

    private let lockedState: NIOLockedValueBox<LockedState>

    /// Immutable session identity: one `Agent` == one session. Rotating to a
    /// new session means building a fresh `Agent`/`SessionRecorder` through the
    /// supported path (the CLI's `/new` and `/resume` replace both together).
    /// There is deliberately no in-place setter —
    /// mutating it would leave tools, the recorder, and background attachments
    /// scoped to different ids.
    public let sessionId: String?

    /// Workspace root forwarded to server-driven providers (Cursor).
    public let cwd: String?

    private let finalTextOnlyOnLastTurn: Bool
    private let terminalToolName: String?
    private let terminalToolReminderLimit: Int
    let idleCompactionTimer = IdleCompactionTimer()
    /// Summary-request usage of compactions run since the last
    /// `takeCompactionUsage()`; see `CompactionUsageCollector`.
    private let compactionUsage = NIOLockedValueBox<Usage?>(nil)

    public var thinkingBudgets: ThinkingBudgets? {
        get { lockedState.withLockedValue { $0.thinkingBudgets } }
        set { lockedState.withLockedValue { $0.thinkingBudgets = newValue } }
    }
    public var maxRetryDelayMs: Int? {
        get { lockedState.withLockedValue { $0.maxRetryDelayMs } }
        set { lockedState.withLockedValue { $0.maxRetryDelayMs = newValue } }
    }
    public var maxTurns: Int? {
        get { lockedState.withLockedValue { $0.maxTurns } }
        set { lockedState.withLockedValue { $0.maxTurns = newValue } }
    }
    public var toolExecution: ToolExecutionMode {
        get { lockedState.withLockedValue { $0.toolExecution } }
        set { lockedState.withLockedValue { $0.toolExecution = newValue } }
    }
    public var toolChoice: ToolChoice? {
        get { lockedState.withLockedValue { $0.toolChoice } }
        set { lockedState.withLockedValue { $0.toolChoice = newValue } }
    }
    public var parallelToolCalls: Bool? {
        get { lockedState.withLockedValue { $0.parallelToolCalls } }
        set { lockedState.withLockedValue { $0.parallelToolCalls = newValue } }
    }
    public var beforeToolCall: BeforeToolCallHook? {
        get { lockedState.withLockedValue { $0.beforeToolCall } }
        set { lockedState.withLockedValue { $0.beforeToolCall = newValue } }
    }
    public var afterToolCall: AfterToolCallHook? {
        get { lockedState.withLockedValue { $0.afterToolCall } }
        set { lockedState.withLockedValue { $0.afterToolCall = newValue } }
    }
    public var userPromptSubmit: UserPromptSubmitHook? {
        get { lockedState.withLockedValue { $0.userPromptSubmit } }
        set { lockedState.withLockedValue { $0.userPromptSubmit = newValue } }
    }
    public var convertToLlm: ConvertToLlmHook? {
        get { lockedState.withLockedValue { $0.convertToLlm } }
        set { lockedState.withLockedValue { $0.convertToLlm = newValue } }
    }
    public var transformContext: TransformContextHook? {
        get { lockedState.withLockedValue { $0.transformContext } }
        set { lockedState.withLockedValue { $0.transformContext = newValue } }
    }
    public var betweenTurns: BetweenTurnsHook? {
        get { lockedState.withLockedValue { $0.betweenTurns } }
        set { lockedState.withLockedValue { $0.betweenTurns = newValue } }
    }
    public var beforeRunEnd: BeforeRunEndHook? {
        get { lockedState.withLockedValue { $0.beforeRunEnd } }
        set { lockedState.withLockedValue { $0.beforeRunEnd = newValue } }
    }
    public var autoCompact: AgentAutoCompactOptions? {
        get { lockedState.withLockedValue { $0.autoCompact } }
        set { lockedState.withLockedValue { $0.autoCompact = newValue } }
    }

    /// Idle-time compaction. Assigning restarts the idle countdown from now
    /// (or cancels it for `nil`), so a change made while the agent is already
    /// idle takes effect without waiting for another run.
    public var idleCompact: AgentIdleCompactOptions? {
        get { lockedState.withLockedValue { $0.idleCompact } }
        set {
            lockedState.withLockedValue { $0.idleCompact = newValue }
            idleCompactionTimer.cancel()
            noteIdleActivity()
        }
    }
    /// Model used for compaction summaries. Assign `nil` to follow the live
    /// conversation model again. This never mutates `state.model`.
    public var compactionModel: Model? {
        get { lockedState.withLockedValue { $0.compactionModel } }
        set { lockedState.withLockedValue { $0.compactionModel = newValue } }
    }
    public var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? {
        get { lockedState.withLockedValue { $0.authResolver } }
        set { lockedState.withLockedValue { $0.authResolver = newValue } }
    }

    /// Base delay (ms) used for exponential backoff between stream retries.
    /// Exposed internally so tests can shrink the 1-second default.
    internal var retryBaseDelayMs: UInt64 {
        get { lockedState.withLockedValue { $0.retryBaseDelayMs } }
        set { lockedState.withLockedValue { $0.retryBaseDelayMs = newValue } }
    }

    /// Whether a subscriber writes streamed assistant output somewhere it
    /// cannot take back (e.g. `kwwk -p` printing text deltas to stdout).
    /// While false (the default), a provider failure that left no side effect
    /// is retried from scratch even after text or tool-call blocks streamed:
    /// the partial attempt is discarded with `streamRewind`. While true, such
    /// an attempt is final, as streamed output is treated as delivered.
    public var streamsToIrreversibleSink: Bool {
        get { lockedState.withLockedValue { $0.streamsToIrreversibleSink } }
        set { lockedState.withLockedValue { $0.streamsToIrreversibleSink = newValue } }
    }

    private let steeringQueue: PendingMessageQueue
    private let followUpQueue: PendingMessageQueue
    /// Machine-generated context (background completions, runtime notices).
    /// Kept separate from steering so it never appears in editable user queue
    /// UI, while still being drained at the next model step boundary.
    private let runtimeAsideQueue: PendingMessageQueue
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
        self.usesCustomStream = options.streamFn != nil
        self.streamFn = options.streamFn ?? { model, context, options in
            try await KWWKAI.stream(model: model, context: context, options: options)
        }
        self.sessionId = options.sessionId
        self.cwd = options.cwd
        // Build the locked storage directly — the public accessors are
        // lock-guarded computed properties, so they can't be used until every
        // stored property is initialized.
        self.lockedState = NIOLockedValueBox(LockedState(
            thinkingBudgets: options.thinkingBudgets,
            maxRetryDelayMs: options.maxRetryDelayMs,
            maxTurns: options.maxTurns,
            toolExecution: options.toolExecution,
            toolChoice: options.toolChoice,
            parallelToolCalls: options.parallelToolCalls,
            beforeToolCall: options.beforeToolCall,
            afterToolCall: options.afterToolCall,
            userPromptSubmit: options.userPromptSubmit,
            convertToLlm: options.convertToLlm,
            transformContext: options.transformContext,
            betweenTurns: options.betweenTurns,
            beforeRunEnd: options.beforeRunEnd,
            autoCompact: options.autoCompact,
            idleCompact: options.idleCompact,
            compactionModel: options.compactionModel,
            authResolver: options.authResolver,
            streamsToIrreversibleSink: options.streamsToIrreversibleSink
        ))
        self.finalTextOnlyOnLastTurn = options.finalTextOnlyOnLastTurn
        self.terminalToolName = options.terminalToolName
        self.terminalToolReminderLimit = max(0, options.terminalToolReminderLimit)
        self.steeringQueue = PendingMessageQueue(mode: options.steeringMode)
        self.followUpQueue = PendingMessageQueue(mode: options.followUpMode)
        self.runtimeAsideQueue = PendingMessageQueue(mode: .all)
        // A restored session may be left untouched from the start.
        noteIdleActivity()
    }

    internal func streamForCompaction(
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async throws -> AssistantMessageStream {
        try await streamFn(model, context, options)
    }

    internal func noteCompactionUsage(_ usage: Usage?) {
        guard let usage else { return }
        compactionUsage.withLockedValue { $0 = ($0 ?? Usage()).adding(usage) }
    }

    /// Drain the provider-reported usage of compaction summary requests made
    /// since the previous call. Those replies never enter the transcript, so
    /// a session recorder persists this on its next compaction marker.
    public func takeCompactionUsage() -> Usage? {
        compactionUsage.withLockedValue { usage in
            defer { usage = nil }
            return usage
        }
    }

    internal func resolvedCompactionConfig(_ config: AgentContextCompactionConfig) -> AgentContextCompactionConfig {
        var config = config
        if !usesCustomStream && config.nativeCompaction == nil {
            config.nativeCompaction = { model, context, instructions, options in
                try await compactNative(model: model, context: context, instructions: instructions, options: options)
            }
        }
        return config
    }

    /// Queue a message to inject after the current assistant turn finishes.
    public func steer(_ message: Message) { steeringQueue.enqueue(message) }

    /// Queue machine-generated context for the next model step without
    /// exposing it through the user's editable steering queue.
    public func aside(_ message: UserMessage) {
        var runtimeMessage = message
        runtimeMessage.source = .runtime
        runtimeAsideQueue.enqueue(.user(runtimeMessage))
    }

    /// Convenience: enqueue a plain-text runtime aside.
    public func aside(_ text: String) {
        aside(UserMessage(text: text, source: .runtime))
    }

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
    public func clearAllQueues() {
        clearSteeringQueue()
        clearFollowUpQueue()
        runtimeAsideQueue.clear()
        for attachment in backgroundAttachmentList.list() {
            attachment.deliveryConsumer.clearPendingMessages()
        }
    }
    public func hasQueuedMessages() -> Bool {
        runtimeAsideQueue.hasItems()
            || backgroundAttachmentList.list().contains(where: {
                $0.deliveryConsumer.hasPendingMessages()
            })
            || steeringQueue.hasItems()
            || followUpQueue.hasItems()
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
        lockedState.withLockedValue { $0.listeners.append((id, handler)) }
        return { [weak self] in
            guard let self else { return }
            self.lockedState.withLockedValue { state in
                state.listeners.removeAll { $0.id == id }
            }
        }
    }

    private func snapshotListeners() -> [AgentListener] {
        lockedState.withLockedValue { state in state.listeners.map { $0.handler } }
    }
}

/// Tiny Sendable mutable boolean for closure capture.
final class FlagBox: Sendable {
    private let value: NIOLockedValueBox<Bool>
    init(initial: Bool) { self.value = NIOLockedValueBox(initial) }
    /// If true, flip to false and return true. Otherwise return false.
    func swapFalse() -> Bool {
        value.withLockedValue { value in
            if value { value = false; return true }
            return false
        }
    }
    func set(_ v: Bool) { value.withLockedValue { $0 = v } }
    func get() -> Bool { value.withLockedValue { $0 } }
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
        // Own the run before touching any queue. Background wake-ups race with
        // direct user prompts; draining first would lose messages when the
        // subsequent lifecycle acquisition throws `alreadyRunning`.
        let cancellation = try acquireRun()

        // Queued work always wins over the role-based continuation. This is
        // important after manual compaction: the replacement recap has role
        // `.user`, while a prompt submitted during the maintenance window is
        // already queued. Answer that real prompt in the recap context instead
        // of first generating an unsolicited response to the recap itself.
        let queuedAsides = drainRuntimeMessages()
        if !queuedAsides.isEmpty {
            await runOwnedLifecycle(cancellation: cancellation) { [self] cancellation, emit in
                try await AgentLoop.run(
                    prompts: queuedAsides,
                    context: snapshotContext(),
                    config: loopConfig(skipInitialRuntimePoll: true),
                    emit: emit,
                    cancellation: cancellation,
                    streamFn: streamFn
                )
            }
            return
        }
        let queuedSteering = steeringQueue.drain()
        if !queuedSteering.isEmpty {
            await runOwnedLifecycle(cancellation: cancellation) { [self] cancellation, emit in
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
            await runOwnedLifecycle(cancellation: cancellation) { [self] cancellation, emit in
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

        let messages = state.messages
        // Tool declarations are transcript bookkeeping, not a turn: continue
        // from the last real message.
        guard let last = messages.last(where: { $0.role != .system }) else {
            finishRun()
            throw AgentError.noMessagesToContinue
        }

        switch last.role {
        case .system:
            preconditionFailure("system messages are skipped above")
        case .user, .toolResult:
            await runOwnedLifecycle(cancellation: cancellation) { [self] cancellation, emit in
                try await AgentLoop.runContinue(
                    context: snapshotContext(),
                    config: loopConfig(),
                    emit: emit,
                    cancellation: cancellation,
                    streamFn: streamFn
                )
            }
        case .assistant:
            finishRun()
            // A consumer can enqueue after the empty drain while this run still
            // owns the streaming flag, so its wake callback intentionally does
            // not start a competing run. Recheck after releasing ownership.
            if hasQueuedMessages() {
                try await self.continue()
                return
            }
            throw AgentError.cannotContinueFromRole(last.role.rawValue)
        }
    }

    public func abort() {
        let cancellations = lockedState.withLockedValue { state in
            [state.activeCancellation, state.maintenanceCancellation].compactMap { $0 }
        }
        for cancellation in cancellations {
            cancellation.cancel(reason: "aborted")
        }
    }

    /// Permanently reject future prompt/continue/maintenance acquisition.
    /// Existing work is cancelled; callers may await `waitForIdle()` before
    /// closing provider resources.
    public func retire() {
        let cancellations: [CancellationHandle] = lockedState.withLockedValue { state in
            state.retired = true
            return [state.activeCancellation, state.maintenanceCancellation].compactMap { $0 }
        }
        for cancellation in cancellations {
            cancellation.cancel(reason: "session retired")
        }
        idleCompactionTimer.cancel()
        clearAllQueues()
    }

    public func waitForIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResume: Bool = lockedState.withLockedValue { state in
                if state.activeCancellation == nil && state.maintenanceCancellation == nil { return true }
                state.idleWaiters.append(cont)
                return false
            }
            if shouldResume { cont.resume() }
        }
    }

    /// Run transcript-mutating maintenance under the same exclusive ownership
    /// used by model runs. Prompts/background wake-ups that race this window
    /// receive `alreadyRunning` without touching queues.
    ///
    /// Releasing maintenance deliberately does not start queued work. Callers
    /// often have durable/UI settlement to finish after mutating the transcript
    /// (manual compaction must persist its projection before another turn can
    /// append). Once that settlement is complete, call `resumeQueuedWork()`.
    public func withMaintenance<T: Sendable>(
        _ body: @escaping @Sendable (CancellationHandle) async -> T
    ) async throws -> T {
        let cancellation: CancellationHandle = try lockedState.withLockedValue { state in
            if state.retired || state.activeCancellation != nil || state.maintenanceCancellation != nil {
                throw AgentError.alreadyRunning
            }
            let cancellation = CancellationHandle()
            state.maintenanceCancellation = cancellation
            return cancellation
        }

        let result = await body(cancellation)
        finishMaintenance(cancellation)
        return result
    }

    /// Convenience overload for maintenance that does not itself need to
    /// observe cancellation. Exit/session teardown still owns and releases the
    /// underlying handle; cancellable operations such as compaction should use
    /// the handle-taking overload above.
    public func withMaintenance<T: Sendable>(
        _ body: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withMaintenance { _ in await body() }
    }

    /// Resume work queued while a maintenance owner was active.
    ///
    /// This is intentionally fire-and-forget: UI callers can finish their
    /// persistence and repaint transaction, release maintenance, then hand the
    /// queue back to the normal run arbiter without blocking on the model turn.
    /// Waiting for idle first also makes the method safe when a competing run or
    /// a background-delivery wake already acquired ownership.
    public func resumeQueuedWork() {
        guard hasQueuedMessages() else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.waitForIdle()
            guard self.hasQueuedMessages() else { return }
            try? await self.continue()
        }
    }

    // MARK: - Internal helpers

    private func snapshotContext() -> AgentContext {
        AgentContext(
            systemPrompt: state.effectiveSystemPrompt,
            messages: state.messages,
            tools: state.effectiveTools
        )
    }

    private func loopConfig(
        skipInitialSteeringPoll: Bool = false,
        skipInitialRuntimePoll: Bool = false
    ) -> AgentLoopConfig {
        let steering = steeringQueue
        let followUp = followUpQueue
        let skipSteeringBox = FlagBox(initial: skipInitialSteeringPoll)
        let skipRuntimeBox = FlagBox(initial: skipInitialRuntimePoll)
        // Filter reasoning intent by the live model's capability. Non-
        // reasoning models (e.g. Copilot GPT-4.1) would otherwise receive
        // a `reasoning`/`thinking` field they don't understand — some
        // endpoints 400 on unknown params. Users set the level via
        // `/thinking`; we just gate whether to forward it.
        let effectiveReasoning: ReasoningLevel? = {
            guard state.model.reasoning, state.thinkingLevel != .off else { return nil }
            return thinkingLevelToReasoning(state.thinkingLevel)
        }()
        var config = AgentLoopConfig(
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
            getRuntimeMessages: {
                if skipRuntimeBox.swapFalse() { return [] }
                return self.drainRuntimeMessages()
            },
            getSteeringMessages: {
                if skipSteeringBox.swapFalse() { return [] }
                return steering.drain()
            },
            hasSteeringMessages: { steering.hasItems() },
            getFollowUpMessages: { followUp.drain() },
            authResolver: authResolver,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall,
            userPromptSubmit: userPromptSubmit,
            convertToLlm: convertToLlm,
            transformContext: transformContext,
            betweenTurns: builtInBetweenTurnsHook(),
            beforeRunEnd: beforeRunEnd,
            contextCompaction: builtInContextCompactionHook()
        )
        config.currentTools = { [state] in state.effectiveTools }
        config.serviceTier = state.serviceTier
        config.finalTextOnlyOnLastTurn = finalTextOnlyOnLastTurn
        config.terminalToolName = terminalToolName
        config.terminalToolReminderLimit = terminalToolReminderLimit
        config.streamsToIrreversibleSink = streamsToIrreversibleSink
        return config
    }

    private func thinkingLevelToReasoning(_ level: ThinkingLevel) -> ReasoningLevel? {
        switch level {
        case .off: return nil
        case .minimal: return .minimal
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .xhigh: return .xhigh
        case .max: return .max
        }
    }

    /// Reasoning level for compaction-summary requests issued on this agent's
    /// behalf, mirroring the live turn's effective reasoning (gated on the
    /// summary model's capability). An absent level encodes to an explicit
    /// "reasoning disabled" on several wire formats, and reasoning-mandatory
    /// endpoints (e.g. xAI Grok behind OpenRouter) reject that with a 400 —
    /// which would permanently wedge compaction while live turns keep working.
    func summaryReasoning(for summaryModel: Model) -> ReasoningLevel? {
        guard summaryModel.reasoning, state.thinkingLevel != .off else { return nil }
        return thinkingLevelToReasoning(state.thinkingLevel)
    }

    private func runLifecycle(
        _ executor: @escaping @Sendable (
            _ cancellation: CancellationHandle,
            _ emit: @escaping AgentEventSink
        ) async throws -> Void
    ) async throws {
        let cancellation = try acquireRun()
        await runOwnedLifecycle(cancellation: cancellation, executor)
    }

    private func acquireRun() throws -> CancellationHandle {
        try lockedState.withLockedValue { (state: inout LockedState) throws -> Void in
            if state.retired || state.activeCancellation != nil || state.maintenanceCancellation != nil {
                throw AgentError.alreadyRunning
            }
            let handle = CancellationHandle()
            state.activeCancellation = handle
        }

        let cancellation = lockedState.withLockedValue { $0.activeCancellation! }
        idleCompactionTimer.cancel()
        state.setStreaming(true)
        state.setStreamingMessage(nil)
        state.setErrorMessage(nil)
        return cancellation
    }

    private func runOwnedLifecycle(
        cancellation: CancellationHandle,
        _ executor: @escaping @Sendable (
            _ cancellation: CancellationHandle,
            _ emit: @escaping AgentEventSink
        ) async throws -> Void
    ) async {
        let emit: AgentEventSink = { [weak self] event in
            await self?.processEvent(event, cancellation: cancellation)
        }

        do {
            try await executor(cancellation, emit)
        } catch {
            await handleRunFailure(error: error, aborted: cancellation.isCancelled)
        }

        finishRun()
    }

    private func finishRun() {
        // Publish the non-streaming state before releasing run ownership. If
        // ownership were cleared first, a new prompt could acquire and set
        // streaming=true only for this old run to overwrite it with false.
        state.setStreaming(false)
        state.setStreamingMessage(nil)
        state.clearPendingToolCalls()
        let waiters: [CheckedContinuation<Void, Never>] = lockedState.withLockedValue { state in
            state.activeCancellation = nil
            let drained = state.idleWaiters
            state.idleWaiters.removeAll()
            return drained
        }
        for waiter in waiters { waiter.resume() }
        noteIdleActivity()
    }

    private func finishMaintenance(_ cancellation: CancellationHandle) {
        let waiters: [CheckedContinuation<Void, Never>] = lockedState.withLockedValue { state in
            guard state.maintenanceCancellation === cancellation else { return [] }
            state.maintenanceCancellation = nil
            let drained = state.idleWaiters
            state.idleWaiters.removeAll()
            return drained
        }
        for waiter in waiters { waiter.resume() }
        noteIdleActivity()
    }

    private func drainRuntimeMessages() -> [Message] {
        var messages = runtimeAsideQueue.drain()
        for attachment in backgroundAttachmentList.list() {
            messages.append(contentsOf: attachment.deliveryConsumer.drainMessages())
        }
        return messages
    }

    private func builtInBetweenTurnsHook() -> BetweenTurnsHook? {
        // Built-in automatic compaction runs once, immediately before each
        // provider request, through `contextCompaction`. Keep this hook solely
        // for SDK callers' custom between-turn behavior; running the built-in
        // driver here as well retries a failed summary at the same boundary and
        // emits duplicate compactStart/compactEnd pairs.
        betweenTurns
    }

    private func builtInContextCompactionHook() -> ContextCompactionHook? {
        guard let autoCompact, autoCompact.threshold != nil else { return nil }
        return { [weak self] context, trigger, cancellation in
            guard let self else { return nil }
            return try await self.performAutomaticCompaction(
                context: context,
                trigger: trigger,
                autoCompact: autoCompact,
                cancellation: cancellation
            )
        }
    }

    private func performAutomaticCompaction(
        context: AgentContext,
        trigger: AgentContextCompactionTrigger,
        autoCompact: AgentAutoCompactOptions,
        cancellation: CancellationHandle?
    ) async throws -> AgentContext? {
        guard let threshold = autoCompact.threshold,
              threshold.isFinite,
              threshold > 0 else {
            return nil
        }

        var measuredContext = context
        let forced: Bool
        switch trigger {
        case .preflight(let pendingMessages):
            measuredContext.messages.append(contentsOf: pendingMessages)
            forced = false
        case .proactive:
            forced = false
        case .providerOverflow:
            forced = true
        }

        let stateSnapshot = state.snapshotModelContext()
        let model = stateSnapshot.model
        // Freeze the summary model for this compaction attempt. Runtime
        // changes made while listeners/provider calls suspend apply to the
        // next attempt, while the live model remains revision-guarded below.
        let summaryModel = compactionModel ?? model
        let usage = AgentContextCompactor.currentUsage(
            context: measuredContext,
            model: model
        )
        let inputBudget = AgentRequestBudget.inputTokens(for: model)
        let isBlockingPreflight: Bool = {
            guard case .preflight(let pendingMessages) = trigger else { return false }
            return pendingMessages.isEmpty && usage.tokens >= inputBudget
        }()

        let pendingMessages: [Message]
        if case .preflight(let pending) = trigger {
            pendingMessages = pending
        } else {
            pendingMessages = []
        }

        // If the fixed prompt/tools plus the pending user input already fill
        // the usable input budget, summarizing old history cannot make this
        // initial preflight fit. Let the loop append and surface the exact user
        // prompt first; its blocking preflight will then report irreducibility
        // without paying for two summaries.
        if !pendingMessages.isEmpty {
            var irreducibleContext = context
            irreducibleContext.messages = pendingMessages
            let irreducibleUsage = AgentContextCompactor.currentUsage(
                context: irreducibleContext,
                model: model
            )
            if irreducibleUsage.tokens >= inputBudget {
                return nil
            }
        }

        guard !context.messages.isEmpty else {
            if isBlockingPreflight {
                throw AgentContextPreflightError.irreducible(
                    tokens: usage.tokens,
                    inputBudget: inputBudget
                )
            }
            return nil
        }

        guard forced || isBlockingPreflight || AgentContextCompactor.shouldCompact(
            context: measuredContext,
            model: model,
            threshold: threshold
        ) else {
            return nil
        }

        guard AgentContextCompactor.contextsMatchForCompaction(
            stateSnapshot.context,
            context
        ) else {
            if isBlockingPreflight || forced {
                throw AgentContextCompactionError.contextChanged
            }
            return nil
        }
        await emitSynthetic(
            .compactStart(messagesCount: context.messages.count, usage: usage),
            cancellation: cancellation
        )

        // A compactStart listener is allowed to enqueue work, but it must not
        // mutate the transcript being summarized. Detect that before the LLM
        // round trip; the final compare-and-swap still protects the commit.
        guard state.hasContextRevision(stateSnapshot.revision) else {
            let outcome = AgentContextCompactionOutcome.failed(
                AgentContextCompactionError.contextChanged.localizedDescription
            )
            await emitSynthetic(.compactEnd(outcome: outcome), cancellation: cancellation)
            if isBlockingPreflight || forced {
                throw AgentContextCompactionError.contextChanged
            }
            return nil
        }

        let recoveryTarget = automaticRecoveryTarget(
            model: model,
            threshold: threshold,
            recoveryRatio: autoCompact.config.recoveryRatio
        )
        let outcome = await AgentContextCompactor.compactAgentContext(
            agent: self,
            context: context,
            model: model,
            summaryModel: summaryModel,
            expectedContextRevision: stateSnapshot.revision,
            backgroundManager: autoCompact.backgroundManager,
            sessionId: sessionId,
            config: autoCompact.config,
            targetTokens: recoveryTarget,
            additionalMessages: pendingMessages,
            respectMinimumMessages: false,
            cancellation: cancellation
        )
        await emitSynthetic(.compactEnd(outcome: outcome), cancellation: cancellation)

        guard case .compacted = outcome else {
            if cancellation?.isCancelled == true || Task.isCancelled {
                throw AgentContextCompactionError.cancelled
            }
            if case .failed(let reason) = outcome,
               reason == AgentContextCompactionError.cancelled.localizedDescription {
                throw AgentContextCompactionError.cancelled
            }
            if isBlockingPreflight {
                if case .refusedTooFewMessages = outcome {
                    throw AgentContextPreflightError.irreducible(
                        tokens: usage.tokens,
                        inputBudget: inputBudget
                    )
                }
                throw AgentContextPreflightError.compactionFailed(outcome)
            }
            return nil
        }
        var replacement = context
        replacement.messages = state.messages
        // Compaction may have unloaded deferred tools.
        replacement.tools = state.effectiveTools
        var measuredReplacement = replacement
        measuredReplacement.messages.append(contentsOf: pendingMessages)
        let replacementUsage = AgentContextCompactor.currentUsage(
            context: measuredReplacement,
            model: model
        )
        if isBlockingPreflight || forced {
            if replacementUsage.tokens >= inputBudget {
                throw AgentContextPreflightError.irreducible(
                    tokens: replacementUsage.tokens,
                    inputBudget: inputBudget
                )
            }
        }
        return replacement
    }

    private func automaticRecoveryTarget(
        model: Model,
        threshold: Double,
        recoveryRatio: Double
    ) -> Int? {
        // Tiny windows are test doubles rather than usable LLM contexts; keep
        // their historic trigger behavior without imposing an impossible
        // structured-recap headroom target.
        let window = model.contextWindow
        guard window >= 1_024 else { return nil }
        let triggerRatio = min(0.95, max(0.05, threshold))
        let recoveryRatio = min(0.95, max(0.1, recoveryRatio))
        return max(
            1,
            min(
                Int(Double(window) * triggerRatio * recoveryRatio),
                AgentRequestBudget.inputTokens(for: model)
            )
        )
    }

    private func emitSynthetic(_ event: AgentEvent, cancellation: CancellationHandle?) async {
        for listener in snapshotListeners() {
            await listener(event, cancellation)
        }
    }

    func emitIdleCompaction(_ event: AgentEvent, cancellation: CancellationHandle) async {
        await emitSynthetic(event, cancellation: cancellation)
    }

    /// Emit process-local telemetry that originates outside an active model
    /// run (for example a background subagent terminal event). It deliberately
    /// bypasses transcript/state mutation.
    func emitExternalRuntimeEvent(_ event: AgentRuntimeEvent) async {
        await emitSynthetic(.runtimeEvent(event), cancellation: nil)
    }

    private func handleRunFailure(error: Error, aborted: Bool) async {
        let failure = AssistantMessage(
            content: [.text(TextContent(text: ""))],
            api: state.model.api,
            provider: state.model.provider,
            model: state.model.id,
            usage: Usage(),
            stopReason: aborted ? .aborted : .error,
            errorMessage: error.displayDescription,
            timestamp: Timestamp.now()
        )
        state.appendMessage(.assistant(failure))
        state.setErrorMessage(failure.errorMessage)
        let cancellation = lockedState.withLockedValue { $0.activeCancellation }
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
