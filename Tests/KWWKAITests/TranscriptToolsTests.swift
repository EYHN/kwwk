import Foundation
import Testing
@testable import KWWKAI

private func tool(_ name: String, _ description: String = "") -> Tool {
    Tool(name: name, description: description.isEmpty ? "\(name) tool" : description, parameters: ["type": "object"])
}

private func declare(added: [Tool] = [], removed: [String] = []) -> Message {
    .system(SystemMessage(toolsAdded: added, toolsRemoved: removed, timestamp: 1))
}

private struct MissingBody: Error {}

private func jsonBody(_ data: Data?) throws -> [String: Any] {
    guard let data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MissingBody()
    }
    return object
}

private func assistant(_ text: String = "ok") -> Message {
    .assistant(AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: "anthropic-messages", provider: "anthropic", model: "claude-test"
    ))
}

@Suite("Transcript tool state")
struct TranscriptToolsTests {
    @Test("replaying declarations yields the current tools in declaration order")
    func replay() {
        let messages: [Message] = [
            declare(added: [tool("read"), tool("bash")]),
            .user(UserMessage(text: "hi")),
            assistant(),
            declare(added: [tool("mcp__gh__search")], removed: ["bash"]),
            declare(added: [tool("read", "new read")]),
        ]
        #expect(TranscriptTools.currentTools(in: messages).map(\.name) == ["mcp__gh__search", "read"])
        #expect(TranscriptTools.currentTools(in: messages).last?.description == "new read")
        #expect(TranscriptTools.initialTools(in: messages).map(\.name) == ["read", "bash"])
        #expect(TranscriptTools.hasNonAdditiveChanges(in: messages))
    }

    @Test("changes report additions, redefinitions and removals")
    func changes() {
        let changes = TranscriptTools.changes(
            from: [tool("a"), tool("b"), tool("c")],
            to: [tool("a"), tool("b", "changed"), tool("d")]
        )
        #expect(changes.toolsAdded.map(\.name) == ["b", "d"])
        #expect(changes.toolsRemoved == ["c"])
        #expect(TranscriptTools.changes(from: [tool("a")], to: [tool("a")]).isEmpty)
    }

    @Test("the initial declaration may follow a compaction recap but not an answer")
    func initialDeclaration() {
        let recap = Message.user(UserMessage(text: "recap"))
        #expect(TranscriptTools.initialDeclarationIndex(in: [recap, declare(added: [tool("a")])]) == 1)
        #expect(TranscriptTools.initialDeclarationIndex(in: [recap, assistant(), declare(added: [tool("a")])]) == nil)
        var failed = AssistantMessage(content: [], api: "x", provider: "x", model: "x", stopReason: .error)
        failed.errorMessage = "boom"
        #expect(TranscriptTools.initialDeclarationIndex(in: [.assistant(failed), declare(added: [tool("a")])]) == 1)
    }

    @Test("resolve anchors only consistent transcripts")
    func resolve() {
        let base: [Message] = [declare(added: [tool("a")]), .user(UserMessage(text: "hi")), assistant()]
        let added = base + [declare(added: [tool("b")])]
        let anchored = TranscriptTools.resolve(
            messages: added, tools: [tool("a"), tool("b")], supportsChanges: true, allowsNonAdditive: false
        )
        #expect(anchored.anchorsChanges)
        #expect(anchored.requestTools.map(\.name) == ["a"])

        // A narrowed request (forced final turn) sends exactly what it asked for.
        let narrowed = TranscriptTools.resolve(
            messages: added, tools: [tool("a")], supportsChanges: true, allowsNonAdditive: false
        )
        #expect(!narrowed.anchorsChanges)
        #expect(narrowed.requestTools.map(\.name) == ["a"])

        // Addition-only transports fall back once a tool was removed.
        let removed = added + [declare(removed: ["a"])]
        #expect(!TranscriptTools.resolve(
            messages: removed, tools: [tool("b")], supportsChanges: true, allowsNonAdditive: false
        ).anchorsChanges)
        #expect(TranscriptTools.resolve(
            messages: removed, tools: [tool("b")], supportsChanges: true, allowsNonAdditive: true
        ).anchorsChanges)

        #expect(!TranscriptTools.resolve(
            messages: added, tools: [tool("a"), tool("b")], supportsChanges: false, allowsNonAdditive: true
        ).anchorsChanges)
    }

    @Test("system messages round-trip through Codable")
    func codable() throws {
        let message = declare(added: [tool("a")], removed: ["b"])
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(Message.self, from: data) == message)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["role"] as? String == "system")
    }
}

