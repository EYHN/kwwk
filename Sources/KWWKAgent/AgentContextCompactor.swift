import Foundation
import KWWKAI

public let agentCompactMinMessages = 4

public struct AgentContextUsage: Equatable, Sendable {
    public let tokens: Int
    public let window: Int

    public var ratio: Double {
        window > 0 ? Double(tokens) / Double(window) : 0
    }

    public init(tokens: Int, window: Int) {
        self.tokens = tokens
        self.window = window
    }
}

public struct AgentContextCompactionConfig: Sendable {
    public var minMessages: Int
    public var toolOutputCharacterLimit: Int
    public var summaryWordTarget: Int
    public var keepRecentTokens: Int
    public var messageTextByteLimit: Int
    public var thinkingByteLimit: Int
    public var toolArgumentByteLimit: Int
    public var toolDetailsByteLimit: Int
    /// Optional hard cap for summary generation. `0` leaves the stream option
    /// unset so the provider/model default is used; positive values opt into
    /// an explicit cap. A positive value also seeds the total stored-recap
    /// allowance; automatic mode derives that allowance from
    /// `summaryWordTarget`. Window planning still reserves safe output headroom.
    public var summaryMaxTokens: Int
    public var recoveryRatio: Double
    public var maxSummaryAttempts: Int

    public init(
        minMessages: Int = agentCompactMinMessages,
        toolOutputCharacterLimit: Int = 4_000,
        summaryWordTarget: Int = 900,
        keepRecentTokens: Int = 20_000,
        messageTextByteLimit: Int = 12_000,
        thinkingByteLimit: Int = 8_000,
        toolArgumentByteLimit: Int = 4_000,
        toolDetailsByteLimit: Int = 2_000,
        summaryMaxTokens: Int = 0,
        recoveryRatio: Double = 0.8,
        maxSummaryAttempts: Int = 2
    ) {
        self.minMessages = minMessages
        self.toolOutputCharacterLimit = toolOutputCharacterLimit
        self.summaryWordTarget = summaryWordTarget
        self.keepRecentTokens = keepRecentTokens
        self.messageTextByteLimit = messageTextByteLimit
        self.thinkingByteLimit = thinkingByteLimit
        self.toolArgumentByteLimit = toolArgumentByteLimit
        self.toolDetailsByteLimit = toolDetailsByteLimit
        self.summaryMaxTokens = summaryMaxTokens
        self.recoveryRatio = recoveryRatio
        self.maxSummaryAttempts = maxSummaryAttempts
    }
}

public enum AgentContextCompactionOutcome: Sendable, Equatable {
    case compacted(messagesCompacted: Int, hasRunningTasksLedger: Bool)
    case refusedAgentBusy
    case refusedTooFewMessages(count: Int)
    case failed(String)
}

public enum AgentContextCompactor {
    public static func currentUsage(messages: [Message], model: Model) -> AgentContextUsage {
        let estimate = ContextTokenEstimator.estimate(messages: messages, model: model)
        return AgentContextUsage(tokens: estimate.effective, window: model.contextWindow)
    }

    public static func currentUsage(context: AgentContext, model: Model) -> AgentContextUsage {
        let estimate = ContextTokenEstimator.estimate(context: context, model: model)
        return AgentContextUsage(tokens: estimate.effective, window: model.contextWindow)
    }

    public static func shouldCompact(
        messages: [Message],
        model: Model,
        threshold: Double?
    ) -> Bool {
        guard let threshold, threshold.isFinite, threshold > 0 else { return false }
        let usage = currentUsage(messages: messages, model: model)
        guard usage.window > 0 else { return false }
        return usage.ratio >= threshold
    }

    public static func shouldCompact(
        context: AgentContext,
        model: Model,
        threshold: Double?
    ) -> Bool {
        guard let threshold, threshold.isFinite, threshold > 0 else { return false }
        let usage = currentUsage(context: context, model: model)
        guard usage.window > 0 else { return false }
        return usage.ratio >= threshold
    }

