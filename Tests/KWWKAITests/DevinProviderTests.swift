import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Path-routed HTTP stub: each URL path answers with a status and a list of
/// body chunks; every request is recorded.
final class DevinRouteStubClient: HTTPClient, @unchecked Sendable {
    struct Route {
        var status: Int
        var chunks: [Data]
    }

    private let lock = NSLock()
    private var routes: [String: [Route]]
    private(set) var requests: [(url: URL, headers: [String: String], body: Data?)] = []

    init(_ routes: [String: [Route]]) {
        self.routes = routes
    }

    func requests(to path: String) -> [(url: URL, headers: [String: String], body: Data?)] {
        lock.withLock { requests.filter { $0.url.path == path } }
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let route: Route = lock.withLock {
            requests.append((url, headers, body))
            guard var queue = routes[url.path], !queue.isEmpty else { return Route(status: 404, chunks: []) }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            routes[url.path] = queue
            return next
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        let stream = AsyncThrowingStream<Data, Error> { cont in
            for chunk in route.chunks { cont.yield(chunk) }
            cont.finish()
        }
        return (response, stream)
    }
}

// MARK: - Helpers

private func frame(_ payload: Data, flags: UInt8 = 0, gzip: Bool = false) -> Data {
    let body = gzip ? try! Gzip.compress(payload) : payload
    var out = Data([flags | (gzip ? 0x01 : 0)])
    out.append(DevinAgentProvider.bigEndian(UInt32(body.count)))
    out.append(body)
    return out
}

private func jwtResponse(_ jwt: String, customURL: String = "") -> Data {
    var w = ProtoWriter()
    w.stringField(1, jwt)
    if !customURL.isEmpty { w.stringField(2, customURL) }
    return w.data
}

private func chatDelta(_ build: (inout ProtoWriter) -> Void) -> Data {
    var w = ProtoWriter()
    build(&w)
    return w.data
}

private func toolCall(id: String = "", name: String = "", args: String = "") -> Data {
    DevinProto.ChatToolCall(id: id, name: name, argumentsJson: args).encode()
}

/// Top-level fields of a protobuf message, grouped by number.
private func fields(_ data: Data) -> [Int: [ProtoReader.Value]] {
    var out: [Int: [ProtoReader.Value]] = [:]
    var r = ProtoReader(data)
    while let f = r.next() { out[f.number, default: []].append(f.value) }
    return out
}

/// Unwrap the single gzip Connect frame the provider posts to GetChatMessage.
private func decodeChatRequest(_ body: Data?) throws -> [Int: [ProtoReader.Value]] {
    let body = try #require(body)
    #expect(body[body.startIndex] == 0x01)
    let payload = Data(body.dropFirst(5))
    return fields(try Gzip.decompress(payload))
}

/// Explicit per-level routing (absent levels map to `nil` = unsupported).
private func levelMap(_ routes: [String: String]) -> [String: String?] {
    var map: [String: String?] = [:]
    for level in DevinModels.thinkingLevels { map[level] = .some(routes[level]) }
    return map
}

private func devinTestModel(
    id: String = "swe-1-6",
    reasoning: Bool = true,
    compat: ModelCompat? = nil,
    thinkingLevelMap: [String: String?]? = nil
) -> Model {
    Model(
        id: id, name: id, api: "devin-agent", provider: "devin",
        baseURL: "https://devin.test", reasoning: reasoning, input: [.text],
        cost: ModelCost(input: 1, output: 2), contextWindow: 200_000, maxTokens: 32_000,
        compat: compat, thinkingLevelMap: thinkingLevelMap
    )
}

private func collect(_ stream: AssistantMessageStream) async -> (events: [AssistantMessageEvent], final: AssistantMessage?) {
    var events: [AssistantMessageEvent] = []
    var final: AssistantMessage?
    for await event in stream {
        events.append(event)
        switch event {
        case .done(_, let message): final = message
        case .error(_, let message): final = message
        default: break
        }
    }
    return (events, final)
}

// MARK: - Tests

@Suite("Devin gzip + Connect framing")
struct DevinFramingTests {
    @Test("gzip round-trips and emits the gzip magic")
    func gzipRoundTrip() throws {
        let input = Data(String(repeating: "devin cascade ", count: 500).utf8)
        let compressed = try Gzip.compress(input)
        #expect(Gzip.isGzip(compressed))
        #expect(compressed.count < input.count)
        #expect(try Gzip.decompress(compressed) == input)
        #expect(try Gzip.decompress(try Gzip.compress(Data())) == Data())
    }

