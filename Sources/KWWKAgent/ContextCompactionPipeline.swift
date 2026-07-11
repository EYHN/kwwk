import Foundation
import KWWKAI

struct ContextCompactionPipelineRequest: Sendable {
    let context: AgentContext
    let reservedMessages: [Message]
    /// Live conversation model. Retention and post-compaction measurements
    /// are evaluated against this model's context window.
    let contextModel: Model
    /// Model used only for the summary-generation requests.
    let summaryModel: Model
    let backgroundManager: BackgroundTaskManager?
    let sessionId: String?
    let config: AgentContextCompactionConfig
    let targetTokens: Int?
    let authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    let transformContext: TransformContextHook?
    let convertToLlm: ConvertToLlmHook?
    let stream: StreamFn?
    let cancellation: CancellationHandle?
}

enum ContextCompactionPipeline {
    static func run(
        _ request: ContextCompactionPipelineRequest
    ) async throws -> AgentContextCompactionResult {
        try checkCancellation(request.cancellation)

        if let target = request.targetTokens, target <= 0 {
            throw AgentContextCompactionError.insufficientReduction(
                actual: measuredTokens(
                    context: request.context,
                    appending: request.reservedMessages,
                    model: request.contextModel
                ),
                target: target
            )
        }

        let strategy = effectiveStrategy(request.config.strategy)
        let recapTokenBudget = maximumRecapTokenBudget(for: request)
        if let target = request.targetTokens,
           recapTokenBudget < CompactionRecapRenderer.minimumUsefulTokenBudget {
            // The recap budget is min(configured, target/4, target - fixed -
            // margin); a sufficient retry target must clear BOTH target-derived
            // constraints, so report the larger. Using the margin's cap keeps
            // the reported value sufficient even though the margin itself
            // grows with the target.
            throw AgentContextCompactionError.recoveryTargetTooSmall(
                minimum: max(
                    fixedTokenEstimate(for: request)
                        + CompactionRecapRenderer.minimumUsefulTokenBudget
                        + maximumRecapSafetyMargin,
                    4 * CompactionRecapRenderer.minimumUsefulTokenBudget
                ),
                target: target
            )
        }
        var keepRecentTokens = initialRecentTokenBudget(
            for: request,
            recapTokenBudget: recapTokenBudget
        )
        let attemptLimit = request.targetTokens == nil || strategy == .legacyFullSummary
            ? 1
            : max(1, request.config.maxSummaryAttempts)
        var previousCut: Int?
        var lastTokensAfter: Int?

        for attemptIndex in 0..<attemptLimit {
            guard let plan = makePlan(
                messages: request.context.messages,
                strategy: strategy,
                keepRecentTokens: keepRecentTokens
            ) else {
                throw ContextCompactionPipelineError.noCompressibleMessages
            }
            guard previousCut != plan.firstKeptMessageIndex else { break }
            previousCut = plan.firstKeptMessageIndex

            let historySummary = try await summarizeHistory(plan: plan, request: request)
            let turnPrefixSummary = try await summarizeTurnPrefix(plan: plan, request: request)
            guard historySummary != nil || turnPrefixSummary != nil else {
                throw ContextCompactionPipelineError.noCompressibleMessages
            }
            try checkCancellation(request.cancellation)

            let replacement = await makeReplacement(
                plan: plan,
                historySummary: historySummary,
                turnPrefixSummary: turnPrefixSummary,
                recapTokenBudget: recapTokenBudget,
                request: request
            )
            let result = makeResult(
                replacement: replacement.messages,
                plan: plan,
                hasRunningTasksLedger: replacement.hasRunningTasksLedger,
                request: request
            )
            guard let target = request.targetTokens,
                  let after = result.tokensAfter,
                  after > target else {
                return result
            }

            lastTokensAfter = after
            guard attemptIndex < attemptLimit - 1 else { break }
            let recapTokens = replacement.messages.first.map {
                ContextTokenEstimator.estimate(message: $0)
            } ?? 0
            let exactRecentAllowance = max(
                1,
                target
                    - fixedTokenEstimate(for: request)
                    - recapTokens
                    - recapSafetyMargin(for: target)
            )
            var nextBudget = min(
                exactRecentAllowance,
                max(1, plan.estimatedRecentTokens - 1)
            )
            if nextBudget >= keepRecentTokens {
                nextBudget = max(1, keepRecentTokens / 2)
            }
            keepRecentTokens = nextBudget
        }

        throw AgentContextCompactionError.insufficientReduction(
            actual: lastTokensAfter ?? measuredTokens(
                context: request.context,
                appending: request.reservedMessages,
                model: request.contextModel
            ),
            target: request.targetTokens ?? 0
        )
    }

    private static func makePlan(
        messages: [Message],
        strategy: AgentContextCompactionStrategy,
        keepRecentTokens: Int
    ) -> CompactionPlan? {
        switch strategy {
        case .legacyFullSummary:
            return CompactionPlanner.legacyPlan(messages: messages)
        case .retainedTailV1:
            return CompactionPlanner.plan(
                messages: messages,
                keepRecentTokens: keepRecentTokens
            )
        }
    }

