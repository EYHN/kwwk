import Foundation
import KWWKAI

/// Configuration for one invocation of the agent loop. Mirrors a subset of
/// pi-agent-core's AgentLoopConfig — the fields we currently wire through.
public struct AgentLoopConfig: Sendable {
    public var model: Model
    public var reasoning: ReasoningLevel?
    public var thinkingBudgets: ThinkingBudgets?
    public var sessionId: String?
    public var verboseEnabled: Bool
    public var maxRetryDelayMs: Int?
    public var toolExecution: ToolExecutionMode
    public var toolChoice: ToolChoice?
    public var parallelToolCalls: Bool?
    // Hard ceiling on assistant turns per run. Mirrors the SDK's
    // `max_turns` — prevents runaway tool-loops from burning budget.
    // Nil = unlimited.
    public var maxTurns: Int?
    // Base delay for exponential backoff between stream retries. Prod
    // defaults to 1_000 ms; tests override to something small.
    public var retryBaseDelayMs: UInt64
    public var getSteeringMessages: @Sendable () async -> [Message]
    public var getFollowUpMessages: @Sendable () async -> [Message]
    public var authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var userPromptSubmit: UserPromptSubmitHook?
    public var convertToLlm: ConvertToLlmHook?
    public var transformContext: TransformContextHook?
    public var betweenTurns: BetweenTurnsHook?

    public init(
        model: Model,
        reasoning: ReasoningLevel? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        sessionId: String? = nil,
        verboseEnabled: Bool = false,
        maxRetryDelayMs: Int? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        maxTurns: Int? = nil,
        retryBaseDelayMs: UInt64 = 1_000,
        getSteeringMessages: @escaping @Sendable () async -> [Message] = { [] },
        getFollowUpMessages: @escaping @Sendable () async -> [Message] = { [] },
        authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        userPromptSubmit: UserPromptSubmitHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        transformContext: TransformContextHook? = nil,
        betweenTurns: BetweenTurnsHook? = nil
    ) {
        self.model = model
        self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets
        self.sessionId = sessionId
        self.verboseEnabled = verboseEnabled
        self.maxRetryDelayMs = maxRetryDelayMs
        self.toolExecution = toolExecution
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.maxTurns = maxTurns
        self.retryBaseDelayMs = retryBaseDelayMs
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.authResolver = authResolver
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.userPromptSubmit = userPromptSubmit
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.betweenTurns = betweenTurns
    }
}

public typealias AgentEventSink = @Sendable (AgentEvent) async -> Void

/// A snapshot of the agent's context at the start of a run. The loop copies
/// these arrays before mutating so the caller's state is never aliased.
public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [Message]
    public var tools: [AgentTool]

    public init(systemPrompt: String, messages: [Message], tools: [AgentTool]) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

/// Stateless loop driver. `Agent` wraps this with state management, cancellation,
/// and subscription fan-out.
public enum AgentLoop {

    /// Run the loop for a fresh prompt. Mirrors pi-agent-core's `runAgentLoop`.
    public static func run(
        prompts: [Message],
        context: AgentContext,
        config: AgentLoopConfig,
        emit: @escaping AgentEventSink,
        cancellation: CancellationHandle?,
        streamFn: @escaping StreamFn
    ) async throws {
        var currentContext = context
        // Run every user prompt through the UserPromptSubmit hook
        // before it enters context. Blocked messages are silently
        // dropped; modified replacements take the original's place
        // so downstream emit/append sees the sanitized version.
        var effectivePrompts: [Message] = []
        for prompt in prompts {
            if case .user(let u) = prompt {
                if let kept = await applyUserPromptSubmitHook(
                    message: u,
                    context: currentContext,
                    config: config,
                    cancellation: cancellation
                ) {
                    effectivePrompts.append(.user(kept))
                }
            } else {
                effectivePrompts.append(prompt)
            }
        }
        currentContext.messages.append(contentsOf: effectivePrompts)

        await emit(.agentStart)
        await emit(.turnStart)
        for prompt in effectivePrompts {
            await emit(.messageStart(message: prompt))
            await emit(.messageEnd(message: prompt))
        }

        try await runLoop(
            currentContext: &currentContext,
            firstTurn: false,
            config: config,
            cancellation: cancellation,
            emit: emit,
            streamFn: streamFn
        )
    }

