import Foundation
import Testing
@testable import KWWKAI

@Suite("Anthropic server-side fallback")
struct AnthropicFallbackTests {
    @Test func nativeCompactionPreservesFallbackHistoryAndBeta() async throws {
        let client = StubSSEClient(body: #"{"stop_reason":"compaction","content":[{"type":"compaction","content":"summary"}]}"#)
        let history = AssistantMessage(content: [
            .fallback(AnthropicFallbackContent(from: "claude-fable-5", to: "claude-opus-4-8")),
            .thinking(ThinkingContent(thinking: "reasoning", thinkingSignature: "opus-sig")),
            .text(TextContent(text: "done")),
        ], api: "anthropic-messages", provider: "anthropic", model: "claude-fable-5", responseModel: "claude-opus-4-8")
        _ = try await AnthropicProvider(client: client).compact(model: model(), context: Context(messages: [.assistant(history)]), instructions: "summarize", options: nil)
        let request = try #require(client.lastRequest)
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["fallback", "thinking", "text"])
        #expect(content[1]["signature"] as? String == "opus-sig")
        #expect(body["fallbacks"] != nil)
        #expect(request.headers["anthropic-beta"]?.contains("server-side-fallback-2026-06-01") == true)
        #expect(request.headers["anthropic-beta"]?.contains("compact-2026-01-12") == true)
    }
    private func model(_ id: String = "claude-fable-5") -> Model {
        var model = AnthropicProviderTests.sampleModel
        model.id = id
        return model
    }

    private func sse(_ events: [String]) -> String {
        events.map { "data: \($0)\n\n" }.joined()
    }

    private let start = #"{"type":"message_start","message":{"id":"msg_fallback","model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":0}}}"#
    private let handoff = #"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-fable-5"},"to":{"model":"claude-opus-4-8"}}}"#
    private let text = #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#
    private let delta = #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hello"}}"#
    private let stop = #"{"type":"message_stop"}"#

    @Test(arguments: ["claude-fable-5", "claude-fable-5-1"])
    func requestOptsIntoFallback(_ id: String) async throws {
        let client = StubSSEClient(body: sse([start, stop]))
        _ = await AnthropicProvider(client: client).stream(model: model(id), context: Context(), options: nil).result()
        let request = try #require(client.lastRequest)
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((body["fallbacks"] as? [[String: String]]) == [["model": "claude-opus-4-8"]])
        #expect(request.headers["anthropic-beta"]?.contains("server-side-fallback-2026-06-01") == true)
    }

    @Test func doesNotEnableOnOtherRoutesOrOptOut() async throws {
        for variant in 0..<5 {
            var selected = model()
            var options = StreamOptions()
            if variant == 0 { selected.baseURL = "https://proxy.example.com" }
            if variant == 1 { selected.provider = "github-copilot" }
            if variant == 2 { selected.id = "claude-opus-4-8" }
            if variant == 3 { options.anthropicServerSideFallback = false }
            if variant == 4 { selected.baseURL = "https://api.anthropic.com.evil.example" }
            let client = StubSSEClient(body: sse([start, stop]))
            _ = await AnthropicProvider(client: client).stream(model: selected, context: Context(), options: options).result()
            let request = try #require(client.lastRequest)
            let data = try #require(request.body)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["fallbacks"] == nil)
            #expect(request.headers["anthropic-beta"]?.contains("server-side-fallback") != true)
        }
    }

    @Test func handoffTracksModelAndUsesDenseContentIndices() async throws {
        let client = StubSSEClient(body: sse([
            start, handoff, #"{"type":"content_block_stop","index":0}"#, text, delta,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#, stop,
        ]))
        let stream = AnthropicProvider(client: client).stream(model: model(), context: Context(), options: nil)
        var indices: [Int] = []
        for await event in stream {
            switch event {
            case .textStart(let index, _), .textDelta(let index, _, _), .textEnd(let index, _, _):
                indices.append(index)
            default: break
            }
        }
        let result = await stream.result()
        #expect(indices == [1, 1, 1])
        #expect(result.model == "claude-fable-5")
        #expect(result.responseModel == "claude-opus-4-8")
        #expect(result.content == [.fallback(AnthropicFallbackContent(from: "claude-fable-5", to: "claude-opus-4-8")), .text(TextContent(text: "hello"))])
        #expect(result.stopReason == .stop)
        let served = try #require(ModelsCatalog.model(provider: "anthropic", id: "claude-opus-4-8"))
        #expect(result.usage.cost == calculateCost(model: served, usage: result.usage))
        let restored = try JSONDecoder().decode(AssistantMessage.self, from: JSONEncoder().encode(result))
        #expect(restored.responseModel == result.responseModel)
    }