    @Test("decompression refuses output beyond the cap")
    func gzipLimit() throws {
        let bomb = try Gzip.compress(Data(repeating: 0, count: 1_000_000))
        #expect(throws: Gzip.GzipError.self) { try Gzip.decompress(bomb, limit: 1000) }
    }

    @Test("frame parser reassembles frames split across chunks")
    func frameParser() throws {
        let a = frame(Data("one".utf8))
        let b = frame(Data("{}".utf8), flags: 0x02)
        let joined = a + b
        var parser = ConnectFrameParser(maxPayload: 1024)
        var frames: [ConnectFrameParser.Frame] = []
        for i in stride(from: 0, to: joined.count, by: 3) {
            frames += try parser.append(Data(joined[i..<min(i + 3, joined.count)]))
        }
        #expect(frames.count == 2)
        #expect(frames[0].payload == Data("one".utf8))
        #expect(frames[1].flags == 0x02)
    }

    @Test("frame parser rejects an oversized length prefix")
    func frameTooLarge() {
        var parser = ConnectFrameParser(maxPayload: 10)
        #expect(throws: ConnectFrameParser.ParseError.self) {
            _ = try parser.append(Data([0, 0, 0, 1, 0]))
        }
    }
}

@Suite("Devin provider stream")
struct DevinProviderStreamTests {
    @Test("streams thinking, text and a tool call; request carries auth, history and routed uid")
    func fullTurn() async throws {
        let chat = [
            frame(chatDelta { w in
                w.stringField(1, "msg-1")
                w.stringField(9, "pondering")
                w.stringField(10, "sig-1")
            }, gzip: true),
            frame(chatDelta { $0.stringField(3, "Hello") }),
            frame(chatDelta { $0.bytesField(6, toolCall(id: "call-1", name: "read", args: "{\"path\":")) }),
            frame(chatDelta { w in
                w.bytesField(6, toolCall(args: "{\"path\":\"a.txt\"}"))
                w.messageField(7) { u in
                    u.varintField(2, 100)
                    u.varintField(3, 20)
                    u.varintField(4, 5)
                    u.varintField(5, 50)
                }
                w.stringField(23, "swe-1-6-actual")
            }),
            frame(Data("{}".utf8), flags: 0x02),
        ]
        let client = DevinRouteStubClient([
            DevinWire.getUserJwtPath: [.init(status: 200, chunks: [jwtResponse("user-jwt")])],
            DevinWire.getChatMessagePath: [.init(status: 200, chunks: chat)],
        ])
        let model = devinTestModel(
            id: "claude-opus-5",
            thinkingLevelMap: levelMap(["low": "claude-opus-5-low", "high": "claude-opus-5-high"])
        )
        let context = Context(
            systemPrompt: "be terse",
            messages: [
                .user(UserMessage(text: "read a.txt")),
            ],
            tools: [Tool(name: "read", description: "Read a file", parameters: .object(["type": .string("object")]))]
        )
        let provider = DevinAgentProvider(client: client)
        let (events, final) = await collect(provider.stream(
            model: model, context: context,
            options: StreamOptions(apiKey: "tok", sessionId: "cascade-1", reasoning: .high)
        ))

        let message = try #require(final)
        #expect(message.stopReason == .toolUse)
        #expect(message.responseId == "msg-1")
        #expect(message.responseModel == "swe-1-6-actual")
        #expect(message.usage.input == 100)
        #expect(message.usage.output == 20)
        #expect(message.usage.cacheWrite == 5)
        #expect(message.usage.cacheRead == 50)
        #expect(message.usage.totalTokens == 175)
        #expect(message.content.count == 3)
        if case .thinking(let th) = message.content[0] {
            #expect(th.thinking == "pondering")
            #expect(th.thinkingSignature == "sig-1")
        } else { Issue.record("expected thinking first") }
        if case .text(let t) = message.content[1] { #expect(t.text == "Hello") } else { Issue.record("expected text") }
        if case .toolCall(let call) = message.content[2] {
            #expect(call.id == "call-1")
            #expect(call.name == "read")
            #expect(call.arguments == .object(["path": .string("a.txt")]))
        } else { Issue.record("expected tool call") }
        #expect(events.contains { if case .toolCallEnd = $0 { return true }; return false })

        // GetUserJwt: session-token-prefixed key inside Metadata.
        let auth = try #require(client.requests(to: DevinWire.getUserJwtPath).first)
        let authBody = try #require(auth.body)
        let authMeta = fields(try #require(fields(authBody)[1]?.first?.asData))
        #expect(authMeta[3]?.first?.asString == "devin-session-token$tok")
        #expect(authMeta[1]?.first?.asString == "devin-cli")
        #expect(authMeta[28]?.first?.asString == "chisel")

        // GetChatMessage: gzip frame with jwt, routed uid, prompt and history.
        let chatRequest = try #require(client.requests(to: DevinWire.getChatMessagePath).first)
        #expect(chatRequest.headers["connect-content-encoding"] == "gzip")
        #expect(chatRequest.headers["content-type"] == "application/connect+proto")
        let req = try decodeChatRequest(chatRequest.body)
        let meta = fields(try #require(req[1]?.first?.asData))
        #expect(meta[21]?.first?.asString == "user-jwt")
        #expect(req[21]?.first?.asString == "claude-opus-5-high")
        #expect(req[2]?.first?.asString == "be terse")
        #expect(req[16]?.first?.asString == "cascade-1")
        #expect(req[7]?.first?.asUInt64 == 5)
        #expect(req[11]?.first?.asBool == true) // no parallel-tool compat ⇒ disabled
        let prompt = fields(try #require(req[3]?.first?.asData))
        #expect(prompt[2]?.first?.asUInt64 == 1)
        #expect(prompt[3]?.first?.asString == "read a.txt")
        let tool = fields(try #require(req[10]?.first?.asData))
        #expect(tool[1]?.first?.asString == "read")
        #expect(tool[3]?.first?.asString == "{\"type\":\"object\"}")
    }

    @Test("history maps assistant turns, tool calls and tool results onto Cascade channels")
    func historyMapping() {
        let model = devinTestModel()
        let messages: [Message] = [
            .user(UserMessage(text: "hi")),
            .assistant(AssistantMessage(
                content: [.thinking(ThinkingContent(thinking: "t", thinkingSignature: "s")),
                          .text(TextContent(text: "ok")),
                          .toolCall(ToolCall(id: "c1", name: "ls", arguments: .object([:])))],
                api: "devin-agent", provider: "devin", model: "swe-1-6", responseId: "resp-9"
            )),
            .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "ls", content: [.text(TextContent(text: "a b"))], isError: true)),
        ]
        let prompts = DevinAgentProvider.chatMessagePrompts(messages, cascadeId: "c", model: model)
        #expect(prompts.count == 3)
        #expect(prompts[0].source == .user)
        #expect(prompts[1].source == .system)
        #expect(prompts[1].messageId == "resp-9")
        #expect(prompts[1].signature == "s")
        #expect(prompts[1].toolCalls.first?.name == "ls")
        #expect(prompts[2].source == .tool)
        #expect(prompts[2].toolCallId == "c1")
        #expect(prompts[2].toolResultIsError)
        // Deterministic ids are stable across rebuilds.
        let again = DevinAgentProvider.chatMessagePrompts(messages, cascadeId: "c", model: model)
        #expect(again[0].messageId == prompts[0].messageId)
    }

    @Test("401 on the prefixed session token retries GetUserJwt with the raw key")
    func authRetry() async throws {
        let client = DevinRouteStubClient([
            DevinWire.getUserJwtPath: [
                .init(status: 401, chunks: [Data("{\"code\":\"unauthenticated\",\"message\":\"bad\"}".utf8)]),
                .init(status: 200, chunks: [jwtResponse("jwt-2", customURL: "https://custom.test/")]),
            ],
        ])
        let provider = DevinAgentProvider(client: client)
        let auth = try await provider.fetchAuth(apiKey: "raw", baseURL: "https://devin.test", cancellation: nil)
        #expect(auth.userJwt == "jwt-2")
        #expect(auth.apiKey == "raw")
        #expect(auth.baseURL == "https://custom.test")
        #expect(client.requests(to: DevinWire.getUserJwtPath).count == 2)
    }

    @Test("router models call AssignModel and send the assigned uid + JWT")
    func routerAssignment() async throws {
        var assignment = ProtoWriter()
        assignment.messageField(1) { a in
            a.stringField(1, "assign-jwt")
            a.stringField(2, "swe-1-7")
        }
        let client = DevinRouteStubClient([
            DevinWire.getUserJwtPath: [.init(status: 200, chunks: [jwtResponse("jwt")])],
            DevinWire.assignModelPath: [.init(status: 200, chunks: [assignment.data])],
            DevinWire.getChatMessagePath: [.init(status: 200, chunks: [
                frame(chatDelta { $0.stringField(3, "routed") }),
                frame(Data(), flags: 0x02),
            ])],
        ])
        var compat = ModelCompat()
        compat.modelRouter = true
        let provider = DevinAgentProvider(client: client)
        let (_, final) = await collect(provider.stream(
            model: devinTestModel(id: "adaptive", compat: compat),
            context: Context(messages: [.user(UserMessage(text: "go"))]),
            options: StreamOptions(apiKey: "tok")
        ))
        #expect(final?.stopReason == .stop)
        #expect(final?.responseModel == "swe-1-7")
        let assign = fields(try #require(client.requests(to: DevinWire.assignModelPath).first?.body))
        #expect(assign[2]?.first?.asString == "adaptive")
        let req = try decodeChatRequest(client.requests(to: DevinWire.getChatMessagePath).first?.body)
        #expect(req[21]?.first?.asString == "swe-1-7")
        #expect(req[26]?.first?.asString == "assign-jwt")
    }

    @Test("HTTP errors surface the Connect error message and status")
    func httpError() async throws {
        let client = DevinRouteStubClient([
            DevinWire.getUserJwtPath: [.init(status: 200, chunks: [jwtResponse("jwt")])],
            DevinWire.getChatMessagePath: [.init(status: 429, chunks: [
                Data("{\"code\":\"resource_exhausted\",\"message\":\"slow down\"}".utf8),
            ])],
        ])
        let (_, final) = await collect(DevinAgentProvider(client: client).stream(
            model: devinTestModel(), context: Context(messages: [.user(UserMessage(text: "x"))]),
            options: StreamOptions(apiKey: "tok")
        ))
        #expect(final?.stopReason == .error)
        #expect(final?.failure?.httpStatus == 429)
        #expect(final?.errorMessage?.contains("slow down") == true)
        #expect(final?.failure?.category == .rateLimit)
    }

    @Test("missing token fails fast without network")
    func missingToken() async {
        let client = DevinRouteStubClient([:])
        let (_, final) = await collect(DevinAgentProvider(client: client).stream(
            model: devinTestModel(), context: Context(messages: []), options: nil
        ))
        #expect(final?.stopReason == .error)
        #expect(client.requests.isEmpty)
    }

    @Test("invalid_argument internal error with a large history is classified as context overflow")
    func trailerOverflow() throws {
        let trailer = Data(#"{"error":{"code":"invalid_argument","message":"an internal error occurred"}}"#.utf8)
        let large = try #require(DevinAgentProvider.trailerFailure(trailer, historyBytes: { 600 * 1024 }))
        #expect(large.category == .contextOverflow)
        let small = try #require(DevinAgentProvider.trailerFailure(trailer, historyBytes: { 1024 }))
        #expect(small.category == .invalidRequest)
        #expect(DevinAgentProvider.trailerFailure(Data("{}".utf8), historyBytes: { 0 }) == nil)
    }

    @Test("Gemini schema normalization folds type arrays into nullable")
    func geminiSchema() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["n": .object(["type": .array([.string("number"), .string("null")])])]),
        ])
        let normalized = DevinAgentProvider.normalizeSchemaForGoogle(schema)
        #expect(normalized == .object([
            "type": .string("object"),
            "properties": .object(["n": .object(["type": .string("number"), "nullable": .bool(true)])]),
        ]))
        #expect(DevinAgentProvider.isGeminiUid("MODEL_GOOGLE_GEMINI_3"))
        #expect(DevinAgentProvider.isGeminiUid("gemini-3-7-flash-low"))
    }

    @Test("wire uid follows the thinking level map, clamping to the nearest routed level")
    func wireModelId() {
        let model = devinTestModel(
            id: "fam",
            thinkingLevelMap: levelMap(["low": "fam-low", "high": "fam-high"])
        )
        #expect(DevinAgentProvider.wireModelId(model: model, reasoning: nil) == "fam-low")
        #expect(DevinAgentProvider.wireModelId(model: model, reasoning: .medium) == "fam-high")
        #expect(DevinAgentProvider.wireModelId(model: devinTestModel(), reasoning: .high) == "swe-1-6")
    }
}

