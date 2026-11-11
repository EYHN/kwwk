import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The catalogue below is the shape Raccoon's gate gives since 2026-10-04
// (`model_name`, no `id`), from the captures JanXiao's provider for Apelin
// was written against (owngoal-dev/Apelin#40). The chat itself is standard
// OpenAI over standard SSE.

private func chunk(_ delta: String, finish: String = "null") -> String {
    #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
        + "\n\n"
}

private let textStream = chunk(#"{"role":"assistant","reasoning_content":"Look first."}"#)
    + chunk(#"{"content":"你好"}"#)
    + chunk("{}", finish: #""stop""#)
    + "data: [DONE]\n\n"

private let credentials = OAuthCredentials(
    access: "access-1",
    refresh: "refresh-1",
    expires: .max,
    extras: ["officeIdentity": .string("org-1")]
)

private let auth = ResolvedProviderAuth(
    token: "access-1",
    scheme: .bearer,
    headers: RaccoonWire.accountHeaders(credentials)
)

private let hello = Context(systemPrompt: "You are kwwk.", messages: [.user(UserMessage(text: "hi"))])

private func body(_ client: StubSSEClient) throws -> [String: Any] {
    let data = try #require(client.lastRequest?.body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Raccoon provider")
struct RaccoonProviderTests {
    @Test("A chat goes to the gate's chat/completions as the account, its office named, and reads back as OpenAI's")
    func chat() async throws {
        let client = StubSSEClient(body: textStream)
        let stream = RaccoonProvider(client: client).stream(
            model: RaccoonModels.model(id: "sn-kimi-k3"),
            context: hello,
            options: StreamOptions(resolvedAuth: auth)
        )
        let result = await stream.result()

        let request = try #require(client.lastRequest)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://xiaohuanxiong.com/api/web/llm/v2/chat/completions")
        #expect(request.headers == [
            "content-type": "application/json",
            "accept": "text/event-stream",
            "Authorization": "Bearer access-1",
            // Without it the gate answers as to an unauthorized caller.
            "X-Org-Code": "org-1",
            "X-Raccoon-Language": "zh",
            "X-Client-Platform": "desktop-windows",
        ])
        let sent = try body(client)
        #expect(sent["model"] as? String == "sn-kimi-k3")
        // No level is named, so the gate keeps its own default.
        #expect(sent["extra_body"] == nil)
        #expect(sent["reasoning_effort"] == nil)

        #expect(result.stopReason == .stop)
        #expect(result.content == [
            .thinking(ThinkingContent(thinking: "Look first.", thinkingSignature: "reasoning_content")),
            .text(TextContent(text: "你好")),
        ])
        #expect(result.provider == "raccoon")
    }

    @Test("The output limit is clamped to what the gate takes, and a level goes inside extra_body")
    func mend() {
        let model = RaccoonModels.model(id: "sn-kimi-k3")
        var root: [String: Any] = [
            "model": "sn-kimi-k3",
            "max_tokens": 100_000,
            "max_completion_tokens": 4096,
            "reasoning_effort": "high",
            "reasoning": ["effort": "high"],
        ]
        RaccoonWire.mend(&root, model: model, options: StreamOptions(reasoning: .high))
        // Above 65,536 the gate answers 400 for the whole turn.
        #expect(root["max_tokens"] as? Int == 65_536)
        #expect(root["max_completion_tokens"] as? Int == 4096)
        // The gate accepts the field and ignores it; at the top level
        // `thinking` is ignored too.
        #expect(root["reasoning_effort"] == nil && root["reasoning"] == nil)
        #expect(root["extra_body"] as? [String: [String: String]] == ["thinking": ["type": "enabled"]])

        var plain: [String: Any] = ["model": "sn-kimi-k3"]
        RaccoonWire.mend(&plain, model: model, options: nil)
        #expect(Set(plain.keys) == ["model"])
    }
}

/// Answers the catalogue once and counts how often it was asked.
private final class CatalogStub: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: String
    private let status: Int
    private(set) var asked: [(url: URL, method: String, headers: [String: String])] = []

    init(_ answer: String, status: Int = 200) {
        self.answer = answer
        self.status = status
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        lock.withLock { asked.append((url, method, headers)) }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        let answer = answer
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(Data(answer.utf8))
            continuation.finish()
        })
    }
}

