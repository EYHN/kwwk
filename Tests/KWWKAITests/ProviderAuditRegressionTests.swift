// Protocol/combination regressions from the pi/omp parity audit.
// Upstream provenance and deliberate policy differences: THIRD_PARTY_NOTICES.md.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

@Suite("Provider audit regressions")
struct ProviderAuditRegressionTests {
    @Test(arguments: [400, 401, 403, 404, 422])
    func permanentStatusDominatesNestedTimeout(status: Int) {
        for failure in [
            ProviderFailure(message: "Error Domain=NSURLErrorDomain Code=-1001", httpStatus: status),
            ProviderFailure(message: "opaque", httpStatus: status, transportDomain: NSURLErrorDomain, transportCode: -1001),
        ] {
            #expect(!failure.isRetryable)
        }
    }

    @Test(arguments: ["4", "8", "13", "14", "deadline_exceeded", "resource_exhausted", "internal", "unavailable"])
    func grpcRetryableWireCodes(code: String) {
        for message in ["", "invalid connection state", "connection not found"] {
            #expect(ProviderFailure.capture(CursorConnectError.grpc(status: code, message: message)).isRetryable)
        }
    }
    @Test(arguments: ["1", "3", "7", "16", "canceled", "invalid_argument", "permission_denied", "unauthenticated"])
    func grpcTerminalWireCodes(code: String) {
        #expect(!ProviderFailure.capture(CursorConnectError.grpc(status: code, message: "connection timed out")).isRetryable)
    }
    @Test func connectEndStreamRetainsCode() throws {
        let body = Data(#"{"error":{"code":"unavailable","message":"opaque"}}"#.utf8)
        let failure = ProviderFailure.capture(try #require(CursorConnectResponse.errorFromEndStream(body)))
        #expect(failure.providerCode == "unavailable")
        #expect(failure.isRetryable)
    }

    @Test func stringSSEErrorRetainsPaymentStatus() async {
        let client = StubSSEClient(body: "data: {\"error\":\"temporarily unavailable\",\"status\":402,\"request_id\":\"req-test\"}\n\n")
        let result = await OpenAICompletionsProvider(client: client).stream(
            model: OpenAICompletionsTests.model, context: Context(messages: []), options: nil).result()
        #expect(result.failure?.httpStatus == 402)
        #expect(result.failure?.requestId == "req-test")
        #expect(result.providerFailure?.isRetryable == false)
    }

    @Test func openRouterNestedOverflowSurvivesHTTPNormalization() async {
        let body = #"{"error":{"message":"Provider returned error","code":400,"metadata":{"raw":"prompt is too long: 536700 tokens > 500000 maximum"}}}"#
        let client = StubSSEClient(body: body, statusCode: 400)
        let result = await OpenAICompletionsProvider(client: client).stream(
            model: OpenAICompletionsTests.model, context: Context(messages: []), options: nil).result()
        #expect(result.failure?.httpStatus == 400)
        #expect(result.providerFailure?.category == .contextOverflow)
        #expect(result.providerFailure?.isRetryable == false)
    }

    @Test(arguments: ["", "data: {\"type\":\"response.created\",\"response\":{\"id\":\"r\"}}\n\n", "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\"}}\n\ndata: {\"type\":\"response.content_part.added\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"partial summary\"}\n\n"])
    func responsesPrematureEOFIsFailure(body: String) async {
        let result = await OpenAIResponsesProvider(client: StubSSEClient(body: body)).stream(
            model: OpenAIResponsesTests.model, context: Context(messages: []), options: StreamOptions(transport: .sse)).result()
        #expect(result.stopReason == .error)
        #expect(result.providerFailure?.isRetryable == true)
        if body.contains("partial summary") {
            #expect(result.hasReplayUnsafeContent)
        }
    }

    @Test(arguments: [400, 401, 402, 403, 422, 429, 503])
    func explicitWebSocketProviderFailureDoesNotFallBack(status: Int) async {
        for phase in ["connect", "send", "receive"] {
            let http = StubSSEClient(body: OpenAIResponsesTests.textSSE)
            let failure = ProviderFailure(message: "opaque", httpStatus: status, retryAfterMs: 2500)
            let connection = StubWebSocketConnection(batches: [], receiveError: phase == "receive" ? failure : nil,
                                                    sendErrors: phase == "send" ? [failure] : [])
            let websocket = StubWebSocketClient(connection: connection, error: phase == "connect" ? failure : nil)
            let provider = OpenAIResponsesProvider(client: http, webSocketClient: websocket)
            let result = await provider.stream(model: OpenAIResponsesTests.model, context: Context(messages: []),
                                              options: StreamOptions(sessionId: UUID().uuidString)).result()
            #expect(http.lastRequest == nil)
            #expect(result.stopReason == .error)
            #expect(result.failure?.httpStatus == status)
            #expect(result.failure?.retryAfterMs == 2500)
        }
    }

    @Test(arguments: [400, 402, 429, 503])
    func rejectedUpgradeKeepsActualHTTPResponse(status: Int) {
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Retry-After": "3", "X-Request-ID": "handshake-id"])!
        let failure = URLSessionWebSocketClient.captureFailure(URLError(.badServerResponse), response: response)
        #expect(failure.httpStatus == status)
        #expect(failure.requestId == "handshake-id")
        #expect(failure.retryAfterMs == 3000)
        #expect(failure.isRetryable == (status == 429 || status == 503))
    }

    @Test func rawMetadataIsBoundedRedactedAndDoesNotOverrideOuterStatus() throws {
        let raw = #"{"error":{"message":"prompt is too long","access_token":"secret-token"},"authorization":"Bearer secret-key"}"#
        let value: JSONValue = .object(["error": .object([
            "message": .string("Provider returned error"), "code": .int(402),
            "metadata": .object(["raw": .string(raw + String(repeating: "x", count: 5000))]),
        ])])
        let failure = ProviderFailure.payload(value)
        #expect(failure.category == .quota)
        #expect(failure.upstreamMessage?.contains("secret-token") == false)
        #expect(failure.upstreamMessage?.contains("secret-key") == false)
        #expect((failure.upstreamMessage?.count ?? 0) <= 4096)
        #expect(failure.message == "Provider returned error")
        let decoded = try JSONDecoder().decode(ProviderFailure.self, from: JSONEncoder().encode(failure))
        #expect(decoded == failure)
    }

    @Test func concurrentQuotaIsTransientButAccountQuotaIsNot() {
        #expect(ProviderFailure(message: "Online prediction concurrent requests quota exceeded", httpStatus: 429).isRetryable)
        #expect(!ProviderFailure(message: "concurrent requests quota exceeded", httpStatus: 402).isRetryable)
        #expect(!ProviderFailure(message: "monthly quota exceeded", httpStatus: 429).isRetryable)
        #expect(!ProviderFailure(message: "concurrent invocation is not supported").isRetryable)
    }

    @Test(arguments: ["socket hang up", "other side closed", "reset before headers", "http2 request did not get a response", "please retry your request", "internal_error", "service_unavailable"])
    func piTransientFallbacks(message: String) {
        #expect(ProviderFailure(message: message).isRetryable)
        #expect(!ProviderFailure(message: message, httpStatus: 400).isRetryable)
    }

    @Test func mutatedRetryAttemptsStayValid() {
        var policy = ProviderRetryPolicy()
        policy.maxAttempts = 0
        #expect(policy.maxAttempts >= 1)
        policy.maxAttempts = -1
        #expect(policy.maxAttempts >= 1)
    }
}