    private static func summarizeHistory(
        plan: CompactionPlan,
        request: ContextCompactionPipelineRequest
    ) async throws -> String? {
        guard !plan.messagesToSummarize.isEmpty else {
            return plan.previousSummary
        }
        return try await summarizeInChunks(
            messages: plan.messagesToSummarize,
            previousSummary: priorDurableSummary(for: plan),
            kind: .history,
            request: request
        )
    }

    private static func summarizeTurnPrefix(
        plan: CompactionPlan,
        request: ContextCompactionPipelineRequest
    ) async throws -> String? {
        guard !plan.turnPrefixToSummarize.isEmpty else { return nil }
        return try await summarizeInChunks(
            messages: plan.turnPrefixToSummarize,
            // With no intervening history, this is a later slice of the same
            // active turn. Update its prior prefix summary instead of starting
            // over and discarding the earlier slice. Once history advances,
            // the old prefix is folded into `priorDurableSummary` above and
            // this prefix belongs to a newer active turn.
            previousSummary: plan.messagesToSummarize.isEmpty
                ? plan.previousTurnPrefixSummary
                : nil,
            kind: .activeTurnPrefix,
            request: request
        )
    }

    private static func summarizeInChunks(
        messages: [Message],
        previousSummary: String?,
        kind: CompactionSummaryKind,
        request: ContextCompactionPipelineRequest
    ) async throws -> String? {
        var transformed = messages
        if let transform = request.transformContext {
            transformed = await transform(transformed, request.cancellation)
        }
        if let convert = request.convertToLlm {
            transformed = await convert(transformed)
        }
        transformed = transformed.map(redactedForPersistence)
        try checkCancellation(request.cancellation)

        var accumulator = previousSummary
        let summaryConfig = effectiveSummaryConfig(for: request)
        // LIFO storage with reversed insertion preserves transcript order
        // without Array.removeFirst()/front insertion shifting every pending
        // chunk on long histories.
        var pending = [transformed]
        while !pending.isEmpty {
            let transcriptBudget = try CompactionSummaryGenerator.availableTranscriptTokens(
                model: request.summaryModel,
                config: summaryConfig,
                previousSummary: accumulator,
                kind: kind
            )
            let candidate = pending.removeLast()
            let refined = CompactionSummaryChunker.chunks(
                candidate,
                maxTokens: transcriptBudget,
                limits: summaryConfig.transcriptLimits
            )
            guard let chunk = refined.first else { continue }
            if refined.count > 1 {
                pending.append(contentsOf: refined.reversed())
                continue
            }
            accumulator = try await CompactionSummaryGenerator.generate(
                CompactionSummaryRequest(
                    messages: chunk,
                    model: request.summaryModel,
                    sessionId: request.sessionId,
                    config: summaryConfig,
                    previousSummary: accumulator,
                    kind: kind,
                    authResolver: request.authResolver,
                    stream: request.stream,
                    cancellation: request.cancellation
                )
            )
        }
        return accumulator
    }

    private static func makeReplacement(
        plan: CompactionPlan,
        historySummary: String?,
        turnPrefixSummary: String?,
        recapTokenBudget: Int,
        request: ContextCompactionPipelineRequest
    ) async -> (messages: [Message], hasRunningTasksLedger: Bool) {
        let facts = CompactionFactsExtractor.extract(
            from: plan.messagesToSummarize + plan.turnPrefixToSummarize
        )
        let runningTasks = await request.backgroundManager?
            .runningTasksSummary(sessionId: request.sessionId)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rendered = CompactionRecapRenderer.render(
            historySummary: historySummary,
            turnPrefixSummary: turnPrefixSummary,
            facts: facts,
            previousRecapForFacts: plan.previousRecapForFacts,
            runningTasks: runningTasks,
            maxTokens: recapTokenBudget
        )
        let recap = Message.user(UserMessage(
            text: rendered.text,
            timestamp: recapTimestamp(after: request.context.messages),
            source: .compaction
        ))
        return ([recap] + plan.recentTail, rendered.hasRunningTasksLedger)
    }

    private static func makeResult(
        replacement: [Message],
        plan: CompactionPlan,
        hasRunningTasksLedger: Bool,
        request: ContextCompactionPipelineRequest
    ) -> AgentContextCompactionResult {
        let beforeTokens = measuredTokens(
            context: request.context,
            appending: request.reservedMessages,
            model: request.contextModel
        )
        var projectedContext = request.context
        projectedContext.messages = replacement
        let afterTokens = measuredTokens(
            context: projectedContext,
            appending: request.reservedMessages,
            model: request.contextModel
        )
        return AgentContextCompactionResult(
            messages: replacement,
            messagesCompacted: plan.firstKeptMessageIndex,
            hasRunningTasksLedger: hasRunningTasksLedger,
            firstKeptMessageIndex: plan.firstKeptMessageIndex,
            tokensBefore: beforeTokens,
            tokensAfter: afterTokens
        )
    }

