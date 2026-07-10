import Foundation

struct CompactionRecapRenderResult: Sendable, Equatable {
    let text: String
    let hasRunningTasksLedger: Bool
}

/// Renders one canonical recap under a single shared token budget. History,
/// active-turn context, file facts, and running tasks all draw from this same
/// allowance so auxiliary ledgers cannot silently make the replacement larger
/// than the planner reserved.
enum CompactionRecapRenderer {
    static let minimumUsefulTokenBudget = 64

    static func render(
        historySummary: String?,
        turnPrefixSummary: String?,
        facts: CompactionFileFacts,
        previousRecapForFacts: String?,
        runningTasks: String,
        maxTokens: Int
    ) -> CompactionRecapRenderResult {
        let budget = max(1, maxTokens)
        let hasFacts = !facts.isEmpty
            || previousRecapForFacts?.contains("<file-operations>") == true
        let hasTasks = !runningTasks.isEmpty
        let weights = ComponentWeights(
            history: historySummary == nil ? 0 : 6,
            turnPrefix: turnPrefixSummary == nil ? 0 : 3,
            facts: hasFacts ? 2 : 0,
            runningTasks: hasTasks ? 2 : 0
        )
        let emptyEnvelopeTokens = ContextTokenEstimator.estimate(text: envelope(
            history: nil,
            turnPrefix: nil,
            facts: nil,
            runningTasks: nil
        ))
        guard emptyEnvelopeTokens <= budget else {
            return CompactionRecapRenderResult(text: "", hasRunningTasksLedger: false)
        }
        let contentBudget = max(1, budget - emptyEnvelopeTokens - 8)
        let shares = weights.tokenShares(total: contentBudget)

        var scale = 1.0
        var last = CompactionRecapRenderResult(
            text: envelope(history: nil, turnPrefix: nil, facts: nil, runningTasks: nil),
            hasRunningTasksLedger: false
        )

        // XML escaping and mixed CJK/ASCII text make bytes-to-token sizing
        // non-linear. Re-rendering these four bounded strings is cheap; use the
        // exact estimator to converge while preserving structured fact lines.
        for _ in 0..<12 {
            let history = boundedSemanticText(
                historySummary,
                maxTokens: scaledLimit(shares.history, by: scale, minimum: 16)
            )
            let turnPrefix = boundedSemanticText(
                turnPrefixSummary,
                maxTokens: scaledLimit(shares.turnPrefix, by: scale, minimum: 16)
            )
            let factsByteLimit = scaledByteLimit(shares.facts, by: scale)
            let renderedFacts = CompactionFactsExtractor.render(
                facts,
                carryingForwardFrom: previousRecapForFacts,
                maximumBytes: factsByteLimit
            )
            let tasks = boundedSemanticText(
                hasTasks ? runningTasks : nil,
                maxTokens: scaledLimit(shares.runningTasks, by: scale, minimum: 0)
            )
            let text = envelope(
                history: history,
                turnPrefix: turnPrefix,
                facts: renderedFacts,
                runningTasks: tasks
            )
            last = CompactionRecapRenderResult(
                text: text,
                hasRunningTasksLedger: tasks != nil
            )
            let actual = ContextTokenEstimator.estimate(text: text)
            if actual <= budget {
                return last
            }
            scale *= max(0.1, min(0.9, Double(budget) / Double(actual) * 0.9))
        }

        // A useful automatic budget is at least 64 tokens, so the loop above
        // normally converges well before this point. Preserve semantic summary
        // sections as the final fallback and drop optional ledgers first.
        var semanticBudget = max(1, budget - emptyEnvelopeTokens - 16)
        for _ in 0..<12 {
            let fallbackHistory = boundedSemanticText(
                historySummary,
                maxTokens: turnPrefixSummary == nil
                    ? semanticBudget
                    : semanticBudget * 2 / 3
            )
            let fallbackPrefix = boundedSemanticText(
                turnPrefixSummary,
                maxTokens: historySummary == nil
                    ? semanticBudget
                    : semanticBudget / 3
            )
            let fallbackText = envelope(
                history: fallbackHistory,
                turnPrefix: fallbackPrefix,
                facts: nil,
                runningTasks: nil
            )
            let actual = ContextTokenEstimator.estimate(text: fallbackText)
            if actual <= budget {
                return CompactionRecapRenderResult(
                    text: fallbackText,
                    hasRunningTasksLedger: false
                )
            }
            semanticBudget = max(
                1,
                Int(Double(semanticBudget) * Double(budget) / Double(actual) * 0.8)
            )
        }

        // The outer pipeline rejects automatic budgets below 64, while the
        // empty canonical envelope is much smaller. This final guard makes the
        // renderer's hard-cap contract total even for direct/internal callers.
        return CompactionRecapRenderResult(
            text: envelope(history: nil, turnPrefix: nil, facts: nil, runningTasks: nil),
            hasRunningTasksLedger: false
        )
    }

