import Foundation
import KWWKAI

enum ContextLimitClassifier {
    static func isInputOverflow(_ message: String) -> Bool {
        let normalized = message.lowercased()

        // Rate-limit errors often describe their quota in input tokens (for
        // example, "would exceed the rate limit ... input tokens per minute").
        // They are transient transport failures, not evidence that the stored
        // conversation is too large. Keep this exclusion ahead of all textual
        // overflow heuristics so a 429 can never trigger destructive recovery.
        let isRateLimit = normalized.contains("rate_limit_error")
            || normalized.contains("rate limit")
            || normalized.contains("too many requests")
            || normalized.contains("per minute")
            || normalized.range(of: #"\b429\b"#, options: .regularExpression) != nil
        if isRateLimit {
            return false
        }

        let exactSignals = [
            "context_length_exceeded",
            "model_context_window_exceeded",
            "prompt_too_long",
            "prompt is too long",
            "prompt too long",
            "input_too_long",
            "input is too long",
            "maximum context length",
            "context window exceeded",
            "context window is too small",
            "exceeds the context window",
            "too many input tokens",
            "input tokens exceed",
            "input token limit exceeded",
            "maximum input length exceeded",
            "prompt tokens exceed",
            "request is too large for this model",
        ]
        if exactSignals.contains(where: normalized.contains) {
            return true
        }

        // Anthropic reports this before "prompt is too long" when the
        // requested output allowance and input cannot coexist in the window:
        // "input length and max_tokens exceed context limit: X + Y > Z".
        if normalized.range(
            of: #"input\s+length.*max_tokens.*exceed.*context\s+limit"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // Some providers insert the measured token count between the stable
        // words, for example: "input token count (123) exceeds ... (100)".
        let describesTokenCount = normalized.contains("maximum")
            || normalized.contains("allowed")
            || normalized.contains("context")
        return normalized.contains("input token")
            && normalized.contains("exceed")
            && describesTokenCount
    }
}

struct ProviderContextOverflow: Error, Sendable {
    let assistant: AssistantMessage
    let emittedStart: Bool
}
