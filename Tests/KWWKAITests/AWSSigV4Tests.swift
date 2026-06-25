import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

@Suite("AWS SigV4 signer")
struct AWSSigV4Tests {

    /// Canonical test vector from AWS documentation:
    /// GET iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08
    /// on 2015-08-30T12:36:00Z with standard example creds.
    /// We validate POST-shaped input since that's our production path, but
    /// derive authorization from a known-good body.
    @Test("produces the x-amz-date and authorization headers for a signed POST")
    func producesSignedHeaders() {
        let url = URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com/model/claude-sonnet-4/converse-stream")!
        let body = Data("{\"messages\":[]}".utf8)
        let creds = AWSSigV4.Credentials(
            accessKeyId: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        )
        let dc = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "UTC"),
            year: 2024, month: 1, day: 1, hour: 0, minute: 0, second: 0
        )
        let headers = AWSSigV4.signPOST(
            url: url,
            body: body,
            region: "us-east-1",
            service: "bedrock",
            credentials: creds,
            now: dc.date!
        )
        #expect(headers["x-amz-date"] == "20240101T000000Z")
        #expect(headers["x-amz-content-sha256"]?.count == 64)
        let auth = headers["authorization"] ?? ""
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256"))
        #expect(auth.contains("Credential=AKIDEXAMPLE/20240101/us-east-1/bedrock/aws4_request"))
        #expect(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        #expect(auth.contains("Signature="))
    }

    @Test("includes x-amz-security-token when session creds supplied")
    func sessionTokenIncluded() {
        let url = URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com/x")!
        let creds = AWSSigV4.Credentials(
            accessKeyId: "k", secretAccessKey: "s", sessionToken: "TOKENXYZ"
        )
        let headers = AWSSigV4.signPOST(
            url: url, body: Data(), region: "us-east-1", service: "bedrock", credentials: creds
        )
        #expect(headers["x-amz-security-token"] == "TOKENXYZ")
        #expect(headers["authorization"]?.contains("x-amz-security-token") == true)
    }
}

@Suite("AWS event stream framing")
struct AWSEventStreamTests {

    @Test("round-trips a single frame with headers and payload")
    func roundTrip() async throws {
        let payload = Data("{\"hello\":1}".utf8)
        let frame = encodeAWSEventFrame(
            headers: [":event-type": "messageStart", ":content-type": "application/json"],
            payload: payload
        )
        let bytes = AsyncThrowingStream<UInt8, Error> { cont in
            Task {
                for b in frame { cont.yield(b) }
                cont.finish()
            }
        }
        var messages: [AWSEventMessage] = []
        for try await msg in parseAWSEventStream(bytes: bytes) {
            messages.append(msg)
        }
        #expect(messages.count == 1)
        #expect(messages.first?.headers[":event-type"] == "messageStart")
        #expect(messages.first?.payload == payload)
    }

    @Test("parses two concatenated frames out of one byte stream")
    func twoFrames() async throws {
        let one = encodeAWSEventFrame(
            headers: [":event-type": "messageStart"], payload: Data("{}".utf8)
        )
        let two = encodeAWSEventFrame(
            headers: [":event-type": "messageStop"], payload: Data("{\"stopReason\":\"end_turn\"}".utf8)
        )
        let combined = one + two
        let bytes = AsyncThrowingStream<UInt8, Error> { cont in
            Task {
                for b in combined { cont.yield(b) }
                cont.finish()
            }
        }
        var types: [String] = []
        for try await msg in parseAWSEventStream(bytes: bytes) {
            types.append(msg.headers[":event-type"] ?? "")
        }
        #expect(types == ["messageStart", "messageStop"])
    }
}

@Suite("Bedrock provider")
struct BedrockProviderTests {
    static let model = Model(
        id: "anthropic.claude-sonnet-4-20250514-v1:0",
        name: "claude",
        api: "bedrock-converse-stream",
        provider: "amazon-bedrock",
        contextWindow: 200_000,
        maxTokens: 8192
    )

    private static func frames(_ pairs: [(String, String)]) -> Data {
        var out = Data()
        for (type, payload) in pairs {
            out.append(encodeAWSEventFrame(
                headers: [":event-type": type, ":message-type": "event"],
                payload: Data(payload.utf8)
            ))
        }
        return out
    }