    private static func envelope(
        history: String?,
        turnPrefix: String?,
        facts: String?,
        runningTasks: String?
    ) -> String {
        var sections: [String] = []
        if let history {
            sections += [
                "<history>",
                CompactionFactsExtractor.escapeXML(history),
                "</history>",
            ]
        }
        if let turnPrefix {
            sections += [
                "<current-turn-prefix>",
                CompactionFactsExtractor.escapeXML(turnPrefix),
                "</current-turn-prefix>",
            ]
        }
        if let facts { sections.append(facts) }

        var text = """
        <previous-session-summary>
        <kwwk-compaction version="2">
        \(sections.joined(separator: "\n"))
        </kwwk-compaction>
        </previous-session-summary>
        """
        if let runningTasks {
            text += "\n\n<running-background-tasks>\n\(CompactionFactsExtractor.escapeXML(runningTasks))\n</running-background-tasks>"
        }
        return text
    }

    private static func boundedSemanticText(_ text: String?, maxTokens: Int) -> String? {
        guard let text, !text.isEmpty, maxTokens > 0 else { return nil }
        guard ContextTokenEstimator.estimate(text: text) > maxTokens else { return text }

        var lowerBound = 0
        var upperBound = text.utf8.count
        var best: String?
        while lowerBound <= upperBound {
            let byteLimit = lowerBound + (upperBound - lowerBound) / 2
            let candidate = CompactionTranscriptSerializer.bounded(text, byteLimit: byteLimit)
            if ContextTokenEstimator.estimate(text: candidate) <= maxTokens {
                best = candidate
                lowerBound = byteLimit + 1
            } else {
                upperBound = byteLimit - 1
            }
        }
        return best
    }

    private static func scaledLimit(_ share: Int, by scale: Double, minimum: Int) -> Int {
        guard share > 0 else { return 0 }
        return max(minimum, Int(Double(share) * scale))
    }

    private static func scaledByteLimit(_ tokenShare: Int, by scale: Double) -> Int {
        guard tokenShare > 0 else { return 0 }
        let byteReference = tokenShare > Int.max / 3 ? Int.max : tokenShare * 3
        let scaled = Double(byteReference) * scale
        let scaledBytes = scaled >= Double(Int.max) ? Int.max : Int(scaled)
        return min(
            CompactionFactsExtractor.maximumRenderedBytes,
            max(0, scaledBytes)
        )
    }

    private struct ComponentWeights {
        let history: Int
        let turnPrefix: Int
        let facts: Int
        let runningTasks: Int

        func tokenShares(total: Int) -> ComponentWeights {
            let weight = max(1, history + turnPrefix + facts + runningTasks)
            return ComponentWeights(
                history: share(history, total: total, weight: weight),
                turnPrefix: share(turnPrefix, total: total, weight: weight),
                facts: share(facts, total: total, weight: weight),
                runningTasks: share(runningTasks, total: total, weight: weight)
            )
        }

        private func share(_ component: Int, total: Int, weight: Int) -> Int {
            guard component > 0 else { return 0 }
            let quotient = total / weight
            let remainder = total % weight
            return max(1, quotient * component + remainder * component / weight)
        }
    }
}