    /// Apply the user-prompt-submit hook. Returns nil if the hook
    /// blocked the message, otherwise the (possibly modified) message
    /// to append to the transcript.
    private static func applyUserPromptSubmitHook(
        message: UserMessage,
        context: AgentContext,
        config: AgentLoopConfig,
        cancellation: CancellationHandle?
    ) async -> UserMessage? {
        guard let hook = config.userPromptSubmit else { return message }
        let ctx = UserPromptSubmitContext(message: message, context: context)
        guard let result = await hook(ctx, cancellation) else { return message }
        if result.block { return nil }
        return result.modifiedMessage ?? message
    }

    /// Continue an existing transcript. Mirrors `runAgentLoopContinue`.
    public static func runContinue(
        context: AgentContext,
        config: AgentLoopConfig,
        emit: @escaping AgentEventSink,
        cancellation: CancellationHandle?,
        streamFn: @escaping StreamFn
    ) async throws {
        guard !context.messages.isEmpty else {
            throw AgentError.noMessagesToContinue
        }
        let last = context.messages.last!
        if case .assistant = last {
            throw AgentError.cannotContinueFromRole(last.role.rawValue)
        }

        var currentContext = context
        await emit(.agentStart)
        await emit(.turnStart)

        try await runLoop(
            currentContext: &currentContext,
            firstTurn: false,
            config: config,
            cancellation: cancellation,
            emit: emit,
            streamFn: streamFn
        )
    }

    // MARK: - Shared inner loop

