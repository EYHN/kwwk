// Swift adaptations of pi/omp regression cases. See THIRD_PARTY_NOTICES.md
// for pinned upstream paths, deliberate differences and MIT license notices.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

@Suite("Provider failure parity — pi / omp")
struct ProviderFailureParityTests {
    // omp error-transient-status-boundary.test.ts
    @Test(arguments: ["503 Service Unavailable", "upstream returned 502", "HTTP 429 from provider", "auth-gateway 524: <none>"])
    func realStatuses(text: String) {
        #expect(ProviderFailure(message: text).isRetryable)
    }

    @Test(arguments: [
        "Summarization failed: 400 invalid_request_error: prompt is too long: 3030000 tokens > 1000000 maximum\nraw-http-request=/home/u/.omp/logs/http-400-requests/1787022540720-3o503gxo48bvb.json",
        "auth-gateway 404: not found", "model gpt-500x rejected the request", "request req500502 failed validation",
        "request req-503 failed", "HTTP 400: unexpected EOF; retry after timeout",
    ])
    func terminalStatuses(text: String) {
        #expect(!ProviderFailure(message: text).isRetryable)
    }

    // omp error-aierr.test.ts: governing status wins over the cause's prose.
    @Test(arguments: [400, 401, 403, 404, 413, 422])
    func governingTerminalStatus(status: Int) {
        #expect(!ProviderFailure(message: "unexpected EOF connection timeout", httpStatus: status).isRetryable)
    }
    @Test(arguments: [408, 429, 500, 502, 503, 504, 524, 529, 599])
    func governingTransientStatus(status: Int) {
        #expect(ProviderFailure(message: "opaque provider failure", httpStatus: status).isRetryable)
    }

