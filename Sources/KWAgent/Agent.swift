import Foundation
import KWAI

/// Listener invoked for every `AgentEvent`. Async listeners are awaited in
/// subscription order before the agent returns to idle, matching pi-agent-core.
public typealias AgentListener = @Sendable (AgentEvent, CancellationHandle?) async -> Void

/// Handle returned from `subscribe`. Call to unsubscribe.
public typealias Unsubscribe = @Sendable () -> Void

public struct AgentInitialState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var tools: [AgentTool]
    public var messages: [Message]

    public init(
        systemPrompt: String = "",
        model: Model,
        thinkingLevel: ThinkingLevel = .off,
        tools: [AgentTool] = [],
        messages: [Message] = []
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
    }
}

public enum AgentError: Error, Equatable {
    case noMessagesToContinue
    case cannotContinueFromRole(String)
    case alreadyRunning
    case listenerOutsideActiveRun
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
    public var thinkingBudgets: ThinkingBudgets?
    public var maxRetryDelayMs: Int?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var convertToLlm: ConvertToLlmHook?
    public var transformContext: TransformContextHook?
    public var apiKeyResolver: (@Sendable (String) async -> String?)?

    public init(
        initialState: AgentInitialState,
        streamFn: StreamFn? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        steeringMode: QueueMode = .oneAtATime,
        followUpMode: QueueMode = .oneAtATime,
        sessionId: String? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        maxRetryDelayMs: Int? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        transformContext: TransformContextHook? = nil,
        apiKeyResolver: (@Sendable (String) async -> String?)? = nil
    ) {
        self.initialState = initialState
        self.streamFn = streamFn
        self.toolExecution = toolExecution
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.sessionId = sessionId
        self.thinkingBudgets = thinkingBudgets
        self.maxRetryDelayMs = maxRetryDelayMs
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.apiKeyResolver = apiKeyResolver
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

    public var sessionId: String?
    public var thinkingBudgets: ThinkingBudgets?
    public var maxRetryDelayMs: Int?
    public var toolExecution: ToolExecutionMode
    public var toolChoice: ToolChoice?
    public var parallelToolCalls: Bool?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var convertToLlm: ConvertToLlmHook?
    public var transformContext: TransformContextHook?
    public var apiKeyResolver: (@Sendable (String) async -> String?)?

    private let steeringQueue: PendingMessageQueue
    private let followUpQueue: PendingMessageQueue

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
            tools: options.initialState.tools,
            messages: options.initialState.messages
        )
        self.streamFn = options.streamFn ?? { model, context, options in
            try await KWAI.stream(model: model, context: context, options: options)
        }
        self.toolExecution = options.toolExecution
        self.toolChoice = options.toolChoice
        self.parallelToolCalls = options.parallelToolCalls
        self.sessionId = options.sessionId
        self.thinkingBudgets = options.thinkingBudgets
        self.maxRetryDelayMs = options.maxRetryDelayMs
        self.beforeToolCall = options.beforeToolCall
        self.afterToolCall = options.afterToolCall
        self.convertToLlm = options.convertToLlm
        self.transformContext = options.transformContext
        self.apiKeyResolver = options.apiKeyResolver
        self.steeringQueue = PendingMessageQueue(mode: options.steeringMode)
        self.followUpQueue = PendingMessageQueue(mode: options.followUpMode)
    }

    /// Queue a message to inject after the current assistant turn finishes.
    public func steer(_ message: Message) { steeringQueue.enqueue(message) }

    /// Queue a message to run only after the agent would otherwise stop.
    public func followUp(_ message: Message) { followUpQueue.enqueue(message) }

    public func clearSteeringQueue() { steeringQueue.clear() }
    public func clearFollowUpQueue() { followUpQueue.clear() }
    public func clearAllQueues() { clearSteeringQueue(); clearFollowUpQueue() }
    public func hasQueuedMessages() -> Bool {
        steeringQueue.hasItems() || followUpQueue.hasItems()
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
        return AgentLoopConfig(
            model: state.model,
            reasoning: state.thinkingLevel == .off ? nil : thinkingLevelToReasoning(state.thinkingLevel),
            thinkingBudgets: thinkingBudgets,
            sessionId: sessionId,
            maxRetryDelayMs: maxRetryDelayMs,
            toolExecution: toolExecution,
            toolChoice: toolChoice,
            parallelToolCalls: parallelToolCalls,
            getSteeringMessages: {
                if skipBox.swapFalse() { return [] }
                return steering.drain()
            },
            getFollowUpMessages: { followUp.drain() },
            apiKeyResolver: apiKeyResolver,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall,
            convertToLlm: convertToLlm,
            transformContext: transformContext
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
        for listener in listeners {
            await listener(.agentEnd(messages: [.assistant(failure)]), cancellation)
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