@Suite("Devin model normalization")
struct DevinModelNormalizationTests {
    private func config(
        _ uid: String, label: String? = nil, thinking: Bool = true, images: Bool = false,
        display: UInt64 = 0, router: Bool = false, family: DevinProto.ModelFamilyMetadata? = nil,
        isDefault: Bool = false, disabled: Bool = false, dims: [DevinProto.ModelDimension] = []
    ) -> DevinProto.ClientModelConfig {
        var c = DevinProto.ClientModelConfig()
        c.label = label ?? uid
        c.modelUid = uid
        c.disabled = disabled
        c.maxTokens = 400_000
        var info = DevinProto.ModelInfo()
        info.modelFeatures = .init(supportsImages: images, supportsToolCalls: true, supportsParallelToolCalls: true, supportsThinking: thinking)
        info.maxOutputTokens = 32_000
        info.displayOption = display
        info.isModelRouter = router
        c.modelInfo = info
        c.modelFamilyMetadata = family
        c.isDefaultModelInFamily = isDefault
        c.modelDimensions = dims
        return c
    }

    private func family(_ label: String, effort: String, fast: Bool = false) -> DevinProto.ModelFamilyMetadata {
        var meta = DevinProto.ModelFamilyMetadata()
        meta.label = label
        meta.entries = [.init(key: "Reasoning Effort", order: 0, name: effort, hasValue: true)]
        if fast { meta.entries.append(.init(key: "Fast Mode", order: 1, name: "On", hasValue: true)) }
        return meta
    }