    @Test func midOutputFallbackPreservesBoundaryAndContinues() async {
        let client = StubSSEClient(body: sse([start, text, delta,
            handoff.replacingOccurrences(of: "\"index\":0", with: "\"index\":2"),
            text.replacingOccurrences(of: "\"index\":1", with: "\"index\":3"),
            delta.replacingOccurrences(of: "\"index\":1", with: "\"index\":3"), stop]))
        let result = await AnthropicProvider(client: client).stream(model: model(), context: Context(), options: nil).result()
        #expect(result.stopReason == .stop)
        #expect(result.content == [.text(TextContent(text: "hello")),
                                  .fallback(AnthropicFallbackContent(from: "claude-fable-5", to: "claude-opus-4-8")),
                                  .text(TextContent(text: "hello"))])
    }

    @Test func usageFallbackSignalAndResponseModelAreRecorded() async {
        let client = StubSSEClient(body: sse([
            start, text, delta,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2,"iterations":[{"type":"message","model":"claude-fable-5-20260101"},{"type":"fallback_message","model":"claude-opus-4-8"}]}}"#,
            stop,
        ]))
        let result = await AnthropicProvider(client: client).stream(model: model(), context: Context(), options: nil).result()
        #expect(result.responseModel == "claude-opus-4-8")
    }

    @Test func fallbackThinkingIsNotReplayedAsFableThinking() {
        let message = AssistantMessage(content: [.thinking(ThinkingContent(thinking: "reasoning", thinkingSignature: "opus-signature"))],
                                       api: "anthropic-messages", provider: "anthropic", model: "claude-fable-5",
                                       responseModel: "claude-opus-4-8")
        let result = TransformMessages.stripCrossModelThinking([.assistant(message)], model: model())
        guard case .assistant(let replay) = result.first else { Issue.record("Missing assistant"); return }
        #expect(replay.content == [.text(TextContent(text: "reasoning"))])
    }

    @Test func oauthPreservesBetasAndHonorsTopLevelServedModel() async throws {
        let client = StubSSEClient(body: sse([
            start.replacingOccurrences(of: "claude-fable-5", with: "claude-opus-4-8"), stop,
        ]))
        let provider = ProviderVariants.anthropicOAuth(client: client)
        let result = await provider.stream(model: model("claude-fable-5-1"), context: Context(),
                                          options: StreamOptions(headers: ["Anthropic-Beta": "custom-beta"])).result()
        #expect(result.responseModel == "claude-opus-4-8")
        let headers = try #require(client.lastRequest?.headers)
        #expect(headers.keys.filter { $0.lowercased() == "anthropic-beta" }.count == 1)
        for beta in ["custom-beta", "oauth-2025-04-20", "claude-code-20250219", "server-side-fallback-2026-06-01"] {
            #expect(headers["anthropic-beta"]?.contains(beta) == true)
        }
    }

    @Test func nextRequestReplaysPersistedBoundaryAndBothSignatures() async throws {
        let client = StubSSEClient(body: sse([
            start,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"fable-signature"}}"#,
            handoff.replacingOccurrences(of: "\"index\":0", with: "\"index\":1"),
            #"{"type":"content_block_start","index":2,"content_block":{"type":"thinking"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"signature_delta","signature":"opus-signature"}}"#,
            stop,
        ]))
        let first = await AnthropicProvider(client: client).stream(model: model(), context: Context(), options: nil).result()
        let restored = try JSONDecoder().decode(AssistantMessage.self, from: JSONEncoder().encode(first))
        #expect(restored == first)
        for variant in 0..<4 {
            var selected = model()
            var options = StreamOptions()
            if variant == 1 { options.anthropicServerSideFallback = false }
            if variant == 2 { selected.baseURL = "https://proxy.example.com" }
            if variant == 3 { selected.provider = "other" }
            // Sticky-routed follow-up has no new handoff block.
            let nextClient = StubSSEClient(body: sse([
                start.replacingOccurrences(of: "claude-fable-5", with: "claude-opus-4-8"),
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"iterations":[{"type":"fallback_message","model":"claude-opus-4-8","input_tokens":10,"output_tokens":2}]}}"#,
                stop,
            ]))
            let second = await AnthropicProvider(client: nextClient).stream(
                model: selected, context: Context(messages: [.assistant(restored), .user(UserMessage(text: "continue"))]), options: options
            ).result()
            let data = try #require(nextClient.lastRequest?.body)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let content = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            if variant == 0 {
                #expect(second.responseModel == "claude-opus-4-8")
                #expect(second.content.isEmpty)
                #expect(second.usage.anthropicIterations?.count == 1)
                #expect(body["model"] as? String == "claude-fable-5")
                #expect(content.compactMap { $0["type"] as? String } == ["thinking", "fallback", "thinking", "text"])
                #expect(content[0]["signature"] as? String == "fable-signature")
                #expect(content[2]["signature"] as? String == "opus-signature")
                #expect((content[1]["to"] as? [String: String])?["model"] == "claude-opus-4-8")
                #expect(content[1]["cache_control"] == nil)
            } else {
                #expect(!content.contains { $0["type"] as? String == "fallback" })
                #expect(!content.contains { $0["type"] as? String == "thinking" })
            }
        }
    }

    @Test func replayMovesToolsAfterBoundaryWithoutLosingTheirResults() async throws {
        let marker = AnthropicFallbackContent(from: "claude-fable-5", to: "claude-opus-4-8")
        let calls = [ToolCall(id: "before", name: "noop", arguments: .object([:])),
                     ToolCall(id: "after", name: "noop", arguments: .object([:]))]
        let assistant = AssistantMessage(content: [.toolCall(calls[0]), .fallback(marker), .text(TextContent(text: "continued")), .toolCall(calls[1])],
                                         api: "anthropic-messages", provider: "anthropic", model: "claude-fable-5", responseModel: "claude-opus-4-8", stopReason: .toolUse)
        let history: [Message] = [.assistant(assistant)] + calls.map {
            .toolResult(ToolResultMessage(toolCallId: $0.id, toolName: $0.name, content: [.text(TextContent(text: "ok"))]))
        }
        let client = StubSSEClient(body: sse([start, stop]))
        _ = await AnthropicProvider(client: client).stream(model: model(), context: Context(messages: history), options: nil).result()
        let data = try #require(client.lastRequest?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let blocks = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(blocks.compactMap { $0["type"] as? String } == ["fallback", "text", "tool_use", "tool_use"])
        #expect(blocks.compactMap { $0["id"] as? String } == ["before", "after"])
        let results = messages.dropFirst().flatMap { $0["content"] as? [[String: Any]] ?? [] }
        #expect(results.compactMap { $0["tool_use_id"] as? String } == ["before", "after"])
    }

    @Test(arguments: [0, 7])
    func iterationBillingWaivesBlockedAttemptsAndCreditsFallbackInput(_ primaryOutput: Int) throws {
        let primary = try #require(ModelsCatalog.model(provider: "anthropic", id: "claude-fable-5"))
        let opus = try #require(ModelsCatalog.model(provider: "anthropic", id: "claude-opus-4-8"))
        let state = AnthropicStreamState(api: primary.api, provider: primary.provider, modelId: primary.id)
        state.requestModel = primary
        state.fallbackEnabled = true
        let raw = """
        {"input_tokens":200,"output_tokens":\(primaryOutput + 10),"iterations":[
          {"type":"message","model":"claude-fable-5","input_tokens":100,"output_tokens":\(primaryOutput)},
          {"type":"fallback_message","model":"claude-opus-4-8","input_tokens":100,"output_tokens":10,"cache_read_input_tokens":20}
        ]}
        """
        guard case .object(let payload) = parseJSONObject(raw) else { Issue.record("Bad fixture"); return }
        state.applyUsageDelta(payload)
        let expectedPrimary = primaryOutput == 0 ? Cost() : calculateCost(model: primary, usage: Usage(input: 100, output: primaryOutput))
        let expectedFallback = calculateCost(model: opus, usage: Usage(output: 10, cacheRead: 120))
        #expect(state.usage.cost.total == expectedPrimary.total + expectedFallback.total)
        #expect(state.usage.cost.input == expectedPrimary.input)
        #expect(state.usage.cost.cacheRead == expectedFallback.cacheRead)
        #expect(state.usage.input == 200)
        #expect(state.responseModel == opus.id)
        #expect(state.finalize().usage.anthropicIterations?.count == 2)
    }
}
