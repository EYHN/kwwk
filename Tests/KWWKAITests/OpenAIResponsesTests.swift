import Foundation
import Testing
@testable import KWWKAI

@Suite("OpenAI Responses provider")
struct OpenAIResponsesTests {
    static let model = Model(
        id: "gpt-5",
        name: "GPT-5",
        api: "openai-responses",
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: true,
        input: [.text, .image],
        contextWindow: 200_000,
        maxTokens: 8192
    )

    static let textSSE = """
    data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}

    data: {"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}

    data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hello"}

    data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":", world"}

    data: {"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hello, world"}}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message"}}

    data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":5,"output_tokens":3}}}

    """

    static let toolUseSSE = """
    data: {"type":"response.created","response":{"id":"resp_2","status":"in_progress"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"calc","arguments":""}}

    data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"a\\":1"}

    data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":",\\"b\\":2}"}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"calc"}}

    data: {"type":"response.completed","response":{"id":"resp_2","status":"completed","usage":{"input_tokens":12,"output_tokens":8}}}

    """

    static let toolUseDoneArgumentsSSE = """
    data: {"type":"response.created","response":{"id":"resp_4","status":"in_progress"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"calc","arguments":""}}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"calc","arguments":"{\\"a\\":1,\\"b\\":2}"}}

    data: {"type":"response.completed","response":{"id":"resp_4","status":"completed","usage":{"input_tokens":12,"output_tokens":8}}}

    """

    static let reasoningSSE = """
    data: {"type":"response.created","response":{"id":"resp_3","status":"in_progress"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"r_1"}}

    data: {"type":"response.reasoning_text.delta","output_index":0,"delta":"think…"}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning"}}

    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","role":"assistant","content":[]}}

    data: {"type":"response.content_part.added","output_index":1,"content_index":0,"part":{"type":"output_text","text":""}}

    data: {"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"answer"}

    data: {"type":"response.content_part.done","output_index":1,"content_index":0,"part":{"type":"output_text","text":"answer"}}

    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message"}}

    data: {"type":"response.completed","response":{"id":"resp_3","status":"completed","usage":{"input_tokens":20,"output_tokens":10}}}

    """