    // pi retry.test.ts: guidance, DNS, stream termination, permanent limits.
    @Test(arguments: [
        "An error occurred while processing your request. You can retry your request, or contact us through our help center",
        "The system encountered an unexpected error during processing. Try your request again.",
        "ResourceExhausted: Worker local total request limit reached (288/48)",
        "The socket connection was closed unexpectedly. For more information, pass verbose: true",
        "Error: exceeded request buffer limit while retrying upstream",
        "The pending stream has been canceled (caused by: getaddrinfo ENOTFOUND bedrock-runtime.us-east-1.amazonaws.com)",
        "connect ENOTFOUND api.example.com", "EAI_AGAIN api.example.com", "getaddrinfo failed for api.example.com",
        "OpenAI Responses stream ended before a terminal response event", "overloaded_error", "524 status code (no body)",
    ])
    func transientFallback(text: String) { #expect(ProviderFailure(message: text).isRetryable) }

    @Test(arguments: ["429 quota exceeded", "insufficient_quota", "monthly usage limit reached", "available balance is insufficient", "out of budget", "billing error"])
    func permanentLimits(text: String) {
        #expect(!ProviderFailure(message: text, httpStatus: 429).isRetryable)
    }

    @Test(arguments: [-1001, -1003, -1004, -1005, -1006, -1009])
    func urlSessionTransient(code: Int) {
        let failure = ProviderFailure.capture(NSError(domain: NSURLErrorDomain, code: code))
        #expect(failure.isRetryable)
        #expect(ProviderFailure(message: "Error Domain=NSURLErrorDomain Code=\(code) \"(null)\"").isRetryable)
        #expect(failure.transportCode == code)
    }
    @Test(arguments: [-999, -1000, -1012, -1200, -1202, -9999])
    func urlSessionPermanent(code: Int) {
        #expect(!ProviderFailure.capture(NSError(domain: NSURLErrorDomain, code: code,
                                               userInfo: [NSLocalizedDescriptionKey: "connection timed out"])).isRetryable)
    }
    @Test func underlyingTransportAndPermanentOuter() {
        let timeout = NSError(domain: NSURLErrorDomain, code: -1001)
        let wrapper = NSError(domain: "Proxy", code: 1, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(ProviderFailure.capture(wrapper).category == .timeout)
        let tls = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(!ProviderFailure.capture(tls).isRetryable)
        #expect(!ProviderFailure.capture(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))).isRetryable)
        #expect(ProviderFailure.capture(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))).isRetryable)
    }

    @Test func serverHintsAndCaps() {
        let policy = ProviderRetryPolicy(maxRetryDelayMs: 1000)
        #expect(policy.delay(for: .init(message: "busy", httpStatus: 429, retryAfterMs: 1000), attempt: 0) == 1000)
        #expect(policy.delay(for: .init(message: "busy", httpStatus: 429, retryAfterMs: 1001), attempt: 0) == nil)
        #expect(policy.delay(for: .init(message: "busy", httpStatus: 429, shouldRetry: false), attempt: 0) == nil)
        #expect(ProviderRetryPolicy(maxRetryDelayMs: 0).delay(for: .init(message: "busy", httpStatus: 429, retryAfterMs: 277403000), attempt: 0) == 277403000)
        #expect(ProviderRetryPolicy(maxAttempts: 20).delay(for: .init(message: "busy", httpStatus: 503), attempt: 10) == 30000)
        #expect(policy.delay(for: .init(message: "busy", httpStatus: 503), attempt: 4) == nil)
        #expect(policy.delay(for: .init(message: "busy", httpStatus: 503), attempt: 0, jitter: 0.75) == 750)
        #expect(policy.delay(for: .init(message: "busy", httpStatus: 429, retryAfterMs: 1000), attempt: 0, jitter: 0.75) == 1000)
    }

    @Test func retryAfterFormats() {
        #expect(ProviderFailure.retryDelay(headers: ["Retry-After": "2"]) == 2000)
        #expect(ProviderFailure.retryDelay(headers: ["retry-after-ms": "12", "Retry-After": "2"]) == 12)
        #expect(ProviderFailure.retryDelay(headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:02 GMT"], now: Date(timeIntervalSince1970: 0)) == 2000)
        #expect(ProviderFailure.retryDelay(headers: ["retry-after": "invalid"]) == nil)
        #expect(ProviderFailure.retryDelay(headers: ["retry-after": "-1"]) == nil)
        #expect(ProviderFailure.retryDelay(headers: ["retry-after": "inf"]) == nil)
    }

    @Test func persistenceCompatibility() throws {
        var message = fauxAssistantMessage("", stopReason: .error, errorMessage: "opaque")
        message.failure = .init(message: "opaque", httpStatus: 503, providerCode: "overloaded_error", requestId: "req-example", retryAfterMs: 5)
        let decoded = try JSONDecoder().decode(AssistantMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.failure == message.failure)
        #expect(decoded.providerFailure?.isRetryable == true)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        old.removeValue(forKey: "failure")
        let legacy = try JSONDecoder().decode(AssistantMessage.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.failure == nil)
    }

    @Test func selfContainedRetryBudgetAndRecovery() async throws {
        var attempts = 0
        let policy = ProviderRetryPolicy(maxAttempts: 3, baseDelayMs: 0)
        let result = try await policy.complete {
            attempts += 1
            return fauxAssistantMessage(attempts < 3 ? "" : "recovered", stopReason: attempts < 3 ? .error : .stop,
                                        errorMessage: attempts < 3 ? "terminated" : nil)
        }
        #expect(attempts == 3)
        #expect(result.stopReason == .stop)
        attempts = 0
        let final = try await policy.complete {
            attempts += 1
            return fauxAssistantMessage("", stopReason: .error, errorMessage: "terminated")
        }
        #expect(attempts == 3)
        #expect(final.errorMessage == "terminated")
    }

    @Test(arguments: [StopReason.aborted, .stop, .error])
    func terminalOneShot(reason: StopReason) async throws {
        var attempts = 0
        _ = try await ProviderRetryPolicy(baseDelayMs: 0).complete {
            attempts += 1
            return fauxAssistantMessage("", stopReason: reason, errorMessage: "insufficient_quota")
        }
        #expect(attempts == 1)
    }
    @Test func cancelledDelayDoesNotRetry() async {
        let cancellation = CancellationHandle()
        var attempts = 0
        do {
            _ = try await ProviderRetryPolicy(maxRetryDelayMs: 0).complete(cancellation: cancellation) {
                attempts += 1
                cancellation.cancel(reason: "test")
                var message = fauxAssistantMessage("", stopReason: .error)
                message.failure = .init(message: "busy", httpStatus: 429, retryAfterMs: 277403000)
                return message
            }
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(attempts == 1)
    }
}