    private static func runLoop(
        currentContext: inout AgentContext,
        firstTurn initialFirstTurn: Bool,
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        emit: @escaping AgentEventSink,
        streamFn: @escaping StreamFn
    ) async throws {
        // Single source of truth: `currentContext.messages` is the running
        // transcript used both for the request body and the agentEnd payload.
        // We snapshot its length here so the delta emitted at agentEnd is
        // exactly the messages appended inside this run (prompts passed to
        // `run()` were already appended before we got here — they are part of
        // the "prior" context, not the "new" delta, which matches how the
        // original parallel-array version behaved).
        var baseCount = currentContext.messages.count
        func delta() -> [Message] {
            guard currentContext.messages.count >= baseCount else {
                return currentContext.messages
            }
            return Array(currentContext.messages[baseCount...])
        }

        // Run-level telemetry accumulated into `AgentRunSummary` and
        // emitted on `agentEnd`. Usage fields are additive across every
        // assistant turn; `finalStopReason` tracks the last turn's
        // reason so consumers can branch on "stopped normally" vs
        // "errored out". The start timestamp is captured in ms so we
        // can report wall-clock duration without keeping a Date around.
        let runStartMs = Timestamp.now()
        var summary = AgentRunSummary()
        func finalize(_ reason: StopReason?) -> AgentRunSummary {
            var s = summary
            s.durationMs = Int(Timestamp.now() - runStartMs)
            s.finalStopReason = reason ?? s.finalStopReason
            s.cost = calculateCost(model: config.model, usage: s.usage)
            return s
        }
        func accumulate(_ assistant: AssistantMessage) {
            summary.turns += 1
            summary.usage.input += assistant.usage.input
            summary.usage.output += assistant.usage.output
            summary.usage.cacheRead += assistant.usage.cacheRead
            summary.usage.cacheWrite += assistant.usage.cacheWrite
            summary.usage.totalTokens += assistant.usage.totalTokens
            summary.finalStopReason = assistant.stopReason
        }

        var firstTurn = initialFirstTurn
        var pendingMessages = await config.getSteeringMessages()
        // Count assistant turns actually executed (post-stream). Checked
        // against `config.maxTurns` right before each streaming call so
        // the cap applies to what the API *would* see, not the loop head.
        var turnsExecuted = 0

        outer: while true {
            var hasMoreToolCalls = true

            while hasMoreToolCalls || !pendingMessages.isEmpty {
                if !firstTurn {
                    await emit(.turnStart)
                } else {
                    firstTurn = false
                }

                if !pendingMessages.isEmpty {
                    for message in pendingMessages {
                        // Route user messages through the submit hook
                        // the same way `run()` does for initial prompts,
                        // so steering / follow-up injections get the
                        // same redaction / block semantics.
                        if case .user(let u) = message {
                            guard let kept = await applyUserPromptSubmitHook(
                                message: u,
                                context: currentContext,
                                config: config,
                                cancellation: cancellation
                            ) else { continue }
                            let msg = Message.user(kept)
                            await emit(.messageStart(message: msg))
                            await emit(.messageEnd(message: msg))
                            currentContext.messages.append(msg)
                        } else {
                            await emit(.messageStart(message: message))
                            await emit(.messageEnd(message: message))
                            currentContext.messages.append(message)
                        }
                    }
                    pendingMessages = []
                }

                if let cap = config.maxTurns, turnsExecuted >= cap {
                    // Synthesize an error assistant message so the
                    // transcript surfaces a clear "turn cap reached"
                    // line instead of silently returning.
                    let capped = AssistantMessage(
                        content: [],
                        api: config.model.api,
                        provider: config.model.provider,
                        model: config.model.id,
                        stopReason: .error,
                        errorMessage: "Maximum turn limit (\(cap)) reached",
                        timestamp: Timestamp.now()
                    )
                    // The capped message is synthetic — it never hit
                    // the provider, so don't bump `turns` or usage.
                    // Just record the stop reason for the summary.
                    summary.finalStopReason = .error
                    await emit(.messageStart(message: .assistant(capped)))
                    await emit(.messageEnd(message: .assistant(capped)))
                    currentContext.messages.append(.assistant(capped))
                    await emit(.turnEnd(message: .assistant(capped), toolResults: []))
                    await emit(.agentEnd(messages: delta(), summary: finalize(.error)))
                    return
                }

                let assistant = try await streamAssistantResponse(
                    context: &currentContext,
                    config: config,
                    cancellation: cancellation,
                    emit: emit,
                    streamFn: streamFn
                )
                // Append to the in-loop context BEFORE running tools, so the
                // next turn's request body carries the assistant turn
                // (including any tool_use / function_call items) right in
                // front of the upcoming tool_result / function_call_output.
                // Providers like OpenAI Responses and Anthropic Messages
                // enforce that ordering.
                currentContext.messages.append(.assistant(assistant))
                turnsExecuted += 1
                accumulate(assistant)

                if assistant.stopReason == .error || assistant.stopReason == .aborted {
                    await emit(.turnEnd(message: .assistant(assistant), toolResults: []))
                    await emit(.agentEnd(messages: delta(), summary: finalize(nil)))
                    return
                }

                let toolCalls = assistant.content.compactMap { block -> ToolCall? in
                    if case .toolCall(let tc) = block { return tc } else { return nil }
                }
                hasMoreToolCalls = !toolCalls.isEmpty

                var toolResults: [ToolResultMessage] = []
                if hasMoreToolCalls {
                    toolResults = await executeToolCalls(
                        currentContext: currentContext,
                        assistantMessage: assistant,
                        toolCalls: toolCalls,
                        mode: config.toolExecution,
                        config: config,
                        cancellation: cancellation,
                        emit: emit
                    )
                    for result in toolResults {
                        currentContext.messages.append(.toolResult(result))
                        if let subagent = subagentRunSummary(from: result) {
                            summary.subagents.append(subagent)
                        }
                    }
                }

                await emit(.turnEnd(message: .assistant(assistant), toolResults: toolResults))

                // Between-turn hook: the auto-compact driver injects a
                // summarized transcript here so the next LLM call
                // doesn't carry the full pre-compact history. Runs
                // synchronously — the loop blocks until it returns,
                // which is exactly what we want for "compact is a
                // blocking state".
                if let hook = config.betweenTurns {
                    let beforeHookCount = currentContext.messages.count
                    if let replacement = await hook(currentContext, cancellation) {
                        currentContext = replacement
                        if currentContext.messages.count < baseCount ||
                           currentContext.messages.count < beforeHookCount {
                            baseCount = 0
                        }
                    }
                }

                // If the user aborted during tool execution, bail before the
                // next LLM turn — otherwise we'd re-enter streaming with a
                // cancelled handle and burn a round trip to discover it.
                if cancellation?.isCancelled == true {
                    let aborted = AssistantMessage(
                        content: [],
                        api: config.model.api,
                        provider: config.model.provider,
                        model: config.model.id,
                        stopReason: .aborted,
                        errorMessage: "Request was aborted",
                        timestamp: Timestamp.now()
                    )
                    summary.finalStopReason = .aborted
                    await emit(.messageStart(message: .assistant(aborted)))
                    await emit(.messageEnd(message: .assistant(aborted)))
                    // `aborted` is not appended to currentContext — preserving
                    // the prior behavior where the synthetic abort message is
                    // surfaced via messageEnd but not part of the agent-end
                    // delta or the transcript.
                    await emit(.agentEnd(messages: delta(), summary: finalize(.aborted)))
                    return
                }

                pendingMessages = await config.getSteeringMessages()
            }

            let followUps = await config.getFollowUpMessages()
            if !followUps.isEmpty {
                pendingMessages = followUps
                continue outer
            }
            break
        }

        await emit(.agentEnd(messages: delta(), summary: finalize(nil)))
    }

