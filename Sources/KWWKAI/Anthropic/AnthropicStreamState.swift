import Foundation
import NIOConcurrencyHelpers

/// Mutable state the Anthropic stream driver mutates while consuming SSE.
final class AnthropicStreamState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?

    var responseId: String?
    var responseModel: String? { didSet { updateCost() } }
    var requestModel: Model?
    var fallbackEnabled = false
    var usage = Usage()
    var stopReason: StopReason = .stop
    var errorMessage: String?
    var failure: ProviderFailure?

    /// Content blocks. For text/thinking we accumulate a running string; for
    /// tool calls we keep an in-progress JSON buffer.
    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String)
        case fallback(AnthropicFallbackContent)
    }
    private struct State {
        var blocks: [Int: Block] = [:]
        var orderedIndices: [Int] = []
        /// The non-empty input a tool_use block's `content_block_start`
        /// carried. Some relays send the whole input there and no delta after;
        /// others send only the first keys there and stream the rest as
        /// input_json_delta, so deltas are still collected and merged at the end.
        var startInputs: [Int: [String: JSONValue]] = [:]
    }
    private let state = NIOLockedValueBox(State())

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func applyMessageStart(_ obj: [String: JSONValue]) {
        if case .string(let id) = obj["id"] ?? .null { responseId = id }
        if case .string(let model) = obj["model"], !model.isEmpty, model != modelId {
            responseModel = model
        }
        if case .object(let u) = obj["usage"] ?? .null { applyUsageDelta(u) }
    }

    func applyUsageDelta(_ obj: [String: JSONValue]) {
        if fallbackEnabled, case .array(let iterations) = obj["iterations"] {
            usage.anthropicIterations = iterations
            for case .object(let iteration) in iterations {
                if iteration["type"] == .string("fallback_message"),
                   case .string(let model) = iteration["model"], !model.isEmpty {
                    responseModel = model
                }
            }
        }
        if case .int(let v) = obj["input_tokens"] ?? .null { usage.input = v }
        if case .int(let v) = obj["output_tokens"] ?? .null { usage.output = v }
        if case .int(let v) = obj["cache_read_input_tokens"] ?? .null { usage.cacheRead = v }
        if case .int(let v) = obj["cache_creation_input_tokens"] ?? .null { usage.cacheWrite = v }
        // pi parity: 1h cache-write subset (message_start) and reasoning tokens
        // (message_delta). Reading both at every usage event is harmless.
        if case .object(let cc) = obj["cache_creation"] ?? .null,
           case .int(let v) = cc["ephemeral_1h_input_tokens"] ?? .null { usage.cacheWrite1h = v }
        if case .object(let d) = obj["output_tokens_details"] ?? .null,
           case .int(let v) = d["thinking_tokens"] ?? .null { usage.reasoning = v }
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
        updateCost()
    }

    private func updateCost() {
        guard let requestModel else { return }
        func pricedModel(_ id: String?) -> Model {
            guard fallbackEnabled, let id, id != requestModel.id else { return requestModel }
            return ModelsCatalog.model(provider: requestModel.behaviorProvider, id: id) ?? requestModel
        }
        guard fallbackEnabled, let iterations = usage.anthropicIterations, !iterations.isEmpty else {
            usage.cost = calculateCost(model: pricedModel(responseModel), usage: usage)
            return
        }
        let entries = iterations.compactMap { value -> [String: JSONValue]? in
            if case .object(let entry) = value { return entry }; return nil
        }
        let hasFallback = entries.contains { $0["type"] == .string("fallback_message") }
        var total = Cost()
        var applied = false
        for entry in entries {
            func count(_ key: String) -> Int {
                if case .int(let value) = entry[key] { return max(0, value) }; return 0
            }
            let input = count("input_tokens"), output = count("output_tokens")
            let cacheWrite = count("cache_creation_input_tokens")
            let isFallback = entry["type"] == .string("fallback_message")
            // Classifier-blocked attempts before any output/cache write are waived.
            if hasFallback && !isFallback && output == 0 && cacheWrite == 0 { continue }
            let attempt = Usage(
                input: isFallback ? 0 : input,
                output: output,
                cacheRead: count("cache_read_input_tokens") + (isFallback ? input : 0),
                cacheWrite: cacheWrite
            )
            let id: String? = { if case .string(let id) = entry["model"] { return id }; return nil }()
            let cost = calculateCost(model: pricedModel(id), usage: attempt)
            total.input += cost.input
            total.output += cost.output
            total.cacheRead += cost.cacheRead
            total.cacheWrite += cost.cacheWrite
            total.total += cost.total
            applied = true
        }
        if applied { usage.cost = total }
    }

    /// SSE indices include ignored protocol blocks; public indices address content.
    func contentIndex(for wireIndex: Int) -> Int {
        state.withLockedValue { state in
            state.orderedIndices.sorted().filter { state.blocks[$0] != nil }.firstIndex(of: wireIndex) ?? 0
        }
    }

    func startBlock(index: Int, type: String, raw: [String: JSONValue]) {
        state.withLockedValue { state in
            if !state.orderedIndices.contains(index) { state.orderedIndices.append(index) }
            switch type {
            case "text": state.blocks[index] = .text(TextContent(text: ""))
            case "thinking": state.blocks[index] = .thinking(ThinkingContent(thinking: ""))
            case "redacted_thinking":
                let data: String = {
                    if case .string(let v) = raw["data"] ?? .null { return v } else { return "" }
                }()
                state.blocks[index] = .thinking(ThinkingContent(
                    thinking: "[Reasoning redacted]",
                    thinkingSignature: data,
                    redacted: true))
            case "tool_use":
                let id: String = {
                    if case .string(let v) = raw["id"] ?? .null { return v } else { return "" }
                }()
                let name: String = {
                    if case .string(let v) = raw["name"] ?? .null { return v } else { return "" }
                }()
                // Anthropic starts a tool_use with `"input": {}` and streams the
                // arguments as input_json_delta. Some Anthropic-shaped relays
                // put input here: all of it with no delta after (magpie
                // c5b57b90), or only its first keys with the rest streamed.
                // Keep it aside; `toolArguments` merges it with the deltas.
                if case .object(let input) = raw["input"] ?? .null, !input.isEmpty {
                    state.startInputs[index] = input
                }
                state.blocks[index] = .toolUse(id: id, name: name, json: "")
            default: break
            }
        }
    }

    func startFallback(index: Int, from: String, to: String) {
        state.withLockedValue { state in
            if !state.orderedIndices.contains(index) { state.orderedIndices.append(index) }
            state.blocks[index] = .fallback(AnthropicFallbackContent(from: from, to: to))
        }
    }

    func appendText(index: Int, text: String) {
        state.withLockedValue { state in
            if case .text(var t) = state.blocks[index] {
                t.text += text
                state.blocks[index] = .text(t)
            }
        }
    }

    func appendThinking(index: Int, text: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] {
                th.thinking += text
                state.blocks[index] = .thinking(th)
            }
        }
    }

    func appendSignature(index: Int, signature: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] {
                th.thinkingSignature = (th.thinkingSignature ?? "") + signature
                state.blocks[index] = .thinking(th)
            }
        }
    }

    func appendToolJSON(index: Int, chunk: String) {
        state.withLockedValue { state in
            if case .toolUse(let id, let name, let json) = state.blocks[index] {
                state.blocks[index] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    /// A finished tool call's arguments. With no input on the block start this
    /// is just the streamed JSON. With one, the streamed JSON may repeat the
    /// whole input, carry only the remaining keys as an object, or continue
    /// the start's object (`,"k":"v"}`); each is merged over the start's keys,
    /// the streamed value winning. Nothing streamed leaves the start's input.
    /// Streamed text that reads as none of these is handed back as unparsed.
    private static func toolArguments(
        json: String,
        start: [String: JSONValue]?
    ) -> (arguments: JSONValue, unparsed: String?) {
        guard let start else { return StreamedToolArguments.decode(json) }
        if let merged = StreamedToolArguments.merging(start: start, streamed: json) {
            return (.object(merged), nil)
        }
        return (.object(start), json)
    }

    enum Finalized { case text(String); case thinking(String); case toolCall(ToolCall); case none }

    func finishBlock(index: Int) -> Finalized {
        state.withLockedValue { state in
            guard let block = state.blocks[index] else { return .none }
            switch block {
            case .fallback: return .none
            case .text(let t): return .text(t.text)
            case .thinking(let th): return .thinking(th.thinking)
            case .toolUse(let id, let name, let json):
                let decoded = Self.toolArguments(json: json, start: state.startInputs[index])
                let call = ToolCall(
                    id: id,
                    name: name,
                    arguments: decoded.arguments,
                    unparsedArguments: decoded.unparsed
                )
                state.blocks[index] = .toolUse(id: id, name: name, json: json)
                return .toolCall(call)
            }
        }
    }

    /// Streaming snapshot. In-progress tool calls are represented with an empty
    /// object rather than re-parsing the (usually incomplete) argument buffer on
    /// every delta — that reparse is O(n) per delta, O(n^2) over a tool call.
    /// The complete arguments are parsed once in `finishBlock`/`finalize`.
    func snapshot() -> AssistantMessage { buildMessage(parseToolArgs: false) }

    private func buildMessage(parseToolArgs: Bool) -> AssistantMessage {
        state.withLockedValue { state in
            var content: [AssistantBlock] = []
            for i in state.orderedIndices.sorted() {
                guard let block = state.blocks[i] else { continue }
                switch block {
                case .fallback(let fallback): content.append(.fallback(fallback))
                case .text(let t): content.append(.text(t))
                case .thinking(let th): content.append(.thinking(th))
                case .toolUse(let id, let name, let json):
                    let decoded: (arguments: JSONValue, unparsed: String?) = parseToolArgs
                        ? Self.toolArguments(json: json, start: state.startInputs[i])
                        : (.object([:]), nil)
                    content.append(.toolCall(ToolCall(
                        id: id,
                        name: name,
                        arguments: decoded.arguments,
                        unparsedArguments: decoded.unparsed
                    )))
                }
            }
            return AssistantMessage(
                content: content,
                api: api,
                provider: provider,
                model: modelId,
                responseId: responseId,
                responseModel: responseModel,
                usage: usage,
                stopReason: stopReason,
                errorMessage: errorMessage,
                failure: failure,
                timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage {
        var m = buildMessage(parseToolArgs: true)
        m.stopReason = stopReason
        return m
    }

    func asError(text: String) -> AssistantMessage {
        errorMessage = text
        stopReason = .error
        return finalize()
    }

    func asAborted() -> AssistantMessage {
        errorMessage = "Request was aborted"
        stopReason = .aborted
        return finalize()
    }
}
