import Foundation
import KWAI

/// Configuration for one invocation of the agent loop. Mirrors a subset of
/// pi-agent-core's AgentLoopConfig — the fields we currently wire through.
public struct AgentLoopConfig: Sendable {
    public var model: Model
    public var reasoning: ReasoningLevel?
    public var thinkingBudgets: ThinkingBudgets?
    public var sessionId: String?
    public var maxRetryDelayMs: Int?
    public var toolExecution: ToolExecutionMode
    public var toolChoice: ToolChoice?
    public var parallelToolCalls: Bool?
    public var getSteeringMessages: @Sendable () async -> [Message]
    public var getFollowUpMessages: @Sendable () async -> [Message]
    public var apiKeyResolver: (@Sendable (String) async -> String?)?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var convertToLlm: ConvertToLlmHook?
    public var transformContext: TransformContextHook?

    public init(
        model: Model,
        reasoning: ReasoningLevel? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        sessionId: String? = nil,
        maxRetryDelayMs: Int? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        getSteeringMessages: @escaping @Sendable () async -> [Message] = { [] },
        getFollowUpMessages: @escaping @Sendable () async -> [Message] = { [] },
        apiKeyResolver: (@Sendable (String) async -> String?)? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        transformContext: TransformContextHook? = nil
    ) {
        self.model = model
        self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets
        self.sessionId = sessionId
        self.maxRetryDelayMs = maxRetryDelayMs
        self.toolExecution = toolExecution
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.apiKeyResolver = apiKeyResolver
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
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
        currentContext.messages.append(contentsOf: prompts)

        await emit(.agentStart)
        await emit(.turnStart)
        for prompt in prompts {
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
        let baseCount = currentContext.messages.count
        func delta() -> [Message] {
            Array(currentContext.messages[baseCount...])
        }

        var firstTurn = initialFirstTurn
        var pendingMessages = await config.getSteeringMessages()

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
                        await emit(.messageStart(message: message))
                        await emit(.messageEnd(message: message))
                        currentContext.messages.append(message)
                    }
                    pendingMessages = []
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

                if assistant.stopReason == .error || assistant.stopReason == .aborted {
                    await emit(.turnEnd(message: .assistant(assistant), toolResults: []))
                    await emit(.agentEnd(messages: delta()))
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
                    }
                }

                await emit(.turnEnd(message: .assistant(assistant), toolResults: toolResults))

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
                    await emit(.messageStart(message: .assistant(aborted)))
                    await emit(.messageEnd(message: .assistant(aborted)))
                    // `aborted` is not appended to currentContext — preserving
                    // the prior behavior where the synthetic abort message is
                    // surfaced via messageEnd but not part of the agent-end
                    // delta or the transcript.
                    await emit(.agentEnd(messages: delta()))
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

        await emit(.agentEnd(messages: delta()))
    }

    // MARK: - Stream assistant response

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

        let resolvedKey = await config.apiKeyResolver?(config.model.provider)
        let options = StreamOptions(
            apiKey: resolvedKey,
            cacheRetention: nil,
            sessionId: config.sessionId,
            maxRetryDelayMs: config.maxRetryDelayMs,
            reasoning: config.reasoning,
            thinkingBudgets: config.thinkingBudgets,
            cancellation: cancellation,
            toolChoice: config.toolChoice,
            parallelToolCalls: config.parallelToolCalls
        )

        let response = try await streamFn(config.model, llmContext, options)

        var emittedStart = false

        for await event in response {
            switch event {
            case .start(let partial):
                await emit(.messageStart(message: .assistant(partial)))
                await emit(.messageUpdate(message: partial, assistantMessageEvent: event))
                emittedStart = true

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
                let final = await response.result()
                if !emittedStart {
                    await emit(.messageStart(message: .assistant(final)))
                }
                await emit(.messageEnd(message: .assistant(final)))
                return final
            }
        }

        let final = await response.result()
        if !emittedStart {
            await emit(.messageStart(message: .assistant(final)))
        }
        await emit(.messageEnd(message: .assistant(final)))
        return final
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

        if let before = config.beforeToolCall {
            let ctx = BeforeToolCallContext(
                assistantMessage: assistantMessage,
                toolCall: toolCall,
                args: args,
                context: context
            )
            if let result = await before(ctx, cancellation), result.block {
                return .immediate(
                    errorToolResult(result.reason ?? "Tool execution was blocked"),
                    true
                )
            }
        }
        return .prepared(PreparedToolCall(call: toolCall, tool: tool, args: args))
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
        }
        do {
            let result = try await prepared.tool.execute(prepared.call.id, prepared.args, cancellation, onUpdate)
            await emitBox.waitForPending()
            return ExecutedOutcome(result: result, isError: false)
        } catch {
            await emitBox.waitForPending()
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
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

    private static func errorToolResult(_ text: String) -> AgentToolResult {
        AgentToolResult(content: [.text(TextContent(text: text))], details: nil)
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
