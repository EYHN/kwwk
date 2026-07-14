import Foundation
import KWWKAI

/// Configuration for one invocation of the agent loop. Mirrors a subset of
/// pi-agent-core's AgentLoopConfig — the fields we currently wire through.
public struct AgentLoopConfig: Sendable {
    public var model: Model
    public var reasoning: ReasoningLevel?
    public var thinkingBudgets: ThinkingBudgets?
    public var sessionId: String?
    /// Workspace root reported to providers with a server-driven harness
    /// (Cursor's requestContext env). Nil = don't report one.
    public var cwd: String?
    public var verboseEnabled: Bool
    public var maxRetryDelayMs: Int?
    public var toolExecution: ToolExecutionMode
    public var toolChoice: ToolChoice?
    public var parallelToolCalls: Bool?
    // Hard ceiling on assistant turns per run. Mirrors the SDK's
    // `max_turns` — prevents runaway tool-loops from burning budget.
    // Nil = unlimited.
    public var maxTurns: Int?
    /// Internal subagent mode: reserve the last permitted provider turn for
    /// synthesis by hiding tools and requiring a text response. The ordinary
    /// Agent SDK keeps its existing hard-cap behavior unless explicitly
    /// enabled by the subagent runner.
    var finalTextOnlyOnLastTurn: Bool = false
    /// Internal completion contract used by subagents. A successful call to
    /// this tool is the only terminal success signal. Natural provider stops
    /// receive bounded runtime reminders instead of being mistaken for a
    /// completed delegated task.
    var terminalToolName: String?
    var terminalToolReminderLimit: Int = 0
    // Base delay for exponential backoff between stream retries. Prod
    // defaults to 1_000 ms; tests override to something small.
    public var retryBaseDelayMs: UInt64
    public var getRuntimeMessages: @Sendable () async -> [Message]
    public var getSteeringMessages: @Sendable () async -> [Message]
    public var hasSteeringMessages: @Sendable () -> Bool
    public var getFollowUpMessages: @Sendable () async -> [Message]
    public var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var userPromptSubmit: UserPromptSubmitHook?
    public var convertToLlm: ConvertToLlmHook?
    public var transformContext: TransformContextHook?
    public var betweenTurns: BetweenTurnsHook?
    public var contextCompaction: ContextCompactionHook?

    public init(
        model: Model,
        reasoning: ReasoningLevel? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        sessionId: String? = nil,
        cwd: String? = nil,
        verboseEnabled: Bool = false,
        maxRetryDelayMs: Int? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        maxTurns: Int? = nil,
        retryBaseDelayMs: UInt64 = 1_000,
        getRuntimeMessages: @escaping @Sendable () async -> [Message] = { [] },
        getSteeringMessages: @escaping @Sendable () async -> [Message] = { [] },
        hasSteeringMessages: @escaping @Sendable () -> Bool = { false },
        getFollowUpMessages: @escaping @Sendable () async -> [Message] = { [] },
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        userPromptSubmit: UserPromptSubmitHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        transformContext: TransformContextHook? = nil,
        betweenTurns: BetweenTurnsHook? = nil,
        contextCompaction: ContextCompactionHook? = nil
    ) {
        self.model = model
        self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets
        self.sessionId = sessionId
        self.cwd = cwd
        self.verboseEnabled = verboseEnabled
        self.maxRetryDelayMs = maxRetryDelayMs
        self.toolExecution = toolExecution
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.maxTurns = maxTurns
        self.retryBaseDelayMs = retryBaseDelayMs
        self.getRuntimeMessages = getRuntimeMessages
        self.getSteeringMessages = getSteeringMessages
        self.hasSteeringMessages = hasSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.authResolver = authResolver
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.userPromptSubmit = userPromptSubmit
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.betweenTurns = betweenTurns
        self.contextCompaction = contextCompaction
    }
}

public typealias AgentEventSink = @Sendable (AgentEvent) async -> Void

