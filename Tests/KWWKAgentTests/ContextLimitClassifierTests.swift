import Testing
@testable import KWWKAgent

@Suite("Context limit classification")
struct ContextLimitClassifierTests {
    @Test("recognizes Anthropic input plus output context overflow")
    func anthropicContextLimitOverflow() {
        let message = """
        Anthropic returned status 400 — {"type":"error","error":{"type":"invalid_request_error","message":"input length and max_tokens exceed context limit: 150000 + 64000 > 200000"}}
        """

        #expect(ContextLimitClassifier.isInputOverflow(message))
        #expect(!AgentLoop.isRetryableError(message))
    }

    @Test("keeps Anthropic token-per-minute limits on the retry path")
    func anthropicRateLimitIsNotContextOverflow() {
        let message = """
        Anthropic returned status 429 — {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization of 80,000 input tokens per minute"}}
        """

        #expect(!ContextLimitClassifier.isInputOverflow(message))
        #expect(AgentLoop.isRetryableError(message))
    }
}
