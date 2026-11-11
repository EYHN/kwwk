import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// Collects the provider-reported usage of every summary request one
/// compaction makes (chunked summaries and retried attempts included), so the
/// tokens a compaction spends are not lost: the summary reply never enters the
/// transcript, and its usage would otherwise vanish with it.
///
/// Scoped with a task-local around `AgentContextCompactor.compactAgentContext`,
/// so every summary request issued under that call (including child tasks)
/// reports here without threading a parameter through the pipeline.
final class CompactionUsageCollector: Sendable {
    @TaskLocal static var current: CompactionUsageCollector?

    private let total = NIOLockedValueBox<Usage?>(nil)

    func add(_ usage: Usage) {
        total.withLockedValue { $0 = ($0 ?? Usage()).adding(usage) }
    }

    var usage: Usage? { total.withLockedValue { $0 } }
}

extension Usage {
    /// Field-wise sum of two usage records, costs included.
    func adding(_ other: Usage) -> Usage {
        Usage(
            input: input + other.input,
            output: output + other.output,
            cacheRead: cacheRead + other.cacheRead,
            cacheWrite: cacheWrite + other.cacheWrite,
            cacheWrite1h: cacheWrite1h + other.cacheWrite1h,
            reasoning: reasoning + other.reasoning,
            totalTokens: totalTokens + other.totalTokens,
            cost: Cost(
                input: cost.input + other.cost.input,
                output: cost.output + other.cost.output,
                cacheRead: cost.cacheRead + other.cost.cacheRead,
                cacheWrite: cost.cacheWrite + other.cost.cacheWrite,
                total: cost.total + other.cost.total
            )
        )
    }
}