    @Test("collapses server families, the static table, and filters internal configs")
    func normalize() throws {
        let configs = [
            config("gpt-x-low", family: family("GPT-X", effort: "Low")),
            config("gpt-x-high", family: family("GPT-X", effort: "X High"), isDefault: true),
            config("gpt-x-low-fast", family: family("GPT-X", effort: "Low", fast: true)),
            config("claude-opus-5-low"),
            config("claude-opus-5-high"),
            config("adaptive", thinking: false, display: DevinProto.DisplayOption.modelRouter),
            config("quick", display: DevinProto.DisplayOption.quickReview),
            config("gone", disabled: true),
            config("fusion-swe-1-6-sidekick-gpt", router: true),
            config("swe-1-6", images: true, dims: [
                .init(label: "Input", value: 0.1, denominator: "1M tokens", kind: 1),
                .init(label: "Output", value: 0.5, denominator: "1M tokens", kind: 2),
                .init(label: "Sidekick", value: 0, denominator: "", kind: 0),
                .init(label: "Input", value: 9, denominator: "1M tokens", kind: 1),
            ]),
            config("swe-2"),
        ]
        let models = DevinModels.normalize(configs)
        let byId = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        #expect(Set(byId.keys) == ["gpt-x", "gpt-x-fast", "claude-opus-5", "adaptive", "swe-1-6", "swe-2"])

        let gpt = try #require(byId["gpt-x"])
        #expect(gpt.reasoning)
        #expect(gpt.thinkingLevelMap?["low"] == .some("gpt-x-low"))
        #expect(gpt.thinkingLevelMap?["xhigh"] == .some("gpt-x-high"))
        #expect(gpt.thinkingLevelMap?["off"] == .some(nil))
        #expect(gpt.contextWindow == 400_000)
        #expect(gpt.maxTokens == 32_000)

        let opus = try #require(byId["claude-opus-5"])
        #expect(opus.name == "Claude Opus 5")
        #expect(opus.thinkingLevelMap?["high"] == .some("claude-opus-5-high"))
        #expect(opus.thinkingLevelMap?["medium"] == .some(nil))

        #expect(byId["adaptive"]?.compat?.modelRouter == true)
        // SWE-1.6 is image-blind despite the advertised feature; the Sidekick
        // marker stops the cost scan.
        #expect(byId["swe-1-6"]?.input == [.text])
        #expect(byId["swe-1-6"]?.cost.input == 0.1)
        #expect(byId["swe-1-6"]?.cost.output == 0.5)
        // Plan-included model with no cost dimensions gets the list-price fallback.
        #expect(byId["swe-2"]?.cost.input == 0.75)
    }

