import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stands in for Code Assist: each request takes the next scripted answer,
/// the last one repeating, and is recorded.
private final class AntigravityStubClient: HTTPClient, @unchecked Sendable {
    struct Answer {
        var status = 200
        var headers = ["Content-Type": "text/event-stream"]
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

/// One SSE event, as Code Assist frames a chunk: `data: {"response": …}`.
private func chunk(_ response: String) -> Data {
    Data("data: {\"response\":\(response)}\n\n".utf8)
}

private func event(_ json: String) -> Data { Data("data: \(json)\n\n".utf8) }

private func candidate(_ parts: String, finish: String? = nil, usage: String? = nil) -> Data {
    var json = #"{"candidates":[{"content":{"role":"model","parts":[\#(parts)]}"#
    if let finish { json += #","finishReason":"\#(finish)""# }
    json += "}]"
    if let usage { json += #","usageMetadata":\#(usage)"# }
    return chunk(json + "}")
}

private let hubVersion = AntigravityHubVersion(fixed: "3.1.4")

private func catalog(_ id: String) -> Model {
    ModelsCatalog.model(provider: "antigravity", id: id)!
}

private let flash = catalog("gemini-3.8-flash")
private let opus = catalog("claude-opus-4-6-thinking")
private let sonnet = catalog("claude-sonnet-4-6")
private let gptOSS = catalog("gpt-oss-120b-medium")

private func auth(
    token: String = "tok",
    project: String? = "ag-proj",
    baseURL: String? = nil
) -> ResolvedProviderAuth {
    ResolvedProviderAuth(
        token: token,
        scheme: .bearer,
        baseURL: baseURL,
        metadata: project.map { ["projectId": .string($0)] } ?? [:]
    )
}

/// Runs one turn against scripted chunks and returns the final message and
/// the events on the way.
private func turn(
    _ client: AntigravityStubClient,
    model: Model = flash,
    context: Context = Context(messages: [.user(UserMessage(text: "hi"))]),
    reasoning: ReasoningLevel? = nil,
    auth: ResolvedProviderAuth? = auth()
) async -> (AssistantMessage, [AssistantMessageEvent]) {
    let stream = AntigravityProvider(client: client, hubVersion: hubVersion).stream(
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

/// A built envelope, read the way magpie's tests read it.
/// Whether a decoded `thinkingConfig` says `includeThoughts: true`. Linux's
/// JSONSerialization reads a JSON `true` back as the number 1, macOS as a
/// Bool, so the check takes either spelling.
private func includesThoughts(_ thinking: [String: Any]?) -> Bool {
    guard let value = thinking?["includeThoughts"] else { return false }
    return (value as? Bool) == true || (value as? Int) == 1
}

private struct Envelope {
    var root: [String: Any]
    var request: [String: Any] { root["request"] as? [String: Any] ?? [:] }
    var contents: [[String: Any]] { request["contents"] as? [[String: Any]] ?? [] }
    var generation: [String: Any] { request["generationConfig"] as? [String: Any] ?? [:] }
    var thinking: [String: Any]? { generation["thinkingConfig"] as? [String: Any] }
    var declarations: [[String: Any]] {
        ((request["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]]) ?? []
    }
    var functionCalling: [String: Any]? {
        (request["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any]
    }
    var system: String? {
        ((request["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String
    }

    func parts(_ index: Int) -> [[String: Any]] { contents[index]["parts"] as? [[String: Any]] ?? [] }
    func role(_ index: Int) -> String { contents[index]["role"] as? String ?? "" }
}

private func build(
    model: Model = flash,
    sent: String? = nil,
    system: String? = nil,
    messages: [Message] = [.user(UserMessage(text: "hi"))],
    tools: [Tool] = [],
    reasoning: ReasoningLevel? = nil,
    maxTokens: Int? = nil,
    toolChoice: ToolChoice? = nil
) throws -> Envelope {
    let options = StreamOptions(maxTokens: maxTokens, reasoning: reasoning, toolChoice: toolChoice)
    return Envelope(root: try object(try AntigravityRequest.build(
        model: model,
        sent: sent ?? AntigravityModels.variantId(model: model, reasoning: reasoning),
        projectId: "ag-proj",
        systemPrompt: system,
        messages: messages,
        tools: tools,
        options: options
    )))
}

private func assistant(_ blocks: [AssistantBlock], model: Model = flash, provider: String? = nil, api: String? = nil) -> Message {
    .assistant(AssistantMessage(
        content: blocks, api: api ?? model.api, provider: provider ?? model.provider, model: model.id
    ))
}

private func text(_ text: String, signature: String? = nil) -> AssistantBlock {
    .text(TextContent(text: text, textSignature: signature))
}

private func call(_ id: String, _ name: String, _ arguments: JSONValue = .object([:]), signature: String? = nil) -> AssistantBlock {
    .toolCall(ToolCall(id: id, name: name, arguments: arguments, thoughtSignature: signature))
}

private func result(_ id: String, _ blocks: [ToolResultBlock], name: String = "tool", isError: Bool = false) -> Message {
    .toolResult(ToolResultMessage(toolCallId: id, toolName: name, content: blocks, isError: isError))
}

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private let objectSchema: JSONValue = .object(["type": "object", "properties": .object([:])])

/// Antigravity's answer to Claude Code's and the Agent SDK's system prompt
/// (magpie #666), and its 429 when the plan's own allowance is used up.
private let turnedAwayBody = #"{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}"#
private let quotaSpentBody = #"{"error":{"code":429,"message":"You have exhausted your capacity on this model. Your quota will reset after 3h19m30s.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"QUOTA_EXHAUSTED","domain":"cloudcode-pa.googleapis.com"}]}}"#
private let claudeCodeSystem = "x-anthropic-billing-header: cc_version=2.1.288.e3f; cc_entrypoint=sdk-cli;\nYou are Claude Code, Anthropic's official CLI for Claude."
private let codexGPT5System = "You are Codex, an agent based on GPT-5. You and the user share one workspace, and your job is to collaborate with them until their goal is genuinely handled."
private let hermesOldSystem = "You are Hermes Agent, an intelligent AI assistant created by Nous Research. You are helpful, knowledgeable, and direct."

// MARK: - Envelope

@Suite("Antigravity envelope")
struct AntigravityEnvelopeTests {
    @Test("The request is the Hub's: its endpoint, its headers, Antigravity's ids around a Gemini request")
    func wire() async throws {
        let client = AntigravityStubClient(candidate(#"{"text":"Hello"}"#, finish: "STOP"))
        let (message, _) = await turn(client, context: Context(systemPrompt: "Be brief.", messages: [.user(UserMessage(text: "hi"))]))
        #expect(said(message) == "|text:Hello|stop:stop")
        let request = try #require(client.requests.first)
        #expect(request.url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse")
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer tok")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["User-Agent"]?.range(
            of: #"^antigravity/hub/3\.1\.4 (darwin|linux|windows)/(arm64|amd64)$"#, options: .regularExpression
        ) != nil)
        #expect(request.headers["Accept"] == nil)
        #expect(request.headers.count == 3)

        let envelope = Envelope(root: try object(request.body))
        // The family's default variant, high, with no level asked.
        #expect(envelope.root["model"] as? String == "gemini-3.8-flash-high")
        #expect(envelope.root["project"] as? String == "ag-proj")
        #expect(envelope.root["userAgent"] as? String == "antigravity")
        #expect(envelope.root["requestType"] as? String == "agent")
        #expect((envelope.root["requestId"] as? String)?.range(of: #"^agent-[A-Za-z0-9_-]{16}$"#, options: .regularExpression) != nil)
        #expect((envelope.request["sessionId"] as? String)?.range(of: #"^-\d+$"#, options: .regularExpression) != nil)
        #expect(envelope.contents.count == 1)
        #expect(envelope.role(0) == "user")
        #expect(envelope.parts(0) as? [[String: String]] == [["text": "hi"]])
        #expect((envelope.request["systemInstruction"] as? [String: Any])?["role"] as? String == "user")
        #expect(envelope.system == "Be brief.")
        #expect(envelope.thinking?["thinkingLevel"] as? String == "high")
        #expect(envelope.generation["maxOutputTokens"] == nil)
    }

    @Test("The session is the conversation's: the same for one first message, another for another")
    func session() throws {
        let one = try build(messages: [.user(UserMessage(text: "hi"))]).request["sessionId"] as? String
        let same = try build(messages: [.user(UserMessage(text: "hi")), assistant([text("hey")]), .user(UserMessage(text: "more"))])
            .request["sessionId"] as? String
        let other = try build(messages: [.user(UserMessage(text: "hello"))]).request["sessionId"] as? String
        #expect(one != nil)
        #expect(one == same)
        #expect(one != other)
        // No text at all: a session of its own each time.
        let empty = AntigravityRequest.sessionId(contents: [])
        #expect(empty != AntigravityRequest.sessionId(contents: []))
        #expect(empty.hasPrefix("-"))
    }

    @Test("Without a sign-in or a project nothing is sent, and the reason is readable")
    func notConfigured() async throws {
        var client = AntigravityStubClient()
        var (message, events) = await turn(client, auth: nil)
        #expect(message.errorMessage == "Antigravity sign-in is required (run /login antigravity)")
        #expect(client.requests.isEmpty)
        #expect(events.count == 1)

        client = AntigravityStubClient()
        (message, _) = await turn(client, auth: auth(project: nil))
        #expect(message.errorMessage == "Antigravity: the login names no Google Cloud project; sign in to Antigravity again")
        #expect(message.failure?.isRetryable == false)
        #expect(client.requests.isEmpty)
    }

    @Test("A Claude model that thinks is asked for interleaved thinking; other models are not (pi, oh-my-pi)")
    func interleavedThinking() async throws {
        for (model, beta) in [(opus, "interleaved-thinking-2025-05-14"), (sonnet, nil), (flash, nil), (gptOSS, nil)] as [(Model, String?)] {
            let client = AntigravityStubClient(candidate(#"{"text":"Hello"}"#, finish: "STOP"))
            _ = await turn(client, model: model)
            #expect(client.requests.first?.headers["anthropic-beta"] == beta, "\(model.id)")
        }
        #expect(AntigravityProvider.requestHeaders(token: "t", hubVersion: "1", model: opus)["anthropic-beta"] == "interleaved-thinking-2025-05-14")
        #expect(AntigravityProvider.requestHeaders(token: "t", hubVersion: "1")["anthropic-beta"] == nil)
    }

    @Test("A host's base URL stands in for the daily host")
    func resolvedBaseURL() async throws {
        let client = AntigravityStubClient(candidate(#"{"text":"Hello"}"#, finish: "STOP"))
        _ = await turn(client, auth: auth(baseURL: "https://example.test/"))
        #expect(client.requests.first?.url.absoluteString == "https://example.test/v1internal:streamGenerateContent?alt=sse")
    }
}

// MARK: - Shaping

@Suite("Antigravity request shaping")
struct AntigravityShapingTests {
    @Test("The effort picks the variant id a family is asked for (magpie TestCollapseAntigravityModels)")
    func variants() {
        // Where the names say the levels, the map carries them so: magpie's
        // 2026-10-20 list had gemini-3.5-flash-extra-low as "(Low)" and -low
        // as "(Medium)", a family a free-tier account isn't served today.
        let flash35 = Model(
            id: "gemini-3.5-flash", api: AntigravityModels.api, provider: "antigravity", reasoning: true,
            thinkingLevelMap: [
                "off": nil, "minimal": nil, "low": "gemini-3.5-flash-extra-low", "medium": "gemini-3.5-flash-low",
                "high": nil, "xhigh": nil, "max": nil,
            ]
        )
        #expect(AntigravityModels.variantId(model: flash, reasoning: nil) == "gemini-3.8-flash-high")
        #expect(AntigravityModels.variantId(model: flash, reasoning: .low) == "gemini-3.8-flash-low")
        #expect(AntigravityModels.variantId(model: flash, reasoning: .medium) == "gemini-3.8-flash-medium")
        #expect(AntigravityModels.variantId(model: flash, reasoning: .high) == "gemini-3.8-flash-high")
        // A level the family lacks goes to the nearest it has.
        #expect(AntigravityModels.variantId(model: flash, reasoning: .max) == "gemini-3.8-flash-high")
        #expect(AntigravityModels.variantId(model: flash, reasoning: .minimal) == "gemini-3.8-flash-low")
        // Without high, the highest there is.
        #expect(AntigravityModels.variantId(model: flash35, reasoning: nil) == "gemini-3.5-flash-low")
        #expect(AntigravityModels.variantId(model: flash35, reasoning: .low) == "gemini-3.5-flash-extra-low")
        #expect(AntigravityModels.variantId(model: flash35, reasoning: .medium) == "gemini-3.5-flash-low")
        #expect(AntigravityModels.variantId(model: flash35, reasoning: .high) == "gemini-3.5-flash-low")
        // A model of one id goes as it is.
        #expect(AntigravityModels.variantId(model: opus, reasoning: .high) == "claude-opus-4-6-thinking")
        #expect(AntigravityModels.variantId(model: gptOSS, reasoning: .low) == "gpt-oss-120b-medium")
        #expect(AntigravityModels.variantId(model: catalog("gemini-3-flash"), reasoning: .low) == "gemini-3-flash")

        #expect(supportedThinkingLevels(flash) == [.low, .medium, .high])
        #expect(supportedThinkingLevels(flash35) == [.low, .medium])
        #expect(supportedThinkingLevels(sonnet) == [.off])
        #expect(supportedThinkingLevels(gptOSS) == [.off])

        // What level an id says: its family's, or any family's for a caller
        // that names the variant itself; a -tiered id names every level and
        // so says none.
        #expect(AntigravityModels.levelSaid(by: "gemini-3.8-flash-low", model: flash) == .low)
        #expect(AntigravityModels.levelSaid(by: "gemini-3.8-flash", model: flash) == nil)
        #expect(AntigravityModels.levelSaid(by: "gemini-3.8-flash-high", model: antigravityModel(id: "gemini-3.8-flash-high")) == .high)
        #expect(AntigravityModels.levelSaid(by: "gpt-oss-120b-medium", model: gptOSS) == nil)
        let tiered = Model(
            id: "gemini-3.8-flash-tiered", api: AntigravityModels.api, provider: "antigravity", reasoning: true,
            thinkingLevelMap: ["low": "gemini-3.8-flash-tiered", "medium": "gemini-3.8-flash-tiered", "high": "gemini-3.8-flash-tiered"]
        )
        #expect(AntigravityModels.variantId(model: tiered, reasoning: .low) == "gemini-3.8-flash-tiered")
        #expect(AntigravityModels.levelSaid(by: "gemini-3.8-flash-tiered", model: tiered) == nil)
    }

    @Test("Gemini 3 and later take a level, Claude a budget, GPT-OSS and a non-thinking Claude none")
    func thinking() throws {
        // A variant is told the level its id says, whatever was asked.
        var envelope = try build(sent: "gemini-3.8-flash-low", reasoning: .high)
        #expect(envelope.thinking?.count == 2)
        #expect(includesThoughts(envelope.thinking))
        #expect(envelope.thinking?["thinkingLevel"] as? String == "low")
        envelope = try build(reasoning: nil)
        #expect(envelope.thinking?["thinkingLevel"] as? String == "high")
        envelope = try build(reasoning: .medium)
        #expect(envelope.root["model"] as? String == "gemini-3.8-flash-medium")
        #expect(envelope.thinking?["thinkingLevel"] as? String == "medium")
        // A tiered id thinks at the level asked.
        let tiered = Model(
            id: "gemini-3.8-flash-tiered", api: AntigravityModels.api, provider: "antigravity", reasoning: true,
            thinkingLevelMap: ["low": "gemini-3.8-flash-tiered", "medium": "gemini-3.8-flash-tiered", "high": "gemini-3.8-flash-tiered"]
        )
        #expect(try build(model: tiered, reasoning: .low).thinking?["thinkingLevel"] as? String == "low")
        #expect(try build(model: tiered, reasoning: .high).thinking?["thinkingLevel"] as? String == "high")

        // A model saying no level, asked none, thinks as it likes; asked
        // one, Flash takes medium, Pro goes up to high, Gemini 4 takes its
        // medium, and minimal goes at low.
        let flash3 = catalog("gemini-3-flash")
        envelope = try build(model: flash3)
        #expect(envelope.request["generationConfig"] == nil)
        #expect(try build(model: flash3, reasoning: .medium).thinking?["thinkingLevel"] as? String == "medium")
        #expect(try build(model: flash3, reasoning: .minimal).thinking?["thinkingLevel"] as? String == "low")
        #expect(try build(model: flash3, reasoning: .max).thinking?["thinkingLevel"] as? String == "high")
        let pro = Model(id: "gemini-3.1-pro", api: AntigravityModels.api, provider: "antigravity", reasoning: true)
        #expect(try build(model: pro, reasoning: .medium).thinking?["thinkingLevel"] as? String == "high")
        #expect(try build(model: pro, reasoning: .low).thinking?["thinkingLevel"] as? String == "low")
        let argon = Model(id: "gemini-4-argon", api: AntigravityModels.api, provider: "antigravity", reasoning: true)
        #expect(try build(model: argon, reasoning: .medium).thinking?["thinkingLevel"] as? String == "medium")
        // Antigravity's Gemini is never told how long its answer may be.
        #expect(try build(model: flash3, maxTokens: 100).generation["maxOutputTokens"] == nil)

        // Claude thinking: a budget, and room for its answer past it.
        envelope = try build(model: opus, reasoning: .high)
        #expect(envelope.thinking?.count == 2)
        #expect(includesThoughts(envelope.thinking))
        #expect(envelope.thinking?["thinkingBudget"] as? Int == 24000)
        #expect(envelope.generation["maxOutputTokens"] as? Int == 56000)
        envelope = try build(model: opus)
        #expect(envelope.thinking?["thinkingBudget"] as? Int == 10000)
        #expect(envelope.generation["maxOutputTokens"] as? Int == 42000)
        #expect(try build(model: opus, reasoning: .max).generation["maxOutputTokens"] as? Int == 64000)
        #expect(try build(model: opus, reasoning: .low).thinking?["thinkingBudget"] as? Int == 4096)
        // A limit the caller set bounds the budget, and too tight a one ends thinking.
        envelope = try build(model: opus, reasoning: .medium, maxTokens: 8000)
        #expect(envelope.thinking?["thinkingBudget"] as? Int == 7999)
        #expect(envelope.generation["maxOutputTokens"] as? Int == 8000)
        envelope = try build(model: opus, reasoning: .medium, maxTokens: 1000)
        #expect(envelope.thinking == nil)
        #expect(envelope.generation["maxOutputTokens"] as? Int == 1000)

        // A Claude whose id doesn't say thinking, and GPT-OSS, are told none.
        envelope = try build(model: sonnet, reasoning: .high)
        #expect(envelope.thinking == nil)
        #expect(envelope.generation["maxOutputTokens"] as? Int == 64000)
        envelope = try build(model: gptOSS, reasoning: .high)
        #expect(envelope.request["generationConfig"] == nil)
    }

    @Test("Tool-call ids are Antigravity's charset, and a result goes back under `result` by its call's id and name")
    func toolIdsAndResults() throws {
        let odd = "call:abc/def|x"
        let envelope = try build(
            messages: [
                .user(UserMessage(text: "read")),
                assistant([call(odd, "read", ["path": "a"]), call("c2", "ls")]),
                result(odd, [.text(TextContent(text: "file"))]),
                result("c2", [.text(TextContent(text: "boom"))], isError: true),
                .user(UserMessage(text: "and?")),
            ],
            tools: [Tool(name: "read", description: "Read", parameters: objectSchema)]
        )
        #expect(envelope.contents.count == 4)
        let calls = envelope.parts(1).compactMap { $0["functionCall"] as? [String: Any] }
        #expect(calls.count == 2)
        #expect(calls[0]["id"] as? String == "call_abc_def_x")
        #expect(calls[0]["name"] as? String == "read")
        #expect(calls[0]["args"] as? [String: String] == ["path": "a"])
        #expect(calls[1]["args"] as? [String: String] == [:])
        // Gemini signs a step's first call; a step it never signed goes with
        // the stand-in on each call.
        #expect(envelope.parts(1).allSatisfy { $0["thoughtSignature"] as? String == "skip_thought_signature_validator" })

        #expect(envelope.role(2) == "user")
        let responses = envelope.parts(2).compactMap { $0["functionResponse"] as? [String: Any] }
        #expect(responses.count == 2)
        #expect(responses[0]["id"] as? String == "call_abc_def_x")
        #expect(responses[0]["name"] as? String == "read")
        #expect(responses[0]["response"] as? [String: String] == ["result": "file"])
        #expect(responses[1]["response"] as? [String: String] == ["result": "Error: boom"])
        // What the user said goes in a turn of its own after the tools'.
        #expect(envelope.role(3) == "user")
        #expect(envelope.parts(3) as? [[String: String]] == [["text": "and?"]])
        #expect(AntigravityRequest.toolID("toolu_01ABC-x") == "toolu_01ABC-x")
        #expect(AntigravityRequest.toolID("call:1|é") == "call_1__")
    }

    @Test("A tool-call id longer than 64 is cut to 64, two that begin alike stay apart, and a call meets its result (pi, oh-my-pi)")
    func longToolIds() throws {
        // OpenAI Responses' ids: call_… joined to fc_… with a bar.
        let one = "call_" + String(repeating: "a", count: 40) + "|fc_" + String(repeating: "b", count: 40)
        let two = "call_" + String(repeating: "a", count: 40) + "|fc_" + String(repeating: "c", count: 40)
        let first = AntigravityRequest.toolID(one)
        let second = AntigravityRequest.toolID(two)
        #expect(first.count == 64)
        #expect(second.count == 64)
        #expect(first != second)
        #expect(first == AntigravityRequest.toolID(one))
        #expect(first.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
        #expect(first.hasPrefix("call_aaaa"))
        let exactly64 = String(repeating: "x", count: 64)
        #expect(AntigravityRequest.toolID(exactly64) == exactly64)

        let envelope = try build(
            model: opus,
            messages: [
                .user(UserMessage(text: "read")),
                assistant([call(one, "read")], model: opus),
                result(one, [.text(TextContent(text: "file"))]),
            ],
            tools: [Tool(name: "read", description: "Read", parameters: objectSchema)]
        )
        let sentCall = envelope.parts(1).compactMap { $0["functionCall"] as? [String: Any] }.first
        let sentResult = envelope.parts(2).compactMap { $0["functionResponse"] as? [String: Any] }.first
        #expect(sentCall?["id"] as? String == first)
        #expect(sentResult?["id"] as? String == first)
    }

    @Test("Claude's calls carry the stand-in signature, are checked against the schema, and its images follow every response")
    func claude() throws {
        let messages: [Message] = [
            .user(UserMessage(text: "look")),
            assistant([call("c1", "read", signature: "AAAA"), call("c2", "shot")], model: opus),
            result("c1", [.text(TextContent(text: "file"))]),
            result("c2", [.image(ImageContent(data: "PNG", mimeType: "image/png")), .image(ImageContent(data: "JPG", mimeType: "image/jpeg"))]),
            .user(UserMessage(text: "and?")),
        ]
        let tools = [Tool(name: "read", description: "Read", parameters: objectSchema)]
        let envelope = try build(model: opus, messages: messages, tools: tools)
        #expect(envelope.functionCalling as? [String: String] == ["mode": "VALIDATED"])
        // Every call, Gemini's own signature left out.
        #expect(envelope.parts(1).map { $0["thoughtSignature"] as? String } == Array(repeating: "skip_thought_signature_validator", count: 2))
        // One turn, the tool_result turn Anthropic reads: the responses, then
        // the images each after a line saying whose, then the user's words.
        #expect(envelope.contents.count == 3)
        let parts = envelope.parts(2)
        #expect(parts.count == 6)
        #expect(parts[0]["functionResponse"] != nil)
        #expect(parts[1]["functionResponse"] != nil)
        #expect(parts[2]["text"] as? String == "2 images returned by tool shot (call c2):")
        #expect((parts[3]["inlineData"] as? [String: String]) == ["mimeType": "image/png", "data": "PNG"])
        #expect((parts[4]["inlineData"] as? [String: String]) == ["mimeType": "image/jpeg", "data": "JPG"])
        #expect(parts[5]["text"] as? String == "and?")

        // Gemini takes a tool's image right after its response, and the
        // user's words in a turn of their own.
        let gemini = try build(messages: messages, tools: tools)
        #expect(gemini.functionCalling as? [String: String] == ["mode": "AUTO"])
        #expect(gemini.contents.count == 4)
        let tool = gemini.parts(2)
        #expect(tool.count == 4)
        #expect(tool[0]["functionResponse"] != nil)
        #expect(tool[1]["functionResponse"] != nil)
        #expect(tool[2]["inlineData"] != nil)
        #expect(tool[3]["inlineData"] != nil)
        #expect(gemini.parts(3) as? [[String: String]] == [["text": "and?"]])
        // A single image's line.
        let one = try build(model: opus, messages: [
            .user(UserMessage(text: "look")), assistant([call("c1", "shot")], model: opus),
            result("c1", [.image(ImageContent(data: "PNG", mimeType: "image/png"))]),
        ])
        #expect(one.parts(2)[1]["text"] as? String == "Image returned by tool shot (call c1):")
    }

    @Test("Gemini's own signatures go back as it gave them; another model's are not sent (magpie #1445)")
    func signatures() throws {
        let envelope = try build(messages: [
            .user(UserMessage(text: "go")),
            assistant([text("plan", signature: "BBBB"), call("c1", "read", signature: "AAAA"), call("c2", "ls")]),
            result("c1", [.text(TextContent(text: "x"))]),
            result("c2", [.text(TextContent(text: "y"))]),
        ])
        let parts = envelope.parts(1)
        #expect(parts[0]["thoughtSignature"] as? String == "BBBB")
        #expect(parts[1]["thoughtSignature"] as? String == "AAAA")
        // Gemini signs the first: the second goes without.
        #expect(parts[2]["thoughtSignature"] == nil)

        let foreign = try build(messages: [
            .user(UserMessage(text: "go")),
            assistant([text("plan", signature: "BBBB"), call("c1", "read", signature: "AAAA")], provider: "google", api: "google-generative-ai"),
            result("c1", [.text(TextContent(text: "x"))]),
        ])
        #expect(foreign.parts(1)[0]["thoughtSignature"] == nil)
        #expect(foreign.parts(1)[1]["thoughtSignature"] as? String == "skip_thought_signature_validator")
    }

    @Test("A history may not open or close on the model's turn, and thinking isn't sent back")
    func opensAndCloses() throws {
        let envelope = try build(messages: [
            assistant([.thinking(ThinkingContent(thinking: "hmm")), text("hello")]),
            .user(UserMessage(text: "hi")),
            assistant([.thinking(ThinkingContent(thinking: "only thought"))]),
            assistant([text("ok")]),
        ])
        #expect(envelope.contents.map { $0["role"] as? String } == ["user", "model", "user", "model", "user"])
        #expect(envelope.parts(0) as? [[String: String]] == [["text": "[Continuing from previous AI thoughts...]"]])
        #expect(envelope.parts(1) as? [[String: String]] == [["text": "hello"]])
        #expect(envelope.parts(3) as? [[String: String]] == [["text": "ok"]])
        #expect(envelope.parts(4) as? [[String: String]] == [["text": "Continue."]])
    }

    @Test("A second answer to one call is dropped; a call made again takes an answer of its own (magpie #2262)")
    func secondAnswers() throws {
        let envelope = try build(messages: [
            .user(UserMessage(text: "go")),
            assistant([call("c1", "read")]),
            result("c1", [.text(TextContent(text: "first"))]),
            result("c1", [.text(TextContent(text: "second"))]),
            assistant([call("c1", "read")]),
            result("c1", [.text(TextContent(text: "again"))]),
            result("", [.text(TextContent(text: "nameless"))]),
        ])
        #expect(envelope.contents.map { $0["role"] as? String } == ["user", "model", "user", "model", "user"])
        func results(_ index: Int) -> [String] {
            envelope.parts(index).compactMap {
                (($0["functionResponse"] as? [String: Any])?["response"] as? [String: String])?["result"]
            }
        }
        #expect(results(2) == ["first"])
        #expect(results(4) == ["again", "nameless"])
    }

    @Test("Tools go as plain declarations, offered as the caller chooses")
    func tools() throws {
        let tools = [
            Tool(name: "read", description: "Read a file", parameters: objectSchema),
            Tool(name: "ls", description: "", parameters: .null),
        ]
        var envelope = try build(tools: tools)
        #expect(envelope.declarations.count == 2)
        #expect(envelope.declarations[0]["description"] as? String == "Read a file")
        #expect(envelope.declarations[0]["parametersJsonSchema"] == nil)
        #expect(envelope.declarations[1]["description"] == nil)
        #expect((envelope.declarations[1]["parameters"] as? [String: Any])?["type"] as? String == "object")
        #expect(((envelope.declarations[1]["parameters"] as? [String: Any])?["properties"] as? [String: Any])?.isEmpty == true)
        #expect(envelope.functionCalling as? [String: String] == ["mode": "AUTO"])
        envelope = try build(tools: tools, toolChoice: .required)
        #expect(envelope.functionCalling as? [String: String] == ["mode": "ANY"])
        envelope = try build(model: opus, tools: tools, toolChoice: .tool(name: "read"))
        #expect(envelope.functionCalling?["mode"] as? String == "ANY")
        #expect(envelope.functionCalling?["allowedFunctionNames"] as? [String] == ["read"])
        envelope = try build(tools: tools, toolChoice: ToolChoice.none)
        #expect(envelope.request["tools"] == nil)
        #expect(envelope.request["toolConfig"] == nil)
    }
}

// MARK: - Schemas

@Suite("Antigravity schemas")
struct AntigravitySchemaTests {
    @Test("Every array has items, however deep it sits (magpie TestPlainSchemaArraysAllHaveItems)")
    func arrays() throws {
        let input = try json(#"""
            {"type":"object","$defs":{"Tags":{"type":"array","description":"tags"}},
            "properties":{
                "grid":{"type":"array","items":{"type":"array"}},
                "maybe":{"anyOf":[{"type":"null"},{"type":"array"}]},
                "one":{"oneOf":[{"type":"array","minItems":1},{"type":"string"}]},
                "both":{"allOf":[{"type":"object","properties":{"list":{"type":"array"}}}]},
                "tags":{"$ref":"#/$defs/Tags"},
                "opt":{"type":["array","null"]},
                "kept":{"type":"array","items":{"type":"string"}},
                "deep":{"type":"object","properties":{"rows":{"type":"array","items":{"type":"object","properties":{"cells":{"type":"array"}}}}}}
            }}
            """#)
        let want = try json(#"""
            {"type":"object","properties":{
                "grid":{"type":"array","items":{"type":"array","items":{}}},
                "maybe":{"type":"array","items":{},"nullable":true},
                "one":{"type":"array","items":{},"minItems":1},
                "both":{"type":"object","properties":{"list":{"type":"array","items":{}}}},
                "tags":{"type":"array","items":{},"description":"tags"},
                "opt":{"type":"array","items":{},"nullable":true},
                "kept":{"type":"array","items":{"type":"string"}},
                "deep":{"type":"object","properties":{"rows":{"type":"array","items":{"type":"object","properties":{"cells":{"type":"array","items":{}}}}}}}
            }}
            """#)
        #expect(AntigravitySchema.plain(input) == want)
        // A schema that isn't an array gets no items.
        let plain = try json(#"{"type":"object","properties":{"s":{"type":"string"}}}"#)
        #expect(AntigravitySchema.plain(plain) == plain)
    }

    @Test("A root union keeps the object, and every union with a shape of its own keeps it (magpie #4046)", arguments: [
        ("root oneOf",
         #"{"type":"object","properties":{"pattern":{"type":"string"},"cursor":{"type":"string"}},"oneOf":[{"required":["pattern"],"not":{"required":["cursor"]}},{"required":["cursor"],"not":{"required":["pattern"]}}]}"#,
         #"{"type":"object","properties":{"pattern":{"type":"string"},"cursor":{"type":"string"}}}"#),
        ("properties only, no type",
         #"{"properties":{"a":{"type":"string"}},"oneOf":[{"required":["a"]}]}"#,
         #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}"#),
        ("nested anyOf",
         #"{"type":"object","properties":{"q":{"type":"object","properties":{"a":{"type":"integer"}},"anyOf":[{"required":["a"]},{"type":"null"}]}}}"#,
         #"{"type":"object","properties":{"q":{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"],"nullable":true}}}"#),
        ("branches add fields",
         #"{"type":"object","properties":{"kind":{"type":"string"}},"required":["kind"],"oneOf":[{"properties":{"kind":{"const":"a"},"x":{"type":"string"}},"required":["kind","x"]},{"properties":{"kind":{"const":"b"},"y":{"type":"number"}},"required":["kind","y"]}]}"#,
         #"{"type":"object","properties":{"kind":{"type":"string"},"x":{"type":"string"},"y":{"type":"number"}},"required":["kind"]}"#),
        ("root allOf",
         #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"allOf":[{"properties":{"b":{"type":"string"}},"required":["b"]},{"not":{"required":["c"]}}]}"#,
         #"{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"}},"required":["a","b"]}"#),
        ("typed scalar",
         #"{"type":"string","description":"d","anyOf":[{"format":"date"},{"format":"uuid"}]}"#,
         #"{"type":"string","description":"d"}"#),
        ("bare union still its first branch",
         #"{"type":"object","properties":{"v":{"description":"value","anyOf":[{"type":"null"},{"type":"integer"},{"type":"string"}]}}}"#,
         #"{"type":"object","properties":{"v":{"type":"integer","description":"value","nullable":true}}}"#),
    ])
    func unions(name: String, input: String, want: String) throws {
        #expect(AntigravitySchema.plain(try json(input)) == (try json(want)), "\(name)")
    }

    @Test("Items only on arrays, properties only on objects, and only the subset's keywords (magpie #187, ferock's display)")
    func subset() throws {
        let input = try json(#"""
            {"type":"object","title":"Show","additionalProperties":false,"properties":{
                "display":{"type":"string","description":"columns","items":{"type":"string"},"enum":["name","size"]},
                "listed":{"type":["string","array","null"],"items":{"type":"string"}},
                "shaped":{"type":["string","object"],"properties":{"q":{"type":"string"}}},
                "word":{"type":"string","minItems":1,"properties":{"q":{"type":"string"}},"required":["q"]},
                "count":{"type":"integer","exclusiveMinimum":0,"default":1,"format":"int32"},
                "mode":{"const":"fast"},
                "mixed":{"enum":["a",1]},
                "never":false,
                "any":true,
                "self":{"$ref":"#"},
                "ref":{"$ref":"#/definitions/Thing"}},
             "required":["display","never","missing"],
             "definitions":{"Thing":{"type":"object","properties":{"id":{"type":"string"}}}}}
            """#)
        let want = try json(#"""
            {"type":"object","properties":{
                "display":{"type":"string","description":"columns","enum":["name","size"]},
                "listed":{"type":"array","items":{"type":"string"},"nullable":true},
                "shaped":{"type":"object","properties":{"q":{"type":"string"}}},
                "word":{"type":"string"},
                "count":{"type":"integer","minimum":0},
                "mode":{"enum":["fast"]},
                "mixed":{},
                "any":{},
                "self":{"type":"object"},
                "ref":{"type":"object","properties":{"id":{"type":"string"}}}},
             "required":["display"]}
            """#)
        #expect(AntigravitySchema.plain(input) == want)
        // The declaration a tool with no schema gets.
        let declaration = AntigravityRequest.declaration(Tool(name: "ls", description: "", parameters: .null))
        #expect((declaration["parameters"] as? [String: Any])?["type"] as? String == "object")
    }
}

// MARK: - Cloak

@Suite("Antigravity cloak")
struct AntigravityCloakTests {
    static let turnedAwayLines = [
        "x-anthropic-billing-header:",
        "built on anthropic's claude agent sdk",
        "you are codex, an agent based on gpt-5",
        "you are codex, a coding agent based on gpt-5",
        "hermes agent, an intelligent ai assistant created by nous research",
    ]

    @Test("Every line Antigravity turns away is broken after its first letter, and nothing else changes (magpie TestAntigravityCloakBreaksEveryLineItTurnsAway)", arguments: [
        claudeCodeSystem,
        "You are a Claude agent, built on Anthropic's Claude Agent SDK.",
        codexGPT5System,
        "You are Codex, a coding agent based on GPT-5. You and the user share the same workspace.",
        hermesOldSystem,
        hermesOldSystem.uppercased(),
        // twice, and after text whose lower case is longer than it is
        "İstanbul ✓ " + codexGPT5System + "\n\n" + hermesOldSystem + "\n" + codexGPT5System,
    ])
    func broken(system: String) {
        let zero = AntigravityCloak.zeroWidth
        #expect(AntigravityCloak.turnsAway(system))
        let cloaked = AntigravityCloak.cloak(system)
        #expect(!AntigravityCloak.turnsAway(cloaked))
        #expect(cloaked.replacingOccurrences(of: zero, with: "") == system)
        #expect(cloaked.contains(zero))
        let low = cloaked.replacingOccurrences(of: zero, with: "|").lowercased()
        for line in Self.turnedAwayLines where system.lowercased().contains(line) {
            #expect(low.contains(String(line.prefix(1)) + "|" + String(line.dropFirst())), "\(line)")
        }
        // A prompt broken up once is not broken again.
        #expect(AntigravityCloak.cloak(cloaked) == cloaked)
        #expect(AntigravityCloak.turnedAwayLines == Self.turnedAwayLines)
    }

    @Test("What Antigravity answers is sent as written", arguments: [
        "",
        "You are opencode, an interactive CLI tool.",
        "You are Claude Code, Anthropic's official CLI for Claude, running within the Claude Agent SDK.",
        "You are Codex, based on GPT-5. You are running as a coding agent in the Codex CLI on a user's computer.",
        "You are Hermes Agent, built by Nous Research. Be direct.",
        "You are Hermes Agent, an intelligent AI assistant created by Nous.",
    ])
    func asWritten(system: String) {
        #expect(!AntigravityCloak.turnsAway(system))
        #expect(AntigravityCloak.cloak(system) == system)
    }

    @Test("The request carries the prompt broken up; the caller's context keeps it as written")
    func sent() async throws {
        let client = AntigravityStubClient(candidate(#"{"text":"ok"}"#, finish: "STOP"))
        let context = Context(systemPrompt: claudeCodeSystem, messages: [.user(UserMessage(text: "hi"))])
        _ = await turn(client, context: context)
        let envelope = Envelope(root: try object(client.requests.first?.body))
        let system = try #require(envelope.system)
        #expect(system != claudeCodeSystem)
        #expect(system.replacingOccurrences(of: AntigravityCloak.zeroWidth, with: "") == claudeCodeSystem)
        #expect(system.hasPrefix("x" + AntigravityCloak.zeroWidth + "-anthropic-billing-header:"))
        #expect(context.systemPrompt == claudeCodeSystem)
    }
}

// MARK: - Reply

@Suite("Antigravity reply decoding")
struct AntigravityReplyTests {
    @Test("Thoughts, text and calls come as Gemini parts wrapped in {response}, with the usage the last chunk carries")
    func textAndCalls() async throws {
        let client = AntigravityStubClient(
            candidate(#"{"text":"Let me think.","thought":true,"thoughtSignature":"c2ln"}"#),
            candidate(#"{"text":"Let me "}"#),
            candidate(#"{"text":"look."}"#),
            candidate(
                #"{"functionCall":{"id":"toolu_1","name":"read","args":{"path":"a"}},"thoughtSignature":"c2ln"},{"functionCall":{"name":"default_api:ls"}}"#,
                finish: "STOP",
                usage: #"{"promptTokenCount":100,"cachedContentTokenCount":20,"candidatesTokenCount":30,"thoughtsTokenCount":5,"totalTokenCount":155}"#
            )
        )
        let (message, events) = await turn(client, reasoning: .high)
        let text = said(message)
        #expect(text.hasPrefix(#"|think:Let me think.|text:Let me look.|call:toolu_1/read|args:{"path":"a"}|call:gemini-tool-"#))
        #expect(text.hasSuffix("/ls|args:{}|stop:toolUse"))
        #expect(message.usage.input == 80)
        #expect(message.usage.cacheRead == 20)
        #expect(message.usage.output == 35)
        #expect(message.usage.reasoning == 5)
        #expect(message.usage.totalTokens == 155)
        #expect(message.api == "antigravity-codeassist")
        #expect(message.provider == "antigravity")
        #expect(message.model == "gemini-3.8-flash")
        guard case .toolCall(let read)? = message.content.dropFirst(2).first else {
            Issue.record("no call: \(message.content)")
            return
        }
        #expect(read.thoughtSignature == "c2ln")
        guard case .start? = events.first, case .done(reason: .toolUse, _)? = events.last else {
            Issue.record("events open with start and close with done: \(events)")
            return
        }
        let kinds = events.map(\.type)
        #expect(kinds.contains("thinking_start") && kinds.contains("thinking_end"))
        #expect(kinds.contains("text_start") && kinds.contains("text_end"))
        #expect(kinds.filter { $0 == "toolcall_end" }.count == 2)
    }

    @Test("A part with no text that carries a signature signs the text before it, and goes back on replay (magpie #1445)")
    func emptySignedText() async throws {
        let client = AntigravityStubClient(
            candidate(#"{"text":"Hello"}"#),
            candidate(#"{"text":"","thoughtSignature":"c2ln"}"#, finish: "STOP")
        )
        let (message, _) = await turn(client)
        #expect(said(message) == "|text:Hello|stop:stop")
        guard case .text(let text)? = message.content.first else {
            Issue.record("no text: \(message.content)")
            return
        }
        #expect(text.textSignature == "c2ln")

        // Alone, it still keeps its signature, on a text of its own.
        let (alone, _) = await turn(AntigravityStubClient(
            candidate(#"{"functionCall":{"name":"ls"}}"#),
            candidate(#"{"text":"","thoughtSignature":"c2ln"}"#, finish: "STOP")
        ))
        #expect(alone.content.contains {
            if case .text(let text) = $0 { return text.text.isEmpty && text.textSignature == "c2ln" }
            return false
        })
        let envelope = try build(messages: [.user(UserMessage(text: "go")), .assistant(alone)])
        #expect(envelope.parts(1).contains { $0["text"] as? String == "" && $0["thoughtSignature"] as? String == "c2ln" })
    }

    @Test("A bare chunk decodes too, and the end is the finish reason", arguments: [
        ("MAX_TOKENS", StopReason.length, nil),
        ("STOP", .stop, nil),
        ("SAFETY", .error, ProviderFailure.Category.refusal),
    ])
    func finish(reason: String, stop: StopReason, category: ProviderFailure.Category?) async throws {
        let (message, _) = await turn(AntigravityStubClient(
            event(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"hi"}]},"finishReason":"\#(reason)"}]}"#)
        ))
        #expect(message.stopReason == stop)
        #expect(message.failure?.category == category)
        if category == nil { #expect(said(message).hasPrefix("|text:hi|")) }
    }

    @Test("A reply that ends without a finish reason, or with nothing said, is a failed reply, not an answer")
    func brokenOff() async throws {
        // What a retired model answers (gemini-3.5-flash-low, 2026-11-02): a
        // notice and no finish reason. Google's words lead the failure.
        let notice = "Gemini 3.5 Flash is no longer available. Please switch to Gemini 3.7 Flash in the latest version of Antigravity."
        var (message, _) = await turn(AntigravityStubClient(candidate(#"{"text":"\#(notice)"}"#)))
        #expect(said(message) == "|text:\(notice)|error:\(notice) (Antigravity stream ended without a finish reason)|stop:error")
        #expect(message.failure?.category == .transport)
        #expect(message.failure?.isRetryable == true)
        // A long reply cut off mid-answer is not quoted.
        let long = String(repeating: "x", count: 301)
        (message, _) = await turn(AntigravityStubClient(candidate(#"{"text":"\#(long)"}"#)))
        #expect(message.errorMessage == "Antigravity stream ended without a finish reason")
        #expect(message.failure?.category == .transport)

        (message, _) = await turn(AntigravityStubClient(candidate(#"{"text":"hmm","thought":true}"#, finish: "STOP")))
        #expect(message.errorMessage == "Antigravity stream ended without content")
        #expect(message.failure?.rawStopReason == "STOP")

        (message, _) = await turn(AntigravityStubClient([
            .init(headers: ["Content-Type": "text/html; charset=utf-8"], chunks: [Data("<html>".utf8)]),
        ]))
        #expect(message.errorMessage == "Antigravity answered with a web page, not an API reply")
        #expect(message.failure?.category == .server)
    }

    @Test("An error said inside the reply ends it, read by what it says (magpie TestAntigravityTurnedAwaySaidInsideTheReply)")
    func errorInsideReply() async throws {
        var (message, events) = await turn(AntigravityStubClient(
            candidate(#"{"text":"hi"}"#),
            event(#"{"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}"#)
        ))
        #expect(said(message) == "|text:hi|error:Antigravity: Internal error encountered.|stop:error")
        #expect(message.failure?.category == .server)
        #expect(message.failure?.isRetryable == true)
        guard case .error(reason: .error, _)? = events.last else {
            Issue.record("the turn did not end in an error: \(events)")
            return
        }

        // The refusal, under a 200: the prompt turned away, not a quota.
        let refusal = event(#"{"error":{"message":"Resource has been exhausted (e.g. check quota)."}}"#)
        (message, _) = await turn(
            AntigravityStubClient(refusal),
            context: Context(systemPrompt: claudeCodeSystem, messages: [.user(UserMessage(text: "hi"))])
        )
        #expect(message.failure?.category == .refusal)
        #expect(message.failure?.providerCode == "prompt_refusal")
        #expect(message.failure?.httpStatus == 429)
        #expect(message.failure?.isRetryable == false)
        // The same words on a prompt Antigravity answers: Google busy, a
        // limit retried, not spent quota (pi and oh-my-pi retry it).
        (message, _) = await turn(AntigravityStubClient(refusal))
        #expect(message.failure?.category == .rateLimit)
        #expect(message.failure?.isRetryable == true)
        #expect(message.errorMessage == "Antigravity: rate limited: Resource has been exhausted (e.g. check quota).")

        // Spent quota said inside the reply is the quota it says.
        (message, _) = await turn(AntigravityStubClient(event(
            #"{"error":{"code":429,"message":"You have exhausted your capacity on this model. Your quota will reset after 2h.","status":"RESOURCE_EXHAUSTED"}}"#
        )))
        #expect(message.failure?.category == .quota)
        #expect(message.failure?.isRetryable == false)
        #expect(message.failure?.resetsAt != nil)
    }
}

// MARK: - Failures

@Suite("Antigravity failures")
struct AntigravityFailureTests {
    @Test("A 429 to a prompt Antigravity turns away is the prompt refused: not retried, not a quota (magpie #666, #1425)", arguments: [
        (claudeCodeSystem, "Claude Code and the Claude Agent SDK"),
        ("You are a Claude agent, built on Anthropic's Claude Agent SDK.", "Claude Code and the Claude Agent SDK"),
        (codexGPT5System, "Codex's own system prompt"),
        (hermesOldSystem, "Hermes Agent's earlier default persona"),
    ])
    func turnedAway(system: String, hint: String) async throws {
        let client = AntigravityStubClient([.init(status: 429, headers: ["Content-Type": "application/json"], chunks: [Data(turnedAwayBody.utf8)])])
        let (message, events) = await turn(client, context: Context(systemPrompt: system, messages: [.user(UserMessage(text: "hi"))]))
        #expect(message.stopReason == .error)
        let failure = try #require(message.failure)
        #expect(failure.httpStatus == 429)
        #expect(failure.providerCode == "prompt_refusal")
        #expect(failure.category == .refusal)
        #expect(failure.outcome == .contentRefused)
        #expect(failure.isRetryable == false)
        #expect(failure.message.hasPrefix("Antigravity: Resource has been exhausted (e.g. check quota). — "))
        #expect(failure.message.contains(hint))
        #expect(events.count == 1)
        #expect(client.requests.count == 1)
    }

    @Test("A plain 429 is the quota it says, with the reset it names (magpie TestAntigravityQuotaRestsUntilItsReset)")
    func quota() async throws {
        var client = AntigravityStubClient([.init(status: 429, headers: ["Content-Type": "application/json"], chunks: [Data(quotaSpentBody.utf8)])])
        var (message, _) = await turn(client, context: Context(systemPrompt: claudeCodeSystem, messages: [.user(UserMessage(text: "hi"))]))
        var failure = try #require(message.failure)
        #expect(failure.category == .quota)
        #expect(failure.outcome == .quotaExhausted)
        #expect(failure.isRetryable == false)
        #expect(failure.providerCode == "RESOURCE_EXHAUSTED")
        #expect(failure.message == "Antigravity: usage limit reached: You have exhausted your capacity on this model. Your quota will reset after 3h19m30s.")
        let resetsAt = try #require(failure.resetsAt)
        let expected = Date().timeIntervalSince1970 + 3 * 3600 + 19 * 60 + 30
        #expect(abs(resetsAt - expected) < 60)

        // The refusal's words without the prompt it refuses: Google busy,
        // retried after the Retry-After it gave.
        client = AntigravityStubClient([.init(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "7"], chunks: [Data(turnedAwayBody.utf8)])])
        (message, _) = await turn(client)
        failure = try #require(message.failure)
        #expect(failure.category == .rateLimit)
        #expect(failure.outcome == .rateLimited)
        #expect(failure.isRetryable == true)
        #expect(failure.resetsAt == nil)
        #expect(failure.retryAfterMs == 7000)
        #expect(ProviderRetryPolicy().delay(for: failure, attempt: 0) == 7000)

        #expect(AntigravityProvider.resetsAfterSeconds("Your quota will reset after 45m2s.") == 2702)
        #expect(AntigravityProvider.resetsAfterSeconds("Your quota will reset after 26s.") == 26)
        #expect(AntigravityProvider.resetsAfterSeconds("Your quota will reset after 155h2m1s.") == 558_121)
        #expect(AntigravityProvider.resetsAfterSeconds("Your quota will reset after ") == nil)
        #expect(AntigravityProvider.resetsAfterSeconds("Resource has been exhausted (e.g. check quota).") == nil)
    }

    @Test("A 429 that is back soon, or Google's capacity, is waited out; spent quota is not (oh-my-pi, magpie backSoon)", arguments: [
        // A short reset, even of the plan's own quota: retried after it.
        (#"{"error":{"code":429,"message":"You have exhausted your capacity on this model. Your quota will reset after 26s.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"QUOTA_EXHAUSTED"}]}}"#,
         ProviderFailure.Category.rateLimit, 26_000.0 as Double?, false),
        // Google's RetryInfo names the wait.
        (#"{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"3.5s"}]}}"#,
         .rateLimit, 3_500, false),
        // No capacity for the model right now.
        (#"{"error":{"code":429,"message":"No capacity available for model claude-opus-4-6-thinking on the server","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"MODEL_CAPACITY_EXHAUSTED"}]}}"#,
         .rateLimit, nil, false),
        (#"{"error":{"code":429,"message":"Too many requests.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"RATE_LIMIT_EXCEEDED"}]}}"#,
         .rateLimit, nil, false),
        // Spent: the plan's words with no reset, a daily quota, a long RetryInfo.
        (#"{"error":{"code":429,"message":"You have exhausted your capacity on this model.","status":"RESOURCE_EXHAUSTED"}}"#,
         .quota, nil, false),
        (#"{"error":{"code":429,"message":"Resource has been exhausted.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel"}]}]}}"#,
         .quota, nil, false),
        (#"{"error":{"code":429,"message":"Resource has been exhausted.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"3600s"}]}}"#,
         .quota, nil, true),
        (quotaSpentBody, .quota, nil, true),
    ])
    func exhausted(body: String, category: ProviderFailure.Category, retryAfterMs: Double?, resets: Bool) {
        let failure = AntigravityProvider.httpFailure(status: 429, body: Data(body.utf8), model: "m", system: nil)
        #expect(failure.httpStatus == 429)
        #expect(failure.category == category)
        #expect(failure.isRetryable == (category == .rateLimit))
        #expect(failure.retryAfterMs == retryAfterMs)
        #expect((failure.resetsAt != nil) == resets)
        if category == .quota {
            #expect(failure.message.hasPrefix("Antigravity: usage limit reached: "))
            #expect(failure.outcome == .quotaExhausted)
        } else {
            #expect(failure.message.hasPrefix("Antigravity: rate limited: "))
            #expect(failure.outcome == .rateLimited)
        }
    }

    @Test("Other answers are read by their status and Google's words", arguments: [
        (400, #"{"error":{"code":400,"message":"* GenerateContentRequest.tools[0].function_declarations[17].parameters.properties[batch].items: missing field.\n","status":"INVALID_ARGUMENT"}}"#,
         "Antigravity: * GenerateContentRequest.tools[0].function_declarations[17].parameters.properties[batch].items: missing field.", ProviderFailure.Category.invalidRequest),
        (403, #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#,
         "Antigravity: The caller does not have permission", .authentication),
        (404, #"{"error":{"code":404,"message":"Requested entity was not found.","status":"NOT_FOUND"}}"#,
         "Antigravity: this account is not served gemini-4-argon (Requested entity was not found.)", .invalidRequest),
        (500, #"{"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}"#,
         "Antigravity: Internal error encountered.", .server),
        (503, "unavailable", "Antigravity: unavailable", .server),
        (502, "", "Antigravity: HTTP 502", .server),
    ])
    func statuses(status: Int, body: String, message: String, category: ProviderFailure.Category) {
        let failure = AntigravityProvider.httpFailure(status: status, body: Data(body.utf8), model: "gemini-4-argon", system: claudeCodeSystem)
        #expect(failure.httpStatus == status)
        #expect(failure.message == message)
        #expect(failure.category == category)
    }
}

// MARK: - Models and registration

@Suite("Antigravity models")
struct AntigravityModelTests {
    @Test("The bundled seed is a free-tier account's live list of 2026-11-02, one row a family, on Antigravity's wire")
    func bundled() {
        let models = ModelsCatalog.models(for: "antigravity")
        #expect(models.map(\.id) == [
            "claude-opus-4-6-thinking", "claude-sonnet-4-6", "gemini-3-flash", "gemini-3.1-flash-lite",
            "gemini-3.8-flash", "gpt-oss-120b-medium",
        ])
        for model in models {
            #expect(model.api == "antigravity-codeassist")
            #expect(model.provider == "antigravity")
            #expect(model.baseURL == "https://daily-cloudcode-pa.googleapis.com")
            #expect(model.cost == ModelCost())
        }
        func limits(_ id: String) -> (Int, Int) { (catalog(id).contextWindow, catalog(id).maxTokens) }
        #expect(limits("gemini-3.8-flash") == (1_048_576, 65_536))
        #expect(limits("gemini-3-flash") == (1_048_576, 65_536))
        #expect(limits("gemini-3.1-flash-lite") == (1_048_576, 65_535))
        #expect(limits("claude-opus-4-6-thinking") == (250_000, 64_000))
        #expect(limits("claude-sonnet-4-6") == (250_000, 64_000))
        #expect(limits("gpt-oss-120b-medium") == (131_072, 32_768))
        #expect(flash.thinkingLevelMap?.compactMapValues { $0 } == [
            "low": "gemini-3.8-flash-low", "medium": "gemini-3.8-flash-medium", "high": "gemini-3.8-flash-high",
        ])
        // The rows are named as Antigravity's picker names them, a family
        // without its level.
        #expect(flash.name == "Gemini 3.8 Flash")
        // Sonnet goes without thinking, so its name doesn't say it does.
        #expect(sonnet.name == "Claude Sonnet 4.6")
        #expect(opus.name == "Claude Opus 4.6 (Thinking)")
        #expect(gptOSS.name == "GPT-OSS 120B (Medium)")
        #expect(flash.input == [.text, .image])
        #expect(gptOSS.input == [.text])
        #expect(!sonnet.reasoning && !gptOSS.reasoning && opus.reasoning)

        // An id the seed lacks still resolves.
        let argon = antigravityModel(id: "gemini-4-argon")
        #expect(argon.api == "antigravity-codeassist")
        #expect(argon.reasoning)
        #expect(argon.contextWindow == 1_048_576)
        #expect(antigravityModel(id: "claude-opus-5-5").contextWindow == 250_000)
        #expect(!antigravityModel(id: "gpt-oss-20b").reasoning)
    }
}

@Suite("Antigravity registration")
struct AntigravityRegistrationTests {
    private func manager(_ credentials: OAuthCredentials) async throws -> OAuthManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
        try await store.set(credentials, for: "antigravity")
        return OAuthManager(store: store)
    }

    @Test("A stored login registers the provider; each request carries its token and the project the sign-in found")
    func stored() async throws {
        let manager = try await manager(OAuthCredentials(
            access: "at", refresh: "rt", expires: .max,
            extras: ["email": "ag@example.com", "projectId": "ag-proj", "tier": "standard-tier", "paidTier": "g1-pro-tier"]
        ))
        let resolved = try #require(try await registerStored(storeId: "antigravity", manager: manager))
        #expect(resolved.model.id == "gemini-3.8-flash")
        #expect(resolved.model.provider == "antigravity")
        #expect(resolved.model.api == "antigravity-codeassist")
        #expect(resolved.modelLabel == "gemini-3.8-flash · Antigravity")
        #expect(await APIRegistry.shared.provider(scope: "antigravity", api: "antigravity-codeassist") is AntigravityProvider)

        let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
        #expect(auth.token == "at")
        #expect(auth.scheme == .bearer)
        #expect(auth.baseURL == nil)
        #expect(auth.metadata == [
            "email": "ag@example.com", "projectId": "ag-proj", "tier": "standard-tier", "paidTier": "g1-pro-tier",
        ])
    }

    @Test("A model override is honoured, and a signed-out store resolves to nothing")
    func overrideAndSignedOut() async throws {
        let manager = try await manager(OAuthCredentials(access: "at", refresh: "rt", expires: .max))
        let resolved = try #require(try await registerStored(
            storeId: "antigravity", manager: manager, modelOverride: "claude-sonnet-4-6", primeToken: false
        ))
        #expect(resolved.model.id == "claude-sonnet-4-6")
        #expect(resolved.model.contextWindow == 250_000)
        #expect(resolved.modelLabel == "claude-sonnet-4-6 · Antigravity")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let empty = OAuthManager(store: try OAuthStore(url: dir.appendingPathComponent("oauth.json")))
        #expect(try await registerStored(storeId: "antigravity", manager: empty) == nil)
        #expect(try await antigravityAuthResolver(manager: empty)(resolved.model, nil) == nil)
    }

    @Test("Antigravity is a known OAuth provider, in the directory after Kiro, attributed by name")
    func known() async throws {
        #expect(OAuthManager.defaultProviders().contains { $0.id == "antigravity" })
        #expect(ProviderAttribution.getProviderDisplayName("antigravity") == "Antigravity")
        #expect(modelProviderScope(forStoreId: "antigravity") == "antigravity")
        #expect(catalogProvider(forStoreId: "antigravity") == "antigravity")
        #expect(providerDisplayName(forStoreId: "antigravity") == "Antigravity")
        #expect(storedProviderOrder(ids: ["antigravity", "kiro", "qoder"]) == ["kiro", "antigravity", "qoder"])
    }
}