    @discardableResult
    public static func compactAgent(
        agent: Agent,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        targetTokens: Int? = nil,
        additionalMessages: [Message] = [],
        respectMinimumMessages: Bool = true,
        ignoreStreaming: Bool = false,
        cancellation: CancellationHandle? = nil
    ) async -> AgentContextCompactionOutcome {
        if cancellation?.isCancelled == true {
            return .failed(AgentContextCompactionError.cancelled.localizedDescription)
        }
        if !ignoreStreaming && agent.state.isStreaming {
            return .refusedAgentBusy
        }

        let snapshot = agent.state.snapshotModelContext()
        return await compactAgentContext(
            agent: agent,
            context: snapshot.context,
            model: snapshot.model,
            summaryModel: agent.compactionModel ?? snapshot.model,
            expectedContextRevision: snapshot.revision,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            config: config,
            targetTokens: targetTokens,
            additionalMessages: additionalMessages,
            respectMinimumMessages: respectMinimumMessages,
            cancellation: cancellation
        )
    }

    static func compactAgentContext(
        agent: Agent,
        context: AgentContext,
        model: Model,
        summaryModel: Model,
        expectedContextRevision: UInt64,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        targetTokens: Int? = nil,
        additionalMessages: [Message] = [],
        respectMinimumMessages: Bool = true,
        cancellation: CancellationHandle? = nil
    ) async -> AgentContextCompactionOutcome {
        let result = await compactContext(
            context: context,
            model: model,
            compactionModel: summaryModel,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            config: config,
            targetTokens: targetTokens,
            additionalMessages: additionalMessages,
            respectMinimumMessages: respectMinimumMessages,
            authResolver: agent.authResolver,
            transformContext: agent.transformContext,
            convertToLlm: agent.convertToLlm,
            streamFn: { model, context, options in
                try await agent.streamForCompaction(
                    model: model,
                    context: context,
                    options: options
                )
            },
            cancellation: cancellation
        )

        switch result {
        case .success(let replacement):
            // Teardown may cancel after the provider produced a final message
            // but before this task resumes. Never let that narrow race replace
            // the live transcript during exit/session retirement.
            if cancellation?.isCancelled == true {
                return .failed(AgentContextCompactionError.cancelled.localizedDescription)
            }
            guard agent.state.replaceMessages(
                replacement.messages,
                ifRevision: expectedContextRevision
            ) else {
                return .failed(AgentContextCompactionError.contextChanged.localizedDescription)
            }
            return .compacted(
                messagesCompacted: replacement.messagesCompacted,
                hasRunningTasksLedger: replacement.hasRunningTasksLedger
            )
        case .failure(let failure):
            return failure.outcome
        }
    }

    public static func compactInlineIfNeeded(
        agent: Agent,
        context: AgentContext,
        threshold: Double?,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        targetTokens: Int? = nil,
        cancellation: CancellationHandle? = nil
    ) async -> AgentContext? {
        let snapshot = agent.state.snapshotModelContext()
        guard contextsMatchForCompaction(snapshot.context, context) else { return nil }
        guard shouldCompact(context: context, model: snapshot.model, threshold: threshold) else {
            return nil
        }
        let outcome = await compactAgentContext(
            agent: agent,
            context: context,
            model: snapshot.model,
            summaryModel: agent.compactionModel ?? snapshot.model,
            expectedContextRevision: snapshot.revision,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            config: config,
            targetTokens: targetTokens,
            cancellation: cancellation
        )
        guard case .compacted = outcome else {
            return nil
        }

        var replaced = context
        replaced.messages = agent.state.messages
        return replaced
    }

    static func contextsMatchForCompaction(
        _ lhs: AgentContext,
        _ rhs: AgentContext
    ) -> Bool {
        lhs.systemPrompt == rhs.systemPrompt
            && lhs.messages == rhs.messages
            && toolSchemasMatch(lhs.tools, rhs.tools)
    }

