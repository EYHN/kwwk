import Foundation

public enum ProviderContextLimit {
    public static func isInputOverflow(_ message: String) -> Bool {
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
            // Kimi For Coding: "Your request exceeded model token limit: X (requested: Y)".
            "exceeded model token limit",
        ]
        if exactSignals.contains(where: normalized.contains) {
            return true
        }

        // xAI's OpenAI-compatible endpoint reports both limits this way.
        if normalized.range(
            of: #"maximum prompt length is \d+.*request contains \d+ tokens"#,
            options: .regularExpression
        ) != nil {
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

    /// A refusal that reads as an authorization failure but is an input
    /// rejection: the account's plan serves the model at a smaller window
    /// than the request needs. Kimi For Coding answers an over-window k3
    /// request with HTTP 401 `authentication_error` "Your current plan
    /// supports only k3 up to 256K context. 1M context is available on
    /// higher-tier Kimi Code plans." (measured 2026-10-07). Replaying it
    /// never helps; shrinking the input does.
    public static func isPlanContextLimit(_ message: String) -> Bool {
        message.lowercased().range(
            of: #"supports only .{1,80}? up to \d+(?:\.\d+)?\s*[km]\s+context"#,
            options: .regularExpression
        ) != nil
    }

    /// The context limit an overflow message states the provider enforced,
    /// in tokens; nil when it states none. Shapes follow the provider
    /// examples pi-mono collects for its overflow detection, plus Kimi's plan
    /// limit (``isPlanContextLimit(_:)``), whose `256K` is 262,144 tokens.
    public static func reportedLimit(in message: String) -> Int? {
        let normalized = message.lowercased()
        if let match = firstMatch(#"up to (\d+(?:\.\d+)?)\s*([km])\s+context"#, in: normalized),
           let value = Double(match[0]) {
            let unit = match[1] == "m" ? 1_048_576.0 : 1_024.0
            return Int((value * unit).rounded())
        }
        let patterns = [
            // Kimi For Coding: "exceeded model token limit: 262144 (requested: 300000)"
            #"exceeded model token limit:?\s*([\d,]+)"#,
            // Anthropic: "prompt is too long: 213462 tokens > 200000 maximum"
            #"prompt is too long:?\s*[\d,]+\s*tokens?\s*>\s*([\d,]+)"#,
            // Anthropic: "input length and max_tokens exceed context limit: X + Y > Z"
            #"context\s+limit:?\s*[\d,]+\s*\+\s*[\d,]+\s*>\s*([\d,]+)"#,
            // OpenAI / OpenRouter / LiteLLM: "maximum context length is 131072 tokens", "… of 131072 tokens"
            #"maximum context length (?:is|of)\s*([\d,]+)\s*tokens?"#,
            // OpenAI-compatible: "exceeds model's maximum context length (262144)"
            #"maximum context length\s*\(([\d,]+)\)"#,
            // xAI: "This model's maximum prompt length is 131072 but …"
            #"maximum prompt length is\s*([\d,]+)"#,
            // Google: "exceeds the maximum number of tokens allowed (1048575)"
            #"maximum number of tokens allowed\s*\(([\d,]+)\)"#,
            // OpenRouter / Poolside: "exceeds the maximum allowed input length of 131072 tokens"
            #"maximum allowed input length of\s*([\d,]+)\s*tokens?"#,
            // Together AI: "is longer than the model's context length (131072 tokens)"
            #"context length\s*\(([\d,]+)\s*tokens?\)"#,
            // GitHub Copilot: "prompt token count of X exceeds the limit of 128000"
            #"exceeds the limit of\s*([\d,]+)"#,
            // DS4: "but the configured context size is 65536 tokens"
            #"configured context size is\s*([\d,]+)\s*tokens?"#,
            // Mistral: "too large for model with 131072 maximum context length"
            #"for model with\s*([\d,]+)\s*maximum context length"#,
        ]
        for pattern in patterns {
            if let match = firstMatch(pattern, in: normalized),
               let value = Int(match[0].replacingOccurrences(of: ",", with: "")) {
                return value
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
