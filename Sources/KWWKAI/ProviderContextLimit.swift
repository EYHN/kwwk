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
            // The rest are other vendors' own words for the same refusal,
            // as pi and magpie collected them from real replies: Groq,
            // OpenRouter, Together, llama.cpp, LM Studio, MiniMax,
            // Kimi/Moonshot, z.ai (code 1261), Ollama, DashScope, Volcengine.
            "reduce the length of the messages",
            "maximum allowed input length",
            "longer than the model's context length",
            "available context size",
            "greater than the context length",
            "context window exceeds limit",
            "exceeded model token limit",
            "configured context size",
            "prompt exceeds max length",
            "exceeded max context length",
            "range of input length should be",
            "input exceeds the context limit",
        ]
        if exactSignals.contains(where: normalized.contains) || isPlanContextLimit(normalized) {
            return true
        }

        // xAI's OpenAI-compatible endpoint reports both limits this way.
        if normalized.range(
            of: #"maximum prompt length is \d+.*request contains \d+ tokens"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // Copilot: "prompt token count of 2000 exceeds the limit of 1000".
        if normalized.range(
            of: #"prompt token count of [\d,]+ exceeds the limit"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // Zhipu words it in Chinese: "输入内容超过模型最大上下文长度".
        if normalized.range(
            of: #"上下文(长度)?(超|过长)|超(过|出)(了)?(模型)?(的)?(最大)?上下文"#,
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

    /// An input rejection that arrives as an authorization failure: the
    /// account's plan serves the model at a smaller window than the request
    /// needs. Kimi For Coding answers an over-window k3 request with HTTP 401
    /// `authentication_error` "Your current plan supports only k3 up to 256K
    /// context. 1M context is available on higher-tier Kimi Code plans."
    /// (measured 2026-10-07). Replaying it never helps; shrinking the input does.
    public static func isPlanContextLimit(_ message: String) -> Bool {
        message.lowercased().range(
            of: #"supports only .{1,80}? up to \d+(?:\.\d+)?\s*[km]\s+context"#,
            options: .regularExpression
        ) != nil
    }
}