    private static func toolSchemasMatch(_ lhs: [AgentTool], _ rhs: [AgentTool]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.name == right.name
                && left.description == right.description
                && left.parameters == right.parameters
        }
    }

    public static func compactMessages(
        messages: [Message],
        model: Model,
        compactionModel: Model? = nil,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        targetTokens: Int? = nil,
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
        transformContext: TransformContextHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        streamFn: StreamFn? = nil,
        cancellation: CancellationHandle? = nil
    ) async -> Result<AgentContextCompactionResult, AgentContextCompactionFailure> {
        let context = AgentContext(systemPrompt: "", messages: messages, tools: [])
        return await compactContext(
            context: context,
            model: model,
            compactionModel: compactionModel,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            config: config,
            targetTokens: targetTokens,
            authResolver: authResolver,
            transformContext: transformContext,
            convertToLlm: convertToLlm,
            streamFn: streamFn,
            cancellation: cancellation
        )
    }

    public static func compactContext(
        context: AgentContext,
        model: Model,
        compactionModel: Model? = nil,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        targetTokens: Int? = nil,
        additionalMessages: [Message] = [],
        respectMinimumMessages: Bool = true,
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
        transformContext: TransformContextHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        streamFn: StreamFn? = nil,
        cancellation: CancellationHandle? = nil
    ) async -> Result<AgentContextCompactionResult, AgentContextCompactionFailure> {
        if cancellation?.isCancelled == true || Task.isCancelled {
            return .failure(.failed(AgentContextCompactionError.cancelled.localizedDescription))
        }
        if respectMinimumMessages, context.messages.count < config.minMessages {
            return .failure(.tooFewMessages(count: context.messages.count))
        }

        do {
            let result = try await ContextCompactionPipeline.run(
                ContextCompactionPipelineRequest(
                    context: context,
                    reservedMessages: additionalMessages,
                    contextModel: model,
                    summaryModel: compactionModel ?? model,
                    backgroundManager: backgroundManager,
                    sessionId: sessionId,
                    config: config,
                    targetTokens: targetTokens,
                    authResolver: authResolver,
                    transformContext: transformContext,
                    convertToLlm: convertToLlm,
                    stream: streamFn,
                    cancellation: cancellation
                )
            )
            return .success(result)
        } catch ContextCompactionPipelineError.noCompressibleMessages {
            return .failure(.tooFewMessages(count: context.messages.count))
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return .failure(.failed(reason))
        }
    }

    public static func renderForSummary(
        _ messages: [Message],
        toolOutputCharacterLimit: Int = AgentContextCompactionConfig().toolOutputCharacterLimit
    ) -> String {
        CompactionTranscriptSerializer.serialize(
            messages,
            limits: .init(toolResultBytes: toolOutputCharacterLimit)
        )
    }

    public static func summarizeTranscript(
        messages: [Message],
        model: Model,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        previousSummary: String? = nil,
        turnPrefix: Bool = false,
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
        streamFn: StreamFn? = nil,
        cancellation: CancellationHandle? = nil
    ) async throws -> String {
        try await CompactionSummaryGenerator.generate(
            CompactionSummaryRequest(
                messages: messages,
                model: model,
                sessionId: sessionId,
                config: config,
                previousSummary: previousSummary,
                kind: turnPrefix ? .activeTurnPrefix : .history,
                authResolver: authResolver,
                stream: streamFn,
                cancellation: cancellation
            )
        )
    }

    // MARK: - Shake (non-LLM tool-output trim)

    /// Default character ceiling for `shakeToolOutputs`. Tool results whose
    /// joined `.text` exceeds this are collapsed into a placeholder.
    public static let shakeToolOutputCharacterLimit = 1000

    /// Leading marker on a collapsed tool result. Used to keep
    /// `shakeToolOutputs` idempotent — a result already carrying this prefix
    /// is left alone so repeated `/shake` calls don't recount or re-elide.
    static let shakePlaceholderPrefix = "[tool result elided to reclaim context"

    private static let removedImagePlaceholder = "[image removed]"

    /// Strip heavy tool-result output from a transcript without any LLM
    /// call (unlike `compactMessages`, which summarizes via the model). Walks
    /// `messages`; for each `.toolResult` whose joined `.text` blocks exceed
    /// `limit`, the text is replaced by a single short placeholder. Every
    /// other field on the `ToolResultMessage` (toolName, toolCallId, isError,
    /// details, timestamp) is preserved, and `.image` blocks are kept — only
    /// the oversized text is collapsed.
    ///
    /// Idempotent: a result already collapsed by a previous pass (detected by
    /// `shakePlaceholderPrefix`) is skipped, so calling this repeatedly is a
    /// no-op after the first trim. Pure: no I/O, no model round-trip.
    ///
    /// Returns the rewritten messages and how many tool results were elided.
    public static func shakeToolOutputs(
        _ messages: [Message],
        keepingUnder limit: Int = shakeToolOutputCharacterLimit
    ) -> (messages: [Message], elidedCount: Int) {
        var elidedCount = 0
        let rewritten = messages.map { message -> Message in
            guard case .toolResult(var result) = message else { return message }
            // Idempotent: leave an already-collapsed result untouched.
            if isShakePlaceholder(result.content) { return message }

            let joined = result.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined(separator: "\n")
            guard joined.count > limit else { return message }

            // Collapse the bulky text into one placeholder block; carry any
            // images through unchanged for the explicit `/shake images` mode.
            var rebuilt: [ToolResultBlock] = [
                .text(TextContent(text: "\(shakePlaceholderPrefix) — was \(joined.count) chars]"))
            ]
            for block in result.content {
                if case .image = block { rebuilt.append(block) }
            }
            result.content = rebuilt
            elidedCount += 1
            return .toolResult(result)
        }
        return (rewritten, elidedCount)
    }

    /// Remove every image block from user and tool-result messages. Messages
    /// that contained only images receive a text placeholder so providers
    /// never see an empty content array. All message metadata and surviving
    /// text blocks retain their original order.
    ///
    /// Pure and idempotent: callers use this same transformation for the live
    /// agent context and every persisted session projection.
    public static func removingImages(
        from messages: [Message]
    ) -> (messages: [Message], removedCount: Int) {
        var removedCount = 0
        let rewritten = messages.map { message -> Message in
            switch message {
            case .user(var user):
                let originalCount = user.content.count
                user.content.removeAll { block in
                    if case .image = block { return true }
                    return false
                }
                let removed = originalCount - user.content.count
                guard removed > 0 else { return message }
                if user.content.isEmpty {
                    user.content = [.text(TextContent(text: removedImagePlaceholder))]
                }
                removedCount += removed
                return .user(user)

            case .toolResult(var result):
                let originalCount = result.content.count
                result.content.removeAll { block in
                    if case .image = block { return true }
                    return false
                }
                let removed = originalCount - result.content.count
                guard removed > 0 else { return message }
                if result.content.isEmpty {
                    result.content = [.text(TextContent(text: removedImagePlaceholder))]
                }
                removedCount += removed
                return .toolResult(result)

            case .assistant:
                return message
            }
        }
        return (rewritten, removedCount)
    }

    private static func isShakePlaceholder(_ content: [ToolResultBlock]) -> Bool {
        for block in content {
            if case .text(let text) = block, text.text.hasPrefix(shakePlaceholderPrefix) {
                return true
            }
        }
        return false
    }
}