    @Test("streams text + completes with usage")
    func basicText() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "sk-test")
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
        #expect(result.responseId == "resp_1")
    }

    @Test("streams function_call with incremental arguments")
    func toolUse() async throws {
        let client = StubSSEClient(body: Self.toolUseSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "go"))]),
            options: nil
        )
        var seenEnd = false
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event {
                #expect(call.id == "call_1")
                #expect(call.name == "calc")
                #expect(call.arguments == .object(["a": 1, "b": 2]))
                seenEnd = true
            }
        }
        let result = await s.result()
        #expect(seenEnd)
        #expect(result.stopReason == .toolUse)
    }

    @Test("reads function_call arguments from output_item.done")
    func toolUseDoneArguments() async throws {
        let client = StubSSEClient(body: Self.toolUseDoneArgumentsSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "go"))]),
            options: nil
        )
        var seenEnd = false
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event {
                #expect(call.id == "call_1")
                #expect(call.name == "calc")
                #expect(call.arguments == .object(["a": 1, "b": 2]))
                seenEnd = true
            }
        }
        let result = await s.result()
        #expect(seenEnd)
        #expect(result.stopReason == .toolUse)
    }

    @Test("surfaces reasoning items as thinking blocks")
    func reasoningBlocks() async throws {
        let client = StubSSEClient(body: Self.reasoningSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "think"))]),
            options: StreamOptions(reasoning: .high)
        )
        for await _ in s {}
        let result = await s.result()
        #expect(result.content.count == 2)
        if case .thinking(let th) = result.content.first {
            #expect(th.thinking == "think…")
        } else { Issue.record("expected thinking first") }
        if case .text(let t) = result.content.last {
            #expect(t.text == "answer")
        } else { Issue.record("expected text last") }
    }

    @Test("resolved auth can select custom API key header")
    func resolvedAuthCustomAPIKeyHeader() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "sk-default")
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                apiKey: "sk-ignored",
                resolvedAuth: ResolvedProviderAuth(
                    token: "azure-key",
                    scheme: .apiKeyHeader(name: "api-key"),
                    headers: ["x-ms-client-request-id": "req-1"]
                )
            )
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let headers = client.lastRequest?.headers ?? [:]
        #expect(headers["authorization"] == nil)
        #expect(headers["api-key"] == "azure-key")
        #expect(headers["x-ms-client-request-id"] == "req-1")
    }

    @Test("encodes input array with instructions + tools")
    func bodyEncoding() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.model,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [.user(UserMessage(text: "hi"))],
                tools: [Tool(
                    name: "calc",
                    description: "arith",
                    parameters: ["type": "object", "properties": ["a": ["type": "number"]]]
                )]
            ),
            options: StreamOptions(
                reasoning: .medium,
                toolChoice: .required,
                parallelToolCalls: false
            )
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["instructions"] as? String == "Be concise.")
        #expect(json?["parallel_tool_calls"] as? Bool == false)
        #expect(json?["tool_choice"] as? String == "required")
        let reasoning = json?["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "medium")
        // store defaults to false (pi parity), and reasoning requests opt into
        // encrypted-reasoning round-tripping.
        #expect(json?["store"] as? Bool == false)
        #expect(json?["include"] as? [String] == ["reasoning.encrypted_content"])
        let input = json?["input"] as? [[String: Any]]
        #expect(input?.first?["type"] as? String == "message")
        #expect(input?.first?["role"] as? String == "user")
        let tools = json?["tools"] as? [[String: Any]]
        #expect(tools?.first?["type"] as? String == "function")
        #expect(tools?.first?["name"] as? String == "calc")
    }

    @Test("prompt_cache_key is clamped to 64 chars")
    func cacheKeyClamped() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        let longId = String(repeating: "x", count: 100)
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(sessionId: longId)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect((json?["prompt_cache_key"] as? String)?.count == 64)
    }

    @Test("represents tool_result as function_call_output in the input array")
    func toolResultEncoding() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call_1", name: "calc", arguments: ["a": 1]))],
            api: "openai-responses",
            provider: "openai",
            model: "gpt-5",
            stopReason: .toolUse
        )
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [
                .user(UserMessage(text: "compute")),
                .assistant(assistant),
                .toolResult(ToolResultMessage(
                    toolCallId: "call_1",
                    toolName: "calc",
                    content: [.text(TextContent(text: "1"))]
                )),
            ]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let input = json?["input"] as? [[String: Any]]
        #expect(input?.count == 3)
        #expect(input?[1]["type"] as? String == "function_call")
        #expect(input?[2]["type"] as? String == "function_call_output")
        #expect(input?[2]["call_id"] as? String == "call_1")
    }

    @Test("reports upstream error event as terminal stream error")
    func providerError() async throws {
        let errorSSE = """
        data: {"type":"response.failed","response":{"status":"failed","error":{"message":"quota exceeded"}}}

        """
        let client = StubSSEClient(body: errorSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        for await _ in s {}
        let result = await s.result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "quota exceeded")
    }

    @Test("defaults to WebSocket and sends response.create")
    func webSocketDefault() async throws {
        let http = StubSSEClient(body: Self.textSSE)
        let connection = StubWebSocketConnection(batches: [Self.webSocketMessages(from: Self.textSSE)])
        let ws = StubWebSocketClient(connection: connection)
        let provider = OpenAIResponsesProvider(client: http, webSocketClient: ws, defaultAPIKey: "k")
        let verbose = VerboseEventRecorder()

        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                sessionId: "ws-default",
                verbose: true,
                onVerbose: { event in await verbose.append(event) }
            )
        )
        for await _ in s {}
        let result = await s.result()

        #expect(result.responseId == "resp_1")
        #expect(ws.connectCount == 1)
        #expect(http.lastRequest == nil)
        #expect(ws.lastURL?.absoluteString == "wss://api.openai.com/v1/responses")
        #expect(ws.lastHeaders["Authorization"] == "Bearer k")
        #expect(ws.lastHeaders["OpenAI-Beta"] == "responses_websockets=2026-02-06")

        let payload = try Self.jsonObject(connection.sentTexts[0])
        #expect(payload["type"] as? String == "response.create")
        #expect(payload["previous_response_id"] == nil)
        let input = payload["input"] as? [[String: Any]]
        #expect(input?.count == 1)

        let messages = await verbose.messages()
        #expect(messages.contains("attempting WebSocket stream"))
        #expect(messages.contains("sent response.create"))
        #expect(messages.contains("WebSocket response completed; failure count reset"))
    }

    @Test("closeSession closes stored WebSocket connection")
    func closeSessionClosesStoredWebSocketConnection() async throws {
        let http = StubSSEClient(body: Self.textSSE)
        let connection = StubWebSocketConnection(batches: [Self.webSocketMessages(from: Self.textSSE)])
        let ws = StubWebSocketClient(connection: connection)
        let provider = OpenAIResponsesProvider(client: http, webSocketClient: ws, defaultAPIKey: "k")

        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(sessionId: "ws-close-session")
        )
        for await _ in s {}
        _ = await s.result()

        #expect(connection.closed == false)
        await provider.closeSession(sessionId: "ws-close-session")
        #expect(connection.closed == true)
    }

    @Test("reuses previous response id and sends only new input over WebSocket")
    func webSocketIncrementalInput() async throws {
        let first = Self.textSSE
        let second = Self.textSSE.replacingOccurrences(of: "resp_1", with: "resp_2")
        let connection = StubWebSocketConnection(batches: [
            Self.webSocketMessages(from: first),
            Self.webSocketMessages(from: second),
        ])
        let ws = StubWebSocketClient(connection: connection)
        let provider = OpenAIResponsesProvider(
            client: StubSSEClient(body: ""),
            webSocketClient: ws,
            defaultAPIKey: "k"
        )

        let firstStream = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(sessionId: "ws-incremental")
        )
        for await _ in firstStream {}
        let firstResult = await firstStream.result()

        let secondStream = provider.stream(
            model: Self.model,
            context: Context(messages: [
                .user(UserMessage(text: "hi")),
                .assistant(firstResult),
                .user(UserMessage(text: "again")),
            ]),
            options: StreamOptions(sessionId: "ws-incremental")
        )
        for await _ in secondStream {}
        let secondResult = await secondStream.result()

        #expect(firstResult.responseId == "resp_1")
        #expect(secondResult.responseId == "resp_2")
        #expect(ws.connectCount == 1)
        #expect(connection.sentTexts.count == 2)

        let payload = try Self.jsonObject(connection.sentTexts[1])
        #expect(payload["previous_response_id"] as? String == "resp_1")
        let input = payload["input"] as? [[String: Any]]
        #expect(input?.count == 1)
        #expect(input?.first?["role"] as? String == "user")
        let content = input?.first?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "again")
    }

    @Test("falls back to HTTP on connect failure and disables WebSocket after the failure budget")
    func webSocketConnectFailureBudgetFallsBackToHTTP() async throws {
        let http = StubSSEClient(body: Self.textSSE)
        let ws = StubWebSocketClient(error: StubWebSocketError.connect)
        let provider = OpenAIResponsesProvider(
            client: http,
            webSocketClient: ws,
            defaultAPIKey: "k",
            maxWebSocketFailures: 2
        )
        let options = StreamOptions(sessionId: "ws-fallback")

        let first = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: options
        )
        for await _ in first {}
        #expect(await first.result().responseId == "resp_1")
        #expect(ws.connectCount == 1)
        #expect(http.lastRequest != nil)

        let second = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "again"))]),
            options: options
        )
        for await _ in second {}
        #expect(await second.result().responseId == "resp_1")
        #expect(ws.connectCount == 2)

        let third = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "after disabled"))]),
            options: options
        )
        for await _ in third {}
        #expect(await third.result().responseId == "resp_1")
        #expect(ws.connectCount == 2)
    }

    @Test("falls back to HTTP when WebSocket receive fails before the first event")
    func webSocketReceiveFailureBeforeFirstEventFallsBackToHTTP() async throws {
        let http = StubSSEClient(body: Self.textSSE)
        let connection = StubWebSocketConnection(batches: [[]], receiveError: StubWebSocketError.receive)
        let ws = StubWebSocketClient(connection: connection)
        let provider = OpenAIResponsesProvider(client: http, webSocketClient: ws, defaultAPIKey: "k")

        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(sessionId: "ws-receive-fallback")
        )
        for await _ in s {}
        let result = await s.result()

        #expect(result.responseId == "resp_1")
        #expect(ws.connectCount == 1)
        #expect(http.lastRequest != nil)
    }

    @Test("reconnects on the next request after a WebSocket stream failure")
    func webSocketStreamFailureReconnectsNextRequest() async throws {
        let responseCreated = """
        {"type":"response.created","response":{"id":"resp_partial","status":"in_progress"}}
        """
        let firstConnection = StubWebSocketConnection(
            batches: [[responseCreated]],
            receiveError: StubWebSocketError.receive
        )
        let secondConnection = StubWebSocketConnection(batches: [Self.webSocketMessages(from: Self.textSSE)])
        let ws = StubWebSocketClient(connections: [firstConnection, secondConnection])
        let http = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: http, webSocketClient: ws, defaultAPIKey: "k")
        let options = StreamOptions(sessionId: "ws-reconnect-after-stream-error")

        let first = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: options
        )
        for await _ in first {}
        let firstResult = await first.result()
        #expect(firstResult.stopReason == .error)
        #expect(firstResult.errorMessage?.contains("WebSocket stream failed") == true)
        #expect(http.lastRequest == nil)
        #expect(ws.connectCount == 1)

        let second = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: options
        )
        for await _ in second {}
        #expect(await second.result().responseId == "resp_1")
        #expect(ws.connectCount == 2)
        #expect(http.lastRequest == nil)
    }

    @Test("returns a stream error when WebSocket closes before response.completed after events")
    func webSocketCloseAfterEventsBeforeCompletedReturnsError() async throws {
        let responseCreated = """
        {"type":"response.created","response":{"id":"resp_partial","status":"in_progress"}}
        """
        let connection = StubWebSocketConnection(batches: [[responseCreated]])
        let ws = StubWebSocketClient(connection: connection)
        let http = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(client: http, webSocketClient: ws, defaultAPIKey: "k")

        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(sessionId: "ws-close-after-events")
        )
        for await _ in s {}
        let result = await s.result()

        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("closed before response.completed") == true)
        #expect(ws.connectCount == 1)
        #expect(http.lastRequest == nil)
    }

    @Test("returns an error instead of multiplexing a busy WebSocket session")
    func webSocketBusySessionReturnsError() async throws {
        let http = StubSSEClient(body: Self.textSSE.replacingOccurrences(of: "resp_1", with: "resp_http"))
        let connection = StubWebSocketConnection(
            batches: [Self.webSocketMessages(from: Self.textSSE)],
            firstReceiveDelayNanoseconds: 300_000_000
        )
        let ws = StubWebSocketClient(connection: connection)
        let provider = OpenAIResponsesProvider(client: http, webSocketClient: ws, defaultAPIKey: "k")
        let options = StreamOptions(sessionId: "ws-busy-session")

        let first = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "first"))]),
            options: options
        )
        #expect(await Self.waitUntil { connection.sentTexts.count == 1 })

        let second = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "second"))]),
            options: options
        )
        for await _ in second {}
        let secondResult = await second.result()

        for await _ in first {}
        let firstResult = await first.result()

        #expect(firstResult.responseId == "resp_1")
        #expect(secondResult.stopReason == .error)
        #expect(secondResult.errorMessage?.contains("in-flight response") == true)
        #expect(ws.connectCount == 1)
        #expect(connection.sentTexts.count == 1)
        #expect(http.lastRequest == nil)
    }

    @Test("successful WebSocket responses reset the failure budget")
    func webSocketSuccessResetsFailureBudget() async throws {
        let failingFirst = StubWebSocketConnection(batches: [[]], receiveError: StubWebSocketError.receive)
        let succeedingThenFailingSecond = StubWebSocketConnection(
            batches: [Self.webSocketMessages(from: Self.textSSE)],
            sendErrors: [nil, StubWebSocketError.send]
        )
        let succeedingFourth = StubWebSocketConnection(batches: [Self.webSocketMessages(from: Self.textSSE)])
        let ws = StubWebSocketClient(connections: [
            failingFirst,
            succeedingThenFailingSecond,
            succeedingFourth,
        ])
        let http = StubSSEClient(body: Self.textSSE)
        let provider = OpenAIResponsesProvider(
            client: http,
            webSocketClient: ws,
            defaultAPIKey: "k",
            maxWebSocketFailures: 2
        )
        let options = StreamOptions(sessionId: "ws-budget-reset")

        let first = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "first"))]),
            options: options
        )
        for await _ in first {}
        #expect(await first.result().responseId == "resp_1")
        #expect(http.lastRequest != nil)

        let second = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "second"))]),
            options: options
        )
        for await _ in second {}
        #expect(await second.result().responseId == "resp_1")

        let third = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "third"))]),
            options: options
        )
        for await _ in third {}
        #expect(await third.result().responseId == "resp_1")

        let fourth = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "fourth"))]),
            options: options
        )
        for await _ in fourth {}
        #expect(await fourth.result().responseId == "resp_1")
        #expect(ws.connectCount == 3)
    }

    private static func webSocketMessages(from sse: String) -> [String] {
        sse.components(separatedBy: "\n\n").compactMap { block in
            let dataLines = block.split(separator: "\n").compactMap { line -> String? in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("data:") else { return nil }
                return String(text.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
    }

    private static func jsonObject(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }
}

enum StubWebSocketError: Error {
    case connect
    case receive
    case send
}

actor VerboseEventRecorder {
    private var events: [VerboseEvent] = []

    func append(_ event: VerboseEvent) {
        events.append(event)
    }

    func messages() -> [String] {
        events.map(\.message)
    }
}

final class StubWebSocketClient: WebSocketClient, @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [StubWebSocketConnection]
    private let error: Error?
    private var _connectCount = 0
    private var _lastURL: URL?
    private var _lastHeaders: [String: String] = [:]

    init(connection: StubWebSocketConnection = StubWebSocketConnection(batches: []), error: Error? = nil) {
        self.connections = [connection]
        self.error = error
    }

    init(connections: [StubWebSocketConnection]) {
        self.connections = connections
        self.error = nil
    }

    var connectCount: Int { lock.withLock { _connectCount } }
    var lastURL: URL? { lock.withLock { _lastURL } }
    var lastHeaders: [String: String] { lock.withLock { _lastHeaders } }

    func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        try lock.withLock {
            _connectCount += 1
            _lastURL = url
            _lastHeaders = headers
            if let error { throw error }
            if connections.count > 1 {
                return connections.removeFirst()
            }
            return connections.first ?? StubWebSocketConnection(batches: [])
        }
    }
}

