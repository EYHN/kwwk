import Foundation
import Testing
@testable import KWWKAI

/// Vendor behaviour measured against live subscriptions on 2026-10-10, after
/// reading how magpie handles each.
@Suite("Provider pitfalls measured live")
struct ProviderPitfallTests {
    private func claude(_ id: String) -> Model {
        var model = AnthropicProviderTests.sampleModel
        model.id = id
        return model
    }

    @Test("A forced tool choice becomes auto for the Claude models that refuse one", arguments: [
        ("claude-opus-5-5", true), ("claude-sonnet-5-5", true), ("claude-fable-5-1", true),
        ("anthropic/claude-opus-5.5", true), ("claude-opus-6-1", true),
        ("claude-opus-5", false), ("claude-sonnet-5", false), ("claude-fable-5", false),
        ("claude-opus-4-8", false), ("claude-sonnet-4-5", false), ("claude-haiku-4-5", false),
        ("claude-opus-5-20260915", false), ("k3", false),
    ])
    func forcedToolChoice(id: String, refused: Bool) {
        #expect(AnthropicProvider.refusesForcedToolChoice(id) == refused)
        let forced = StreamOptions(toolChoice: .tool(name: "yield"), parallelToolCalls: false)
        let choice = AnthropicProvider.buildToolChoice(forced, model: claude(id))
        #expect(choice?["type"] as? String == (refused ? "auto" : "tool"))
        #expect(choice?["name"] as? String == (refused ? nil : "yield"))
        #expect(choice?["disable_parallel_tool_use"] as? Bool == true)
        let any = AnthropicProvider.buildToolChoice(StreamOptions(toolChoice: .required), model: claude(id))
        #expect(any?["type"] as? String == (refused ? "auto" : "any"))
    }

    @Test("A union at a tool schema's root is folded into a plain object")
    func rootUnionFolded() {
        let anyOf: JSONValue = [
            "type": "object",
            "properties": ["a": ["type": "string"], "b": ["type": "string"]],
            "anyOf": [["required": ["a"]], ["required": ["b"]]],
        ]
        let folded = AnthropicProvider.encodeTool(
            Tool(name: "t", description: "t", parameters: anyOf), supportsEager: false
        )["input_schema"] as? [String: Any]
        #expect(folded?["anyOf"] == nil)
        #expect(folded?["type"] as? String == "object")
        #expect((folded?["properties"] as? [String: Any])?.keys.sorted() == ["a", "b"])
        #expect(folded?["required"] == nil)

        let oneOf: JSONValue = [
            "oneOf": [
                ["type": "object", "properties": ["kind": ["const": "x"], "a": ["type": "string"]], "required": ["kind", "a"]],
                ["$ref": "#/$defs/B"],
            ],
            "$defs": ["B": ["type": "object", "properties": ["kind": ["const": "y"], "b": ["type": "number"]], "required": ["kind"]]],
        ]
        guard case .object(let root) = ToolSchemaRoot.objectRoot(oneOf),
              case .object(let properties)? = root["properties"] else {
            Issue.record("not an object"); return
        }
        #expect(root["oneOf"] == nil)
        #expect(root["type"] == .string("object"))
        #expect(properties.keys.sorted() == ["a", "b", "kind"])
        #expect(root["required"] == .array([.string("kind")]))

        let allOf: JSONValue = [
            "type": "object", "properties": ["a": ["type": "string"]], "required": ["a"],
            "allOf": [["properties": ["b": ["type": "string"]], "required": ["b"]]],
        ]
        guard case .object(let merged) = ToolSchemaRoot.objectRoot(allOf) else { Issue.record("not an object"); return }
        #expect(merged["required"] == .array([.string("a"), .string("b")]))

        // A union below the root is accepted and stays as written.
        let nested: JSONValue = ["type": "object", "properties": ["a": ["anyOf": [["type": "string"], ["type": "number"]]]]]
        #expect(ToolSchemaRoot.objectRoot(nested) == nested)
    }

