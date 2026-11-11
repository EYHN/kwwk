import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

@Suite("Provider retry schedule")
struct ProviderRetryScheduleTests {
    static func http(_ status: Int, headers: [String: String]) async -> ProviderFailure {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.test")!, statusCode: status, httpVersion: nil, headerFields: headers
        )!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data(#"{"error":{"message":"Rate limit exceeded","code":429}}"#.utf8))
            continuation.finish()
        }
        return await ProviderFailure.http(response, body: stream, now: Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("transient transport errors are retryable, permanent ones are not")
    func transientTransport() {
        for code in [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                     NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                     NSURLErrorBadServerResponse, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed] {
            #expect(ProviderFailure.capture(NSError(domain: NSURLErrorDomain, code: code)).isRetryable, "\(code)")
        }
        for code in [NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorSecureConnectionFailed, NSURLErrorCancelled] {
            #expect(!ProviderFailure.capture(NSError(domain: NSURLErrorDomain, code: code)).isRetryable, "\(code)")
        }
        // FoundationNetworking's unmapped curl failures arrive as -1 with curl's words.
        for text in ["Recv failure: Connection reset by peer", "Empty reply from server", "Send failure: Broken pipe"] {
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown,
                                userInfo: [NSLocalizedDescriptionKey: text])
            #expect(ProviderFailure.capture(error).isRetryable, "\(text)")
        }
    }

    @Test("backoff doubles from 1 s to a 30 s cap over eight attempts")
    func schedule() {
        let policy = ProviderRetryPolicy()
        let busy = ProviderFailure(message: "busy", httpStatus: 429)
        #expect(policy.maxAttempts == 8)
        #expect((0..<7).map { policy.delay(for: busy, attempt: $0) } == [1000, 2000, 4000, 8000, 16000, 30000, 30000])
        #expect(policy.delay(for: busy, attempt: 7) == nil)
        #expect(policy.delay(for: busy, attempt: 5, jitter: 0.75) == 22500)
    }

    @Test("a timed-out request keeps five attempts")
    func timeoutBudget() {
        let timeout = ProviderFailure.capture(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        let policy = ProviderRetryPolicy()
        #expect((0..<4).map { policy.delay(for: timeout, attempt: $0) } == [1000, 2000, 4000, 8000])
        #expect(policy.delay(for: timeout, attempt: 4) == nil)
        #expect(ProviderRetryPolicy(maxAttempts: 3).delay(for: timeout, attempt: 2) == nil)
    }

    @Test("x-ratelimit-reset formats")
    func resetFormats() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        func reset(_ headers: [String: String]) -> Double? { ProviderFailure.rateLimitReset(headers: headers, now: now) }
        #expect(reset(["x-ratelimit-reset-requests": "1s"]) == 1000)
        #expect(reset(["x-ratelimit-reset-tokens": "6m0s"]) == 360_000)
        #expect(reset(["x-ratelimit-reset-requests": "20ms"]) == 20)
        #expect(reset(["x-ratelimit-reset-requests": "1h2m3.5s"]) == 3_723_500)
        #expect(reset(["X-RateLimit-Reset-Requests": "2s", "x-ratelimit-reset-tokens": "7.5s"]) == 7500)
        // OpenRouter: unix milliseconds; others: unix seconds or delta seconds.
        #expect(reset(["X-RateLimit-Reset": "1794000004000"]) == 4000)
        #expect(reset(["x-ratelimit-reset": "1794000005"]) == 5000)
        #expect(reset(["x-ratelimit-reset": "3"]) == 3000)
        #expect(reset(["x-ratelimit-reset": "1793999000"]) == 0)
        #expect(reset(["x-ratelimit-reset-requests": "soon"]) == nil)
        #expect(reset(["x-ratelimit-reset": "-1"]) == nil)
        #expect(reset([:]) == nil)
    }

    @Test("a 429's x-ratelimit-reset floors the backoff, capped at 30 s and never terminal")
    func resetFloorsBackoff() async {
        let failure = await Self.http(429, headers: ["x-ratelimit-reset-requests": "5s"])
        #expect(failure.retryAfterMs == nil)
        #expect(failure.rateLimitResetMs == 5000)
        let policy = ProviderRetryPolicy()
        #expect(policy.delay(for: failure, attempt: 0) == 5000)
        #expect(policy.delay(for: failure, attempt: 3) == 8000)
        let far = await Self.http(429, headers: ["x-ratelimit-reset-tokens": "10m0s"])
        #expect(policy.delay(for: far, attempt: 0) == 30_000)
        // Retry-After governs when present.
        let both = await Self.http(429, headers: ["retry-after": "2", "x-ratelimit-reset-requests": "9s"])
        #expect(both.rateLimitResetMs == nil)
        #expect(policy.delay(for: both, attempt: 0) == 2000)
        // Only a 429 reads the reset: other responses carry these headers too.
        #expect(await Self.http(503, headers: ["x-ratelimit-reset-requests": "9s"]).rateLimitResetMs == nil)
    }

    @Test("model requests may go 300 s without a byte")
    func idleTimeout() {
        #expect(URLSessionHTTPClient().session.configuration.timeoutIntervalForRequest == 300)
    }
}
