import Foundation
import Testing
@testable import KWAI

/// Stub HTTP client that streams a pre-recorded SSE body from memory. Also
/// captures the request body so we can assert on the encoding.
final class StubSSEClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    let body: String
    var statusCode: Int
    var lastRequest: (url: URL, method: String, headers: [String: String], body: Data?)?

    init(body: String, statusCode: Int = 200) {
        self.body = body
        self.statusCode = statusCode
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body requestBody: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        lock.withLock { lastRequest = (url, method, headers, requestBody) }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "text/event-stream"]
        )!

        let bodyBytes = Array(body.utf8)
        let stream = AsyncThrowingStream<UInt8, Error> { cont in
            Task {
                for byte in bodyBytes {
                    cont.yield(byte)
                }
                cont.finish()
            }
        }
        return (response, stream)
    }
}

@Suite("Anthropic provider")
struct AnthropicProviderTests {

    static let sampleModel = Model(
        id: "claude-test",
        name: "Claude Test",
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: false,
        input: [.text],
        contextWindow: 128_000,
        maxTokens: 1024
    )

    private static let textSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":5,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private static let toolUseSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_2","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":10,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"calc","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"a\\":1"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":",\\"b\\":2}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @Test("streams basic text and resolves final assistant message")
    func basicText() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        let s = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var types: [String] = []
        var accText = ""
        for await event in s {
            types.append(event.type)
            if case .textDelta(_, let delta, _) = event { accText += delta }
        }
        let result = await s.result()
        #expect(types.contains("message_start") == false) // no such type at our boundary
        #expect(types.first == "start")
        #expect(types.contains("text_start"))
        #expect(types.contains("text_delta"))
        #expect(types.contains("text_end"))
        #expect(types.last == "done")
        #expect(accText == "Hello, world")
        #expect(result.stopReason == .stop)
        #expect(result.content == [.text(TextContent(text: "Hello, world"))])
        #expect(result.usage.input == 5)
        #expect(result.usage.output == 4)
    }

    @Test("streams a tool_use block and parses incremental JSON input")
    func toolUse() async throws {
        let client = StubSSEClient(body: Self.toolUseSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        let s = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "please call calc"))]),
            options: nil
        )
        var seenToolEnd = false
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event {
                #expect(call.id == "toolu_1")
                #expect(call.name == "calc")
                #expect(call.arguments == .object(["a": 1, "b": 2]))
                seenToolEnd = true
            }
        }
        let result = await s.result()
        #expect(seenToolEnd)
        #expect(result.stopReason == .toolUse)
    }

    @Test("surfaces HTTP errors as terminal stream errors")
    func httpError() async throws {
        let client = StubSSEClient(body: "", statusCode: 500)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        let s = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        var terminalError: AssistantMessage?
        for await event in s {
            if case .error(_, let err) = event { terminalError = err }
        }
        #expect(terminalError != nil)
        #expect(terminalError?.stopReason == .error)
    }

    @Test("sets x-api-key and anthropic-version headers")
    func headersWired() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(
            client: client,
            defaultAPIKey: "default-key",
            apiVersion: "2023-06-01"
        )
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(apiKey: "override-key")
        )
        // Give the detached task time to emit the request.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let req = client.lastRequest
        #expect(req != nil)
        #expect(req?.headers["x-api-key"] == "override-key")
        #expect(req?.headers["anthropic-version"] == "2023-06-01")
        #expect(req?.headers["accept"] == "text/event-stream")
    }

    @Test("encodes user text and tool blocks in Anthropic body shape")
    func encodesBody() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "k")
        let tool = Tool(
            name: "calc",
            description: "arithmetic",
            parameters: [
                "type": "object",
                "properties": ["a": ["type": "number"], "b": ["type": "number"]],
                "required": ["a", "b"],
            ]
        )
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: "c-1", name: "calc", arguments: ["a": 1, "b": 2]))],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude-test",
            stopReason: .toolUse
        )
        _ = provider.stream(
            model: Self.sampleModel,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [
                    .user(UserMessage(text: "calc 1 + 2")),
                    .assistant(assistant),
                    .toolResult(ToolResultMessage(
                        toolCallId: "c-1",
                        toolName: "calc",
                        content: [.text(TextContent(text: "3"))]
                    )),
                    .user(UserMessage(text: "thanks")),
                ],
                tools: [tool]
            ),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)

        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "claude-test")
        #expect(json?["system"] as? String == "Be concise.")
        #expect((json?["messages"] as? [[String: Any]])?.count == 4)
        let tools = json?["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "calc")
    }
}