    @Test("Tool-call ids Anthropic would refuse reach it rewritten, the call and its result alike")
    func anthropicSafeIds() {
        let devin = "Bash:0#a65b6a5e02194b87bbc796c4428c946d"
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: devin, name: "bash", arguments: [:]))],
            api: "devin-agent", provider: "devin", model: "swe-2", stopReason: .toolUse
        )
        let history: [Message] = [
            .assistant(assistant),
            .toolResult(ToolResultMessage(toolCallId: devin, toolName: "bash", content: [.text(TextContent(text: "ok"))])),
        ]
        let out = TransformMessages.normalizeToolCallIds(history, model: claude("claude-sonnet-5-5"))
        guard case .assistant(let a) = out[0], case .toolCall(let call)? = a.content.first,
              case .toolResult(let result) = out[1] else { Issue.record("shape"); return }
        #expect(call.id.wholeMatch(of: #/[a-zA-Z0-9_-]+/#) != nil)
        #expect(result.toolCallId == call.id)
    }

    @Test("Other vendors' words for a conversation too long", arguments: [
        "Please reduce the length of the messages or completion",
        "Input length 2000 exceeds the maximum allowed input length of 1000 tokens.",
        "The input (2000 tokens) is longer than the model's context length (1000 tokens).",
        "the request exceeds the available context size, try increasing it",
        "tokens to keep from the initial prompt is greater than the context length",
        "prompt token count of 2000 exceeds the limit of 1000",
        "invalid params, context window exceeds limit",
        "Your request exceeded model token limit: 262144 (requested: 300000)",
        "Prompt has 2000 tokens, but the configured context size is 1000 tokens",
        #"{"code":"1261","message":"Prompt exceeds max length"}"#,
        "prompt too long; exceeded max context length by 100 tokens",
        "Range of input length should be [1, 98304]",
        "Input exceeds the context limit",
        "输入内容超过模型最大上下文长度",
    ])
    func overflowWordings(text: String) {
        #expect(ProviderContextLimit.isInputOverflow(text))
        #expect(ProviderFailure(message: text, httpStatus: 400).category == .contextOverflow)
    }

    @Test("A rate limit worded with tokens is not a conversation too long")
    func rateLimitIsNotOverflow() {
        #expect(!ProviderContextLimit.isInputOverflow("Too many tokens per minute, please wait before trying again."))
    }

    @Test("Out of credit is quota, whatever status carries it")
    func outOfCredit() {
        let anthropic = #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}"#
        #expect(ProviderFailure(message: anthropic, httpStatus: 400).category == .quota)
        #expect(ProviderFailure(message: "billing_address: field required", httpStatus: 400).category == .invalidRequest)
        for body in [
            #"{"error":{"code":"1113","message":"余额不足或无可用资源包,请充值。"}}"#,
            #"{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}"#,
        ] {
            let failure = ProviderFailure(message: body, httpStatus: 429)
            #expect(failure.category == .quota)
            #expect(!failure.isRetryable)
        }
        #expect(ProviderFailure(message: "Too many requests", httpStatus: 429).category == .rateLimit)
    }

    @Test("Devin never gets a temperature of exactly 0")
    func devinTemperature() {
        func temperature(_ requested: Double?) -> Double {
            DevinAgentProvider.buildChatRequest(
                model: Model(id: "swe-2", api: "devin-agent", provider: "devin"),
                context: Context(messages: []), messages: [],
                options: StreamOptions(temperature: requested),
                apiKey: "k", userJwt: "j", cascadeId: "c", assignment: nil
            ).configuration.temperature
        }
        #expect(temperature(0) == 1e-6)
        #expect(temperature(0.7) == 0.7)
        #expect(temperature(nil) == 0.4)
    }

    @Test("Moonshot's top-level cached_tokens counts as cache read")
    func moonshotCachedTokens() async {
        let sse = """
        data: {"id":"c","choices":[{"index":0,"delta":{"content":"hi"}}]}

        data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":20,"cached_tokens":30}}

        data: [DONE]

        """
        let provider = OpenAICompletionsProvider(client: StubSSEClient(body: sse), defaultAPIKey: "sk-test")
        let result = await provider.stream(
            model: OpenAICompletionsTests.model,
            context: Context(messages: [.user(UserMessage(text: "x"))]), options: nil
        ).result()
        #expect(result.usage.cacheRead == 30)
        #expect(result.usage.input == 70)
    }
}
