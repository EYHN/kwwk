import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

// A stub HTTPClient that returns a fixed status + body, delivered as one or
// more `Data` chunks (chunk-based streaming, matching the production contract).
private final class ChunkStubClient: HTTPClient, @unchecked Sendable {
    let chunks: [Data]
    let statusCode: Int
    init(body: Data, statusCode: Int = 200, splitInto: Int = 1) {
        self.statusCode = statusCode
        if splitInto <= 1 || body.isEmpty {
            self.chunks = [body]
        } else {
            let size = max(1, body.count / splitInto)
            var out: [Data] = []
            var i = 0
            while i < body.count {
                let end = min(i + size, body.count)
                out.append(body.subdata(in: i..<end))
                i = end
            }
            self.chunks = out
        }
    }

    convenience init(text: String, statusCode: Int = 200) {
        self.init(body: Data(text.utf8), statusCode: statusCode)
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "text/event-stream"]
        )!
        let chunks = self.chunks
        let stream = AsyncThrowingStream<Data, Error> { cont in
            Task {
                for c in chunks { cont.yield(c) }
                cont.finish()
            }
        }
        return (response, stream)
    }
}

@Suite("SSEParser UTF-8 boundary buffering")
struct SSEParserBoundaryTests {
    @Test("multi-byte character split across ingest calls is not dropped")
    func splitMultibyte() {
        let parser = SSEParser()
        // "café" — the é is 2 bytes (0xC3 0xA9). Split the line between them.
        let full = Data("data: café\n\n".utf8)
        let splitAt = full.firstIndex(of: 0xA9)! // second byte of é
        parser.ingest(bytes: full.subdata(in: 0..<splitAt))
        parser.ingest(bytes: full.subdata(in: splitAt..<full.count))
        let messages = parser.drain()
        #expect(messages.count == 1)
        #expect(messages.first?.data == "café")
    }

    @Test("decodeUTF8Prefix keeps an incomplete trailing sequence")
    func decodePrefix() {
        // "aé" with the last byte of é chopped off.
        var data = Data("a".utf8)
        data.append(0xC3) // lead byte of é, incomplete
        let (decoded, remaining) = SSEParser.decodeUTF8Prefix(data)
        #expect(decoded == "a")
        #expect(remaining == Data([0xC3]))
    }
}

@Suite("parseSSE chunk consumption")
struct ParseSSEChunkTests {
    @Test("parses SSE messages from Data chunks split mid-line")
    func chunkedParse() async throws {
        let sse = "event: message\ndata: {\"n\":1}\n\ndata: {\"n\":2}\n\n"
        let body = Data(sse.utf8)
        let bytes = AsyncThrowingStream<Data, Error> { cont in
            Task {
                // Split so a line boundary falls inside a chunk.
                cont.yield(body.subdata(in: 0..<10))
                cont.yield(body.subdata(in: 10..<body.count))
                cont.finish()
            }
        }
        var datas: [String] = []
        for try await msg in parseSSE(bytes: bytes) {
            datas.append(msg.data)
        }
        #expect(datas == ["{\"n\":1}", "{\"n\":2}"])
    }
}

@Suite("AssistantMessageStream producer/consumer split")
struct AssistantMessageStreamSplitTests {
    @Test("makeStream feeds events and settles a result via the continuation")
    func makeStreamBasic() async {
        let (stream, continuation) = AssistantMessageStream.makeStream()
        let msg = fauxAssistantMessage("hi")
        continuation.push(.start(partial: msg))
        continuation.push(.done(reason: .stop, message: msg))
        continuation.end(msg)

        var types: [String] = []
        for await event in stream { types.append(event.type) }
        let result = await stream.result()
        #expect(types == ["start", "done"])
        #expect(result.stopReason == .stop)
    }

    @Test("cancelling a consumer task ends iteration promptly without a producer")
    func cancellationEndsIteration() async {
        // The stream is never pushed to nor ended. Without cancellation-aware
        // iteration this would hang forever.
        let (stream, _) = AssistantMessageStream.makeStream()
        let task = Task<Int, Never> {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let count = await task.value
        #expect(count == 0)
    }
}

@Suite("Anthropic terminal-state hardening")
struct AnthropicTerminalTests {
    static let model = Model(
        id: "claude-test", name: "Claude Test",
        api: "anthropic-messages", provider: "anthropic",
        baseURL: "https://api.anthropic.com",
        reasoning: false, input: [.text],
        contextWindow: 128_000, maxTokens: 1024
    )

