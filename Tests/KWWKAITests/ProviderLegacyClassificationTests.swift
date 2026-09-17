import Testing
import KWWKAI

@Suite("Context limit classification")
struct ProviderContextClassificationTests {
    @Test("recognizes Anthropic input plus output context overflow")
    func anthropicContextLimitOverflow() {
        let message = """
        Anthropic returned status 400 — {"type":"error","error":{"type":"invalid_request_error","message":"input length and max_tokens exceed context limit: 150000 + 64000 > 200000"}}
        """

        #expect(ProviderContextLimit.isInputOverflow(message))
        #expect(!ProviderFailure(message: message).isRetryable)
    }

    @Test("keeps Anthropic token-per-minute limits on the retry path")
    func anthropicRateLimitIsNotContextOverflow() {
        let message = """
        Anthropic returned status 429 — {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization of 80,000 input tokens per minute"}}
        """

        #expect(!ProviderContextLimit.isInputOverflow(message))
        #expect(ProviderFailure(message: message).isRetryable)
    }
    @Test("overflow phrases are not treated as transient transport failures")
    func overflowClassificationPrecedesRetry() {
        #expect(ProviderContextLimit.isInputOverflow("context_length_exceeded"))
        #expect(ProviderContextLimit.isInputOverflow("maximum context length is 128000"))
        #expect(ProviderContextLimit.isInputOverflow(
            "prompt is too long: 213799 tokens > 200000 maximum"
        ))
        #expect(ProviderContextLimit.isInputOverflow(
            "The input token count (1195854) exceeds the maximum number of tokens allowed (1048576)."
        ))
        #expect(!ProviderContextLimit.isInputOverflow("input token rate exceeded for this minute"))
        #expect(!ProviderContextLimit.isInputOverflow("max_tokens output limit reached"))
        #expect(!ProviderContextLimit.isInputOverflow("output token count exceeds max_tokens"))
        #expect(!ProviderFailure(message: "context_length_exceeded").isRetryable)
    }

}

@Suite("Retry error classification")
struct RetryClassificationTests {
    @Test("POSIX socket deaths are retryable")
    func posixSocketErrors() {
        // The exact shape of the user-reported subagent failure.
        #expect(ProviderFailure(message: "WebSocket stream failed: Error Domain=NSPOSIXErrorDomain Code=57 \"Socket is not connected\"").isRetryable)
        #expect(ProviderFailure(message: "Error Domain=NSPOSIXErrorDomain Code=54 \"Connection reset by peer\"").isRetryable)
        #expect(ProviderFailure(message: "The network connection was lost.").isRetryable)
        #expect(ProviderFailure(message: "WebSocket stream closed before response.completed").isRetryable)
        #expect(ProviderFailure(message: "WebSocket connection keepalive failed: no inbound traffic for 60s").isRetryable)
    }

    @Test("timeouts and retryable statuses are retryable")
    func transientStatuses() {
        #expect(ProviderFailure(message: "The request timed out.").isRetryable)
        #expect(ProviderFailure(message: "HTTP 429: rate limit exceeded").isRetryable)
        #expect(ProviderFailure(message: "HTTP 503: service unavailable").isRetryable)
        #expect(ProviderFailure(message: "HTTP 529: overloaded").isRetryable)
        // gRPC-based providers (e.g. NVIDIA NIM) report quota pressure as
        // ResourceExhausted (pi #6449).
        #expect(ProviderFailure(message: "ResourceExhausted: Worker local total request limit reached").isRetryable)
        #expect(!ProviderFailure(message: "ResourceExhausted: quota exceeded").isRetryable)
        #expect(ProviderFailure(message: "gRPC status RESOURCE_EXHAUSTED").isRetryable)
    }

    @Test("validation and auth failures are not retryable")
    func permanentFailures() {
        #expect(!ProviderFailure(message: "HTTP 400: invalid request body").isRetryable)
        #expect(!ProviderFailure(message: "HTTP 401: unauthorized").isRetryable)
        #expect(!ProviderFailure(message: "model not found").isRetryable)
        // Validation short-circuit wins even when the message also
        // mentions a transport-ish word.
        #expect(!ProviderFailure(message: "invalid connection parameters").isRetryable)
        // Permanent validation evidence is not overridden by timeout prose.
        #expect(!ProviderFailure(message: "invalid state: request timed out").isRetryable)
    }

    @Test("in-flight session conflict is not retryable")
    func busySessionNotRetryable() {
        #expect(!ProviderFailure(message: "OpenAI Responses WebSocket session already has an in-flight response for this sessionId. Use a distinct sessionId for parallel runs.").isRetryable)
    }
}
