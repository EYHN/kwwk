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

    // MARK: - helpers

    static let usageSSE = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"hi"}]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":40,"candidatesTokenCount":20,"thoughtsTokenCount":15,"totalTokenCount":135}}

    """

    static func reasoningModel(_ id: String) -> Model {
        Model(id: id, name: id, api: "google-generative-ai", provider: "google",
              baseUrl: "https://generativelanguage.googleapis.com", reasoning: true,
              input: [.text, .image], contextWindow: 1_000_000, maxTokens: 8192)
    }

    static func encodedBody(model: Model, context: Context, options: StreamOptions?) async throws -> [String: Any] {
        let client = StubSSEClient(body: Self.textSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k")
        _ = provider.stream(model: model, context: context, options: options)
        try? await Task.sleep(nanoseconds: 30_000_000)
        return try JSONSerialization.jsonObject(with: client.lastRequest!.body!) as! [String: Any]
    }

    // MARK: - Feature 1: default thinking budgets

    @Test("2.5-pro emits per-level default thinkingBudget when no custom table")
    func defaultBudget25Pro() async throws {
        let json = try await Self.encodedBody(
            model: Self.reasoningModel("gemini-2.5-pro"),
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .high))
        let thinking = (json["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["thinkingBudget"] as? Int == 32768)
        #expect(thinking?["includeThoughts"] as? Bool == true)
    }

    @Test("non-2.5 reasoning model falls back to dynamic budget -1")
    func dynamicBudgetFallback() async throws {
        let json = try await Self.encodedBody(
            model: Self.reasoningModel("gemini-2.0-flash-thinking"),
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .low))
        let thinking = (json["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["thinkingBudget"] as? Int == -1)
    }

    @Test("custom thinkingBudgets table wins over defaults")
    func customBudgetWins() async throws {
        let json = try await Self.encodedBody(
            model: Self.reasoningModel("gemini-2.5-pro"),
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(reasoning: .high, thinkingBudgets: ThinkingBudgets(high: 99)))
        let thinking = (json["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["thinkingBudget"] as? Int == 99)
    }

    // MARK: - Feature 5: disabled thinking config

    @Test("reasoning-off Gemini 2.5 sends thinkingBudget 0")
    func disabledThinking25() async throws {
        let json = try await Self.encodedBody(
            model: Self.reasoningModel("gemini-2.5-flash"),
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions())
        let tc = (json["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(tc?["thinkingBudget"] as? Int == 0)
        #expect(tc?["includeThoughts"] == nil)
    }

    @Test("reasoning-off Gemini 3 Pro pins thinkingLevel LOW")
    func disabledThinking3Pro() async throws {
        let json = try await Self.encodedBody(
            model: Self.reasoningModel("gemini-3-pro"),
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions())
        let tc = (json["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(tc?["thinkingLevel"] as? String == "LOW")
        #expect(tc?["includeThoughts"] == nil)
    }

    // MARK: - Feature 2: thought-signature preservation

    @Test("preserves valid base64 textSignature on replayed same-model text part")
    func replayTextSignature() async throws {
        let model = Self.model
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "prior", textSignature: "YWJjZA=="))],
            api: model.api, provider: model.provider, model: model.id)
        let json = try await Self.encodedBody(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi")), .assistant(assistant),
                                        .user(UserMessage(text: "again"))]),
            options: nil)
        let contents = json["contents"] as? [[String: Any]]
        let modelTurn = contents!.first { ($0["role"] as? String) == "model" }!
        let textPart = (modelTurn["parts"] as? [[String: Any]])!.first { $0["text"] != nil }!
        #expect(textPart["thoughtSignature"] as? String == "YWJjZA==")
    }

    @Test("drops invalid (non-base64) textSignature on replay")
    func dropsInvalidSignature() async throws {
        let model = Self.model
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "prior", textSignature: "not valid sig!!"))],
            api: model.api, provider: model.provider, model: model.id)
        let json = try await Self.encodedBody(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi")), .assistant(assistant),
                                        .user(UserMessage(text: "again"))]),
            options: nil)
        let contents = json["contents"] as? [[String: Any]]
        let modelTurn = contents!.first { ($0["role"] as? String) == "model" }!
        let textPart = (modelTurn["parts"] as? [[String: Any]])!.first { $0["text"] != nil }!
        #expect(textPart["thoughtSignature"] == nil)
    }

    @Test("cross-model assistant text drops signature (downgraded upstream)")
    func crossModelDropsSignature() async throws {
        let model = Self.model
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "prior", textSignature: "YWJjZA=="))],
            api: "openai", provider: "openai", model: "gpt-4")
        let json = try await Self.encodedBody(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi")), .assistant(assistant),
                                        .user(UserMessage(text: "again"))]),
            options: nil)
        let contents = json["contents"] as? [[String: Any]]
        let modelTurn = contents!.first { ($0["role"] as? String) == "model" }!
        let textPart = (modelTurn["parts"] as? [[String: Any]])!.first { $0["text"] != nil }!
        #expect(textPart["thoughtSignature"] == nil)
    }

    // MARK: - Feature 3: function responses

    static func assistantToolCall(model: Model, id: String, name: String) -> AssistantMessage {
        AssistantMessage(
            content: [.toolCall(ToolCall(id: id, name: name, arguments: .object([:])))],
            api: model.api, provider: model.provider, model: model.id, stopReason: .toolUse)
    }

    @Test("tool error uses {error} key and role user, not function")
    func toolErrorResponse() async throws {
        let call = Self.assistantToolCall(model: Self.model, id: "c1", name: "calc")
        let tr = ToolResultMessage(toolCallId: "c1", toolName: "calc",
            content: [.text(TextContent(text: "boom"))], isError: true)
        let json = try await Self.encodedBody(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "x")), .assistant(call), .toolResult(tr)]),
            options: nil)
        let contents = json["contents"] as? [[String: Any]]
        let turn = contents!.last!
        #expect(turn["role"] as? String == "user")
        let fr = ((turn["parts"] as? [[String: Any]])!.first!["functionResponse"]) as? [String: Any]
        let resp = fr?["response"] as? [String: Any]
        #expect(resp?["error"] as? String == "boom")
        #expect(resp?["output"] == nil)
    }

    @Test("consecutive tool results merge into one user turn")
    func mergeToolResults() async throws {
        let calls = AssistantMessage(
            content: [.toolCall(ToolCall(id: "a", name: "f1", arguments: .object([:]))),
                      .toolCall(ToolCall(id: "b", name: "f2", arguments: .object([:])))],
            api: Self.model.api, provider: Self.model.provider, model: Self.model.id, stopReason: .toolUse)
        let t1 = ToolResultMessage(toolCallId: "a", toolName: "f1", content: [.text(TextContent(text: "r1"))])
        let t2 = ToolResultMessage(toolCallId: "b", toolName: "f2", content: [.text(TextContent(text: "r2"))])
        let json = try await Self.encodedBody(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "x")), .assistant(calls), .toolResult(t1), .toolResult(t2)]),
            options: nil)
        let contents = json["contents"] as? [[String: Any]]
        let turn = contents!.last!
        #expect(turn["role"] as? String == "user")
        let parts = turn["parts"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect(parts?.allSatisfy { $0["functionResponse"] != nil } == true)
    }

    @Test("claude- model adds id to functionResponse")
    func toolResultId() async throws {
        let claude = Model(id: "claude-3-5-sonnet", name: "c", api: "google-generative-ai",
                           provider: "google", reasoning: false, input: [.text])
        let call = Self.assistantToolCall(model: claude, id: "call_xyz", name: "f")
        let tr = ToolResultMessage(toolCallId: "call_xyz", toolName: "f",
            content: [.text(TextContent(text: "ok"))])
        let json = try await Self.encodedBody(
            model: claude,
            context: Context(messages: [.user(UserMessage(text: "x")), .assistant(call), .toolResult(tr)]),
            options: nil)
        let contents = json["contents"] as? [[String: Any]]
        let fr = ((contents!.last!["parts"] as? [[String: Any]])!.first!["functionResponse"]) as? [String: Any]
        #expect(fr?["id"] as? String == "call_xyz")
    }

    @Test("Gemini 3 nests tool-result image in functionResponse.parts")
    func toolResultImageMultimodal() async throws {
        let model = Self.reasoningModel("gemini-3-pro")
        let call = Self.assistantToolCall(model: model, id: "a", name: "f")
        let tr = ToolResultMessage(toolCallId: "a", toolName: "f",
            content: [.image(ImageContent(data: "QUJD", mimeType: "image/png"))])
        let json = try await Self.encodedBody(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "x")), .assistant(call), .toolResult(tr)]),
            options: nil)
        let contents = json["contents"] as? [[String: Any]]
        let fr = ((contents!.last!["parts"] as? [[String: Any]])!.first!["functionResponse"]) as? [String: Any]
        let imgParts = fr?["parts"] as? [[String: Any]]
        #expect(imgParts?.count == 1)
        #expect((imgParts?.first?["inlineData"] as? [String: Any])?["data"] as? String == "QUJD")
        let resp = fr?["response"] as? [String: Any]
        #expect(resp?["output"] as? String == "(see attached image)")
    }

    // MARK: - Feature 4: usage accounting

    @Test("usage subtracts cache from input and folds thoughts into output")
    func usageAccounting() async throws {
        let client = StubSSEClient(body: Self.usageSSE)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "k")
        let s = provider.stream(model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]), options: nil)
        for await _ in s {}
        let r = await s.result()
        #expect(r.usage.input == 60)
        #expect(r.usage.output == 35)
        #expect(r.usage.cacheRead == 40)
        #expect(r.usage.reasoning == 15)
        #expect(r.usage.totalTokens == 135)
    }
}