    // MARK: - Stream assistant response

    private static let maxRetries = 5

    private static func isRetryableError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("timeout")
            || lower.contains("network")
            || lower.contains("connection")
            || lower.contains("429")
            || lower.contains("rate limit")
            || lower.contains("too many requests")
            || lower.contains("502")
            || lower.contains("503")
            || lower.contains("504")
            || lower.contains("internal server error")
            || lower.contains("service unavailable")
            || lower.contains("bad gateway")
            || lower.contains("gateway timeout")
    }

    private static func streamAssistantResponse(
        context: inout AgentContext,
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        emit: @escaping AgentEventSink,
        streamFn: @escaping StreamFn
    ) async throws -> AssistantMessage {
        var messages = context.messages
        if let transform = config.transformContext {
            messages = await transform(messages, cancellation)
        }
        if let convert = config.convertToLlm {
            messages = await convert(messages)
        }
        let llmContext = Context(
            systemPrompt: context.systemPrompt,
            messages: messages,
            tools: context.tools.map { $0.toKWAITool() }
        )

        let resolvedAuth = await config.authResolver?(config.model, config.sessionId)
        var requestModel = config.model
        if let baseURL = resolvedAuth?.baseURL, !baseURL.isEmpty {
            requestModel.baseUrl = baseURL
        }
        let mergedMetadata: [String: JSONValue]? = {
            guard let authMetadata = resolvedAuth?.metadata, !authMetadata.isEmpty else { return nil }
            return authMetadata
        }()
        let options = StreamOptions(
            apiKey: resolvedAuth?.token,
            cacheRetention: nil,
            sessionId: config.sessionId,
            maxRetryDelayMs: config.maxRetryDelayMs,
            metadata: mergedMetadata,
            resolvedAuth: resolvedAuth,
            reasoning: config.reasoning,
            thinkingBudgets: config.thinkingBudgets,
            cancellation: cancellation,
            toolChoice: config.toolChoice,
            parallelToolCalls: config.parallelToolCalls,
            verbose: config.verboseEnabled,
            onVerbose: { event in
                await emit(.verbose(event))
            }
        )

        var lastError: Error?

        for attempt in 0..<maxRetries {
            if cancellation?.isCancelled == true {
                throw AgentError.aborted
            }

            do {
                let response = try await streamFn(requestModel, llmContext, options)

                // Live-stream events as they arrive so the UI shows tokens
                // in real time. A retryable mid-stream error emits
                // `streamRewind` below, which the UI treats as "discard
                // whatever partial you rendered for this turn"; the retry
                // then produces a fresh `messageStart` and updates. Older
                // code buffered everything until the stream ended — it
                // avoided retry-rendered-text ghosts but killed visible
                // streaming entirely.
                var emittedStart = false
                for await event in response {
                    switch event {
                    case .start(let partial):
                        if !emittedStart {
                            await emit(.messageStart(message: .assistant(partial)))
                            emittedStart = true
                        }
                        await emit(.messageUpdate(message: partial, assistantMessageEvent: event))

                    case .textStart(_, let partial),
                         .textDelta(_, _, let partial),
                         .textEnd(_, _, let partial),
                         .thinkingStart(_, let partial),
                         .thinkingDelta(_, _, let partial),
                         .thinkingEnd(_, _, let partial),
                         .toolCallStart(_, let partial),
                         .toolCallDelta(_, _, let partial),
                         .toolCallEnd(_, _, let partial):
                        if !emittedStart {
                            await emit(.messageStart(message: .assistant(partial)))
                            emittedStart = true
                        }
                        await emit(.messageUpdate(message: partial, assistantMessageEvent: event))

                    case .done, .error:
                        // Final settlement is handled after the loop via
                        // `response.result()`. These marker events carry no
                        // additional partial we haven't already shown.
                        break
                    }
                }
                let final = await response.result()

                // Retry on stream-level errors that look transient. Ask the
                // UI to drop the partial render first so the retried stream
                // doesn't paint over a corrupted frame.
                if final.stopReason == .error,
                   let msg = final.errorMessage,
                   isRetryableError(msg),
                   attempt < maxRetries - 1 {
                    if emittedStart {
                        await emit(.streamRewind)
                    }
                    let delayMs = min(config.retryBaseDelayMs * (1 << attempt), 30_000)
                    await emit(.streamRetry(attempt: attempt, delayMs: delayMs, reason: msg))
                    // Sleep in 100ms increments so an Esc press (abort)
                    // cuts through the backoff instead of waiting out the
                    // full 30s exponential cap.
                    let tickMs: UInt64 = 100
                    var remainingMs = delayMs
                    while remainingMs > 0 {
                        if cancellation?.isCancelled == true { throw AgentError.aborted }
                        let step = min(remainingMs, tickMs)
                        try? await Task.sleep(nanoseconds: step * 1_000_000)
                        remainingMs -= step
                    }
                    lastError = AgentError.maxRetriesExceeded
                    continue
                }

                if !emittedStart {
                    await emit(.messageStart(message: .assistant(final)))
                }
                await emit(.messageEnd(message: .assistant(final)))
                return final

            } catch {
                lastError = error
                let reason = "\(error)"
                if isRetryableError(reason), attempt < maxRetries - 1 {
                    let delayMs = min(config.retryBaseDelayMs * (1 << attempt), 30_000)
                    await emit(.streamRetry(attempt: attempt, delayMs: delayMs, reason: reason))
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    continue
                }
                throw error
            }
        }

        throw lastError ?? AgentError.maxRetriesExceeded
    }

    // MARK: - Tool execution

    private static func executeToolCalls(
        currentContext: AgentContext,
        assistantMessage: AssistantMessage,
        toolCalls: [ToolCall],
        mode: ToolExecutionMode,
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        emit: @escaping AgentEventSink
    ) async -> [ToolResultMessage] {
        switch mode {
        case .sequential:
            return await executeSequential(
                currentContext: currentContext,
                assistantMessage: assistantMessage,
                toolCalls: toolCalls,
                config: config,
                cancellation: cancellation,
                emit: emit
            )
        case .parallel:
            return await executeParallel(
                currentContext: currentContext,
                assistantMessage: assistantMessage,
                toolCalls: toolCalls,
                config: config,
                cancellation: cancellation,
                emit: emit
            )
        }
    }

    private static func executeSequential(
        currentContext: AgentContext,
        assistantMessage: AssistantMessage,
        toolCalls: [ToolCall],
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        emit: @escaping AgentEventSink
    ) async -> [ToolResultMessage] {
        var out: [ToolResultMessage] = []
        for call in toolCalls {
            await emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, args: call.arguments))
            let prep = await prepareToolCall(
                context: currentContext,
                assistantMessage: assistantMessage,
                toolCall: call,
                config: config,
                cancellation: cancellation
            )
            switch prep {
            case .immediate(let result, let isError):
                out.append(await finalize(
                    call: call,
                    assistantMessage: assistantMessage,
                    args: call.arguments,
                    context: currentContext,
                    outcome: ExecutedOutcome(result: result, isError: isError),
                    config: config,
                    cancellation: cancellation,
                    emit: emit
                ))
            case .prepared(let prepared):
                let executed = await executePrepared(prepared, cancellation: cancellation, emit: emit)
                out.append(await finalize(
                    call: call,
                    assistantMessage: assistantMessage,
                    args: prepared.args,
                    context: currentContext,
                    outcome: executed,
                    config: config,
                    cancellation: cancellation,
                    emit: emit
                ))
            }
        }
        return out
    }

    private static func executeParallel(
        currentContext: AgentContext,
        assistantMessage: AssistantMessage,
        toolCalls: [ToolCall],
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        emit: @escaping AgentEventSink
    ) async -> [ToolResultMessage] {
        enum Run {
            case immediate(ToolCall, AgentToolResult, Bool)
            case prepared(PreparedToolCall)
        }
        var runs: [Run] = []
        for call in toolCalls {
            await emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, args: call.arguments))
            let prep = await prepareToolCall(
                context: currentContext,
                assistantMessage: assistantMessage,
                toolCall: call,
                config: config,
                cancellation: cancellation
            )
            switch prep {
            case .immediate(let res, let isError): runs.append(.immediate(call, res, isError))
            case .prepared(let p): runs.append(.prepared(p))
            }
        }

        let runningTasks: [(id: String, task: Task<ExecutedOutcome, Never>)] = runs.compactMap { run in
            if case .prepared(let p) = run {
                let t = Task.detached { () -> ExecutedOutcome in
                    await executePrepared(p, cancellation: cancellation, emit: emit)
                }
                return (p.call.id, t)
            }
            return nil
        }

        var taskResults: [String: ExecutedOutcome] = [:]
        for entry in runningTasks {
            taskResults[entry.id] = await entry.task.value
        }

        var results: [ToolResultMessage] = []
        for run in runs {
            switch run {
            case .immediate(let call, let res, let isError):
                results.append(await finalize(
                    call: call,
                    assistantMessage: assistantMessage,
                    args: call.arguments,
                    context: currentContext,
                    outcome: ExecutedOutcome(result: res, isError: isError),
                    config: config,
                    cancellation: cancellation,
                    emit: emit
                ))
            case .prepared(let p):
                if let executed = taskResults[p.call.id] {
                    results.append(await finalize(
                        call: p.call,
                        assistantMessage: assistantMessage,
                        args: p.args,
                        context: currentContext,
                        outcome: executed,
                        config: config,
                        cancellation: cancellation,
                        emit: emit
                    ))
                }
            }
        }
        return results
    }

    // MARK: - Tool execution helpers

    private struct PreparedToolCall: Sendable {
        let call: ToolCall
        let tool: AgentTool
        let args: JSONValue
    }

    private struct ExecutedOutcome: Sendable {
        let result: AgentToolResult
        let isError: Bool
    }

    private enum ToolPreparation {
        case immediate(AgentToolResult, Bool)
        case prepared(PreparedToolCall)
    }

    private static func prepareToolCall(
        context: AgentContext,
        assistantMessage: AssistantMessage,
        toolCall: ToolCall,
        config: AgentLoopConfig,
        cancellation: CancellationHandle?
    ) async -> ToolPreparation {
        guard let tool = context.tools.first(where: { $0.name == toolCall.name }) else {
            return .immediate(errorToolResult("Tool \(toolCall.name) not found"), true)
        }
        let args: JSONValue
        do {
            let kwaiTool = tool.toKWAITool()
            args = try validateToolArguments(tool: kwaiTool, toolCall: toolCall)
        } catch {
            let msg = (error as? JSONSchemaError)?.description ?? "\(error)"
            return .immediate(errorToolResult(msg), true)
        }

        var effectiveArgs = args
        if let before = config.beforeToolCall {
            let ctx = BeforeToolCallContext(
                assistantMessage: assistantMessage,
                toolCall: toolCall,
                args: args,
                context: context
            )
            if let result = await before(ctx, cancellation) {
                if result.block {
                    return .immediate(
                        errorToolResult(result.reason ?? "Tool execution was blocked"),
                        true
                    )
                }
                // Hook rewrote the input — propagate the new args into
                // execution and finalize so the tool body + after-hook
                // see the sanitized version. `toolExecutionStart` has
                // already fired with the LLM's original args (callers
                // who care about the diff can read `args` on the after-
                // hook context or the toolExecutionEnd event).
                if let rewritten = result.modifiedArgs {
                    effectiveArgs = rewritten
                }
            }
        }
        return .prepared(PreparedToolCall(call: toolCall, tool: tool, args: effectiveArgs))
    }

    private static func executePrepared(
        _ prepared: PreparedToolCall,
        cancellation: CancellationHandle?,
        emit: @escaping AgentEventSink
    ) async -> ExecutedOutcome {
        let emitBox = EmitBox(emit: emit)
        let onUpdate: AgentToolUpdate = { @Sendable partial in
            let call = prepared.call
            emitBox.launchUpdate(.toolExecutionUpdate(
                toolCallId: call.id,
                toolName: call.name,
                args: call.arguments,
                partialResult: partial
            ))
            for runtimeEvent in partial.runtimeEvents ?? [] {
                emitBox.launchUpdate(.runtimeEvent(runtimeEvent))
            }
        }
        do {
            let result = try await prepared.tool.execute(prepared.call.id, prepared.args, cancellation, onUpdate)
            await emitBox.waitForPending()
            return ExecutedOutcome(result: result, isError: false)
        } catch {
            await emitBox.waitForPending()
            let message: String
            if error is CancellationError || (error as? CodingToolError) == .aborted {
                message = "aborted by user"
            } else {
                message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            if let structured = error as? StructuredToolExecutionError {
                return ExecutedOutcome(
                    result: errorToolResult(
                        message,
                        details: structured.details,
                        runtimeEvents: structured.runtimeEvents
                    ),
                    isError: true
                )
            }
            return ExecutedOutcome(result: errorToolResult(message), isError: true)
        }
    }

    private static func finalize(
        call: ToolCall,
        assistantMessage: AssistantMessage,
        args: JSONValue,
        context: AgentContext,
        outcome: ExecutedOutcome,
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        emit: @escaping AgentEventSink
    ) async -> ToolResultMessage {
        var final = outcome.result
        var isError = outcome.isError

        if let after = config.afterToolCall {
            let ctx = AfterToolCallContext(
                assistantMessage: assistantMessage,
                toolCall: call,
                args: args,
                result: final,
                isError: isError,
                context: context
            )
            if let override = await after(ctx, cancellation) {
                if let content = override.content { final.content = content }
                if let details = override.details { final.details = details }
                if let errFlag = override.isError { isError = errFlag }
            }
        }

        await emit(.toolExecutionEnd(
            toolCallId: call.id,
            toolName: call.name,
            result: final,
            isError: isError
        ))
        for runtimeEvent in final.runtimeEvents ?? [] {
            await emit(.runtimeEvent(runtimeEvent))
        }
        let message = ToolResultMessage(
            toolCallId: call.id,
            toolName: call.name,
            content: final.content,
            details: final.details,
            isError: isError
        )
        await emit(.messageStart(message: .toolResult(message)))
        await emit(.messageEnd(message: .toolResult(message)))
        return message
    }

    private static func errorToolResult(
        _ text: String,
        details: JSONValue? = nil,
        runtimeEvents: [AgentRuntimeEvent]? = nil
    ) -> AgentToolResult {
        AgentToolResult(
            content: [.text(TextContent(text: text))],
            details: details,
            runtimeEvents: runtimeEvents
        )
    }

    private static func subagentRunSummary(from result: ToolResultMessage) -> SubagentRunSummary? {
        guard result.toolName == "agent",
              case .object(let details) = result.details ?? .null,
              let subagentType = stringValue(details["subagent_type"]) else {
            return nil
        }
        let statusRaw = stringValue(details["status"]) ?? (result.isError ? "failed" : "")
        let status: SubagentRunStatus
        switch statusRaw {
        case "completed":
            status = .completed
        case "background_started":
            status = .backgroundStarted
        case "failed":
            status = .failed
        default:
            status = result.isError ? .failed : .completed
        }
        return SubagentRunSummary(
            subagentType: subagentType,
            childSessionId: stringValue(details["child_session_id"]),
            description: stringValue(details["description"]),
            status: status,
            model: stringValue(details["model"]),
            stopReason: stringValue(details["stop_reason"]).flatMap(StopReason.init(rawValue:)),
            usage: usageValue(details["usage"]),
            turns: intValue(details["turns"]),
            cost: costValue(details["cost"]),
            durationMs: intValue(details["duration_ms"]),
            backgroundTaskId: stringValue(details["task_id"]),
            outputFile: stringValue(details["output_file"]),
            errorMessage: stringValue(details["error_message"])
        )
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let string) = value ?? .null else { return nil }
        return string
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        guard case .int(let int) = value ?? .null else { return nil }
        return int
    }

    private static func doubleValue(_ value: JSONValue?) -> Double? {
        switch value ?? .null {
        case .double(let double): return double
        case .int(let int): return Double(int)
        default: return nil
        }
    }

    private static func usageValue(_ value: JSONValue?) -> Usage? {
        guard case .object(let object) = value ?? .null else { return nil }
        return Usage(
            input: intValue(object["input"]) ?? 0,
            output: intValue(object["output"]) ?? 0,
            cacheRead: intValue(object["cache_read"]) ?? 0,
            cacheWrite: intValue(object["cache_write"]) ?? 0,
            totalTokens: intValue(object["total_tokens"]) ?? 0
        )
    }

    private static func costValue(_ value: JSONValue?) -> Cost? {
        guard case .object(let object) = value ?? .null else { return nil }
        return Cost(
            input: doubleValue(object["input"]) ?? 0,
            output: doubleValue(object["output"]) ?? 0,
            cacheRead: doubleValue(object["cache_read"]) ?? 0,
            cacheWrite: doubleValue(object["cache_write"]) ?? 0,
            total: doubleValue(object["total"]) ?? 0
        )
    }
}

/// Tracks in-flight tool_execution_update emits so parallel tool execution can
/// wait for them before emitting tool_execution_end (matching pi-agent-core's
/// `Promise.all(updateEvents)` semantics).
private final class EmitBox: @unchecked Sendable {
    private let emit: AgentEventSink
    private let lock = NSLock()
    private var pending: [Task<Void, Never>] = []

    init(emit: @escaping AgentEventSink) {
        self.emit = emit
    }

    func launchUpdate(_ event: AgentEvent) {
        let emit = self.emit
        let task = Task { await emit(event) }
        lock.withLock { pending.append(task) }
    }

    func waitForPending() async {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            let out = pending
            pending.removeAll()
            return out
        }
        for task in tasks {
            _ = await task.value
        }
    }
}

extension AgentTool {
    /// Convert to the Tool struct that KWAI's streaming providers consume.
    func toKWAITool() -> Tool {
        Tool(name: name, description: description, parameters: parameters)
    }
}