    @Test("stream closing without message_stop is surfaced as an error")
    func prematureEOF() async {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":1,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}


        """
        let provider = AnthropicProvider(client: ChunkStubClient(text: sse), defaultAPIKey: "k")
        let s = provider.stream(model: Self.model, context: Context(messages: [.user(UserMessage(text: "hi"))]), options: nil)
        var terminal: AssistantMessage?
        for await event in s {
            if case .error(_, let err) = event { terminal = err }
        }
        let result = await s.result()
        #expect(terminal?.stopReason == .error)
        #expect(result.stopReason == .error)
        #expect((result.errorMessage ?? "").contains("message_stop"))
    }

    @Test("refusal stop_reason is surfaced as an error, not a clean stop")
    func refusal() async {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":1,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"No"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":1}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let provider = AnthropicProvider(client: ChunkStubClient(text: sse), defaultAPIKey: "k")
        let s = provider.stream(model: Self.model, context: Context(messages: [.user(UserMessage(text: "hi"))]), options: nil)
        var sawError = false
        for await event in s {
            if case .error(_, let err) = event, err.stopReason == .error { sawError = true }
        }
        let result = await s.result()
        #expect(sawError)
        #expect(result.stopReason == .error)
    }
}

@Suite("OpenAI Responses incomplete handling")
struct OpenAIResponsesIncompleteTests {
    static let model = Model(
        id: "gpt-5-test", name: "GPT-5 Test",
        api: "openai-responses", provider: "openai",
        baseURL: "https://api.openai.com",
        reasoning: true, input: [.text],
        contextWindow: 128_000, maxTokens: 1024
    )

    @Test("response.incomplete finishes as length-truncated, not a clean stop")
    func incomplete() async {
        let sse = """
        data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}

        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}

        data: {"type":"response.content_part.added","output_index":0,"part":{"type":"output_text"}}

        data: {"type":"response.output_text.delta","output_index":0,"delta":"partial answer"}

        data: {"type":"response.incomplete","response":{"id":"resp_1","status":"incomplete","usage":{"input_tokens":3,"output_tokens":2}}}


        """
        let provider = OpenAIResponsesProvider(client: ChunkStubClient(text: sse), webSocketClient: nil, defaultAPIKey: "k")
        let s = provider.stream(model: Self.model, context: Context(messages: [.user(UserMessage(text: "hi"))]), options: nil)
        for await _ in s {}
        let result = await s.result()
        #expect(result.stopReason == .length)
        if case .text(let t)? = result.content.first {
            #expect(t.text == "partial answer")
        } else {
            Issue.record("expected streamed text content")
        }
    }
}

@Suite("Bedrock reasoning signature capture")
struct BedrockSignatureTests {
    static let model = Model(
        id: "anthropic.claude-sonnet-4-20250514-v1:0", name: "claude",
        api: "bedrock-converse-stream", provider: "amazon-bedrock",
        contextWindow: 200_000, maxTokens: 8192
    )

    private static func frame(_ type: String, _ payload: String) -> Data {
        encodeAWSEventFrame(
            headers: [":event-type": type, ":message-type": "event"],
            payload: Data(payload.utf8)
        )
    }

    @Test("reasoningContent.signature delta is captured onto the thinking block")
    func capturesSignature() async {
        var body = Data()
        body.append(Self.frame("messageStart", "{\"role\":\"assistant\"}"))
        body.append(Self.frame("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"reasoningContent\":{\"text\":\"thinking\"}}}"))
        body.append(Self.frame("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"reasoningContent\":{\"signature\":\"SIG123\"}}}"))
        body.append(Self.frame("contentBlockStop", "{\"contentBlockIndex\":0}"))
        body.append(Self.frame("messageStop", "{\"stopReason\":\"end_turn\"}"))

        let provider = BedrockProvider(
            client: ChunkStubClient(body: body),
            region: "us-east-1",
            resolveProfileFiles: false,
            credentialsProvider: { AWSSigV4.Credentials(accessKeyId: "k", secretAccessKey: "s") }
        )
        let s = provider.stream(model: Self.model, context: Context(messages: [.user(UserMessage(text: "hi"))]), options: nil)
        for await _ in s {}
        let result = await s.result()
        if case .thinking(let th)? = result.content.first {
            #expect(th.thinking == "thinking")
            #expect(th.thinkingSignature == "SIG123")
        } else {
            Issue.record("expected a thinking block with a captured signature")
        }
    }
}
