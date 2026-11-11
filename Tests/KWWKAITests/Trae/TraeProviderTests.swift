import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The frames and listings below are the shapes Trae's gate gives
// (`llm_utils_chat`, `get_detail_param`), from the captures JanXiao's
// provider for Apelin was written against (owngoal-dev/Apelin#40).

private func sse(_ frames: (event: String, data: String)...) -> String {
    frames.map { "event: \($0.event)\ndata: \($0.data)\n\n" }.joined()
}

private let textStream = sse(
    ("output", #"{"reasoning_content":"Look first.","response":""}"#),
    ("output", #"{"response":"我来"}"#),
    ("output", #"{"response":"看一下。"}"#),
    ("token_usage", #"{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}"#),
    ("done", #"{"finish_reason":"stop"}"#)
)

private let credentials = OAuthCredentials(
    access: "jwt-1",
    refresh: "refresh-1",
    expires: .max,
    extras: [
        "userId": .string("user-1"),
        "machineId": .string("machine-1"),
        "checkinDeviceId": .string("device-1"),
    ]
)

private func auth() -> ResolvedProviderAuth {
    ResolvedProviderAuth(headers: TraeWire.accountHeaders(token: "jwt-1", credentials: credentials))
}

private func run(
    _ site: TraeSite = .china,
    modelId: String = "glm-5.3",
    functions: [String: String] = [:],
    client: StubSSEClient,
    context: Context
) async -> (events: [AssistantMessageEvent], result: AssistantMessage) {
    let stream = TraeProvider(site: site, functions: functions, client: client).stream(
        model: TraeModels.model(site: site, id: modelId),
        context: context,
        options: StreamOptions(resolvedAuth: auth())
    )
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return (events, await stream.result())
}

private func body(_ client: StubSSEClient) throws -> [String: Any] {
    let data = try #require(client.lastRequest?.body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let hello = Context(systemPrompt: "You are kwwk.", messages: [.user(UserMessage(text: "hi"))])

@Suite("Trae provider")
struct TraeProviderTests {
    // MARK: - Request

    @Test("A chat goes to the build's llm_utils_chat with the client's headers and the account's", arguments: [
        (TraeSite.china, "https://trae-api-cn.mchost.guru/api/agent/v3/llm_utils_chat"),
        (TraeSite.international, "https://core-normal.trae.ai/api/agent/v3/llm_utils_chat"),
    ])
    func requestHeaders(site: TraeSite, endpoint: String) async throws {
        let client = StubSSEClient(body: textStream)
        _ = await run(site, client: client, context: hello)
        let request = try #require(client.lastRequest)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == endpoint)

        var headers = request.headers
        let trace = headers.removeValue(forKey: "x-custom-trace-id") ?? ""
        let traceParent = headers.removeValue(forKey: "x-flow-traceparent")
        let osVersion = headers.removeValue(forKey: "x-os-version") ?? ""
        #expect(trace.count == 32 && trace.allSatisfy(\.isHexDigit))
        #expect(traceParent == "04-\(trace)-\(trace.prefix(16))-01")
        #expect(osVersion.hasPrefix("iOS "))
        #expect(headers == [
            "content-type": "application/json",
            "accept": "text/event-stream",
            // The token, in the three places the gate reads it; none as a bearer.
            "Authorization": "Cloud-IDE-JWT jwt-1",
            "X-Ide-Token": "jwt-1",
            "X-Cloudide-Token": "jwt-1",
            "x-uid": "user-1",
            "x-machine-id": "machine-1",
            "x-device-id": "device-1",
            "x-plugin-channel": "icube-ai",
            "x-app-id": "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8",
            "x-device-type": "ios",
            "x-device-cpu": "arm64",
            "x-ide-version-type": "stable",
            // One set: the gate's configuration table matches all three.
            "x-app-version": "0.1.61",
            "x-ide-version": "0.1.61",
            "x-app-version-code": "20260820",
            "x-ide-version-code": "20260820",
            "User-Agent": "Trae/0.1.61",
            "request-traffic-type": "prod",
        ])
    }

    @Test("A login that recorded no device names one made from the account, the same each time")
    func derivedMachine() {
        var bare = credentials
        bare.extras = ["userId": .string("user-1")]
        let first = TraeWire.accountHeaders(token: "jwt-1", credentials: bare)
        let second = TraeWire.accountHeaders(token: "jwt-2", credentials: bare)
        #expect(first["x-machine-id"]?.count == 32)
        #expect(first["x-machine-id"] == second["x-machine-id"])
        #expect(first["x-device-id"] == first["x-machine-id"])
        #expect(first["x-custom-trace-id"] != second["x-custom-trace-id"])
    }

    @Test("The body is the gate's own: the model under two names, the function that lists it, messages as text blocks")
    func requestBody() async throws {
        let client = StubSSEClient(body: textStream)
        _ = await run(functions: ["glm-5.3": "solo_work_lite"], client: client, context: hello)
        let sent = try body(client)
        #expect(Set(sent.keys) == [
            "app_id", "app_version_code", "function", "model", "config_name", "stream", "messages",
        ])
        #expect(sent["app_id"] as? String == "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8")
        #expect(sent["app_version_code"] as? Int == 20260820)
        #expect(sent["function"] as? String == "solo_work_lite")
        #expect(sent["model"] as? String == "glm-5.3")
        #expect(sent["config_name"] as? String == "glm-5.3")
        #expect(sent["stream"] as? Bool == true)
        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[1]["content"] as? [[String: String]] == [["type": "text", "text": "hi"]])

        // A model no roster listed is asked through the default function.
        _ = await run(modelId: "auto", client: client, context: hello)
        #expect(try body(client)["function"] as? String == "solo_work_remote")
    }

    @Test("Tools carry their parameters as a JSON string, and a call in the history is a function_call")
    func tools() async throws {
        let client = StubSSEClient(body: textStream)
        let earlier = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call_0", name: "grep", arguments: .object(["pattern": .string("TODO")])))],
            api: "openai-completions", provider: "trae", model: "glm-5.3", stopReason: .toolUse
        )
        let context = Context(
            systemPrompt: "You are kwwk.",
            messages: [
                .user(UserMessage(text: "find them")),
                .assistant(earlier),
                .toolResult(ToolResultMessage(
                    toolCallId: "call_0",
                    toolName: "grep",
                    content: [.text(TextContent(text: "a.swift:1"))]
                )),
            ],
            tools: [
                Tool(name: "grep", description: "Search", parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["pattern": .object(["type": .string("string")])]),
                ])),
            ]
        )
        _ = await run(client: client, context: context)
        let sent = try body(client)

        let tools = try #require(sent["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "grep")
        #expect(function["parameters"] as? String
            == #"{"properties":{"pattern":{"type":"string"}},"type":"object"}"#)

        let messages = try #require(sent["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        #expect(assistant["tool_calls"] == nil)
        let calls = try #require(assistant["function_call"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call_0")
        // Null content beside calls is refused for every later request of
        // the conversation; an empty block list is taken.
        #expect(assistant["content"] is [Any])
        let result = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(result["content"] as? [[String: String]] == [["type": "text", "text": "a.swift:1"]])
    }

    @Test("Messages are mended as the reference client mends them")
    func mendMessages() {
        let mended = TraeWire.mendMessages([
            ["role": "developer", "content": "be brief"],
            ["role": "user", "content": [
                ["type": "text", "text": "what is this"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]],
            ] as [[String: Any]]],
            // An interrupted turn: nothing said, nothing called.
            ["role": "assistant", "content": NSNull()],
            ["role": "assistant", "content": "", "tool_calls": [[String: Any]]()],
            ["role": "assistant", "content": "thinking aloud", "reasoning_content": "hm", "reasoning_details": []],
            ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "c1"]]],
        ])
        #expect(mended.map { $0["role"] as? String } == ["system", "user", "assistant", "assistant"])
        #expect(mended[1]["content"] as? [[String: String]] == [["type": "text", "text": "what is this"]])
        #expect(mended[2]["content"] as? [[String: String]] == [["type": "text", "text": "thinking aloud"]])
        #expect(mended[2]["reasoning_content"] == nil && mended[2]["reasoning_details"] == nil)
        #expect(mended[3]["content"] as? [[String: String]] == [["type": "text", "text": ""]])
        #expect((mended[3]["function_call"] as? [[String: String]]) == [["id": "c1"]])
        #expect(mended[3]["tool_calls"] == nil)
    }

    @Test("A tool with no parameters is given an empty object's schema")
    func bareTool() {
        let mended = TraeWire.mendTools([
            ["type": "function", "function": ["name": "now", "description": "The time"]],
            ["type": "function"],
        ])
        #expect(mended.count == 1)
        #expect((mended[0]["function"] as? [String: Any])?["parameters"] as? String
            == #"{"type":"object","properties":{}}"#)
    }

    // MARK: - Response

    @Test("The gate's frames are read as a reply: thinking, text, usage and its finish")
    func reply() async throws {
        let (events, result) = await run(client: StubSSEClient(body: textStream), context: hello)
        #expect(events.last?.type == "done")
        #expect(result.content == [
            .thinking(ThinkingContent(thinking: "Look first.", thinkingSignature: "reasoning_content")),
            .text(TextContent(text: "我来看一下。")),
        ])
        #expect(result.stopReason == .stop)
        #expect(result.usage.input == 3)
        #expect(result.usage.output == 2)
        #expect(result.provider == "trae")
        #expect(result.failure == nil)
    }

    @Test("A call streams back as fragments under function_call, and a turn that made one ends as a tool use")
    func toolCall() async throws {
        let stream = sse(
            ("output", #"{"tool_calls":[{"id":"call_1","index":0,"function_call":{"name":"grep","arguments":""}}]}"#),
            ("output", #"{"tool_calls":[{"index":0,"function_call":{"arguments":"{\"pat"}}]}"#),
            ("output", #"{"tool_calls":[{"index":0,"function":{"arguments":"tern\":\"TODO\"}"}}]}"#),
            ("done", #"{"finish_reason":"function_call"}"#)
        )
        let (_, result) = await run(client: StubSSEClient(body: stream), context: hello)
        #expect(result.stopReason == .toolUse)
        #expect(result.content == [
            .toolCall(ToolCall(id: "call_1", name: "grep", arguments: .object(["pattern": .string("TODO")]))),
        ])
    }

    @Test("A frame with no event name is an output, and the finish reasons are OpenAI's")
    func frames() {
        let unnamed = TraeWire.translated(event: "", data: #"{"response":"hi"}"#)
        #expect(unnamed.answers && !unnamed.ends)
        #expect(String(decoding: unnamed.lines[0], as: UTF8.self)
            == #"data: {"choices":[{"delta":{"content":"hi"},"finish_reason":null,"index":0}]}"# + "\n\n")
        #expect(TraeWire.translated(event: "output", data: "{}").lines.isEmpty)
        #expect(TraeWire.translated(event: "output", data: "not json").lines.isEmpty)
        #expect(TraeWire.translated(event: "heartbeat", data: "{}").lines.isEmpty)
        #expect(TraeWire.translated(event: "done", data: "{}").ends)

        #expect(TraeWire.finishReason(nil) == "stop")
        #expect(TraeWire.finishReason("end") == "stop")
        #expect(TraeWire.finishReason("max_tokens") == "length")
        #expect(TraeWire.finishReason("function_call") == "tool_calls")
        #expect(TraeWire.finishReason("content_filter") == "content_filter")
    }

    @Test("The gate's refusal ends the turn as a failure in its words, under its code")
    func refusal() async throws {
        let stream = sse(
            ("output", #"{"response":"par"}"#),
            ("error", #"{"code":4001,"message":"param is invalid"}"#)
        )
        let (events, result) = await run(client: StubSSEClient(body: stream), context: hello)
        #expect(events.last?.type == "error")
        #expect(result.stopReason == .error)
        let failure = try #require(result.failure)
        #expect(failure.message == "Trae code 4001: param is invalid")
        #expect(failure.providerCode == "4001")
    }

    @Test("A queue's refusal comes as a 200 frame that carries its own status")
    func queueRefusal() async throws {
        let stream = "data: " + #"{"statusCodeValue":429,"body":"too many requests in queue"}"# + "\n\n"
        let (_, result) = await run(client: StubSSEClient(body: stream), context: hello)
        let failure = try #require(result.failure)
        #expect(failure.message == "Trae answered 429: too many requests in queue")
        #expect(failure.httpStatus == 429)
    }

    @Test("An HTTP refusal is read as it came")
    func httpRefusal() async throws {
        let client = StubSSEClient(body: #"{"code":20101,"message":"token invalid"}"#, statusCode: 401)
        let (_, result) = await run(client: client, context: hello)
        #expect(result.stopReason == .error)
        #expect(result.failure?.httpStatus == 401)
    }

    @Test("A stream cut after it answered ends as cut short; one that never answered is a failure")
    func cutShort() async throws {
        let (_, cut) = await run(
            client: StubSSEClient(body: sse(("output", #"{"response":"我来"}"#))),
            context: hello
        )
        #expect(cut.stopReason == .length)
        #expect(cut.content == [.text(TextContent(text: "我来"))])

        let (_, silent) = await run(
            client: StubSSEClient(body: sse(("token_usage", #"{"prompt_tokens":3}"#))),
            context: hello
        )
        #expect(silent.stopReason == .error)
        #expect(silent.failure?.message == "Trae ended the stream without an answer.")
    }
}

// MARK: - Models

/// Answers the directory by the function a request names, and records what
/// it was asked.
private final class DirectoryStub: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let listings: [String: String]
    private(set) var asked: [(url: URL, headers: [String: String], body: [String: Any])] = []

    init(_ listings: [String: String]) {
        self.listings = listings
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let sent = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        lock.withLock { asked.append((url, headers, sent)) }
        let listing = listings[sent["function"] as? String ?? ""]
        let response = HTTPURLResponse(
            url: url,
            statusCode: listing == nil ? 500 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(Data((listing ?? "").utf8))
            continuation.finish()
        })
    }
}

private func listing(_ entries: String...) -> String {
    #"{"config_info_list":[\#(entries.joined(separator: ","))]}"#
}

private let remoteListing = listing(
    #"{"config_name":"auto","context_window_tokens":{"dev":200000}}"#,
    #"{"config_name":"glm-5.3","display_config":{"model_capability":"reasoning_model"},"context_window_tokens":{"dev":119040},"model_detail_list":[{"max_tokens":32000,"prompt_max_tokens":100000}]}"#,
    #"{"config_name":"hidden-one","is_invisible_to_user":true}"#,
    #"{"config_name":"search_agent_v2"}"#
)

private let liteListing = listing(
    #"{"config_name":"glm-5.3","model_detail_list":[{"max_tokens":8000}]}"#,
    #"{"config_name":"kimi-k3","model_detail_list":[{"prompt_max_tokens":204800}]}"#,
    #"{"config_name":"title_generation_v1"}"#,
    #"{"config_name":"doubao_auto"}"#
)

private func account(_ userID: String) -> OAuthCredentials {
    var account = credentials
    account.extras["userId"] = .string(userID)
    return account
}

@Suite("Trae models")
struct TraeModelsTests {
    @Test("The roster is every function's listing, each model under the first function that lists it")
    func roster() async throws {
        let client = DirectoryStub(["solo_work_remote": remoteListing, "solo_work_lite": liteListing])
        let credentials = account("roster-user")
        let roster = await TraeModels.roster(site: .china, token: "jwt-1", credentials: credentials, client: client)
        #expect(roster == [
            TraeModels.Entry(
                id: "auto",
                function: "solo_work_remote",
                reasoning: false,
                contextWindow: 200_000,
                maxTokens: 64_000
            ),
            TraeModels.Entry(
                id: "glm-5.3",
                function: "solo_work_remote",
                reasoning: true,
                contextWindow: 119_040,
                maxTokens: 32_000
            ),
            TraeModels.Entry(
                id: "kimi-k3",
                function: "solo_work_lite",
                reasoning: false,
                contextWindow: 204_800,
                maxTokens: 64_000
            ),
        ])

        #expect(client.asked.count == 2)
        let asked = try #require(client.asked.first { $0.body["function"] as? String == "solo_work_remote" })
        #expect(asked.url.absoluteString == "https://trae-api-cn.mchost.guru/api/ide/v1/get_detail_param")
        #expect(asked.headers["Authorization"] == "Cloud-IDE-JWT jwt-1")
        #expect(asked.headers["x-ide-version-code"] == "20260820")
        #expect(asked.headers["Accept"] == "application/json")
        #expect(asked.body["poly_prompt"] as? Bool == true)
        #expect(asked.body["need_prompt"] as? Bool == false)
        #expect(asked.body["config_names"] is NSNull)

        // The same account's roster is not asked for again.
        _ = await TraeModels.roster(site: .china, token: "jwt-1", credentials: credentials, client: client)
        #expect(client.asked.count == 2)
    }

    @Test("A function that does not answer costs only its own models, and a directory that says nothing is no roster")
    func partial() async throws {
        let lite = DirectoryStub(["solo_work_lite": liteListing])
        let rows = try await TraeModels.fetch(site: .international, credentials: account("lite-user"), client: lite)
        #expect(rows.map(\.id) == ["glm-5.3", "kimi-k3"])
        #expect(rows[0].provider == "trae-intl")
        #expect(rows[0].baseURL == "https://core-normal.trae.ai/api/agent/v3/llm_utils_chat")
        #expect(rows[0].maxTokens == 8000)

        await #expect(throws: ProviderFailure.self) {
            _ = try await TraeModels.fetch(site: .china, credentials: account("nobody"), client: DirectoryStub([:]))
        }
    }

    @Test("The agent's own entries are not models a user picks")
    func internalEntries() {
        for id in [
            "custom_model_1", "search_agent", "coding_agent_v3", "x_advisor", "doubao_auto",
            "summary_v2", "title_generation", "input_optimization_1", "fast_apply", "sagitta", "aquila",
        ] {
            #expect(TraeModels.isInternal(id), "\(id)")
        }
        for id in ["auto", "glm-5.3", "Doubao-Seed-2.1-Pro", "DeepSeek-V4-Pro-Official"] {
            #expect(!TraeModels.isInternal(id), "\(id)")
        }
    }

    @Test("Both builds are seeded with the same rows, and a reasoning model is offered no level")
    func seed() {
        for site in TraeSite.all {
            let rows = ModelsCatalog.models(for: site.id)
            #expect(Set(rows.map(\.id)) == Set(TraeModels.seedEntries.map(\.id)))
            #expect(rows.allSatisfy { $0.provider == site.id && $0.api == "openai-completions" })
        }
        let reasons = TraeModels.model(site: .china, id: "glm-5.3")
        #expect(reasons.reasoning)
        #expect(reasons.contextWindow == 119_040)
        // No request made of the gate has named a level, so none goes out.
        #expect(supportedThinkingLevels(reasons).isEmpty)
        #expect(resolveThinkingLevel(reasons, .high) == nil)

        let unknown = TraeModels.model(site: .international, id: "gpt-6")
        #expect(unknown.provider == "trae-intl")
        #expect(!unknown.reasoning)
        #expect(unknown.contextWindow == 200_000)
    }
}

// MARK: - Registration

@Suite("Trae registration", .serialized)
struct TraeRegistrationTests {
    @Test("A stored login reads its roster, takes the model's row from it, and asks through the function that lists it")
    func registers() async throws {
        let store = OAuthStore()
        try await store.set(account("registered-user"), for: "trae")
        let gate = DirectoryStub(["solo_work_lite": liteListing])
        let resolved = await registerTrae(
            site: .china,
            manager: OAuthManager(store: store),
            modelOverride: "kimi-k3",
            client: gate
        )
        #expect(resolved.model.id == "kimi-k3")
        #expect(resolved.model.provider == "trae")
        #expect(resolved.model.contextWindow == 204_800)
        #expect(resolved.modelLabel == "kimi-k3 · Trae CN")

        let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
        #expect(auth.token == nil)
        #expect(auth.scheme == .none)
        #expect(auth.headers["Authorization"] == "Cloud-IDE-JWT jwt-1")
        #expect(auth.headers["x-uid"] == "registered-user")
        #expect(auth.onRejected != nil)

        let provider = try #require(
            await APIRegistry.shared.provider(scope: "trae", api: "openai-completions") as? TraeProvider
        )
        // The registered provider asks the gate it was given; a chat names
        // the function the roster listed the model under.
        let chat = StubSSEClient(body: textStream)
        let stream = TraeProvider(site: provider.site, functions: ["kimi-k3": "solo_work_lite"], client: chat)
            .stream(model: resolved.model, context: hello, options: StreamOptions(resolvedAuth: auth))
        _ = await stream.result()
        #expect(try body(chat)["function"] as? String == "solo_work_lite")
        await APIRegistry.shared.unregisterScope("trae")
    }

    @Test("A login that is not the active one registers without asking the gate, on the seed's first model")
    func unprimed() async throws {
        let store = OAuthStore()
        try await store.set(account("idle-user"), for: "trae-intl")
        let gate = DirectoryStub([:])
        let resolved = await registerTrae(
            site: .international,
            manager: OAuthManager(store: store),
            primeToken: false,
            client: gate
        )
        #expect(gate.asked.isEmpty)
        #expect(resolved.model.id == "auto")
        #expect(resolved.model.provider == "trae-intl")
        #expect(resolved.modelLabel == "auto · Trae")
        await APIRegistry.shared.unregisterScope("trae-intl")
    }

    @Test("Both builds are in the directory, the refresh providers and the display names")
    func directory() {
        for (id, name) in [("trae", "Trae CN"), ("trae-intl", "Trae")] {
            #expect(modelProviderScope(forStoreId: id) == id)
            #expect(catalogProvider(forStoreId: id) == id)
            #expect(providerDisplayName(forStoreId: id) == name)
            #expect(ProviderAttribution.getProviderDisplayName(id) == name)
            #expect(OAuthManager.defaultProviders().contains { $0.id == id })
        }
    }
}
