import Foundation
import Testing
@testable import KWWKAI

@Suite("Google Gemini provider")
struct GoogleGeminiTests {
    static let model = Model(
        id: "gemini-2.5-flash",
        name: "Gemini 2.5 Flash",
        api: "google-generative-ai",
        provider: "google",
        baseUrl: "https://generativelanguage.googleapis.com",
        reasoning: false,
        input: [.text, .image],
        contextWindow: 1_000_000,
        maxTokens: 8192
    )

    static let textSSE = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]},"index":0}]}

    data: {"candidates":[{"content":{"role":"model","parts":[{"text":", world"}]},"index":0}]}

    data: {"candidates":[{"content":{"role":"model","parts":[]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":3,"totalTokenCount":8}}

    """

    static let toolUseSSE = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"calc","args":{"a":1,"b":2}}}]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"totalTokenCount":15}}

    """

    static let missingArgsSSE = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_status"}}]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"totalTokenCount":15}}

    """

    static let thoughtSSE = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"ponder…","thought":true}]},"index":0}]}

    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"answer"}]},"index":0}]}

    data: {"candidates":[{"content":{"role":"model","parts":[]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":3,"totalTokenCount":8}}

    """

    @Test("streams text across two parts and reports usage")
    func basicText() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "test-key")
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

    @Test("emits a single toolcall block with parsed args")
    func toolUse() async throws {
        let client = StubSSEClient(body: Self.toolUseSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "calc"))]),
            options: nil
        )
        var seenEnd = false
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event {
                #expect(call.name == "calc")
                #expect(call.arguments == .object(["a": 1, "b": 2]))
                seenEnd = true
            }
        }
        let result = await s.result()
        #expect(seenEnd)
        #expect(result.stopReason == .toolUse)
    }

    /// Ported from pi-mono/google-tool-call-missing-args.test.ts: some
    /// Gemini responses omit `args` when the tool takes no arguments.
    @Test("defaults arguments to {} when the args field is missing")
    func missingArgs() async throws {
        let client = StubSSEClient(body: Self.missingArgsSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(
                messages: [.user(UserMessage(text: "status"))],
                tools: [Tool(name: "get_status", description: "n", parameters: ["type": "object"])]
            ),
            options: nil
        )
        for await _ in s {}
        let result = await s.result()
        #expect(result.stopReason == .toolUse)
        #expect(result.content.count == 1)
        if case .toolCall(let tc) = result.content.first {
            #expect(tc.name == "get_status")
            #expect(tc.arguments == .object([:]))
        } else { Issue.record("expected a single tool call") }
    }

    @Test("parts with thought=true become thinking blocks")
    func thoughtFlag() async throws {
        let client = StubSSEClient(body: Self.thoughtSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .medium)
        )
        for await _ in s {}
        let result = await s.result()
        #expect(result.content.count == 2)
        if case .thinking(let th) = result.content.first {
            #expect(th.thinking == "ponder…")
        } else { Issue.record("expected thinking first") }
        if case .text(let t) = result.content.last {
            #expect(t.text == "answer")
        } else { Issue.record("expected text after thinking") }
    }

    @Test("puts the api key in the URL query string (not Authorization)")
    func apiKeyInURL() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "default-key")
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(apiKey: "override-key")
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.lastRequest?.url.absoluteString.contains("key=override-key") == true)
        #expect(client.lastRequest?.headers["authorization"] == nil)
    }

    @Test("resolved auth query key controls URL auth")
    func resolvedAuthQueryKey() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "default-key")
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                apiKey: "ignored-key",
                resolvedAuth: ResolvedProviderAuth(token: "resolved-key", scheme: .queryKey(name: "key"))
            )
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.lastRequest?.url.absoluteString.contains("key=resolved-key") == true)
        #expect(client.lastRequest?.url.absoluteString.contains("ignored-key") == false)
        #expect(client.lastRequest?.headers["authorization"] == nil)
    }

    @Test("resolved auth ignores mismatched query key names")
    func resolvedAuthMismatchedQueryKeyName() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "default-key")
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                resolvedAuth: ResolvedProviderAuth(token: "resolved-key", scheme: .queryKey(name: "api_key"))
            )
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.lastRequest?.url.absoluteString.contains("resolved-key") == false)
        #expect(client.lastRequest?.headers["authorization"] == nil)
    }

    @Test("encodes tools as functionDeclarations + systemInstruction")
    func bodyEncoding() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(
            model: Self.model,
            context: Context(
                systemPrompt: "Be concise.",
                messages: [.user(UserMessage(text: "hi"))],
                tools: [Tool(
                    name: "calc", description: "arith",
                    parameters: ["type": "object", "properties": ["a": ["type": "number"]]]
                )]
            ),
            options: StreamOptions(toolChoice: .required)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body = client.lastRequest?.body ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let sysInstr = json?["systemInstruction"] as? [String: Any]
        let parts = sysInstr?["parts"] as? [[String: Any]]
        #expect(parts?.first?["text"] as? String == "Be concise.")
        let tools = json?["tools"] as? [[String: Any]]
        let decls = tools?.first?["functionDeclarations"] as? [[String: Any]]
        #expect(decls?.first?["name"] as? String == "calc")
        let config = json?["toolConfig"] as? [String: Any]
        let inner = config?["functionCallingConfig"] as? [String: Any]
        #expect(inner?["mode"] as? String == "ANY")
    }
}
