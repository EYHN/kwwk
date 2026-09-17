import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

@Suite("Provider structured failure integration")
struct ProviderFailureIntegrationTests {
    @Test(arguments: ["anthropic", "completions", "responses", "gemini", "bedrock", "mistral"])
    func adaptersPreserveHTTPFailure(providerName: String) async {
        let client = StubSSEClient(body: "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"connection timeout req-503\"}}", statusCode: 400)
        let provider: any APIProvider
        switch providerName {
        case "anthropic": provider = AnthropicProvider(client: client)
        case "completions": provider = OpenAICompletionsProvider(client: client)
        case "responses": provider = OpenAIResponsesProvider(client: client)
        case "gemini": provider = GoogleGeminiProvider(client: client)
        case "mistral": provider = MistralConversationsProvider(client: client)
        default:
            provider = BedrockProvider(client: client, region: "us-east-1", environment: [:], resolveProfileFiles: false,
                                       credentialsProvider: { AWSSigV4.Credentials(accessKeyId: "test", secretAccessKey: "test") })
        }
        let result = await provider.stream(model: OpenAICompletionsTests.model, context: Context(messages: []), options: StreamOptions(transport: .sse)).result()
        #expect(result.stopReason == .error)
        #expect(result.failure?.httpStatus == 400)
        #expect(result.failure?.providerCode == "invalid_request_error")
        #expect(result.failure?.isRetryable == false)
    }
    @Test func responsesContentFilterIsNotLengthTruncation() async {
        let client = StubSSEClient(body: "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"content_filter\"}}}\n\n")
        let result = await OpenAIResponsesProvider(client: client).stream(model: OpenAIResponsesTests.model, context: Context(messages: []), options: StreamOptions(transport: .sse)).result()
        #expect(result.stopReason == .error)
        #expect(result.failure?.category == .refusal)
        #expect(result.failure?.isRetryable == false)
    }
    @Test func geminiBlockedPromptIsNotAnIncompleteStream() async {
        let client = StubSSEClient(body: "data: {\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}\n\n")
        let result = await GoogleGeminiProvider(client: client).stream(model: OpenAICompletionsTests.model, context: Context(messages: []), options: nil).result()
        #expect(result.stopReason == .error)
        #expect(result.failure?.category == .refusal)
        #expect(result.failure?.isRetryable == false)
    }
    @Test func typedCursorErrorPreservesStatusAndTLSFailure() {
        let failure = ProviderFailure.capture(CursorConnectError.httpStatus(400, "connection timed out"))
        #expect(failure.httpStatus == 400)
        #expect(!failure.isRetryable)
        #expect(!ProviderFailure.capture(CursorConnectError.tlsSetupFailed("connection failed")).isRetryable)
        #expect(ProviderFailure.capture(CursorConnectError.grpc(status: "resource_exhausted", message: "busy")).isRetryable)
    }
    @Test func completionsStreamErrorIsNotLostAtEOF() async {
        let client = StubSSEClient(body: "data: {\"error\":{\"code\":\"insufficient_quota\",\"message\":\"account exhausted\",\"status\":429}}\n\n")
        let result = await OpenAICompletionsProvider(client: client).stream(model: OpenAICompletionsTests.model, context: Context(messages: []), options: nil).result()
        #expect(result.stopReason == .error)
        #expect(result.failure?.providerCode == "insufficient_quota")
        #expect(result.failure?.httpStatus == 429)
        #expect(result.failure?.isRetryable == false)
        #expect(result.errorMessage == "account exhausted")
    }
    @Test func anthropicTypedStreamError() async {
        let client = StubSSEClient(body: "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n")
        let result = await AnthropicProvider(client: client).stream(model: AnthropicProviderTests.sampleModel, context: Context(messages: []), options: nil).result()
        #expect(result.failure?.providerCode == "overloaded_error")
        #expect(result.failure?.isRetryable == true)
    }
    @Test func refusalPreservesDetailsWithoutRetrying() async {
        let client = StubSSEClient(body: "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{\"type\":\"test-detail\"}}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        let result = await AnthropicProvider(client: client).stream(model: AnthropicProviderTests.sampleModel, context: Context(messages: []), options: nil).result()
        #expect(result.failure?.rawStopReason == "refusal")
        #expect(result.failure?.stopDetails == .object(["type": .string("test-detail")]))
        #expect(result.failure?.category == .refusal)
        #expect(result.failure?.isRetryable == false)
    }
    @Test func responsesNestedErrorPreservesCode() async {
        let client = StubSSEClient(body: "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"overloaded_error\",\"message\":\"busy\"}}}\n\n")
        let result = await OpenAIResponsesProvider(client: client).stream(model: OpenAIResponsesTests.model, context: Context(messages: []), options: StreamOptions(transport: .sse)).result()
        #expect(result.failure?.providerCode == "overloaded_error")
        #expect(result.failure?.isRetryable == true)
    }
    @Test func httpErrorKeepsStatusWhenBodyReadFails() async {
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 400, httpVersion: nil,
                                       headerFields: ["Retry-After": "2", "X-Request-ID": "req-test"])!
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
        let failure = await ProviderFailure.http(response, body: body)
        #expect(failure.httpStatus == 400)
        #expect(failure.retryAfterMs == 2000)
        #expect(failure.requestId == "req-test")
        #expect(!failure.isRetryable)
    }
    @Test func largeErrorBodyIsBounded() async {
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data(repeating: 65, count: 100_000))
            continuation.finish()
        }
        let failure = await ProviderFailure.http(response, body: body)
        #expect(failure.message.utf8.count <= 4096)
        #expect(failure.isRetryable)
    }
}