    @Test("a static rename family keeps sending the original wire uid")
    func renameFamily() throws {
        let models = DevinModels.normalize([config("MODEL_PRIVATE_11", label: "Haiku", thinking: false)])
        let haiku = try #require(models.first)
        #expect(haiku.id == "claude-haiku-4-5")
        #expect(DevinAgentProvider.wireModelId(model: haiku, reasoning: .high) == "MODEL_PRIVATE_11")
    }

    @Test("discovery decodes GetCliModelConfigs and keeps the seed models")
    func fetch() async throws {
        var response = ProtoWriter()
        var c = ProtoWriter()
        c.stringField(1, "SWE-1.7")
        c.stringField(22, "swe-1-7-solo")
        c.int32Field(18, 300_000)
        response.bytesField(1, c.data)
        let client = DevinRouteStubClient([
            DevinWire.getCliModelConfigsPath: [.init(status: 200, chunks: [try Gzip.compress(response.data)])],
        ])
        let models = try await DevinModels.fetch(apiKey: "tok", baseURL: "https://devin.test", client: client)
        #expect(models.map(\.id) == ["swe-1-6", "swe-1-6-fast", "swe-1-7-solo"])
        #expect(models.last?.contextWindow == 300_000)
        let discoveryBody = try #require(client.requests.first?.body)
        let meta = fields(try #require(fields(discoveryBody)[1]?.first?.asData))
        #expect(meta[1]?.first?.asString == "chisel")
        #expect(meta[3]?.first?.asString == "devin-session-token$tok")
    }

    @Test("bundled catalog carries the default model")
    func bundled() {
        let model = ModelsCatalog.model(provider: "devin", id: DevinModels.defaultModelId)
        #expect(model?.api == "devin-agent")
    }
}

@Suite("Devin OAuth login")
struct DevinOAuthLoginTests {
    @Test("PKCE callback flow exchanges the code for a session token")
    func login() async throws {
        let token = "header.\(Data(#"{"exp":4102444800}"#.utf8).base64EncodedString()).sig"
        let client = DevinRouteStubClient([
            "/auth/cli/token": [.init(status: 200, chunks: [Data("{\"token\":\"\(token)\"}".utf8)])],
        ])
        let port: UInt16 = 53991
        let authURL = LockedBox<URL?>(nil)
        let callbacks = OAuthLogin.Callbacks(
            onAuthURL: { url in
                authURL.set(url)
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""
                Task.detached {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let callback = URL(string: "http://127.0.0.1:\(port)/callback?code=the-code&state=\(state)")!
                    _ = try? await URLSession.shared.data(from: callback)
                }
            },
            onProgress: { _ in }
        )
        let creds = try await OAuthLogin.loginDevin(port: port, callbacks: callbacks, client: client)
        #expect(creds.access == token)
        #expect(creds.refresh == "")
        #expect(creds.expires == 4_102_444_800_000 - 5 * 60 * 1000)

        let url = try #require(authURL.get())
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "app.devin.ai")
        #expect(items["redirect_uri"] == "http://127.0.0.1:\(port)/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["response_type"] == "code")
        #expect(items["prompt"] == "select_account")

        let exchange = try #require(client.requests(to: "/auth/cli/token").first?.body)
        let body = try #require(try JSONSerialization.jsonObject(with: exchange) as? [String: String])
        #expect(body["code"] == "the-code")
        #expect(body["code_verifier"]?.isEmpty == false)
    }

    @Test("OAuth manager recognizes stored Devin credentials")
    func managerKnowsDevin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
        try await store.set(OAuthCredentials(access: "sess", refresh: "", expires: .max), for: "devin")
        let manager = OAuthManager(store: store)
        #expect(try await manager.apiKey(for: "devin") == "sess")
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T { lock.withLock { value } }
}