@Suite("Provider tool-change encoding")
struct ProviderToolChangeEncodingTests {
    private static let sse = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":5,"output_tokens":0}}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private static let transcript: [Message] = [
        declare(added: [tool("read")]),
        .user(UserMessage(text: "find issues")),
        .assistant(AssistantMessage(
            content: [.toolCall(ToolCall(id: "toolu_1", name: "tool_search", arguments: ["query": "issues"]))],
            api: "anthropic-messages", provider: "anthropic", model: "claude-test", stopReason: .toolUse
        )),
        .toolResult(ToolResultMessage(toolCallId: "toolu_1", toolName: "tool_search", content: [.text(TextContent(text: "Loaded 1 tool"))])),
        declare(added: [tool("mcp__gh__issues")]),
    ]

    private func anthropicModel(native: Bool) -> Model {
        var model = AnthropicProviderTests.sampleModel
        if native {
            var compat = ModelCompat()
            compat.supportsMidConvoSystemMessages = true
            compat.supportsMidConvoToolChanges = true
            model.compat = compat
        }
        return model
    }

    private func anthropicRequest(native: Bool) async throws -> (body: [String: Any], beta: String) {
        let client = StubSSEClient(body: Self.sse)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        _ = await provider.stream(
            model: anthropicModel(native: native),
            context: Context(messages: Self.transcript, tools: [tool("read"), tool("mcp__gh__issues")]),
            options: nil
        ).result()
        let request = try #require(client.lastRequest)
        let body = try jsonBody(request.body)
        return (body, request.headers["anthropic-beta"] ?? "")
    }

    @Test("Anthropic native: fixed tool list, placeholder, and in-place tool_addition")
    func anthropicNative() async throws {
        let (body, beta) = try await anthropicRequest(native: true)
        #expect(beta.contains("inline-tools-2026-09-15"))
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["read", "__kwwk_deferred_placeholder__"])
        #expect(tools[0]["cache_control"] != nil)
        #expect(tools[1]["defer_loading"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.compactMap { $0["role"] as? String } == ["user", "assistant", "user", "system"])
        let blocks = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(blocks.first?["type"] as? String == "tool_addition")
        let definition = (blocks.first?["tool"] as? [String: Any])?["definition"] as? [String: Any]
        #expect(definition?["name"] as? String == "mcp__gh__issues")
        // The conversation cache breakpoint closes on the tool change.
        #expect(blocks.last?["cache_control"] != nil)
    }

    @Test("Anthropic native: removals become tool_removal blocks")
    func anthropicRemoval() async throws {
        let client = StubSSEClient(body: Self.sse)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test-key")
        let messages = Self.transcript + [declare(removed: ["read"])]
        _ = await provider.stream(
            model: anthropicModel(native: true),
            context: Context(messages: messages, tools: [tool("mcp__gh__issues")]),
            options: nil
        ).result()
        let body = try jsonBody(client.lastRequest?.body)
        let wire = try #require(body["messages"] as? [[String: Any]])
        let blocks = wire.filter { $0["role"] as? String == "system" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
        #expect(blocks.compactMap { $0["type"] as? String } == ["tool_addition", "tool_removal"])
    }

    @Test("Anthropic without native support sends the full current list and no system messages")
    func anthropicFallback() async throws {
        let (body, beta) = try await anthropicRequest(native: false)
        #expect(!beta.contains("inline-tools"))
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["read", "mcp__gh__issues"])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(!messages.contains { $0["role"] as? String == "system" })
    }

    private func responsesInput(compat: ModelCompat?) async throws -> (tools: [String], input: [[String: Any]]) {
        let client = StubSSEClient(body: OpenAIResponsesTests.textSSE)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        var model = OpenAIResponsesTests.model
        model.compat = compat
        let transcript: [Message] = [
            declare(added: [tool("read")]),
            .user(UserMessage(text: "hi")),
            .assistant(AssistantMessage(content: [.text(TextContent(text: "ok"))], api: model.api, provider: model.provider, model: model.id)),
            declare(added: [tool("mcp__gh__issues")]),
        ]
        _ = await provider.stream(
            model: model,
            context: Context(messages: transcript, tools: [tool("read"), tool("mcp__gh__issues")]),
            options: nil
        ).result()
        let body = try jsonBody(client.lastRequest?.body)
        let tools = ((body["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        return (tools, (body["input"] as? [[String: Any]]) ?? [])
    }

    @Test("OpenAI Responses: additional_tools item keeps the top-level list")
    func responsesAdditionalTools() async throws {
        var compat = ModelCompat()
        compat.supportsAdditionalTools = true
        compat.supportsToolSearch = true
        let (tools, input) = try await responsesInput(compat: compat)
        #expect(tools == ["read"])
        let item = try #require(input.last)
        #expect(item["type"] as? String == "additional_tools")
        #expect(((item["tools"] as? [[String: Any]])?.first?["name"]) as? String == "mcp__gh__issues")
    }

    @Test("OpenAI Responses: client tool_search pair when only tool search is supported")
    func responsesToolSearch() async throws {
        var compat = ModelCompat()
        compat.supportsToolSearch = true
        let (tools, input) = try await responsesInput(compat: compat)
        #expect(tools == ["read"])
        let types = input.suffix(2).compactMap { $0["type"] as? String }
        #expect(types == ["tool_search_call", "tool_search_output"])
        #expect(input[input.count - 2]["call_id"] as? String == input[input.count - 1]["call_id"] as? String)
        let loaded = (input.last?["tools"] as? [[String: Any]])?.first
        #expect(loaded?["defer_loading"] as? Bool == true)
    }

    @Test("OpenAI Responses without support sends every tool up front")
    func responsesFallback() async throws {
        let (tools, input) = try await responsesInput(compat: nil)
        #expect(tools == ["read", "mcp__gh__issues"])
        #expect(!input.contains { ["additional_tools", "tool_search_call"].contains($0["type"] as? String ?? "") })
    }

    @Test("Chat Completions drops declarations and sends the full list")
    func completionsFallback() async throws {
        let client = StubSSEClient(body: "data: [DONE]\n\n")
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        _ = await provider.stream(
            model: OpenAICompletionsTests.model,
            context: Context(
                messages: [declare(added: [tool("read")]), .user(UserMessage(text: "hi")), declare(added: [tool("x")])],
                tools: [tool("read"), tool("x")]
            ),
            options: nil
        ).result()
        let body = try jsonBody(client.lastRequest?.body)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.compactMap { $0["role"] as? String } == ["user"])
        #expect((body["tools"] as? [[String: Any]])?.count == 2)
    }
}
