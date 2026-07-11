import KWWKAI

/// Resolves the usable input side of a model request from the same output
/// ceiling providers use when `StreamOptions.maxTokens` is automatic.
enum AgentRequestBudget {
    static func inputTokens(for model: Model) -> Int {
        max(1, max(1, model.contextWindow) - outputReserveTokens(for: model))
    }

    static func outputReserveTokens(for model: Model) -> Int {
        let window = max(1, model.contextWindow)
        if let automaticLimit = OutputTokenPolicy.automaticLimit(for: model) {
            return min(max(1, automaticLimit), window)
        }
        if OutputTokenPolicy.isOpenRouter(model) {
            let proportional = max(
                1,
                (window / 100) * 15 + (window % 100) * 15 / 100
            )
            // The 16_384 floor buys generation headroom on big-window models,
            // but must never swallow a small window: uncapped, a 17k-window
            // model would be left ~600 input tokens and fail every preflight.
            return min(max(16_384, proportional), max(proportional, window / 4))
        }
        // Server-driven/first-party routes and zero-metadata custom models do
        // not put a useful automatic limit on the wire. Retain proportional
        // planning headroom without forcing a low generation cap.
        return max(1, window / 4)
    }

    static func supportsExplicitOutputTokenLimit(for model: Model) -> Bool {
        OutputTokenPolicy.supportsExplicitLimit(for: model)
    }
}
