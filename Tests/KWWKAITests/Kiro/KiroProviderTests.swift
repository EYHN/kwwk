import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stands in for Kiro: each request takes the next scripted answer, the last
/// one repeating, and is recorded.
private final class KiroStubClient: HTTPClient, @unchecked Sendable {
    struct Answer {
        var status = 200
        var headers = ["Content-Type": "application/vnd.amazon.eventstream"]
        var chunks: [Data] = []
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private(set) var requests: [(url: URL, method: String, headers: [String: String], body: Data?)] = []

    init(_ answers: [Answer]) { self.answers = answers }

    convenience init(status: Int = 200, _ chunks: Data...) {
        self.init([Answer(status: status, chunks: chunks)])
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let answer: Answer = lock.withLock {
            requests.append((url, method, headers, body))
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers
        )!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in answer.chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return (response, stream)
    }
}

// MARK: - Helpers

private func bigEndian(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
}

/// One event-stream message, the way Kiro sends them (magpie `kiroMsg`).
/// The checksums are left zero: neither magpie's reader nor kwwk's checks them.
private func kiroMessage(_ headers: [(String, String)], _ payload: String) -> Data {
    var head = Data()
    for (name, value) in headers {
        head.append(UInt8(name.utf8.count))
        head.append(Data(name.utf8))
        head.append(7)
        head.append(Data([UInt8(value.utf8.count >> 8), UInt8(value.utf8.count & 0xff)]))
        head.append(Data(value.utf8))
    }
    var out = bigEndian(UInt32(12 + head.count + payload.utf8.count + 4))
    out.append(bigEndian(UInt32(head.count)))
    out.append(bigEndian(0))
    out.append(head)
    out.append(Data(payload.utf8))
    out.append(bigEndian(0))
    return out
}

private func kiroEvent(_ kind: String, _ payload: String) -> Data {
    kiroMessage([(":message-type", "event"), (":event-type", kind), (":content-type", "application/json")], payload)
}

private let sonnet = Model(
    id: "claude-sonnet-4.5", name: "Claude Sonnet 4.5", api: KiroModels.api, provider: "kiro",
    baseURL: "https://runtime.us-east-1.kiro.dev", reasoning: true, input: [.text, .image],
    contextWindow: 200_000, maxTokens: 64_000
)

private func kiroAuth(
    token: String = "tok",
    profile: String? = "arn:p",
    baseURL: String? = nil
) -> ResolvedProviderAuth {
    ResolvedProviderAuth(
        token: token,
        scheme: .bearer,
        baseURL: baseURL,
        metadata: profile.map { ["profileArn": .string($0)] } ?? [:]
    )
}

/// Runs one turn against scripted frames and returns the final message and
/// the events on the way.
private func turn(
    _ client: KiroStubClient,
    model: Model = sonnet,
    context: Context = Context(messages: [.user(UserMessage(text: "hi"))]),
    reasoning: ReasoningLevel? = nil,
    auth: ResolvedProviderAuth? = kiroAuth()
) async -> (AssistantMessage, [AssistantMessageEvent]) {
    let stream = KiroProvider(client: client).stream(
        model: model, context: context, options: StreamOptions(resolvedAuth: auth, reasoning: reasoning)
    )
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return (await stream.result(), events)
}

/// The message's text, thinking and calls, in order (magpie's `said`).
private func said(_ message: AssistantMessage) -> String {
    var out = ""
    for block in message.content {
        switch block {
        case .text(let text): out += "|text:\(text.text)"
        case .thinking(let thinking): out += "|think:\(thinking.thinking)"
        case .toolCall(let call):
            let arguments = (try? JSONValueEncoder.encode(call.arguments)) ?? "?"
            out += "|call:\(call.id)/\(call.name)|args:\(arguments)"
        case .fallback: break
        }
    }
    if let error = message.errorMessage { out += "|error:\(error)" }
    return out + "|stop:\(message.stopReason.rawValue)"
}

private func object(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// A built request body, read the way magpie's `kiroBody` reads it.
private struct BuiltBody {
    var root: [String: Any]
    var state: [String: Any] { root["conversationState"] as? [String: Any] ?? [:] }
    var history: [[String: Any]] { state["history"] as? [[String: Any]] ?? [] }
    var current: [String: Any] {
        (state["currentMessage"] as? [String: Any])?["userInputMessage"] as? [String: Any] ?? [:]
    }

    func user(_ index: Int) -> [String: Any] { history[index]["userInputMessage"] as? [String: Any] ?? [:] }
    func assistant(_ index: Int) -> [String: Any] {
        history[index]["assistantResponseMessage"] as? [String: Any] ?? [:]
    }

    static func images(_ user: [String: Any]) -> [[String: Any]] { user["images"] as? [[String: Any]] ?? [] }
    static func results(_ user: [String: Any]) -> [[String: Any]] {
        (user["userInputMessageContext"] as? [String: Any])?["toolResults"] as? [[String: Any]] ?? []
    }
    static func toolNames(_ user: [String: Any]) -> [String] {
        ((user["userInputMessageContext"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap {
            ($0["toolSpecification"] as? [String: Any])?["name"] as? String
        }
    }
    static func resultText(_ result: [String: Any]) -> String? {
        (result["content"] as? [[String: Any]])?.first?["text"] as? String
    }
}

private func build(
    system: String? = nil,
    messages: [Message],
    tools: [Tool] = [],
    model: Model = sonnet,
    reasoning: ReasoningLevel? = nil
) throws -> BuiltBody {
    BuiltBody(root: try object(KiroRequest.build(
        model: model, systemPrompt: system, messages: messages, tools: tools, profileArn: "arn:p", reasoning: reasoning
    )))
}

private func assistant(_ blocks: [AssistantBlock]) -> Message {
    .assistant(AssistantMessage(content: blocks, api: KiroModels.api, provider: "kiro", model: sonnet.id))
}

private func text(_ text: String) -> AssistantBlock { .text(TextContent(text: text)) }

private func call(_ id: String, _ name: String, _ arguments: JSONValue = .object([:])) -> AssistantBlock {
    .toolCall(ToolCall(id: id, name: name, arguments: arguments))
}

private func result(_ id: String, _ blocks: [ToolResultBlock], isError: Bool = false) -> Message {
    .toolResult(ToolResultMessage(toolCallId: id, toolName: "tool", content: blocks, isError: isError))
}

private let objectSchema: JSONValue = .object(["type": "object"])

// MARK: - Reply

// Ported from magpie's gateway/kiro_test.go, whose frames are Kiro's own.
@Suite("Kiro reply decoding")
struct KiroReplyTests {
    @Test("Text and calls: arguments arrive in pieces, a new id opens the next call")
    func textAndCalls() async throws {
        let client = KiroStubClient(
            kiroEvent("assistantResponseEvent", #"{"content":"Let me "}"#),
            kiroEvent("assistantResponseEvent", #"{"content":"look."}"#),
            kiroEvent("toolUseEvent", #"{"name":"read","toolUseId":"tooluse_1","input":"{\"pa"}"#),
            kiroEvent("toolUseEvent", #"{"name":"read","toolUseId":"tooluse_1","input":"th\":\"a\"}"}"#),
            kiroEvent("toolUseEvent", #"{"name":"read","toolUseId":"tooluse_1","stop":true}"#),
            kiroEvent("toolUseEvent", #"{"name":"ls","toolUseId":"tooluse_2","input":"{}"}"#),
            kiroEvent("metadataEvent", #"{"tokenUsage":{"uncachedInputTokens":120,"outputTokens":30,"cacheReadInputTokens":7}}"#)
        )
        let (message, events) = await turn(client)
        #expect(said(message) == #"|text:Let me look.|call:tooluse_1/read|args:{"path":"a"}|call:tooluse_2/ls|args:{}|stop:toolUse"#)
        #expect(message.usage.input == 120)
        #expect(message.usage.output == 30)
        #expect(message.usage.cacheRead == 7)
        #expect(message.usage.totalTokens == 157)
        #expect(message.api == "kiro-assistant")
        #expect(message.provider == "kiro")

        guard case .start? = events.first, case .done(reason: .toolUse, _)? = events.last else {
            Issue.record("events open with start and close with done: \(events)")
            return
        }
        let deltas = events.compactMap { event -> String? in
            if case .toolCallDelta(_, let delta, _) = event { return delta }
            return nil
        }
        #expect(deltas == [#"{"pa"#, #"th":"a"}"#, "{}"])
        let ended = events.compactMap { event -> String? in
            if case .toolCallEnd(_, let call, _) = event { return call.id }
            return nil
        }
        #expect(ended == ["tooluse_1", "tooluse_2"])
    }

    @Test("An object input and string pieces after it are merged into one call")
    func objectInputThenPieces() async throws {
        let (message, _) = await turn(KiroStubClient(
            kiroEvent("toolUseEvent", #"{"name":"send","toolUseId":"t1","input":{"action":"send"}}"#),
            kiroEvent("toolUseEvent", #"{"name":"send","toolUseId":"t1","input":",\"channel_id\":\"ch_1\"}"}"#),
            kiroEvent("toolUseEvent", #"{"name":"send","toolUseId":"t2","input":{"action":"send"}}"#),
            kiroEvent("toolUseEvent", #"{"name":"send","toolUseId":"t2","input":"{\"channel_id\":\"ch_2\"}"}"#),
            kiroEvent("toolUseEvent", #"{"name":"send","toolUseId":"t3","input":"{\"chan"}"#)
        ))
        let calls = message.content.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        #expect(calls.map(\.arguments) == [
            .object(["action": "send", "channel_id": "ch_1"]),
            .object(["action": "send", "channel_id": "ch_2"]),
            .object([:]),
        ])
        #expect(calls.map(\.unparsedArguments) == [nil, nil, #"{"chan"#])
    }

    @Test("With no token counts, the input is how full Kiro says the context is")
    func usageFromContextPercentage() async throws {
        let (message, _) = await turn(KiroStubClient(
            kiroEvent("assistantResponseEvent", #"{"content":"12345678"}"#),
            kiroEvent("contextUsageEvent", #"{"contextUsagePercentage":1.5}"#),
            kiroEvent("metadataEvent", #"{"stopReason":"MAX_TOKENS"}"#)
        ))
        #expect(message.usage.input == 3000)
        #expect(message.usage.output == 2)
        #expect(message.stopReason == .length)
    }

    @Test("Asked to think, the reply's <thinking> is the thinking, however its tags fall across the pieces")
    func thinkingTags() async throws {
        var (message, _) = await turn(KiroStubClient(
            kiroEvent("assistantResponseEvent", #"{"content":"<thin"}"#),
            kiroEvent("assistantResponseEvent", #"{"content":"king>"}"#),
            kiroEvent("assistantResponseEvent", #"{"content":"\nHmm, a < b"}"#),
            kiroEvent("assistantResponseEvent", #"{"content":" so.</thi"}"#),
            kiroEvent("assistantResponseEvent", #"{"content":"nking>\n\nIt is."}"#)
        ), reasoning: .medium)
        #expect(said(message) == "|think:Hmm, a < b so.|text:It is.|stop:stop")

        // A reply that doesn't open with it is all text.
        (message, _) = await turn(
            KiroStubClient(kiroEvent("assistantResponseEvent", #"{"content":"<b>hi</b>"}"#)), reasoning: .medium
        )
        #expect(said(message) == "|text:<b>hi</b>|stop:stop")

        // And a call ends the thinking it cut short.
        (message, _) = await turn(KiroStubClient(
            kiroEvent("assistantResponseEvent", #"{"content":"<thinking>plan</th"}"#),
            kiroEvent("toolUseEvent", #"{"name":"ls","toolUseId":"t1","input":"{}"}"#)
        ), reasoning: .medium)
        #expect(said(message) == "|think:plan</th|call:t1/ls|args:{}|stop:toolUse")
    }

    @Test("Not asked to think, the tags are the reply's own text")
    func tagsWithoutThinking() async throws {
        let (message, _) = await turn(KiroStubClient(
            kiroEvent("assistantResponseEvent", #"{"content":"<thinking>x</thinking>y"}"#)
        ))
        #expect(said(message) == "|text:<thinking>x</thinking>y|stop:stop")
    }

    @Test("Reasoning events are thinking, with the signature kept on the block")
    func reasoningEvents() async throws {
        let (message, _) = await turn(KiroStubClient(
            kiroEvent("reasoningContentEvent", #"{"text":"Hmm."}"#),
            kiroEvent("reasoningContentEvent", #"{"signature":"sig"}"#),
            kiroEvent("assistantResponseEvent", #"{"content":"Yes."}"#)
        ))
        #expect(said(message) == "|think:Hmm.|text:Yes.|stop:stop")
        guard case .thinking(let block)? = message.content.first else {
            Issue.record("no thinking block")
            return
        }
        #expect(block.thinkingSignature == "sig")
    }

    @Test("Arguments sent as one object are the call's arguments")
    func objectArguments() async throws {
        let (message, _) = await turn(KiroStubClient(
            kiroEvent("toolUseEvent", #"{"name":"read","toolUseId":"t1","input":{"p":1}}"#)
        ))
        #expect(said(message) == #"|call:t1/read|args:{"p":1}|stop:toolUse"#)
    }

    @Test("A frame past Bedrock's megabyte is still Kiro's (magpie reads up to 16 MiB)")
    func longFrame() async throws {
        let long = String(repeating: "x", count: (1 << 20) + 1)
        let (message, _) = await turn(KiroStubClient(
            kiroEvent("toolUseEvent", #"{"name":"write","toolUseId":"t1","input":{"text":""# + long + #""}}"#)
        ))
        #expect(message.stopReason == .toolUse)
        guard case .toolCall(let call)? = message.content.first else {
            Issue.record("no call: \(message)")
            return
        }
        #expect(call.arguments["text"] == .string(long))
    }

    @Test("Text after a call closes the call before it is said")
    func textAfterCall() async throws {
        let (message, events) = await turn(KiroStubClient(
            kiroEvent("toolUseEvent", #"{"name":"ls","toolUseId":"t1","input":"{\"a\":1}"}"#),
            kiroEvent("assistantResponseEvent", #"{"content":"then"}"#)
        ))
        #expect(said(message) == #"|call:t1/ls|args:{"a":1}|text:then|stop:toolUse"#)
        let order = events.compactMap { event -> String? in
            switch event {
            case .toolCallEnd: return "callEnd"
            case .textStart: return "textStart"
            default: return nil
            }
        }
        #expect(order == ["callEnd", "textStart"])
    }

    @Test("An exception in the stream fails the turn, what was said kept")
    func streamException() async throws {
        let (message, events) = await turn(KiroStubClient(
            kiroEvent("assistantResponseEvent", #"{"content":"hi"}"#),
            kiroMessage(
                [(":message-type", "exception"), (":exception-type", "ThrottlingException")],
                #"{"message":"slow down"}"#
            )
        ))
        #expect(said(message) == "|text:hi|error:Kiro: rate limited: slow down|stop:error")
        #expect(message.failure?.category == .rateLimit)
        #expect(message.failure?.providerCode == "ThrottlingException")
        guard case .error(reason: .error, _)? = events.last else {
            Issue.record("the turn did not end in an error: \(events)")
            return
        }
    }

    @Test("An error event names its kind and Kiro's reason")
    func errorEvent() async throws {
        let (message, _) = await turn(KiroStubClient(
            kiroEvent("internalServerException", #"{"Message":"boom","reason":"INTERNAL"}"#)
        ))
        #expect(message.errorMessage == "Kiro: internalServerException: boom (INTERNAL)")
        #expect(message.failure?.category == .server)
    }

    // magpie-plugins kiro errors.test.mjs (0.1.4): Kiro sends these as
    // exceptions under a 200, before any of the answer. The plugin answers
    // its host a 429 for a throttle or a quota and a 502 for the rest; here
    // each is the category the rest of kwwk reads those by, and a spent
    // allowance is not asked again as a throttle would be.
    @Test("An exception before any of the answer is read by what it says", arguments: [
        ("ThrottlingException", #"{"message":"Too many requests"}"#,
         "Kiro: rate limited: Too many requests", ProviderFailure.Category.rateLimit, true),
        ("ServiceQuotaExceededException", #"{"message":"You have reached the limit"}"#,
         "Kiro: usage limit reached: You have reached the limit", .quota, false),
        ("ThrottlingException", #"{"message":"You've reached the limit.","reason":"MONTHLY_REQUEST_COUNT"}"#,
         "Kiro: usage limit reached: You've reached the limit. (MONTHLY_REQUEST_COUNT)", .quota, false),
        ("ValidationException", #"{"message":"Input is too long."}"#,
         "Kiro: ValidationException: Input is too long.", .contextOverflow, false),
        ("InternalServerException", #"{"message":"boom"}"#,
         "Kiro: InternalServerException: boom", .server, true),
    ])
    func earlyException(
        kind: String, payload: String, expected: String, category: ProviderFailure.Category, retried: Bool
    ) async throws {
        let (message, events) = await turn(KiroStubClient(
            kiroMessage([(":message-type", "exception"), (":exception-type", kind)], payload)
        ))
        #expect(said(message) == "|error:\(expected)|stop:error")
        #expect(message.failure?.providerCode == kind)
        #expect(message.failure?.category == category)
        #expect(message.failure?.isRetryable == retried)
        guard case .error(reason: .error, _)? = events.last else {
            Issue.record("the turn did not end in an error: \(events)")
            return
        }
    }

    @Test("A reply cut off mid-message is a transport failure, not a finished answer")
    func brokenOff() async throws {
        let full = kiroEvent("assistantResponseEvent", #"{"content":"hi"}"#)
        let (message, _) = await turn(KiroStubClient(full, full.prefix(10)))
        #expect(said(message) == "|text:hi|error:Kiro stream ended before its last frame was complete|stop:error")
        #expect(message.failure?.category == .transport)
    }

    @Test("A cut-off reply still says the thinking the parser held back")
    func brokenOffWhileThinking() async throws {
        let full = kiroEvent("assistantResponseEvent", #"{"content":"<thinking>plan</th"}"#)
        let (message, _) = await turn(KiroStubClient(full, full.prefix(10)), reasoning: .high)
        #expect(said(message).hasPrefix("|think:plan</th|error:"))
    }

    @Test("No frame at all is an empty reply, and a web page served 200 is no reply")
    func noReply() async throws {
        var (message, _) = await turn(KiroStubClient())
        #expect(message.stopReason == .error)
        #expect(message.failure?.category == .transport)

        (message, _) = await turn(KiroStubClient([
            .init(headers: ["Content-Type": "text/html; charset=utf-8"], chunks: [Data("<html>".utf8)]),
        ]))
        #expect(message.errorMessage == "Kiro answered with a web page, not an API reply")
        #expect(message.failure?.category == .server)
    }

    @Test("A filtered reply is a refusal")
    func filtered() async throws {
        let (message, _) = await turn(KiroStubClient(
            kiroEvent("metadataEvent", #"{"stopReason":"CONTENT_FILTERED"}"#)
        ))
        #expect(message.stopReason == .error)
        #expect(message.failure?.category == .refusal)
    }

    @Test("Headers of other types before the one read do not hide it")
    func frameHeaders() throws {
        var head = Data([4]) + Data("flag".utf8) + Data([0]) // true
        head += Data([3]) + Data("num".utf8) + Data([4, 0, 0, 0, 9]) // int32
        head += Data([2]) + Data("ts".utf8) + Data([8, 0, 0, 0, 0, 0, 0, 0, 1]) // timestamp
        head += Data([11]) + Data(":event-type".utf8) + Data([7, 0, 1]) + Data("x".utf8)
        var frame = bigEndian(UInt32(12 + head.count + 2 + 4)) + bigEndian(UInt32(head.count)) + bigEndian(0)
        frame += head + Data("{}".utf8) + bigEndian(0)

        var decoder = AWSEventStreamDecoder()
        // Fed a byte at a time, the frame is whole only at its last byte.
        var messages: [AWSEventMessage] = []
        for byte in frame {
            #expect(messages.isEmpty)
            messages += try decoder.append(Data([byte]))
        }
        #expect(messages.count == 1)
        #expect(messages.first?.headers[":event-type"] == "x")
        #expect(messages.first?.payload == Data("{}".utf8))
        #expect(!decoder.isMidFrame)
    }

    @Test("Split think tags", arguments: [
        (["<thinking>a</thinking>b"], [KiroThinkParser.Piece.thinking("a"), .text("b")]),
        (["  \n<thinking>\n\na", "</thinking>\n\nb"], [.thinking("a"), .text("b")]),
        (["<", "t", "hinking>a<", "/thinking>", "b"], [.thinking("a"), .text("b")]),
        (["<thought>a"], [.text("<thought>a")]),
        (["<thinking>a"], [.thinking("a")]),
        (["<thi"], [.text("<thi")]),
    ])
    func thinkParser(pieces: [String], expected: [KiroThinkParser.Piece]) {
        var parser = KiroThinkParser()
        var out: [KiroThinkParser.Piece] = []
        for piece in pieces { out += parser.feed(piece) }
        out += parser.end()
        // Neighbouring pieces of one kind are one run.
        var merged: [KiroThinkParser.Piece] = []
        for piece in out {
            switch (merged.last, piece) {
            case (.thinking(let a)?, .thinking(let b)): merged[merged.count - 1] = .thinking(a + b)
            case (.text(let a)?, .text(let b)): merged[merged.count - 1] = .text(a + b)
            default: merged.append(piece)
            }
        }
        #expect(merged == expected)
    }
}

// MARK: - Request

@Suite("Kiro request encoding")
struct KiroRequestTests {
    @Test("The conversation is made the shape Kiro takes (magpie TestBuildKiro)")
    func conversation() throws {
        let long = "call:" + String(repeating: "x", count: 80)
        let body = try build(
            system: "Be brief.",
            messages: [
                assistant([text("an opening the caller made up")]),
                .user(UserMessage(content: [
                    .text(TextContent(text: "hi")),
                    .image(ImageContent(data: "AAA", mimeType: "image/png"))
                ])),
                assistant([text("reading"), call("c1", "read", ["p": 1]), call(long, "grep")]),
                result("c1", [.text(TextContent(text: "file"))]),
                result("orphan", [.text(TextContent(text: "?"))]),
                .user(UserMessage(content: [
                    .text(TextContent(text: "and?")),
                    .image(ImageContent(data: "BBB", mimeType: "image/jpeg"))
                ])),
                assistant([text("done")]),
            ],
            tools: [Tool(name: "read", description: "Read a file", parameters: objectSchema)]
        )
        #expect(body.root["profileArn"] as? String == "arn:p")
        #expect(body.root["agentMode"] as? String == "vibe")
        #expect(body.state["chatTriggerType"] as? String == "MANUAL")
        #expect(body.state["agentTaskType"] as? String == "vibe")
        #expect(UUID(uuidString: body.state["conversationId"] as? String ?? "") != nil)
        #expect(body.history.count == 4)

        // It opens with the user, the instructions at its head, its image
        // gone as only the latest is sent again.
        let first = body.user(0)
        #expect(first["content"] as? String == "Be brief.\n\nhi")
        #expect(first["modelId"] as? String == "claude-sonnet-4.5")
        #expect(first["origin"] as? String == "KIRO_CLI")
        #expect(first["images"] == nil)
        #expect(first["userInputMessageContext"] == nil)

        let reply = body.assistant(1)
        let calls = try #require(reply["toolUses"] as? [[String: Any]])
        #expect(reply["content"] as? String == "reading")
        #expect(calls.count == 2)
        #expect(calls[0]["toolUseId"] as? String == "c1")
        #expect(calls[0]["input"] as? [String: Int] == ["p": 1])
        // Another vendor's id becomes one Kiro takes, the same each time.
        let id = try #require(calls[1]["toolUseId"] as? String)
        #expect(id != long)
        // "t_", then the first 32 characters of its SHA-256 in base64url.
        #expect(id == "t_whKZgCCQ4WATd2nIUMl80uL8pYeOR-p-")
        #expect(id.range(of: #"^[a-zA-Z0-9_.:-]{1,64}$"#, options: .regularExpression) != nil)

        // Both calls answered, the orphan result gone, the user turns one.
        let answer = body.user(2)
        #expect(answer["content"] as? String == "and?")
        #expect(BuiltBody.images(answer).count == 1)
        #expect(BuiltBody.images(answer).first?["format"] as? String == "jpeg")
        #expect((BuiltBody.images(answer).first?["source"] as? [String: String]) == ["bytes": "BBB"])
        let results = BuiltBody.results(answer)
        #expect(results.count == 2)
        #expect(results[0]["toolUseId"] as? String == "c1")
        #expect(results[0]["status"] as? String == "success")
        #expect(BuiltBody.resultText(results[0]) == "file")
        #expect(results[1]["toolUseId"] as? String == id)
        #expect(results[1]["status"] as? String == "error")
        #expect(BuiltBody.resultText(results[1]) == "Tool use was interrupted and did not produce a result.")

        // Ending on a reply, the message answered is an empty one, with the
        // tools offered and a stand-in for one used but no longer offered.
        #expect(body.assistant(3)["content"] as? String == "done")
        #expect(body.assistant(3)["toolUses"] == nil)
        #expect(body.current["content"] as? String == "Please proceed with the task.")
        #expect(BuiltBody.toolNames(body.current) == ["read", "grep"])
    }

    @Test("A tool's image goes with the message answering it, and long names are cut (magpie #369)")
    func toolImagesAndLongNames() async throws {
        let long = "mcp__plugin_vercel_vercel__create_sandboxes_sessions_by_session_id_snapshot_v2"
        let tools = [
            Tool(name: long, description: "Snapshot", parameters: objectSchema),
            Tool(name: "Read", description: "", parameters: .null),
        ]
        let messages: [Message] = [
            .user(UserMessage(text: "look")),
            assistant([call("c1", "Read"), call("c2", long)]),
            result("c1", [.image(ImageContent(data: "PNG", mimeType: "image/png"))]),
            result("c2", [.text(TextContent(text: "ok"))]),
        ]
        let body = try build(messages: messages, tools: tools)
        let images = BuiltBody.images(body.current)
        #expect(images.count == 1)
        #expect(images.first?["format"] as? String == "png")
        #expect((images.first?["source"] as? [String: String]) == ["bytes": "PNG"])
        // A result with nothing to read still says something.
        #expect(BuiltBody.results(body.current).map(BuiltBody.resultText) == ["(no output)", "ok"])

        let short = KiroRequest.toolName(long)
        #expect(short.count <= 64)
        #expect(short.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
        // The first 55 characters, then the first four bytes of its SHA-256.
        #expect(short == "mcp__plugin_vercel_vercel__create_sandboxes_sessions_by_dbd8b2f2")
        let calls = try #require(body.assistant(1)["toolUses"] as? [[String: Any]])
        #expect(calls.map { $0["name"] as? String } == ["Read", short])
        #expect(BuiltBody.toolNames(body.current) == [short, "Read"])
        // A tool with no description is described by its name, one with no
        // schema takes an empty object's.
        let specs = ((body.current["userInputMessageContext"] as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
            .compactMap { $0["toolSpecification"] as? [String: Any] }
        #expect(specs[1]["description"] as? String == "Read")
        let schema = (specs[1]["inputSchema"] as? [String: Any])?["json"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")
        #expect((schema?["properties"] as? [String: Any])?.isEmpty == true)

        // And a call Kiro makes by the short name comes back by the caller's.
        let client = KiroStubClient(kiroEvent("toolUseEvent", #"{"toolUseId":"t1","name":"\#(short)","input":"{}"}"#))
        let (message, _) = await turn(client, context: Context(messages: messages, tools: tools))
        #expect(said(message) == "|call:t1/\(long)|args:{}|stop:toolUse")
    }

    // magpie-plugins kiro tool-names.test.mjs (0.1.8, yetone/magpie#1393):
    // the reporter's two Claude Code MCP names, 71 and 70 characters, alike
    // for their first 40. Kiro answers either "Invalid tool use format."
    @Test("Two long names of one MCP server stay two tools, named alike in the declaration and the history")
    func longNamesOfOneServer() async throws {
        let search = "mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation"
        let guide = "mcp__plugin_cloudflare_cloudflare-docs__migrate_pages_to_workers_guide"
        let tools = [
            Tool(name: search, description: "Search Cloudflare docs", parameters: objectSchema),
            Tool(name: guide, description: "Guide", parameters: objectSchema),
            Tool(name: "Read", description: "read", parameters: objectSchema),
        ]
        let messages: [Message] = [
            .user(UserMessage(text: "search")),
            assistant([call("toolu_1", search, ["q": "workers"])]),
            result("toolu_1", [.text(TextContent(text: "found"))]),
        ]
        let body = try build(messages: messages, tools: tools)
        let names = BuiltBody.toolNames(body.current)
        #expect(names.count == 3)
        #expect(Set(names).count == 3)
        for name in names {
            #expect(name.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
        }
        #expect(names[0].hasPrefix("mcp__plugin_cloudflare_cloudflare-docs__"))
        #expect(names[2] == "Read")
        // The call in the history names the tool as its declaration does,
        // the same each turn, and its result still pairs by id.
        let calls = try #require(body.assistant(1)["toolUses"] as? [[String: Any]])
        #expect(calls.first?["name"] as? String == names[0])
        #expect(KiroRequest.toolName(search) == names[0])
        #expect(BuiltBody.results(body.current).first?["toolUseId"] as? String == "toolu_1")

        // A call Kiro makes under the short name comes back under the caller's.
        let client = KiroStubClient(
            kiroEvent("toolUseEvent", #"{"toolUseId":"tooluse_x","name":"\#(names[1])","input":"{\"q\":\"r2\"}"}"#),
            kiroEvent("toolUseEvent", #"{"toolUseId":"tooluse_x","name":"\#(names[1])","stop":true}"#)
        )
        let (message, _) = await turn(client, context: Context(messages: messages, tools: tools))
        #expect(said(message) == #"|call:tooluse_x/\#(guide)|args:{"q":"r2"}|stop:toolUse"#)
    }

    // magpie-plugins kiro split-calls.test.mjs (yetone/magpie#1275, the
    // request as Claude Code sent it): one turn's parallel calls split over
    // two assistant messages are one reply to Kiro, each call answered by its
    // real result in the message after.
    @Test("A turn's parallel calls split over two replies keep their results")
    func splitParallelCalls() throws {
        let messages: [Message] = [
            .user(UserMessage(text: "read a and b")),
            assistant([call("toolu_a", "read", ["path": "a"])]),
            assistant([call("toolu_b", "read", ["path": "b"])]),
            result("toolu_a", [.text(TextContent(text: "A!"))]),
            result("toolu_b", [.text(TextContent(text: "B!"))]),
        ]
        func answers(_ body: BuiltBody) -> [String] {
            BuiltBody.results(body.current).map {
                "\($0["toolUseId"] as? String ?? "")=\(BuiltBody.resultText($0) ?? "")"
            }
        }
        let body = try build(messages: messages)
        #expect(body.history.map { $0.keys.first } == ["userInputMessage", "assistantResponseMessage"])
        let calls = try #require(body.assistant(1)["toolUses"] as? [[String: Any]])
        #expect(calls.map { $0["toolUseId"] as? String } == ["toolu_a", "toolu_b"])
        #expect(answers(body) == ["toolu_a=A!", "toolu_b=B!"])

        // A call of the split turn that went unanswered is still answered for.
        let unanswered = try build(messages: Array(messages[..<3]) + [messages[4]])
        #expect(answers(unanswered) == ["toolu_b=B!", "toolu_a=\(KiroRequest.noResult)"])
    }

    @Test("Thinking is asked for in words at the head of the message, for Claude and Auto alone")
    func thinking() throws {
        let body = try build(messages: [.user(UserMessage(text: "why?"))], reasoning: .high)
        #expect(body.state["history"] == nil)
        #expect(body.current["content"] as? String
            == "<thinking_mode>enabled</thinking_mode><max_thinking_length>30000</max_thinking_length>\n\nwhy?")
        let withSystem = try build(system: "Be brief.", messages: [.user(UserMessage(text: "why?"))], reasoning: .max)
        #expect(withSystem.current["content"] as? String
            == "<thinking_mode>enabled</thinking_mode><max_thinking_length>50000</max_thinking_length>\nBe brief.\n\nwhy?")

        func model(_ id: String) -> Model { Model(id: id, api: KiroModels.api, provider: "kiro") }
        #expect(KiroRequest.thinks(model: model("claude-opus-4.5"), reasoning: .medium))
        #expect(KiroRequest.thinks(model: model("auto"), reasoning: .low))
        #expect(!KiroRequest.thinks(model: model("deepseek-3.2"), reasoning: .high))
        #expect(!KiroRequest.thinks(model: model("auto"), reasoning: nil))
        #expect(KiroRequest.thinkingBudget(.low) == 10_000)
        #expect(KiroRequest.thinkingBudget(.medium) == 20_000)
        #expect(KiroRequest.thinkingBudget(.xhigh) == 50_000)
        let other = try build(
            messages: [.user(UserMessage(text: "why?"))],
            model: model("deepseek-3.2"),
            reasoning: .high
        )
        #expect(other.current["content"] as? String == "why?")
    }

    @Test("Results with no call before them go, and a turn that only thought is no turn")
    func leadingResultsAndEmptyTurns() throws {
        let body = try build(messages: [
            result("gone", [.text(TextContent(text: "?"))]),
            .user(UserMessage(text: "one")),
            assistant([.thinking(ThinkingContent(thinking: "hmm"))]),
            .user(UserMessage(text: "two")),
        ])
        #expect(body.state["history"] == nil)
        #expect(body.current["content"] as? String == "one\n\ntwo")
        #expect(body.current["userInputMessageContext"] == nil)
    }

    @Test("A tool's output is cut where Kiro's own agent cuts it")
    func longResult() throws {
        let body = try build(messages: [
            .user(UserMessage(text: "go")),
            assistant([call("c1", "read")]),
            result("c1", [.text(TextContent(text: String(repeating: "x", count: 250_001)))], isError: true),
        ])
        let results = BuiltBody.results(body.current)
        #expect(results.first?["status"] as? String == "error")
        #expect(BuiltBody.resultText(results[0]) == String(repeating: "x", count: 250_000) + "\n… (cut)")
    }

    @Test("Image formats are Kiro's names", arguments: [
        ("image/png", "png"), ("image/jpeg", "jpeg"), ("image/JPG", "jpeg"), ("image/webp", "webp"),
        ("", "png"), ("application/pdf", "png"),
    ])
    func imageFormat(mimeType: String, expected: String) {
        #expect(KiroRequest.imageFormat(mimeType) == expected)
    }

    @Test("The request is kiro-cli's: its endpoint, its headers, the login's profile and region")
    func wire() async throws {
        let client = KiroStubClient(kiroEvent("assistantResponseEvent", #"{"content":"Hello"}"#))
        let (message, _) = await turn(
            client, auth: kiroAuth(token: "tok", profile: "arn:p", baseURL: "https://runtime.eu-central-1.kiro.dev/")
        )
        #expect(said(message) == "|text:Hello|stop:stop")
        let request = try #require(client.requests.first)
        #expect(request.url.absoluteString == "https://runtime.eu-central-1.kiro.dev/generateAssistantResponse")
        #expect(request.method == "POST")
        let headers = request.headers
        #expect(headers["Authorization"] == "Bearer tok")
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["Accept"] == "application/vnd.amazon.eventstream")
        #expect(headers["x-amzn-codewhisperer-optout"] == "true")
        #expect(headers["amz-sdk-request"] == "attempt=1; max=1")
        #expect(headers["x-amzn-kiro-agent-mode"] == "vibe")
        #expect(UUID(uuidString: headers["amz-sdk-invocation-id"] ?? "") != nil)
        let agent = try #require(headers["User-Agent"])
        #expect(agent.range(
            of: #"^aws-sdk-rust/1\.0\.0 ua/2\.1 os/other lang/rust api/codewhispererstreaming#1\.28\.3 m/E app/AmazonQ-For-CLI md/appVersion-1\.28\.3-[0-9a-f]{32}$"#,
            options: .regularExpression
        ) != nil)
        #expect(headers["x-amz-user-agent"] == agent)
        #expect(headers.count == 9)

        let body = BuiltBody(root: try object(request.body))
        #expect(body.root["profileArn"] as? String == "arn:p")
        #expect(body.current["content"] as? String == "hi")
    }

    @Test("With no profile on the login none is named, and the model's own region is asked")
    func withoutProfile() async throws {
        let client = KiroStubClient(kiroEvent("assistantResponseEvent", #"{"content":"Hello"}"#))
        _ = await turn(client, auth: kiroAuth(profile: nil))
        let request = try #require(client.requests.first)
        #expect(request.url.absoluteString == "https://runtime.us-east-1.kiro.dev/generateAssistantResponse")
        #expect(try object(request.body)["profileArn"] == nil)
    }

    @Test("Without a sign-in nothing is sent")
    func signedOut() async throws {
        let client = KiroStubClient()
        let (message, _) = await turn(client, auth: nil)
        #expect(message.errorMessage == "Kiro sign-in is required (run /login kiro)")
        #expect(client.requests.isEmpty)
    }

    @Test("A login whose region gives no URL fails the turn, and nothing is sent")
    func unusableRegion() async throws {
        let client = KiroStubClient()
        let (message, _) = await turn(client, auth: kiroAuth(baseURL: "https://runtime.a:b.kiro.dev"))
        #expect(message.stopReason == .error)
        #expect(message.errorMessage == "The Kiro login names a region that is not one; sign in again")
        #expect(client.requests.isEmpty)
    }
}

// MARK: - Errors

@Suite("Kiro failures")
struct KiroFailureTests {
    // magpie TestKiroFailure, with the category the rest of kwwk reads each by.
    @Test("An error Kiro answers with is read by its reason", arguments: [
        (400, #"{"message":"Input is too long.","reason":"CONTENT_LENGTH_EXCEEDS_THRESHOLD"}"#, 400,
         "Kiro: input is too long for the model's context: Input is too long. (CONTENT_LENGTH_EXCEEDS_THRESHOLD)",
         ProviderFailure.Category.contextOverflow),
        (429, #"{"message":"You've reached the limit.","reason":"MONTHLY_REQUEST_COUNT"}"#, 429,
         "Kiro: usage limit reached: You've reached the limit. (MONTHLY_REQUEST_COUNT)", .quota),
        (402, #"{"message":"You have reached the limit.","reason":"MONTHLY_REQUEST_COUNT"}"#, 429,
         "Kiro: usage limit reached: You have reached the limit. (MONTHLY_REQUEST_COUNT)", .quota),
        (500, #"{"message":"busy","reason":"INSUFFICIENT_MODEL_CAPACITY"}"#, 503,
         "Kiro: busy (INSUFFICIENT_MODEL_CAPACITY)", .server),
        (400, "plain", 400, "Kiro: plain", .invalidRequest),
        (403, #"{"message":"The bearer token included in the request is invalid."}"#, 403,
         "Kiro: The bearer token included in the request is invalid.", .authentication),
        (429, "", 429, "Kiro: HTTP 429", .rateLimit),
    ])
    func failure(status: Int, body: String, expected: Int, message: String, category: ProviderFailure.Category) {
        let failure = KiroProvider.httpFailure(status: status, body: Data(body.utf8))
        #expect(failure.httpStatus == expected)
        #expect(failure.message == message)
        #expect(failure.category == category)
    }

    @Test("A refused request ends the turn with Kiro's own words (magpie TestServeKiroUsageLimit)")
    func refused() async throws {
        let client = KiroStubClient([.init(
            status: 402, headers: ["Retry-After": "7"],
            chunks: [Data(#"{"message":"You have reached the limit.","reason":"MONTHLY_REQUEST_COUNT"}"#.utf8)]
        )])
        let (message, events) = await turn(client)
        #expect(message.stopReason == .error)
        #expect(message.errorMessage == "Kiro: usage limit reached: You have reached the limit. (MONTHLY_REQUEST_COUNT)")
        #expect(message.failure?.httpStatus == 429)
        #expect(message.failure?.providerCode == "MONTHLY_REQUEST_COUNT")
        #expect(message.failure?.retryAfterMs == 7000)
        #expect(message.failure?.category == .quota)
        #expect(events.count == 1)
    }
}

// MARK: - Models and registration

@Suite("Kiro models")
struct KiroModelTests {
    // The shape List-Available-Models answered with (magpie TestKiroModelList).
    private static let list = """
        {"models":[
        {"modelId":"claude-sonnet-4.5","modelName":"Claude Sonnet 4.5","supportedInputTypes":["TEXT","IMAGE"],\
        "tokenLimits":{"maxInputTokens":200000,"maxOutputTokens":64000}},
        {"modelId":"auto","modelName":"auto","supportedInputTypes":["TEXT"],"tokenLimits":{"maxInputTokens":200000}},
        {"modelId":""}],"defaultModel":{"modelId":"auto"}}
        """

    @Test("The list is the account's, the default first")
    func parse() throws {
        let models = try KiroModels.parse(Data(Self.list.utf8), region: "eu-central-1")
        #expect(models.map(\.id) == ["auto", "claude-sonnet-4.5"])
        #expect(models[0].name == "Auto")
        #expect(models[0].input == [.text])
        #expect(models[0].maxTokens == 64_000)
        let sonnet = models[1]
        #expect(sonnet.name == "Claude Sonnet 4.5")
        #expect(sonnet.contextWindow == 200_000)
        #expect(sonnet.maxTokens == 64_000)
        #expect(sonnet.input == [.text, .image])
        #expect(sonnet.provider == "kiro")
        #expect(sonnet.api == "kiro-assistant")
        #expect(sonnet.reasoning)
        #expect(sonnet.baseURL == "https://runtime.eu-central-1.kiro.dev")
    }

    @Test("It is asked as kiro-cli asks, of the profile's region, with the login's profile (magpie #422)")
    func fetch() async throws {
        let credentials = OAuthCredentials(
            access: "at", refresh: "rt", expires: .max,
            extras: ["region": "us-east-1", "profileArn": .string(KiroOAuth.builderIDProfile)]
        )
        let client = KiroStubClient([
            .init(headers: ["Content-Type": "application/json"], chunks: [Data(Self.list.utf8)])
        ])
        let models = try await KiroModels.fetch(credentials: credentials, client: client)
        #expect(models.map(\.id) == ["auto", "claude-sonnet-4.5"])
        let request = try #require(client.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.host == "management.us-east-1.kiro.dev")
        #expect(request.url.path == "/List-Available-Models")
        #expect(request.url.query == "origin=KIRO_CLI"
            + "&profileArn=arn%3Aaws%3Acodewhisperer%3Aus-east-1%3A638616132270%3Aprofile%2FAAAACCCCXXXX")
        #expect(request.headers["Authorization"] == "Bearer at")
        #expect(request.headers["Accept"] == "application/json")
    }

    @Test("A region that parses but is not one lists nothing, and nothing is sent", arguments: [
        ("region", "evil.com/x"), ("region", "us-east-1.evil.com"),
        ("profileArn", "arn:aws:codewhisperer:us-east-1.evil.com:1:profile/P"),
    ])
    func fetchHostileRegion(key: String, value: String) async throws {
        var credentials = OAuthCredentials(access: "at", refresh: "rt", expires: .max, extras: ["region": "us-east-1"])
        credentials.extras[key] = .string(value)
        let client = KiroStubClient([.init(chunks: [Data(Self.list.utf8)])])
        await #expect(throws: ProviderFailure(message: "The Kiro login's profile names a region that is not one")) {
            _ = try await KiroModels.fetch(credentials: credentials, client: client)
        }
        #expect(client.requests.isEmpty)
    }

    @Test("An empty list and a refusal are failures, not an empty catalog")
    func fetchFailures() async throws {
        let credentials = OAuthCredentials(access: "at", refresh: "rt", expires: .max)
        await #expect(throws: ProviderFailure(message: "Kiro listed no models")) {
            _ = try await KiroModels.fetch(
                credentials: credentials, client: KiroStubClient(Data(#"{"models":[]}"#.utf8))
            )
        }
        do {
            _ = try await KiroModels.fetch(
                credentials: credentials,
                client: KiroStubClient(status: 400, Data(#"{"message":"profileArn is required"}"#.utf8))
            )
            Issue.record("a refused list was a catalog")
        } catch let failure as ProviderFailure {
            #expect(failure.message == "Kiro: profileArn is required")
            #expect(failure.httpStatus == 400)
        }
    }

    @Test("The bundled seed holds the default model, and an id it lacks still resolves")
    func bundled() {
        let auto = ModelsCatalog.model(provider: "kiro", id: KiroModels.defaultModelId)
        #expect(auto?.api == "kiro-assistant")
        #expect(auto?.baseURL == "https://runtime.us-east-1.kiro.dev")
        for model in ModelsCatalog.models(for: "kiro") {
            #expect(model.api == "kiro-assistant")
            #expect(model.provider == "kiro")
            #expect(model.cost == ModelCost())
        }
        let unknown = kiroModel(id: "deepseek-3.2")
        #expect(unknown.api == "kiro-assistant")
        #expect(!unknown.reasoning)
        #expect(kiroModel(id: "claude-next").reasoning)
    }
}

@Suite("Kiro registration")
struct KiroRegistrationTests {
    private func manager(_ credentials: OAuthCredentials) async throws -> OAuthManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
        try await store.set(credentials, for: "kiro")
        return OAuthManager(store: store)
    }

    @Test("A stored login registers the provider; each request carries its token, profile and region")
    func stored() async throws {
        let manager = try await manager(OAuthCredentials(
            access: "at", refresh: "rt", expires: .max,
            extras: [
                "authMethod": "IdC", "provider": "Enterprise", "region": "eu-west-1",
                "profileArn": "arn:aws:codewhisperer:eu-central-1:9:profile/E",
            ]
        ))
        let resolved = try #require(try await registerStored(storeId: "kiro", manager: manager))
        #expect(resolved.model.id == "auto")
        #expect(resolved.model.provider == "kiro")
        #expect(resolved.modelLabel == "auto · Kiro")
        #expect(await APIRegistry.shared.provider(scope: "kiro", api: "kiro-assistant") is KiroProvider)

        let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
        #expect(auth.token == "at")
        #expect(auth.scheme == .bearer)
        #expect(auth.baseURL == "https://runtime.eu-central-1.kiro.dev")
        #expect(auth.metadata == ["profileArn": "arn:aws:codewhisperer:eu-central-1:9:profile/E"])
    }

    @Test("A login whose region parses but is not one gives no base URL, so no turn is sent", arguments: [
        ("region", "evil.com/x"), ("region", "us-east-1.evil.com"),
        ("profileArn", "arn:aws:codewhisperer:evil.com/x:9:profile/E"),
    ])
    func hostileRegion(key: String, value: String) async throws {
        var credentials = OAuthCredentials(
            access: "at", refresh: "rt", expires: .max,
            extras: ["region": "eu-west-1", "profileArn": "arn:aws:codewhisperer:eu-central-1:9:profile/E"]
        )
        credentials.extras[key] = .string(value)
        let manager = try await manager(credentials)
        let model = kiroModel(id: "auto")
        await #expect(throws: ProviderFailure(message: "The Kiro login names a region that is not one; sign in again")) {
            _ = try await kiroAuthResolver(manager: manager)(model, nil)
        }
    }

    @Test("A model override is honoured, and a signed-out store resolves to nothing")
    func overrideAndSignedOut() async throws {
        let manager = try await manager(OAuthCredentials(access: "at", refresh: "rt", expires: .max))
        let resolved = try #require(try await registerStored(
            storeId: "kiro", manager: manager, modelOverride: "claude-sonnet-4.5", primeToken: false
        ))
        #expect(resolved.model.id == "claude-sonnet-4.5")
        #expect(resolved.modelLabel == "claude-sonnet-4.5 · Kiro")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let empty = OAuthManager(store: try OAuthStore(url: dir.appendingPathComponent("oauth.json")))
        #expect(try await registerStored(storeId: "kiro", manager: empty) == nil)
        #expect(try await kiroAuthResolver(manager: empty)(resolved.model, nil) == nil)
    }

    @Test("Kiro is a known OAuth provider, attributed by name")
    func known() async throws {
        #expect(OAuthManager.defaultProviders().contains { $0.id == "kiro" })
        #expect(ProviderAttribution.getProviderDisplayName("kiro") == "Kiro")
    }
}