final class StubWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[String]]
    private var receiveError: Error?
    private var sendErrors: [Error?]
    private var firstReceiveDelayNanoseconds: UInt64
    private var pending: [WebSocketMessage] = []
    private var _sentTexts: [String] = []
    private var _closed = false

    init(
        batches: [[String]],
        receiveError: Error? = nil,
        sendErrors: [Error?] = [],
        firstReceiveDelayNanoseconds: UInt64 = 0
    ) {
        self.batches = batches
        self.receiveError = receiveError
        self.sendErrors = sendErrors
        self.firstReceiveDelayNanoseconds = firstReceiveDelayNanoseconds
    }

    var sentTexts: [String] { lock.withLock { _sentTexts } }
    var closed: Bool { lock.withLock { _closed } }

    func send(_ message: WebSocketMessage) async throws {
        try lock.withLock {
            if !sendErrors.isEmpty, let error = sendErrors.removeFirst() {
                throw error
            }
            if case .text(let text) = message {
                _sentTexts.append(text)
            }
            if !batches.isEmpty {
                pending.append(contentsOf: batches.removeFirst().map(WebSocketMessage.text))
            }
        }
    }

    func receive() async throws -> WebSocketMessage? {
        let delay = lock.withLock { () -> UInt64 in
            let delay = firstReceiveDelayNanoseconds
            firstReceiveDelayNanoseconds = 0
            return delay
        }
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        return try lock.withLock { () throws -> WebSocketMessage? in
            if !pending.isEmpty {
                return pending.removeFirst()
            }
            if let error = receiveError {
                receiveError = nil
                throw error
            }
            return nil
        }
    }

    func close() {
        lock.withLock { _closed = true }
    }
}