public struct AgentContextCompactionResult: Sendable, Equatable {
    public let messages: [Message]
    public let messagesCompacted: Int
    public let hasRunningTasksLedger: Bool
    public let firstKeptMessageIndex: Int?
    public let tokensBefore: Int?
    public let tokensAfter: Int?

    public init(
        messages: [Message],
        messagesCompacted: Int,
        hasRunningTasksLedger: Bool,
        firstKeptMessageIndex: Int? = nil,
        tokensBefore: Int? = nil,
        tokensAfter: Int? = nil
    ) {
        self.messages = messages
        self.messagesCompacted = messagesCompacted
        self.hasRunningTasksLedger = hasRunningTasksLedger
        self.firstKeptMessageIndex = firstKeptMessageIndex
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }
}

public enum AgentContextCompactionFailure: Error, Sendable, Equatable {
    case tooFewMessages(count: Int)
    case failed(String)

    public var outcome: AgentContextCompactionOutcome {
        switch self {
        case .tooFewMessages(let count): return .refusedTooFewMessages(count: count)
        case .failed(let reason): return .failed(reason)
        }
    }
}

public enum AgentContextCompactionError: Error, LocalizedError {
    case summarizationFailed(String)
    case summaryTruncated
    case summaryInputTooLarge
    case emptySummary
    case cancelled
    case contextChanged
    case recoveryTargetTooSmall(minimum: Int, target: Int)
    case insufficientReduction(actual: Int, target: Int)

    public var errorDescription: String? {
        switch self {
        case .summarizationFailed(let reason): return "summarization failed: \(reason)"
        case .summaryTruncated: return "summary exceeded its output budget"
        case .summaryInputTooLarge: return "summary request does not fit the model context window"
        case .emptySummary: return "LLM returned an empty summary"
        case .cancelled: return "compaction cancelled"
        case .contextChanged: return "context changed while compaction was running"
        case .recoveryTargetTooSmall(let minimum, let target):
            return "recovery target of \(target) tokens is too small for the minimum \(minimum)-token recap"
        case .insufficientReduction(let actual, let target):
            return "compaction left \(actual) tokens, above the recovery target of \(target)"
        }
    }
}