private let catalogue = #"""
{"code":0,"data":{"categories":[
  {"name":"推荐","models":[
    {"model_name":"sn-sensenova-6-8-flash","display_name":"SenseNova-6.8-Flash","tags":["Vision"],"params":{"context_window":256000,"max_tokens":100000},"billing_multiplier":"x0.00"},
    {"model_name":"sn-glm-5-3","display_name":"GLM-5-3","tags":["reasoning"],"params":{"context_window":"1000000","max_tokens":65536}},
    {"model_name":"raccoon-internal","visible":false},
    {"display_name":"No id"}
  ]},
  {"name":"全部","models":[
    {"model_name":"sn-glm-5-3","display_name":"GLM-5-3 again"},
    {"model_name":"sn-deepseek-v4-1-flash","display_name":"DeepSeek-V4.1-Flash"}
  ]}
]}}
"""#

private func account(_ office: String) -> OAuthCredentials {
    var account = credentials
    account.extras["officeIdentity"] = .string(office)
    return account
}

@Suite("Raccoon models")
struct RaccoonModelsTests {
    @Test("The catalogue's visible models are read by model_name, each once, with what the gate takes of them")
    func catalog() async throws {
        let client = CatalogStub(catalogue)
        let rows = try await RaccoonModels.fetch(credentials: account("catalog-office"), client: client)
        #expect(rows.map(\.id) == ["sn-sensenova-6-8-flash", "sn-glm-5-3", "sn-deepseek-v4-1-flash"])
        #expect(rows.map(\.name) == ["SenseNova-6.8-Flash", "GLM-5-3", "DeepSeek-V4.1-Flash"])
        #expect(rows[0].contextWindow == 256_000)
        // The catalogue names 100,000; the gate refuses anything above 65,536.
        #expect(rows[0].maxTokens == 65_536)
        #expect(rows[1].contextWindow == 1_000_000)
        #expect(rows[2].contextWindow == 200_000)
        // Images go by the tags, and to the one model measured to read them
        // without saying so.
        #expect(rows.map { $0.input.contains(.image) } == [true, false, true])
        #expect(rows.allSatisfy { $0.provider == "raccoon" && $0.api == "openai-completions" && $0.reasoning })

        let request = try #require(client.asked.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://xiaohuanxiong.com/api/web/llm/v2/model_catalog")
        #expect(request.headers == [
            "Authorization": "Bearer access-1",
            "X-Org-Code": "catalog-office",
            "X-Raccoon-Language": "zh",
            "X-Client-Platform": "desktop-windows",
            "Content-Type": "application/json",
            "Accept": "application/json",
        ])

        // The same office's catalogue is not asked for again.
        _ = try await RaccoonModels.fetch(credentials: account("catalog-office"), client: client)
        #expect(client.asked.count == 1)
    }

    @Test("A catalogue that cannot be read is no list, and the older field names still read")
    func unreadable() async {
        for client in [CatalogStub("<html>"), CatalogStub(catalogue, status: 500), CatalogStub(#"{"data":{}}"#)] {
            await #expect(throws: ProviderFailure.self) {
                _ = try await RaccoonModels.fetch(credentials: account(UUID().uuidString), client: client)
            }
        }
        let answer = Data(#"""
        {"categories":[{"models":[
          {"id":"old-1","name":"Old One","vision":false,"context_window":32000,"max_output_length":4096},
          {"id":"old-2","input_modalities":["text","image"]}
        ]}]}
        """#.utf8)
        let older = RaccoonModels.rows(in: (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:])
        #expect(older.map(\.id) == ["old-1", "old-2"])
        #expect(older[0].name == "Old One")
        #expect(older[0].contextWindow == 32_000 && older[0].maxTokens == 4096)
        #expect(older.map { $0.input.contains(.image) } == [false, true])
    }

    @Test("The seed stands in before the catalogue has answered, and no level is offered")
    func seed() {
        let rows = ModelsCatalog.models(for: "raccoon")
        #expect(Set(rows.map(\.id)) == Set(RaccoonModels.seedRows.map(\.id)))
        #expect(rows.count == 6)
        let first = RaccoonModels.model(id: RaccoonModels.defaultModelId)
        #expect(first.name == "SenseNova-6.8-Flash")
        #expect(first.maxTokens == 63_999)
        #expect(first.baseURL == "https://xiaohuanxiong.com/api/web/llm/v2/chat/completions")
        // No request made of the gate has named a level, so none goes out.
        #expect(supportedThinkingLevels(first).isEmpty)

        let unknown = RaccoonModels.model(id: "sn-new")
        #expect(unknown.maxTokens == 65_536)
        #expect(unknown.input == [.text])
    }
}

@Suite("Raccoon registration", .serialized)
struct RaccoonRegistrationTests {
    @Test("A stored login reads its catalogue, takes the model's row from it, and signs requests as the office")
    func registers() async throws {
        let store = OAuthStore()
        try await store.set(account("registered-office"), for: "raccoon")
        let resolved = await registerRaccoon(manager: OAuthManager(store: store), client: CatalogStub(catalogue))
        #expect(resolved.model.id == "sn-sensenova-6-8-flash")
        #expect(resolved.model.maxTokens == 65_536)
        #expect(resolved.modelLabel == "SenseNova-6.8-Flash · Raccoon")
        #expect(await APIRegistry.shared.provider(scope: "raccoon", api: "openai-completions") is RaccoonProvider)

        let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
        #expect(auth.token == "access-1")
        #expect(auth.scheme == .bearer)
        #expect(auth.headers == ["X-Org-Code": "registered-office"])
        #expect(auth.onRejected != nil)
        await APIRegistry.shared.unregisterScope("raccoon")
    }

    @Test("A login that is not the active one registers without asking the gate")
    func unprimed() async throws {
        let store = OAuthStore()
        try await store.set(account("idle-office"), for: "raccoon")
        let gate = CatalogStub(catalogue)
        let resolved = await registerRaccoon(
            manager: OAuthManager(store: store),
            modelOverride: "sn-glm-5-3",
            primeToken: false,
            client: gate
        )
        #expect(gate.asked.isEmpty)
        #expect(resolved.model.name == "GLM-5-3")
        await APIRegistry.shared.unregisterScope("raccoon")
    }

    @Test("Raccoon is in the directory, the refresh providers and the display names")
    func directory() {
        #expect(modelProviderScope(forStoreId: "raccoon") == "raccoon")
        #expect(catalogProvider(forStoreId: "raccoon") == "raccoon")
        #expect(providerDisplayName(forStoreId: "raccoon") == "Raccoon")
        #expect(ProviderAttribution.getProviderDisplayName("raccoon") == "Raccoon")
        #expect(OAuthManager.defaultProviders().contains { $0.id == "raccoon" })
    }
}