    private static func recapTimestamp(after messages: [Message]) -> Int64 {
        let latestMessageTimestamp = messages.map { message -> Int64 in
            switch message {
            case .user(let user): return user.timestamp
            case .assistant(let assistant): return assistant.timestamp
            case .toolResult(let result): return result.timestamp
            }
        }.max() ?? 0
        let nextMessageTimestamp = latestMessageTimestamp == Int64.max
            ? Int64.max
            : latestMessageTimestamp + 1
        return max(Timestamp.now(), nextMessageTimestamp)
    }

    /// A prefix summary belongs to the previously active turn. As soon as raw
    /// history beyond the recap is evicted, that turn has advanced into durable
    /// history and both semantic pieces must seed the history update. Keeping
    /// this as plain text avoids feeding the XML recap envelope back to the LLM.
    private static func priorDurableSummary(for plan: CompactionPlan) -> String? {
        guard let prefix = plan.previousTurnPrefixSummary else {
            return plan.previousSummary
        }
        guard let history = plan.previousSummary else {
            return "## Previously Compacted Active-Turn Prefix\n\(prefix)"
        }
        return """
        \(history)

        ## Previously Compacted Active-Turn Prefix
        \(prefix)
        """
    }

    private static func measuredTokens(
        context: AgentContext,
        appending messages: [Message],
        model: Model
    ) -> Int {
        var measured = context
        measured.messages.append(contentsOf: messages)
        return ContextTokenEstimator.estimate(context: measured, model: model).effective
    }

    private static func initialRecentTokenBudget(
        for request: ContextCompactionPipelineRequest,
        recapTokenBudget: Int
    ) -> Int {
        guard let target = request.targetTokens else {
            return max(1, request.config.keepRecentTokens)
        }
        return min(
            max(1, request.config.keepRecentTokens),
            max(
                1,
                target
                    - fixedTokenEstimate(for: request)
                    - recapTokenBudget
                    - recapSafetyMargin(for: target)
            )
        )
    }

    static func maximumRecapTokenBudget(
        for request: ContextCompactionPipelineRequest
    ) -> Int {
        let requested = request.config.summaryMaxTokens > 0
            ? request.config.summaryMaxTokens
            : doubledWithoutOverflow(max(1, request.config.summaryWordTarget))
        let maximum = max(
            CompactionRecapRenderer.minimumUsefulTokenBudget,
            request.contextModel.contextWindow / 2
        )
        let boundedConfigured = min(
            max(requested, CompactionRecapRenderer.minimumUsefulTokenBudget),
            maximum
        )
        guard let target = request.targetTokens else { return boundedConfigured }
        let available = max(
            0,
            target - fixedTokenEstimate(for: request) - recapSafetyMargin(for: target)
        )
        return min(boundedConfigured, max(1, target / 4), available)
    }

    private static func doubledWithoutOverflow(_ value: Int) -> Int {
        value > Int.max / 2 ? Int.max : value * 2
    }

    private static func fixedTokenEstimate(
        for request: ContextCompactionPipelineRequest
    ) -> Int {
        var fixedContext = request.context
        fixedContext.messages = request.reservedMessages
        return ContextTokenEstimator.estimate(
            context: fixedContext,
            model: request.contextModel
        ).locallyEstimated
    }

    private static let maximumRecapSafetyMargin = 256

    private static func recapSafetyMargin(for target: Int) -> Int {
        min(maximumRecapSafetyMargin, max(32, target / 100))
    }

    private static func effectiveSummaryConfig(
        for request: ContextCompactionPipelineRequest
    ) -> AgentContextCompactionConfig {
        var config = request.config
        var wordSizingTokens: Int?
        if request.targetTokens != nil {
            let recoveryOutputLimit = max(64, maximumRecapTokenBudget(for: request))
            wordSizingTokens = recoveryOutputLimit
        }

        let modelOutputReserve = CompactionSummaryGenerator.outputTokenReserve(
            model: request.summaryModel,
            config: config
        )
        let summarySizingTokens = min(
            modelOutputReserve,
            wordSizingTokens ?? modelOutputReserve
        )
        config.summaryWordTarget = min(
            max(1, config.summaryWordTarget),
            max(50, summarySizingTokens * 3 / 4)
        )
        return config
    }

    private static func effectiveStrategy(
        _ configured: AgentContextCompactionStrategy
    ) -> AgentContextCompactionStrategy {
        guard let override = ProcessInfo.processInfo.environment["KWWK_COMPACTION_STRATEGY"],
              !override.isEmpty else {
            return configured
        }
        return AgentContextCompactionStrategy(rawValue: override) ?? configured
    }

    private static func checkCancellation(_ cancellation: CancellationHandle?) throws {
        if cancellation?.isCancelled == true || Task.isCancelled {
            throw AgentContextCompactionError.cancelled
        }
    }
}

enum ContextCompactionPipelineError: Error {
    case noCompressibleMessages
}