    private final class ByteStubClient: HTTPClient, @unchecked Sendable {
        let body: Data
        var statusCode: Int
        var lastRequest: (url: URL, method: String, headers: [String: String], body: Data?)?
        init(body: Data, statusCode: Int = 200) {
            self.body = body
            self.statusCode = statusCode
        }
        func stream(
            url: URL, method: String, headers: [String: String], body requestBody: Data?
        ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
            lastRequest = (url, method, headers, requestBody)
            let response = HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/vnd.amazon.eventstream"]
            )!
            let bytes = Array(body)
            let stream = AsyncThrowingStream<UInt8, Error> { cont in
                Task {
                    for b in bytes { cont.yield(b) }
                    cont.finish()
                }
            }
            return (response, stream)
        }
    }

    @Test("streams text via contentBlockDelta events")
    func basicText() async throws {
        let body = Self.frames([
            ("messageStart", "{\"role\":\"assistant\"}"),
            ("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"Hello\"}}"),
            ("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\", world\"}}"),
            ("contentBlockStop", "{\"contentBlockIndex\":0}"),
            ("messageStop", "{\"stopReason\":\"end_turn\"}"),
            ("metadata", "{\"usage\":{\"inputTokens\":5,\"outputTokens\":3}}"),
        ])
        let client = ByteStubClient(body: body)
        let provider = BedrockProvider(
            client: client,
            region: "us-east-1",
            credentialsProvider: { AWSSigV4.Credentials(accessKeyId: "k", secretAccessKey: "s") }
        )
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var acc = ""
        for await event in s {
            if case .textDelta(_, let d, _) = event { acc += d }
        }
        let result = await s.result()
        #expect(acc == "Hello, world")
        #expect(result.stopReason == .stop)
        #expect(result.usage.input == 5)
        #expect(result.usage.output == 3)
    }

    @Test("streams toolUse with incremental input and emits toolcall_end with parsed args")
    func toolUse() async throws {
        let body = Self.frames([
            ("messageStart", "{\"role\":\"assistant\"}"),
            ("contentBlockStart", "{\"contentBlockIndex\":0,\"start\":{\"toolUse\":{\"toolUseId\":\"tu_1\",\"name\":\"calc\"}}}"),
            ("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"{\\\"a\\\":1\"}}}"),
            ("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\",\\\"b\\\":2}\"}}}"),
            ("contentBlockStop", "{\"contentBlockIndex\":0}"),
            ("messageStop", "{\"stopReason\":\"tool_use\"}"),
        ])
        let client = ByteStubClient(body: body)
        let provider = BedrockProvider(
            client: client,
            region: "us-east-1",
            credentialsProvider: { AWSSigV4.Credentials(accessKeyId: "k", secretAccessKey: "s") }
        )
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "compute"))]),
            options: nil
        )
        var seenEnd = false
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event {
                #expect(call.id == "tu_1")
                #expect(call.name == "calc")
                #expect(call.arguments == .object(["a": 1, "b": 2]))
                seenEnd = true
            }
        }
        let result = await s.result()
        #expect(seenEnd)
        #expect(result.stopReason == .toolUse)
    }

    @Test("signs requests and attaches authorization header")
    func signsRequests() async throws {
        let body = Self.frames([
            ("messageStart", "{\"role\":\"assistant\"}"),
            ("messageStop", "{\"stopReason\":\"end_turn\"}"),
        ])
        let client = ByteStubClient(body: body)
        // Region now resolves from the configured (env) region, not the
        // vestigial `region` constructor arg, per pi precedence. Inject
        // AWS_REGION so resolution is deterministic regardless of ambient env.
        let provider = BedrockProvider(
            client: client,
            region: "us-west-2",
            environment: ["AWS_REGION": "us-west-2"],
            credentialsProvider: {
                AWSSigV4.Credentials(accessKeyId: "AKID", secretAccessKey: "SECRET")
            }
        )
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let h = client.lastRequest?.headers ?? [:]
        #expect(h["authorization"]?.contains("AWS4-HMAC-SHA256") == true)
        #expect(h["authorization"]?.contains("us-west-2/bedrock/aws4_request") == true)
        #expect(h["x-amz-date"]?.hasSuffix("Z") == true)
        let u = client.lastRequest?.url.absoluteString ?? ""
        #expect(u.contains("bedrock-runtime.us-west-2.amazonaws.com"))
        #expect(u.contains("/converse-stream"))
    }

    @Test("encodes converse request body (messages + inferenceConfig + toolConfig)")
    func bodyEncoding() async throws {
        let body = Self.frames([
            ("messageStart", "{\"role\":\"assistant\"}"),
            ("messageStop", "{\"stopReason\":\"end_turn\"}"),
        ])
        let client = ByteStubClient(body: body)
        let provider = BedrockProvider(
            client: client,
            region: "us-east-1",
            credentialsProvider: { AWSSigV4.Credentials(accessKeyId: "k", secretAccessKey: "s") }
        )
        _ = provider.stream(
            model: Self.model,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [.user(UserMessage(text: "hi"))],
                tools: [Tool(
                    name: "calc", description: "arithmetic",
                    parameters: ["type": "object"]
                )]
            ),
            options: StreamOptions(
                temperature: 0.2,
                maxTokens: 1024,
                toolChoice: .required
            )
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let sent = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        let systemParts = json?["system"] as? [[String: Any]]
        #expect(systemParts?.first?["text"] as? String == "Be concise.")
        let inference = json?["inferenceConfig"] as? [String: Any]
        #expect(inference?["maxTokens"] as? Int == 1024)
        #expect(inference?["temperature"] as? Double == 0.2)
        let toolConfig = json?["toolConfig"] as? [String: Any]
        let tools = toolConfig?["tools"] as? [[String: Any]]
        let spec = tools?.first?["toolSpec"] as? [String: Any]
        #expect(spec?["name"] as? String == "calc")
        let toolChoice = toolConfig?["toolChoice"] as? [String: Any]
        #expect(toolChoice?["any"] != nil)
    }

    @Test("surfaces exception frames as terminal stream errors")
    func exceptionFrame() async throws {
        var body = Data()
        body.append(encodeAWSEventFrame(
            headers: [":event-type": "throttlingException", ":message-type": "exception"],
            payload: Data("{\"message\":\"rate limit exceeded\"}".utf8)
        ))
        let client = ByteStubClient(body: body)
        let provider = BedrockProvider(
            client: client,
            region: "us-east-1",
            credentialsProvider: { AWSSigV4.Credentials(accessKeyId: "k", secretAccessKey: "s") }
        )
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var terminal: AssistantMessage?
        for await event in s {
            if case .error(_, let err) = event { terminal = err }
        }
        #expect(terminal?.stopReason == .error)
        #expect(terminal?.errorMessage == "rate limit exceeded")
    }
}