private let multipleTaskPollsCancellationReason = "multiple-task-polls"

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
            if case .user(let u) = prompt, u.source != .runtime {
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

        // Commit the submitted prompts before the first cancellable provider
        // operation. In particular, automatic compaction can take seconds and
        // throw on cancellation; emitting first keeps direct submissions and
        // messages drained by `Agent.continue()` in Agent.state / session
        // persistence even when that preflight is aborted.
        await emit(.agentStart)
        await emit(.turnStart)
        for prompt in effectivePrompts {
            await emit(.messageStart(message: prompt))
            await emit(.messageEnd(message: prompt))
        }

        // `run()` already emitted the run's first `turnStart` above; enter the
        // loop with `firstTurn: true` so the first iteration consumes it
        // instead of emitting a duplicate. Matches pi-agent-core's semantics.
        try await runLoop(
            currentContext: &currentContext,
            firstTurn: true,
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

        // `firstTurn: true` — the `turnStart` just emitted stands in for the
        // loop's first iteration, so exactly one `turnStart` precedes the turn.
        try await runLoop(
            currentContext: &currentContext,
            firstTurn: true,
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
        // `run()` were already appended before we got here and were emitted as
        // ordinary message events). A request-level preflight replacement
        // resets this to zero below so the public hook's only observable copy
        // of the replacement is not omitted from `agentEnd`.
        var baseCount = currentContext.messages.count
        var replacementDeltaPrefix: [Message] = []
        func delta() -> [Message] {
            guard currentContext.messages.count >= baseCount else {
                return replacementDeltaPrefix + currentContext.messages
            }
            return replacementDeltaPrefix + currentContext.messages[baseCount...]
        }
        func unansweredRequestSuffix(in messages: [Message]) -> [Message] {
            // Mirrors CompactionPlanner's protection rule: only the trailing
            // run of user messages is unanswered input a replacement must keep
            // verbatim. An unanswered tool exchange is deliberately excluded —
            // the planner summarizes an over-budget in-flight turn into the
            // recap (that is how provider-overflow recovery shrinks a huge
            // tool result), so re-appending it here would duplicate content
            // the recap already covers and desync the loop from Agent.state,
            // which the built-in hook has already committed to.
            var start = messages.count
            while start > 0, case .user = messages[start - 1] {
                start -= 1
            }
            return Array(messages[start...])
        }
        func applyCompactionReplacement(_ replacement: AgentContext) {
            let previousMessages = currentContext.messages
            let protectedSuffix = unansweredRequestSuffix(in: previousMessages)
            var merged = replacement
            if !protectedSuffix.isEmpty,
               Array(merged.messages.suffix(protectedSuffix.count)) != protectedSuffix {
                merged.messages.append(contentsOf: protectedSuffix)
            }

            let messagesChanged = merged.messages != previousMessages
            currentContext = merged
            guard messagesChanged else { return }

            // Replacement content must be visible in agentEnd, while prompts
            // already published via messageEnd must not be reported twice.
            replacementDeltaPrefix = Array(
                merged.messages.dropLast(protectedSuffix.count)
            )
            baseCount = merged.messages.count
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
        var pendingMessages = await config.getRuntimeMessages()
        pendingMessages += await config.getSteeringMessages()
        // Count assistant turns actually executed (post-stream). Checked
        // against `config.maxTurns` right before each streaming call so
        // the cap applies to what the API *would* see, not the loop head.
        var turnsExecuted = 0
        var terminalRemindersSent = 0
        var forceTerminalTool = false

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
                        if case .user(let u) = message, u.source != .runtime {
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
                    summary.reachedMaxTurns = true
                    await emit(.messageStart(message: .assistant(capped)))
                    await emit(.messageEnd(message: .assistant(capped)))
                    currentContext.messages.append(.assistant(capped))
                    await emit(.turnEnd(message: .assistant(capped), toolResults: []))
                    await emit(.agentEnd(messages: delta(), summary: finalize(.error)))
                    return
                }

                if let compact = config.contextCompaction {
                    if let replacement = try await compact(
                        currentContext,
                        .preflight(pendingMessages: []),
                        cancellation
                    ) {
                        applyCompactionReplacement(replacement)
                    }
                }

                let finalTextOnly = config.finalTextOnlyOnLastTurn
                    && config.maxTurns.map { turnsExecuted == $0 - 1 } == true
                let terminalToolOnly = finalTextOnly || forceTerminalTool
                var cursorResults = CursorToolResultBox()
                var turnToolState = TurnToolExecutionState()
                var streamedAssistant: AssistantMessage?
                var overflowRecoveryAttempted = false

                while streamedAssistant == nil {
                    cursorResults = CursorToolResultBox()
                    turnToolState = TurnToolExecutionState()
                    do {
                        streamedAssistant = try await streamAssistantResponse(
                            context: &currentContext,
                            config: config,
                            finalTextOnly: finalTextOnly,
                            terminalToolOnly: terminalToolOnly,
                            cancellation: cancellation,
                            emit: emit,
                            streamFn: streamFn,
                            cursorResults: cursorResults,
                            turnToolState: turnToolState
                        )
                    } catch let overflow as ProviderContextOverflow {
                        if !overflowRecoveryAttempted,
                           let compact = config.contextCompaction {
                            do {
                                if let replacement = try await compact(
                                    currentContext,
                                    .providerOverflow,
                                    cancellation
                                ) {
                                    if overflow.emittedStart {
                                        await emit(.streamRewind)
                                    }
                                    turnToolState.rollbackAllLeases()
                                    applyCompactionReplacement(replacement)
                                    overflowRecoveryAttempted = true
                                    continue
                                }
                            } catch is CancellationError {
                                throw AgentError.aborted
                            } catch AgentContextCompactionError.cancelled {
                                throw AgentError.aborted
                            } catch let error as AgentError where error == .aborted {
                                throw error
                            } catch {
                                if cancellation?.isCancelled == true || Task.isCancelled {
                                    throw AgentError.aborted
                                }
                            }
                        }

                        if !overflow.emittedStart {
                            await emit(.messageStart(message: .assistant(overflow.assistant)))
                        }
                        await emit(.messageEnd(message: .assistant(overflow.assistant)))
                        streamedAssistant = overflow.assistant
                    }
                }
                let assistant = streamedAssistant!
                // Append to the in-loop context BEFORE running tools, so the
                // next turn's request body carries the assistant turn
                // (including any tool_use / function_call items) right in
                // front of the upcoming tool_result / function_call_output.
                // Providers like OpenAI Responses and Anthropic Messages
                // enforce that ordering.
                currentContext.messages.append(.assistant(assistant))
                turnsExecuted += 1
                accumulate(assistant)

                // Tool results the Cursor provider executed inline over its exec
                // channel land right after the assistant message, pairing with
                // the `cursorExecResolved` toolCall blocks inside it.
                let inlineResults = cursorResults.drain()
                for result in inlineResults {
                    // Cursor executed this while the assistant was streaming.
                    // Emit/persist the result only now, after its paired
                    // assistant tool-call message has been retained.
                    await emit(.messageStart(message: .toolResult(result)))
                    await emit(.messageEnd(message: .toolResult(result)))
                    currentContext.messages.append(.toolResult(result))
                    turnToolState.commitLease(for: result.toolCallId)
                }

                if assistant.stopReason == .error || assistant.stopReason == .aborted {
                    await emit(.turnEnd(message: .assistant(assistant), toolResults: inlineResults))
                    await emit(.agentEnd(messages: delta(), summary: finalize(nil)))
                    return
                }

                if assistant.stopReason == .length {
                    var truncatedResults = inlineResults
                    let unresolvedCalls = assistant.content.compactMap { block -> ToolCall? in
                        guard case .toolCall(let call) = block,
                              call.cursorExecResolved != true else {
                            return nil
                        }
                        return call
                    }
                    for call in unresolvedCalls {
                        let result = ToolResultMessage(
                            toolCallId: call.id,
                            toolName: call.name,
                            content: [.text(TextContent(
                                text: "Tool call was not executed because the assistant response was truncated."
                            ))],
                            isError: true
                        )
                        await emit(.messageStart(message: .toolResult(result)))
                        await emit(.messageEnd(message: .toolResult(result)))
                        currentContext.messages.append(.toolResult(result))
                        truncatedResults.append(result)
                    }
                    await emit(.turnEnd(
                        message: .assistant(assistant),
                        toolResults: truncatedResults
                    ))
                    await emit(.agentEnd(messages: delta(), summary: finalize(.length)))
                    return
                }

                // Skip calls the Cursor provider already resolved inline — the
                // results are in `inlineResults`; running them again would
                // duplicate side effects.
                let emittedToolCalls = assistant.content.compactMap { block -> ToolCall? in
                    guard case .toolCall(let tc) = block, tc.cursorExecResolved != true else { return nil }
                    return tc
                }
                // A terminal tool is a transaction boundary, not an ordinary
                // member of a parallel batch. Keep every emitted call here so
                // `executeToolCalls` can reject the *whole* malformed batch and
                // still publish one paired error result per call. Filtering out
                // siblings would silently drop their results and, on ordinary
                // turns, used to let them execute beside a successful yield.
                let toolCalls = emittedToolCalls
                if finalTextOnly,
                   let terminalToolName = config.terminalToolName,
                   (toolCalls.count != 1 || toolCalls.first?.name != terminalToolName) {
                    summary.reachedMaxTurns = true
                }
                hasMoreToolCalls = !toolCalls.isEmpty

                var toolResults: [ToolResultMessage] = inlineResults
                if hasMoreToolCalls {
                    let executed = await executeToolCalls(
                        currentContext: currentContext,
                        assistantMessage: assistant,
                        toolCalls: toolCalls,
                        mode: config.toolExecution,
                        config: config,
                        terminalToolOnly: terminalToolOnly,
                        cancellation: cancellation,
                        turnToolState: turnToolState,
                        emit: emit
                    )
                    toolResults += executed
                    for result in executed {
                        currentContext.messages.append(.toolResult(result))
                        turnToolState.commitLease(for: result.toolCallId)
                        if let subagent = subagentRunSummary(from: result) {
                            summary.subagents.append(subagent)
                        }
                    }
                }

                // Defensive rollback for a tool result that failed to make it
                // into either retained result list.
                turnToolState.rollbackAllLeases()

                await emit(.turnEnd(message: .assistant(assistant), toolResults: toolResults))

                let terminalToolSucceeded = config.terminalToolName.map { terminalToolName in
                    toolResults.contains {
                        $0.toolName == terminalToolName && !$0.isError
                    }
                } ?? false
                if terminalToolSucceeded {
                    await emit(.agentEnd(messages: delta(), summary: finalize(.stop)))
                    return
                }

                if config.terminalToolName != nil, !hasMoreToolCalls {
                    if finalTextOnly {
                        summary.reachedMaxTurns = true
                        await emit(.agentEnd(messages: delta(), summary: finalize(.error)))
                        return
                    }
                    let reminderLimit = max(0, config.terminalToolReminderLimit)
                    if terminalRemindersSent < reminderLimit {
                        terminalRemindersSent += 1
                        forceTerminalTool = terminalRemindersSent == reminderLimit
                        pendingMessages = [terminalToolReminder(
                            toolName: config.terminalToolName!,
                            isFinal: forceTerminalTool
                        )]
                        continue
                    }
                    await emit(.agentEnd(messages: delta(), summary: finalize(nil)))
                    return
                }
                if hasMoreToolCalls {
                    terminalRemindersSent = 0
                    forceTerminalTool = false
                }

                // A reserved synthesis turn is terminal by definition. Do
                // not let an arriving runtime aside, steer, or follow-up
                // create another iteration that immediately trips the hard
                // cap and overwrites a valid final answer with a synthetic
                // max-turn error. Queued user input remains queued for the
                // parent/session to handle after this child run ends.
                if finalTextOnly {
                    await emit(.agentEnd(messages: delta(), summary: finalize(nil)))
                    return
                }

                // SDK between-turn hooks may replace the context before the
                // next provider step. Automatic compaction has its own single
                // provider-boundary hook above, so this path is user policy.
                if let hook = config.betweenTurns {
                    if let replacement = await hook(currentContext, cancellation) {
                        let messagesChanged = replacement.messages != currentContext.messages
                        currentContext = replacement
                        if messagesChanged {
                            replacementDeltaPrefix = []
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

                pendingMessages = await config.getRuntimeMessages()
                pendingMessages += await config.getSteeringMessages()
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

    /// Whether a stream error looks transient enough to replay the turn.
    /// Ordered like omp's classifier: timeouts always win, then retryable
    /// HTTP statuses, then a validation short-circuit (a permanent 4xx-style
    /// failure must not retry even if it also mentions "connection"), then
    /// transport/overload patterns.
    static func isRetryableError(_ message: String) -> Bool {
        if ContextLimitClassifier.isInputOverflow(message) {
            return false
        }
        let lower = message.lowercased()

        if lower.contains("timeout") || lower.contains("timed out") {
            return true
        }

        for status in ["408", "429", "502", "503", "504", "529"] where lower.contains(status) {
            return true
        }

        for fatal in [
            "invalid", "validation", "bad request", "unsupported", "schema",
            "missing required", "not found", "unauthorized", "forbidden",
        ] where lower.contains(fatal) {
            return false
        }

        // "connect" covers connection/connected/disconnect — including
        // POSIX ENOTCONN's "Socket is not connected", which URLSession
        // surfaces as an NSPOSIXErrorDomain error. "closed before" covers
        // a WebSocket the server dropped mid-response.
        for transient in [
            "network", "connect", "nsposixerrordomain",
            "econnreset", "enotconn", "epipe", "broken pipe", "reset by peer",
            "socket closed", "socket error", "closed before", "closed unexpectedly",
            "rate limit", "too many requests", "overloaded",
            // gRPC-based providers (e.g. NVIDIA NIM) report quota pressure
            // as a ResourceExhausted / RESOURCE_EXHAUSTED status.
            "resourceexhausted", "resource_exhausted", "resource exhausted",
            "internal error", "server error", "service unavailable", "bad gateway",
            "temporarily", "stream stall", "fetch failed",
        ] where lower.contains(transient) {
            return true
        }

        return false
    }

    private static func streamAssistantResponse(
        context: inout AgentContext,
        config: AgentLoopConfig,
        finalTextOnly: Bool,
        terminalToolOnly: Bool,
        cancellation: CancellationHandle?,
        emit: @escaping AgentEventSink,
        streamFn: @escaping StreamFn,
        cursorResults: CursorToolResultBox,
        turnToolState: TurnToolExecutionState
    ) async throws -> AssistantMessage {
        var messages = context.messages
        if let transform = config.transformContext {
            messages = await transform(messages, cancellation)
        }
        if let convert = config.convertToLlm {
            messages = await convert(messages)
        }
        let systemPrompt = terminalToolOnly
            ? appendFinalTurnInstruction(
                to: context.systemPrompt,
                terminalToolName: config.terminalToolName
            )
            : context.systemPrompt
        let availableTools: [Tool]
        if terminalToolOnly, let terminalToolName = config.terminalToolName {
            availableTools = context.tools
                .filter { $0.name == terminalToolName }
                .map { $0.toKWAITool() }
        } else if finalTextOnly {
            availableTools = []
        } else {
            availableTools = context.tools.map { $0.toKWAITool() }
        }
        let llmContext = Context(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: availableTools
        )

        let bridgeContext = context
        let resolvedAuth = try await config.authResolver?(config.model, config.sessionId)
        var requestModel = config.model
        if let baseURL = resolvedAuth?.baseURL, !baseURL.isEmpty {
            requestModel.baseURL = baseURL
        }
        let mergedMetadata: [String: JSONValue]? = {
            guard let authMetadata = resolvedAuth?.metadata, !authMetadata.isEmpty else { return nil }
            return authMetadata
        }()
        var lastError: Error?

        for attemptIndex in 0..<maxRetries {
            if cancellation?.isCancelled == true {
                throw AgentError.aborted
            }

            // A provider retry is a new assistant attempt. Give its inline
            // tools a distinct cancellation domain and bridge so an old Cursor
            // exec task can never append into the next attempt's result box.
            let inlineAttempt = CursorInlineExecutionAttempt(parentCancellation: cancellation)
            let cursorExecBridge: CursorExecBridge? = terminalToolOnly ? nil : CursorExecBridge(cwd: config.cwd) { call in
                guard let attemptCancellation = inlineAttempt.beginInvocation() else {
                    return closedCursorAttemptResult(for: call)
                }
                let result = await executeCursorExec(
                    call: call,
                    context: bridgeContext,
                    config: config,
                    cancellation: attemptCancellation,
                    turnToolState: turnToolState,
                    emit: emit
                )
                let retained = inlineAttempt.finishInvocation {
                    cursorResults.append(result)
                }
                if !retained {
                    turnToolState.rollbackLeases(for: [call.id])
                }
                return result
            }
            let options = StreamOptions(
                apiKey: resolvedAuth?.token,
                cacheRetention: nil,
                sessionId: config.sessionId,
                maxRetryDelayMs: config.maxRetryDelayMs,
                metadata: mergedMetadata,
                resolvedAuth: resolvedAuth,
                // The child already spent earlier turns gathering evidence.
                // On its reserved synthesis turn, extended thinking can
                // consume the entire response and produce stop-without-text
                // (observed with Anthropic). Give the final answer the whole
                // output budget instead.
                reasoning: terminalToolOnly ? nil : config.reasoning,
                thinkingBudgets: terminalToolOnly ? nil : config.thinkingBudgets,
                cancellation: cancellation,
                toolChoice: terminalToolOnly
                    ? config.terminalToolName.map { ToolChoice.tool(name: $0) }
                    : (finalTextOnly ? ToolChoice.none : config.toolChoice),
                parallelToolCalls: terminalToolOnly ? false : config.parallelToolCalls,
                cursorExecBridge: cursorExecBridge,
                verbose: config.verboseEnabled,
                onVerbose: { event in
                    await emit(.verbose(event))
                }
            )

            var emittedStart = false
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

                if requestModel.api != "cursor-agent",
                   final.stopReason == .error,
                   let message = final.errorMessage,
                   ContextLimitClassifier.isInputOverflow(message) {
                    await inlineAttempt.invalidateAndWait(reason: "context-overflow")
                    throw ProviderContextOverflow(
                        assistant: final,
                        emittedStart: emittedStart
                    )
                }

                // Retry on stream-level errors that look transient. Ask the
                // UI to drop the partial render first so the retried stream
                // doesn't paint over a corrupted frame.
                if final.stopReason == .error,
                   let msg = final.errorMessage,
                   isRetryableError(msg),
                   attemptIndex < maxRetries - 1 {
                    await inlineAttempt.invalidateAndWait(reason: "cursor-attempt-retry")
                    // Discard inline Cursor tool results from the rewound
                    // attempt — their toolCall blocks are gone with it, and the
                    // retried stream produces fresh pairs.
                    let discarded = cursorResults.drain()
                    turnToolState.rollbackLeases(for: discarded.map(\.toolCallId))
                    turnToolState.resetPollGateForRetry()
                    if emittedStart {
                        await emit(.streamRewind)
                    }
                    let delayMs = min(config.retryBaseDelayMs * (1 << attemptIndex), 30_000)
                    await emit(.streamRetry(attempt: attemptIndex, delayMs: delayMs, reason: msg))
                    try await waitForRetryDelay(delayMs, cancellation: cancellation)
                    lastError = AgentError.maxRetriesExceeded
                    continue
                }

                await inlineAttempt.sealAndWait()
                if !emittedStart {
                    await emit(.messageStart(message: .assistant(final)))
                }
                await emit(.messageEnd(message: .assistant(final)))
                return final

            } catch {
                await inlineAttempt.invalidateAndWait(reason: "cursor-attempt-error")
                if let overflow = error as? ProviderContextOverflow {
                    let discarded = cursorResults.drain()
                    turnToolState.rollbackLeases(for: discarded.map(\.toolCallId))
                    throw overflow
                }
                lastError = error
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if requestModel.api != "cursor-agent",
                   ContextLimitClassifier.isInputOverflow(reason) {
                    let discarded = cursorResults.drain()
                    turnToolState.rollbackLeases(for: discarded.map(\.toolCallId))
                    let assistant = AssistantMessage(
                        content: [],
                        api: requestModel.api,
                        provider: requestModel.provider,
                        model: requestModel.id,
                        stopReason: .error,
                        errorMessage: reason,
                        timestamp: Timestamp.now()
                    )
                    throw ProviderContextOverflow(
                        assistant: assistant,
                        emittedStart: emittedStart
                    )
                }
                if isRetryableError(reason), attemptIndex < maxRetries - 1 {
                    let discarded = cursorResults.drain()
                    turnToolState.rollbackLeases(for: discarded.map(\.toolCallId))
                    turnToolState.resetPollGateForRetry()
                    let delayMs = min(config.retryBaseDelayMs * (1 << attemptIndex), 30_000)
                    await emit(.streamRetry(attempt: attemptIndex, delayMs: delayMs, reason: reason))
                    try await waitForRetryDelay(delayMs, cancellation: cancellation)
                    continue
                }
                let discarded = cursorResults.drain()
                turnToolState.rollbackLeases(for: discarded.map(\.toolCallId))
                throw error
            }
        }

        throw lastError ?? AgentError.maxRetriesExceeded
    }

    /// Sleep in short increments so cancellation/steering does not disappear
    /// inside a provider retry backoff. Both stream-error and thrown-error retry
    /// paths use this one implementation to keep their abort semantics equal.
    private static func waitForRetryDelay(
        _ delayMs: UInt64,
        cancellation: CancellationHandle?
    ) async throws {
        let tickMs: UInt64 = 100
        var remainingMs = delayMs
        while remainingMs > 0 {
            if cancellation?.isCancelled == true || Task.isCancelled {
                throw AgentError.aborted
            }
            let step = min(remainingMs, tickMs)
            do {
                try await Task.sleep(nanoseconds: step * 1_000_000)
            } catch {
                throw AgentError.aborted
            }
            remainingMs -= step
        }
    }

    private static func appendFinalTurnInstruction(
        to systemPrompt: String?,
        terminalToolName: String?
    ) -> String {
        let instruction: String
        if let terminalToolName {
            instruction = """
            This is your final permitted turn. Do not call any exploration or mutation tools. Call `\(terminalToolName)` exactly once with the best complete result supported by the evidence already gathered. Use status `incomplete` and explain what remains if you cannot deliver the requested result.
            """
        } else {
            instruction = """
            This is your final permitted turn. Do not call tools. Return the best complete final answer you can from the evidence already gathered, and clearly note any uncertainty.
            """
        }
        guard let systemPrompt, !systemPrompt.isEmpty else { return instruction }
        return systemPrompt + "\n\n" + instruction
    }

    private static func terminalToolReminder(toolName: String, isFinal: Bool) -> Message {
        let text: String
        if isFinal {
            text = """
            Your delegated task is not complete until you call `\(toolName)`. This is the final completion reminder: call `\(toolName)` exactly once now. Do not call any other tool. Put the deliverable in `result`; use status `incomplete` and preserve useful evidence if work remains.
            """
        } else {
            text = """
            Your previous response stopped without the required `\(toolName)` completion signal. Continue the task if needed, then call `\(toolName)` exactly once with the deliverable. Do not merely describe what you plan to do next.
            """
        }
        return .user(UserMessage(text: text, source: .runtime))
    }

    // MARK: - Cursor inline exec

    private static func closedCursorAttemptResult(for call: ToolCall) -> ToolResultMessage {
        ToolResultMessage(
            toolCallId: call.id,
            toolName: call.name,
            content: [.text(TextContent(text: "Cursor inline attempt already closed"))],
            isError: true
        )
    }

    /// Execute one tool call on behalf of the Cursor provider's exec channel.
    /// Registered tools run through the same prepare (validation + hooks) /
    /// execute / finalize path as loop-driven calls. Cursor's native `delete`
    /// has no registered counterpart, so its built-in implementation is only
    /// available when the agent explicitly registered file-write capability.
    /// An unregistered native `write` is subject to the same gate; normally it
    /// resolves through kwwk's registered `write` tool above.
    /// Never throws: failures fold into an `isError` result.
    private static func executeCursorExec(
        call: ToolCall,
        context: AgentContext,
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        turnToolState: TurnToolExecutionState,
        emit: @escaping AgentEventSink
    ) async -> ToolResultMessage {
        await emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, args: call.arguments))

        // The hook context wants the surrounding assistant message, which is
        // still streaming — stand in with a placeholder carrying the model
        // coordinates.
        let placeholder = AssistantMessage(
            content: [.toolCall(call)],
            api: config.model.api,
            provider: config.model.provider,
            model: config.model.id
        )

        // Cursor executes MCP calls online before the enclosing assistant
        // message is complete, so the normal whole-batch validator cannot know
        // whether a sibling call will arrive later. Never accept the terminal
        // completion contract through that side channel. Cursor's forced/final
        // turn disables the inline bridge and the unresolved, sole terminal call
        // is then validated and executed by the normal post-stream path.
        if call.name == config.terminalToolName {
            return await finalize(
                call: call,
                assistantMessage: placeholder,
                args: call.arguments,
                context: context,
                outcome: ExecutedOutcome(
                    result: terminalToolBatchError(toolName: call.name),
                    isError: true
                ),
                config: config,
                cancellation: cancellation,
                turnToolState: turnToolState,
                emitMessageEvents: false,
                emit: emit
            )
        }

        // Cursor invokes tools online, before the enclosing assistant message
        // is complete, so the normal batch duplicate scan cannot protect this
        // path. Execute the first id at most once across stream retries and
        // reject every later occurrence before it reaches hooks or tool code.
        guard turnToolState.reserveCursorCallId(call.id) else {
            turnToolState.cancelActiveCursorPoll(matching: call.id)
            return await finalize(
                call: call,
                assistantMessage: placeholder,
                args: call.arguments,
                context: context,
                outcome: ExecutedOutcome(
                    result: duplicateToolCallIdError(call.id),
                    isError: true
                ),
                config: config,
                cancellation: cancellation,
                turnToolState: turnToolState,
                emitMessageEvents: false,
                emit: emit
            )
        }

        if context.tools.contains(where: { $0.name == call.name }) {
            let prep = await prepareToolCall(
                context: context,
                assistantMessage: placeholder,
                toolCall: call,
                config: config,
                cancellation: cancellation,
                turnToolState: turnToolState
            )
            switch prep {
            case .immediate(let result, let isError):
                return await finalize(
                    call: call, assistantMessage: placeholder, args: call.arguments,
                    context: context, outcome: ExecutedOutcome(result: result, isError: isError),
                    config: config, cancellation: cancellation,
                    turnToolState: turnToolState, emitMessageEvents: false, emit: emit
                )
            case .prepared(let prepared):
                var executionCancellation = cancellation
                var cursorPollCancellation: CancellationHandle?
                var cursorPollParentRegistration: CancellationRegistration?
                if isBlockingTaskPoll(prepared) {
                    let pollCancellation = CancellationHandle()
                    let parentRegistration = cancellation?.onCancel { reason in
                        pollCancellation.cancel(reason: reason ?? "aborted")
                    }
                    guard turnToolState.reserveCursorPoll(
                        callId: call.id,
                        cancellation: pollCancellation
                    ) else {
                        parentRegistration?.cancel()
                        return await finalize(
                            call: call, assistantMessage: placeholder, args: prepared.args,
                            context: context,
                            outcome: ExecutedOutcome(
                                result: multipleTaskPollsError(), isError: true
                            ),
                            config: config, cancellation: cancellation,
                            turnToolState: turnToolState, emitMessageEvents: false, emit: emit
                        )
                    }
                    executionCancellation = pollCancellation
                    cursorPollCancellation = pollCancellation
                    cursorPollParentRegistration = parentRegistration
                }
                let executed = await executePrepared(
                    prepared, cancellation: executionCancellation, config: config, emit: emit
                )
                if let cursorPollCancellation {
                    turnToolState.finishCursorPoll(
                        callId: call.id,
                        cancellation: cursorPollCancellation
                    )
                }
                cursorPollParentRegistration?.cancel()
                return await finalize(
                    call: call, assistantMessage: placeholder, args: prepared.args,
                    context: context, outcome: executed,
                    config: config, cancellation: cancellation,
                    turnToolState: turnToolState, emitMessageEvents: false, emit: emit
                )
            }
        }

        var finalizedArgs = call.arguments
        let outcome: ExecutedOutcome
        switch call.name {
        case "write", "delete":
            // Cursor advertises native file tools independently of kwwk's
            // AgentTool list. Never let that provider-side surface expand a
            // read-only/custom agent's whitelist. The registered `write` tool
            // is the explicit opt-in used by `.standard`; registered calls
            // have already taken the normal validation + hook path above.
            guard let writeCapability = context.tools.first(where: {
                $0.codingToolCapabilities.contains(.write)
            }) else {
                outcome = ExecutedOutcome(
                    result: errorToolResult(
                        "Tool \(call.name) is not allowed: this agent has no file-write capability"
                    ),
                    isError: true
                )
                break
            }
            do {
                try JSONSchema.validate(
                    call.arguments,
                    against: builtinFileToolSchema(name: call.name)
                )
            } catch {
                outcome = ExecutedOutcome(
                    result: errorToolResult(schemaValidationMessage(error)),
                    isError: true
                )
                break
            }
            var effectiveArgs = call.arguments
            var blocked: String?
            if let before = config.beforeToolCall {
                let ctx = BeforeToolCallContext(
                    assistantMessage: placeholder, toolCall: call,
                    args: call.arguments, context: context
                )
                if let result = await before(ctx, cancellation) {
                    if result.block {
                        blocked = result.reason ?? "Tool execution was blocked"
                    } else if let rewritten = result.modifiedArgs {
                        do {
                            try JSONSchema.validate(
                                rewritten,
                                against: builtinFileToolSchema(name: call.name)
                            )
                            effectiveArgs = rewritten
                        } catch {
                            blocked = schemaValidationMessage(error)
                        }
                    }
                }
            }
            if let blocked {
                outcome = ExecutedOutcome(result: errorToolResult(blocked), isError: true)
            } else {
                do {
                    guard case .object(var object) = effectiveArgs,
                          case .string(let path) = object["path"] ?? .null else {
                        throw CodingToolError.invalidArgument("\(call.name): `path` is required")
                    }
                    let authorizedPath = try PathUtils.resolveForAccess(
                        path,
                        cwd: writeCapability.fileAccessCwd
                            ?? config.cwd
                            ?? FileManager.default.currentDirectoryPath,
                        policy: writeCapability.fileAccessPolicy ?? .unrestricted,
                        intent: .write
                    )
                    object["path"] = .string(authorizedPath)
                    effectiveArgs = .object(object)
                    finalizedArgs = effectiveArgs
                    outcome = executeBuiltinFileTool(name: call.name, args: effectiveArgs)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    outcome = ExecutedOutcome(result: errorToolResult(message), isError: true)
                }
            }
        default:
            outcome = ExecutedOutcome(
                result: errorToolResult("Tool \(call.name) not found"), isError: true
            )
        }
        return await finalize(
            call: call, assistantMessage: placeholder, args: finalizedArgs,
            context: context, outcome: outcome,
            config: config, cancellation: cancellation,
            turnToolState: turnToolState, emitMessageEvents: false, emit: emit
        )
    }

    /// Built-in `write` (`{path, content}`) and `delete` (`{path}`) used only
    /// for Cursor's native exec tools.
    private static func builtinFileToolSchema(name: String) -> JSONValue {
        var properties: [String: JSONValue] = [
            "path": .object(["type": .string("string")]),
        ]
        var required: [JSONValue] = [.string("path")]
        if name == "write" {
            properties["content"] = .object(["type": .string("string")])
            required.append(.string("content"))
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required),
        ])
    }

    private static func executeBuiltinFileTool(name: String, args: JSONValue) -> ExecutedOutcome {
        guard case .object(let obj) = args, case .string(let path)? = obj["path"], !path.isEmpty else {
            return ExecutedOutcome(result: errorToolResult("\(name): `path` is required"), isError: true)
        }
        let url = URL(fileURLWithPath: path)
        do {
            switch name {
            case "write":
                guard case .string(let content)? = obj["content"] else {
                    return ExecutedOutcome(result: errorToolResult("write: `content` is required"), isError: true)
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(content.utf8).write(to: url)
                return ExecutedOutcome(
                    result: AgentToolResult(content: [.text(TextContent(
                        text: "Wrote \(content.utf8.count) bytes to \(path)"
                    ))]),
                    isError: false
                )
            default:
                try FileManager.default.removeItem(at: url)
                return ExecutedOutcome(
                    result: AgentToolResult(content: [.text(TextContent(text: "Deleted \(path)"))]),
                    isError: false
                )
            }
        } catch {
            return ExecutedOutcome(result: errorToolResult("\(error)"), isError: true)
        }
    }

    // MARK: - Tool execution

    private static func executeToolCalls(
        currentContext: AgentContext,
        assistantMessage: AssistantMessage,
        toolCalls: [ToolCall],
        mode: ToolExecutionMode,
        config: AgentLoopConfig,
        terminalToolOnly: Bool,
        cancellation: CancellationHandle?,
        turnToolState: TurnToolExecutionState,
        emit: @escaping AgentEventSink
    ) async -> [ToolResultMessage] {
        var seenCallIds: Set<String> = []
        var duplicateCallIds: Set<String> = []
        for call in toolCalls where !seenCallIds.insert(call.id).inserted {
            duplicateCallIds.insert(call.id)
        }
        duplicateCallIds.formUnion(turnToolState.cursorCallIds(in: seenCallIds))
        let rejectedTerminalCallIds: Set<String> = {
            guard let terminalToolName = config.terminalToolName else { return [] }
            let terminalCount = toolCalls.lazy.filter { $0.name == terminalToolName }.count
            let hasTerminalBoundary = terminalToolOnly || terminalCount > 0
            guard hasTerminalBoundary,
                  toolCalls.count != 1 || terminalCount != 1 else {
                return []
            }
            return Set(toolCalls.map(\.id))
        }()
        // A model can emit several tool calls in one assistant message. Two
        // independent blocking polls would recreate the wait-all barrier this
        // tool is designed to avoid, so enforce one poll at runtime. The
        // one call may watch every relevant id. If the model emits more than
        // one, reject the entire poll set immediately; running the first could
        // still strand the turn on a slow id that appeared separately from a
        // fast one. Every call still receives a paired tool result.
        // Prepare actual task tools up front so schema validation and
        // `beforeToolCall` rewrites are part of the classification. Other tools
        // retain their existing just-in-time sequential behavior.
        var preparedTaskCalls: [String: ToolPreparation] = [:]
        for call in toolCalls {
            guard !duplicateCallIds.contains(call.id) else { continue }
            guard !rejectedTerminalCallIds.contains(call.id) else { continue }
            guard currentContext.tools.first(where: { $0.name == call.name })?
                .isBackgroundTaskTool == true else { continue }
            preparedTaskCalls[call.id] = await prepareToolCall(
                context: currentContext,
                assistantMessage: assistantMessage,
                toolCall: call,
                config: config,
                cancellation: cancellation,
                turnToolState: turnToolState
            )
        }
        let pollCallIds = preparedTaskCalls.compactMap { id, preparation -> String? in
            guard case .prepared(let prepared) = preparation,
                  isBlockingTaskPoll(prepared) else { return nil }
            return id
        }
        var rejectedPollCallIds = turnToolState.rejectedNormalPollCallIds(pollCallIds)
        let pollCallIdSet = Set(pollCallIds)
        let hasNonPollSibling = !pollCallIds.isEmpty && toolCalls.contains { call in
            !duplicateCallIds.contains(call.id) && !pollCallIdSet.contains(call.id)
        }
        if hasNonPollSibling {
            // A steered poll can return immediately, but a non-interruptible
            // sibling would still keep the assistant turn open. Reject the
            // entire mixed batch before execution; the model can reissue the
            // non-poll work separately without recreating a wait-all barrier.
            rejectedPollCallIds.formUnion(toolCalls.map(\.id))
        }
        switch mode {
        case .sequential:
            return await executeSequential(
                currentContext: currentContext,
                assistantMessage: assistantMessage,
                toolCalls: toolCalls,
                config: config,
                cancellation: cancellation,
                preparedTaskCalls: preparedTaskCalls,
                rejectedPollCallIds: rejectedPollCallIds,
                rejectedTerminalCallIds: rejectedTerminalCallIds,
                duplicateCallIds: duplicateCallIds,
                turnToolState: turnToolState,
                emit: emit
            )
        case .parallel:
            return await executeParallel(
                currentContext: currentContext,
                assistantMessage: assistantMessage,
                toolCalls: toolCalls,
                config: config,
                cancellation: cancellation,
                preparedTaskCalls: preparedTaskCalls,
                rejectedPollCallIds: rejectedPollCallIds,
                rejectedTerminalCallIds: rejectedTerminalCallIds,
                duplicateCallIds: duplicateCallIds,
                turnToolState: turnToolState,
                emit: emit
            )
        }
    }

    private static func isBlockingTaskPoll(_ prepared: PreparedToolCall) -> Bool {
        prepared.tool.isBackgroundTaskTool && taskRequestWillPoll(prepared.args)
    }

    private static func multipleTaskPollsError() -> AgentToolResult {
        errorToolResult(
            "Multiple task polls, or a blocking task poll batched with another tool call, are rejected. Make one poll containing every task id and issue it alone."
        )
    }

    private static func terminalToolBatchError(toolName: String) -> AgentToolResult {
        errorToolResult(
            "Terminal tool `\(toolName)` must be the only tool call in its assistant turn. The complete batch was rejected without executing any call.",
            details: .object([
                "error": .string("invalid_terminal_tool_batch"),
                "terminal_tool": .string(toolName),
            ])
        )
    }

    private static func duplicateToolCallIdError(_ id: String) -> AgentToolResult {
        errorToolResult(
            "Duplicate tool call id '\(id)' in one assistant turn is rejected; every call must have a unique id.",
            details: .object([
                "error": .string("duplicate_tool_call_id"),
                "tool_call_id": .string(id),
            ])
        )
    }

    private static func executeSequential(
        currentContext: AgentContext,
        assistantMessage: AssistantMessage,
        toolCalls: [ToolCall],
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        preparedTaskCalls: [String: ToolPreparation],
        rejectedPollCallIds: Set<String>,
        rejectedTerminalCallIds: Set<String>,
        duplicateCallIds: Set<String>,
        turnToolState: TurnToolExecutionState,
        emit: @escaping AgentEventSink
    ) async -> [ToolResultMessage] {
        var out: [ToolResultMessage] = []
        for call in toolCalls {
            await emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, args: call.arguments))
            let prep: ToolPreparation
            if rejectedTerminalCallIds.contains(call.id) {
                prep = .immediate(
                    terminalToolBatchError(toolName: config.terminalToolName ?? call.name),
                    true
                )
            } else if duplicateCallIds.contains(call.id) {
                prep = .immediate(duplicateToolCallIdError(call.id), true)
            } else if rejectedPollCallIds.contains(call.id) {
                prep = .immediate(multipleTaskPollsError(), true)
            } else if let prepared = preparedTaskCalls[call.id] {
                prep = prepared
            } else {
                prep = await prepareToolCall(
                    context: currentContext,
                    assistantMessage: assistantMessage,
                    toolCall: call,
                    config: config,
                    cancellation: cancellation,
                    turnToolState: turnToolState
                )
            }
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
                    turnToolState: turnToolState,
                    emit: emit
                ))
            case .prepared(let prepared):
                let executed = await executePrepared(
                    prepared, cancellation: cancellation, config: config, emit: emit
                )
                out.append(await finalize(
                    call: call,
                    assistantMessage: assistantMessage,
                    args: prepared.args,
                    context: currentContext,
                    outcome: executed,
                    config: config,
                    cancellation: cancellation,
                    turnToolState: turnToolState,
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
        preparedTaskCalls: [String: ToolPreparation],
        rejectedPollCallIds: Set<String>,
        rejectedTerminalCallIds: Set<String>,
        duplicateCallIds: Set<String>,
        turnToolState: TurnToolExecutionState,
        emit: @escaping AgentEventSink
    ) async -> [ToolResultMessage] {
        enum Run {
            case immediate(ToolCall, AgentToolResult, Bool)
            case prepared(PreparedToolCall)
        }
        var runs: [Run] = []
        for call in toolCalls {
            await emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, args: call.arguments))
            let prep: ToolPreparation
            if rejectedTerminalCallIds.contains(call.id) {
                prep = .immediate(
                    terminalToolBatchError(toolName: config.terminalToolName ?? call.name),
                    true
                )
            } else if duplicateCallIds.contains(call.id) {
                prep = .immediate(duplicateToolCallIdError(call.id), true)
            } else if rejectedPollCallIds.contains(call.id) {
                prep = .immediate(multipleTaskPollsError(), true)
            } else if let prepared = preparedTaskCalls[call.id] {
                prep = prepared
            } else {
                prep = await prepareToolCall(
                    context: currentContext,
                    assistantMessage: assistantMessage,
                    toolCall: call,
                    config: config,
                    cancellation: cancellation,
                    turnToolState: turnToolState
                )
            }
            switch prep {
            case .immediate(let res, let isError): runs.append(.immediate(call, res, isError))
            case .prepared(let p): runs.append(.prepared(p))
            }
        }

        // Execute *and finalize* each call in its own task. Finalization emits
        // toolExecutionEnd, runtime lifecycle events, and after-tool hooks, so
        // keeping it outside this task used to make a fast completion (or an
        // immediate quota error) look "running" until the slowest sibling
        // finished. Model-visible tool-result messages are still published
        // below in source order to preserve provider transcript invariants.
        var finalizationTasks: [(index: Int, task: Task<ToolResultMessage, Never>)] = []
        for (index, run) in runs.enumerated() {
            let task: Task<ToolResultMessage, Never>
            switch run {
            case .immediate(let call, let result, let isError):
                task = Task.detached {
                    await finalize(
                        call: call,
                        assistantMessage: assistantMessage,
                        args: call.arguments,
                        context: currentContext,
                        outcome: ExecutedOutcome(result: result, isError: isError),
                        config: config,
                        cancellation: cancellation,
                        turnToolState: turnToolState,
                        emitMessageEvents: false,
                        emit: emit
                    )
                }
            case .prepared(let prepared):
                task = Task.detached {
                    let executed = await executePrepared(
                        prepared,
                        cancellation: cancellation,
                        config: config,
                        emit: emit
                    )
                    return await finalize(
                        call: prepared.call,
                        assistantMessage: assistantMessage,
                        args: prepared.args,
                        context: currentContext,
                        outcome: executed,
                        config: config,
                        cancellation: cancellation,
                        turnToolState: turnToolState,
                        emitMessageEvents: false,
                        emit: emit
                    )
                }
            }
            finalizationTasks.append((index, task))
        }

        var orderedResults = Array<ToolResultMessage?>(repeating: nil, count: runs.count)
        for entry in finalizationTasks {
            orderedResults[entry.index] = await entry.task.value
        }
        let results = orderedResults.compactMap { $0 }
        for result in results {
            await emit(.messageStart(message: .toolResult(result)))
            await emit(.messageEnd(message: .toolResult(result)))
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
        cancellation: CancellationHandle?,
        turnToolState: TurnToolExecutionState
    ) async -> ToolPreparation {
        guard let tool = context.tools.first(where: { $0.name == toolCall.name }) else {
            return .immediate(errorToolResult("Tool \(toolCall.name) not found"), true)
        }
        if let configuredMax = tool.maxCallsPerTurn {
            let maxCalls = max(0, configuredMax)
            let configuredKey = tool.turnLimitKey?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let limitKey = configuredKey.flatMap { $0.isEmpty ? nil : $0 } ?? tool.name
            if !turnToolState.reserveLimitedCall(
                callId: toolCall.id,
                key: limitKey,
                maxCalls: maxCalls
            ) {
                return .immediate(
                    turnCallLimitError(toolName: tool.name, key: limitKey, maxCalls: maxCalls),
                    true
                )
            }
        }
        let kwaiTool = tool.toKWAITool()
        let args: JSONValue
        do {
            args = try validateToolArguments(tool: kwaiTool, toolCall: toolCall)
        } catch {
            return .immediate(errorToolResult(schemaValidationMessage(error)), true)
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
                    var rewrittenCall = toolCall
                    rewrittenCall.arguments = rewritten
                    do {
                        effectiveArgs = try validateToolArguments(
                            tool: kwaiTool,
                            toolCall: rewrittenCall
                        )
                    } catch {
                        return .immediate(
                            errorToolResult(schemaValidationMessage(error)),
                            true
                        )
                    }
                }
            }
        }
        return .prepared(PreparedToolCall(call: toolCall, tool: tool, args: effectiveArgs))
    }

    private static func schemaValidationMessage(_ error: Error) -> String {
        (error as? JSONSchemaError)?.description ?? "\(error)"
    }

    private static func turnCallLimitError(
        toolName: String,
        key: String,
        maxCalls: Int
    ) -> AgentToolResult {
        errorToolResult(
            "Tool \(toolName) exceeded its per-turn call limit of \(maxCalls); "
                + "additional calls in this assistant turn are rejected.",
            details: .object([
                "error": .string("turn_call_limit_exceeded"),
                "tool": .string(toolName),
                "limit_key": .string(key),
                "max_calls_per_turn": .int(maxCalls),
            ])
        )
    }

    private static func executePrepared(
        _ prepared: PreparedToolCall,
        cancellation: CancellationHandle?,
        config: AgentLoopConfig,
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
        let effectiveCancellation: CancellationHandle?
        let parentRegistration: CancellationRegistration?
        let steeringMonitor: Task<Void, Never>?
        if prepared.tool.interruptible {
            let child = CancellationHandle()
            parentRegistration = cancellation?.onCancel { reason in
                child.cancel(reason: reason ?? "aborted")
            }
            let hasSteeringMessages = config.hasSteeringMessages
            steeringMonitor = Task.detached {
                while !Task.isCancelled && !child.isCancelled {
                    if hasSteeringMessages() {
                        child.cancel(reason: "steering")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            effectiveCancellation = child
        } else {
            effectiveCancellation = cancellation
            parentRegistration = nil
            steeringMonitor = nil
        }
        defer {
            steeringMonitor?.cancel()
            parentRegistration?.cancel()
        }

        do {
            let result = try await prepared.tool.execute(
                prepared.call.id, prepared.args, effectiveCancellation, onUpdate
            )
            await emitBox.waitForPending()
            return ExecutedOutcome(result: result, isError: false)
        } catch {
            await emitBox.waitForPending()
            if effectiveCancellation?.reason == multipleTaskPollsCancellationReason {
                return ExecutedOutcome(result: multipleTaskPollsError(), isError: true)
            }
            let message: String
            if error is CancellationError || (error as? CodingToolError) == .aborted {
                message = "aborted by user"
            } else {
                message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            if let structured = error as? StructuredToolExecutionError {
                return ExecutedOutcome(
                    result: AgentToolResult(
                        content: structured.content ?? [.text(TextContent(text: message))],
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
        turnToolState: TurnToolExecutionState,
        emitMessageEvents: Bool = true,
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
        if let lease = final.retentionLease {
            turnToolState.trackLease(lease, for: call.id)
        }
        if emitMessageEvents {
            await emit(.messageStart(message: .toolResult(message)))
            await emit(.messageEnd(message: .toolResult(message)))
        }
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

/// Collects tool results the Cursor provider produced inline during a stream,
/// drained by the loop right after the assistant message is appended so the
/// transcript reads (assistant with resolved toolCall blocks) → results.
final class CursorToolResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ToolResultMessage] = []

    func append(_ result: ToolResultMessage) {
        lock.withLock { results.append(result) }
    }

    func drain() -> [ToolResultMessage] {
        lock.withLock {
            let out = results
            results.removeAll()
            return out
        }
    }
}

/// Owns every Cursor inline execution started by one provider stream attempt.
/// Invalidating an attempt stops accepting calls, cancels its child tool
/// signal, and waits until all calls have either been discarded or appended to
/// that same attempt's result box.
private final class CursorInlineExecutionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation = CancellationHandle()
    private var parentRegistration: CancellationRegistration?
    private var acceptingInvocations = true
    private var retainResults = true
    private var activeInvocations = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(parentCancellation: CancellationHandle?) {
        let child = cancellation
        parentRegistration = parentCancellation?.onCancel { reason in
            child.cancel(reason: reason ?? "aborted")
        }
    }

    deinit {
        cancellation.cancel(reason: "cursor-attempt-deinit")
        parentRegistration?.cancel()
    }

    func beginInvocation() -> CancellationHandle? {
        lock.withLock {
            guard acceptingInvocations else { return nil }
            activeInvocations += 1
            return cancellation
        }
    }

    /// `retain` runs while the attempt lock is held, before the active count is
    /// decremented. Therefore invalidation cannot finish/drain the result box
    /// and then have a late invocation append behind it.
    func finishInvocation(_ retain: () -> Void) -> Bool {
        var waiters: [CheckedContinuation<Void, Never>] = []
        let retained = lock.withLock { () -> Bool in
            let shouldRetain = retainResults
            if shouldRetain { retain() }
            activeInvocations = max(0, activeInvocations - 1)
            if activeInvocations == 0 {
                waiters = idleWaiters
                idleWaiters.removeAll()
            }
            return shouldRetain
        }
        for waiter in waiters { waiter.resume() }
        return retained
    }

    func invalidateAndWait(reason: String) async {
        lock.withLock {
            acceptingInvocations = false
            retainResults = false
        }
        cancellation.cancel(reason: reason)
        await waitUntilIdle()
        parentRegistration?.cancel()
        parentRegistration = nil
    }

    func sealAndWait() async {
        lock.withLock { acceptingInvocations = false }
        await waitUntilIdle()
        parentRegistration?.cancel()
        parentRegistration = nil
    }

    private func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if activeInvocations == 0 { return true }
                idleWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Per-assistant-turn coordination for blocking polls and side-channel result
/// delivery. Cursor may execute tools concurrently while its assistant message
/// is still streaming, so this state is shared by both inline and normal paths.
private final class TurnToolExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var sawBlockingPoll = false
    private var activeCursorPoll: (callId: String, cancellation: CancellationHandle)?
    private var cursorCallIds: Set<String> = []
    private var duplicateCursorCallIds: Set<String> = []
    private var limitedCallIds: [String: Set<String>] = [:]
    private var leases: [String: AgentToolRetentionLease] = [:]

    deinit {
        rollbackAllLeases()
    }

    func reserveCursorCallId(_ callId: String) -> Bool {
        lock.withLock {
            guard cursorCallIds.insert(callId).inserted else {
                duplicateCursorCallIds.insert(callId)
                return false
            }
            return true
        }
    }

    func cursorCallIds(in candidates: Set<String>) -> Set<String> {
        lock.withLock { candidates.intersection(cursorCallIds) }
    }

    func cancelActiveCursorPoll(matching callId: String) {
        let cancellation = lock.withLock { () -> CancellationHandle? in
            guard activeCursorPoll?.callId == callId else { return nil }
            return activeCursorPoll?.cancellation
        }
        cancellation?.cancel(reason: multipleTaskPollsCancellationReason)
    }

    func reserveCursorPoll(callId: String, cancellation: CancellationHandle) -> Bool {
        var pollToCancel: CancellationHandle?
        let accepted = lock.withLock {
            guard !duplicateCursorCallIds.contains(callId) else {
                pollToCancel = activeCursorPoll?.cancellation
                return false
            }
            guard !sawBlockingPoll else {
                pollToCancel = activeCursorPoll?.cancellation
                return false
            }
            sawBlockingPoll = true
            activeCursorPoll = (callId, cancellation)
            return true
        }
        // A later Cursor inline poll must not merely fail itself while the
        // first one keeps the provider stream open. Cancel the first outside
        // the lock so cancellation listeners can safely re-enter loop state.
        pollToCancel?.cancel(reason: multipleTaskPollsCancellationReason)
        return accepted
    }

    func finishCursorPoll(callId: String, cancellation: CancellationHandle) {
        lock.withLock {
            guard activeCursorPoll?.callId == callId,
                  activeCursorPoll?.cancellation === cancellation else { return }
            activeCursorPoll = nil
        }
    }

    func rejectedNormalPollCallIds(_ callIds: [String]) -> Set<String> {
        let ids = Set(callIds)
        guard !ids.isEmpty else { return [] }
        return lock.withLock {
            if sawBlockingPoll || ids.count > 1 {
                sawBlockingPoll = true
                return ids
            }
            sawBlockingPoll = true
            return []
        }
    }

    func resetPollGateForRetry() {
        // Poll attempts are allowed to retry, but semantic tool-call quotas are
        // deliberately not reset. Reusing the same call id remains idempotent;
        // genuinely new calls from a retried stream still consume the original
        // assistant turn's allowance.
        lock.withLock {
            sawBlockingPoll = false
            activeCursorPoll = nil
        }
    }

    func reserveLimitedCall(callId: String, key: String, maxCalls: Int) -> Bool {
        lock.withLock {
            var ids = limitedCallIds[key, default: []]
            // A retry/duplicate is another real execution attempt. Never let
            // an untrusted repeated id make that attempt quota-free.
            if ids.contains(callId) { return false }
            guard ids.count < maxCalls else { return false }
            ids.insert(callId)
            limitedCallIds[key] = ids
            return true
        }
    }

    func trackLease(_ lease: AgentToolRetentionLease, for toolCallId: String) {
        let replaced = lock.withLock { leases.updateValue(lease, forKey: toolCallId) }
        replaced?.rollback()
    }

    func commitLease(for toolCallId: String) {
        let lease = lock.withLock { leases.removeValue(forKey: toolCallId) }
        lease?.commit()
    }

    func rollbackLeases(for toolCallIds: [String]) {
        let rolledBack = lock.withLock { () -> [AgentToolRetentionLease] in
            toolCallIds.compactMap { leases.removeValue(forKey: $0) }
        }
        for lease in rolledBack { lease.rollback() }
    }

    func rollbackAllLeases() {
        let rolledBack = lock.withLock { () -> [AgentToolRetentionLease] in
            let all = Array(leases.values)
            leases.removeAll()
            return all
        }
        for lease in rolledBack { lease.rollback() }
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
