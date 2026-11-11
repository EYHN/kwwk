import Foundation
import NIOConcurrencyHelpers

/// Mutable state for OpenAI Completions stream. Tracks content block order
/// and incremental tool-call JSON buffers.
final class OpenAICompletionsState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    let model: Model
    var signal: CancellationHandle?

    var responseId: String?
    var usage = Usage()
    var stopReason: StopReason = .stop
    var errorMessage: String?
    var failure: ProviderFailure?

    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String, thoughtSignature: String?)
    }
    private struct State {
        var blocks: [Int: Block] = [:]
        var order: [Int] = []
        var textBlockIndex: Int?
        var thinkingBlockIndex: Int?
        /// Map from OpenAI `tool_calls[i].index` → our content index.
        var toolCallIndexMap: [Int: Int] = [:]
        /// The content index of the call opened last.
        var lastToolCallIndex: Int?
        /// Map from a settled tool-call `id` → our content index. Used to attach
        /// encrypted reasoning details, which arrive keyed by tool-call id.
        var toolCallContentIndexById: [String: Int] = [:]
        /// Reasoning details that arrived before the matching tool-call id settled.
        var pendingReasoningById: [String: String] = [:]
        var endedIndices: Set<Int> = []
    }
    private let state = NIOLockedValueBox(State())

    init(api: String, provider: String, modelId: String, model: Model) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
        self.model = model
    }

    // MARK: Block book-keeping

    func noteTextBlock() -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let idx = state.textBlockIndex { return (idx, false) }
            let idx = state.order.count
            state.textBlockIndex = idx
            state.order.append(idx)
            state.blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock() -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let idx = state.thinkingBlockIndex { return (idx, false) }
            let idx = state.order.count
            state.thinkingBlockIndex = idx
            state.order.append(idx)
            state.blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    /// The content block a tool-call fragment at `rawIndex` belongs to.
    ///
    /// A fragment that names the function starts the next call when it
    /// names an id other than the one the index's open call goes by (magpie
    /// #395, parallel calls all sent at index 0) or a different function;
    /// otherwise it continues the open call.
    ///
    /// A fragment that names no function never starts a call while one is
    /// open: it is more of the call at its index, or, at an index no call
    /// has used, more of the last call. Some relays put a fresh id or index
    /// on each piece of one call's arguments, and read as new calls those
    /// pieces ran as calls of their own, the first with only its first key.
    func noteToolCallBlock(
        at rawIndex: Int,
        id: String? = nil,
        name: String? = nil
    ) -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let idx = state.toolCallIndexMap[rawIndex] {
                guard let name, case .toolUse(let openID, let openName, _, _) = state.blocks[idx] else {
                    return (idx, false)
                }
                let otherID = id.map { !openID.isEmpty && openID != $0 } ?? false
                let otherName = !openName.isEmpty && openName != name
                if !otherID && !otherName { return (idx, false) }
            } else if name == nil, let last = state.lastToolCallIndex {
                state.toolCallIndexMap[rawIndex] = last
                return (last, false)
            }
            let idx = state.order.count
            state.toolCallIndexMap[rawIndex] = idx
            state.lastToolCallIndex = idx
            state.order.append(idx)
            state.blocks[idx] = .toolUse(id: "", name: "", json: "", thoughtSignature: nil)
            return (idx, true)
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

    func setThinkingSignature(index: Int, signature: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index], th.thinkingSignature == nil {
                th.thinkingSignature = signature
                state.blocks[index] = .thinking(th)
            }
        }
    }

    func updateToolCallID(rawIndex: Int, id: String) {
        state.withLockedValue { state in
            guard let contentIndex = state.toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let openID, let name, let json, let sig) = state.blocks[contentIndex] {
                // A piece of this call sent under another id keeps the first.
                guard openID.isEmpty || openID == id else { return }
                var newSig = sig
                if let pending = state.pendingReasoningById.removeValue(forKey: id) { newSig = pending }
                state.blocks[contentIndex] = .toolUse(id: id, name: name, json: json, thoughtSignature: newSig)
            }
            state.toolCallContentIndexById[id] = contentIndex
        }
    }

    func updateToolCallName(rawIndex: Int, name: String) {
        state.withLockedValue { state in
            guard let contentIndex = state.toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let id, let openName, let json, let sig) = state.blocks[contentIndex], openName.isEmpty {
                state.blocks[contentIndex] = .toolUse(id: id, name: name, json: json, thoughtSignature: sig)
            }
        }
    }

    func appendToolCallArgs(rawIndex: Int, chunk: String) {
        state.withLockedValue { state in
            guard let contentIndex = state.toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let id, let name, let json, let sig) = state.blocks[contentIndex] {
                state.blocks[contentIndex] = .toolUse(id: id, name: name, json: json + chunk, thoughtSignature: sig)
            }
        }
    }

    /// Attach an encrypted reasoning detail (serialized JSON) to the tool call
    /// with the matching id, or stash it as pending if the id has not settled.
    func applyReasoningDetail(id: String, serialized: String) {
        state.withLockedValue { state in
            if let contentIndex = state.toolCallContentIndexById[id],
               case .toolUse(let cid, let name, let json, _) = state.blocks[contentIndex] {
                state.blocks[contentIndex] = .toolUse(id: cid, name: name, json: json, thoughtSignature: serialized)
            } else {
                state.pendingReasoningById[id] = serialized
            }
        }
    }

    // MARK: Stream events

    func applyUsage(_ obj: [String: JSONValue]) {
        func intOf(_ v: JSONValue?) -> Int? { if case .int(let n)? = v { return n }; return nil }
        let prompt = intOf(obj["prompt_tokens"]) ?? 0
        let promptDetails: [String: JSONValue] = {
            if case .object(let d)? = obj["prompt_tokens_details"] { return d }
            return [:]
        }()
        // DeepSeek exposes cache hits via `prompt_cache_hit_tokens` instead of
        // `prompt_tokens_details.cached_tokens`, Moonshot via a top-level
        // `cached_tokens`.
        let cacheRead = intOf(promptDetails["cached_tokens"]) ?? intOf(obj["prompt_cache_hit_tokens"])
            ?? intOf(obj["cached_tokens"]) ?? 0
        let cacheWrite = intOf(promptDetails["cache_write_tokens"]) ?? 0
        let output = intOf(obj["completion_tokens"]) ?? 0
        let completionDetails: [String: JSONValue] = {
            if case .object(let d)? = obj["completion_tokens_details"] { return d }
            return [:]
        }()
        let reasoning = intOf(completionDetails["reasoning_tokens"]) ?? 0
        let input = max(0, prompt - cacheRead - cacheWrite)
        usage.input = input
        usage.output = output
        usage.cacheRead = cacheRead
        usage.cacheWrite = cacheWrite
        usage.reasoning = reasoning
        usage.totalTokens = input + output + cacheRead + cacheWrite
        usage.cost = calculateCost(model: model, usage: usage)
        // OpenRouter bills whichever upstream it routed to, often above the
        // catalog's cheapest-provider price, and reports the charge in USD as
        // `usage.cost` on every response. Use it, split across the parts in
        // the catalog's proportions.
        let isOpenRouter = provider == "openrouter" || model.baseURL.lowercased().contains("openrouter.ai")
        let billed: Double? = switch obj["cost"] {
        case .double(let d)?: d
        case .int(let n)?: Double(n)
        default: nil
        }
        if isOpenRouter, let billed {
            let estimate = usage.cost
            let scale = estimate.total > 0 ? billed / estimate.total : 0
            usage.cost = Cost(
                input: estimate.input * scale,
                output: estimate.output * scale,
                cacheRead: estimate.cacheRead * scale,
                cacheWrite: estimate.cacheWrite * scale,
                total: billed,
                billed: true
            )
        }
    }

    /// Streaming snapshot. In-progress tool calls use an empty-object
    /// placeholder rather than re-parsing the growing JSON buffer on every
    /// delta (O(n^2)); full arguments are parsed once in
    /// `finalizeStreamingBlocks`/`finalize`.
    func snapshot() -> AssistantMessage { buildMessage(parseToolArgs: false) }

    /// Gives each tool call the stream never named an id for one of its
    /// own. llama.cpp, Ollama and some relays send none, and a call kept at
    /// `""` can't be told from another one, nor paired with its result, and
    /// Anthropic refuses it outright after a switch (magpie mints
    /// `call_<id>` the same way, gateway/chat.go). The id is minted once and
    /// kept, so the end event, the final message and the tool result agree.
    private func settleEmptyToolCallIds() {
        state.withLockedValue { state in
            for idx in state.order {
                guard case .toolUse(let id, let name, let json, let sig) = state.blocks[idx], id.isEmpty
                else { continue }
                let minted = "call_"
                    + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
                state.blocks[idx] = .toolUse(id: minted, name: name, json: json, thoughtSignature: sig)
            }
        }
    }

    private func buildMessage(parseToolArgs: Bool) -> AssistantMessage {
        if parseToolArgs { settleEmptyToolCallIds() }
        return state.withLockedValue { state in
            AssistantMessage(
                content: state.order.compactMap { idx -> AssistantBlock? in
                    switch state.blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(let id, let name, let json, let sig):
                        let decoded: (arguments: JSONValue, unparsed: String?) = parseToolArgs
                            ? StreamedToolArguments.decode(json)
                            : (.object([:]), nil)
                        return .toolCall(ToolCall(
                            id: id,
                            name: name,
                            arguments: decoded.arguments,
                            thoughtSignature: sig,
                            unparsedArguments: decoded.unparsed
                        ))
                    case .none: return nil
                    }
                },
                api: api,
                provider: provider,
                model: modelId,
                responseId: responseId,
                usage: usage,
                stopReason: stopReason,
                timestamp: Timestamp.now()
            )
        }
    }

    /// Emit `text_end` / `thinking_end` / `toolcall_end` once per block when
    /// the stream reports a finish reason or runs out of events.
    func finalizeStreamingBlocks(emit: (AssistantMessageEvent) -> Void) {
        settleEmptyToolCallIds()
        let indices = state.withLockedValue { $0.order }
        for idx in indices {
            if state.withLockedValue({ $0.endedIndices.contains(idx) }) { continue }
            let partial = snapshot()
            guard let block = state.withLockedValue({ $0.blocks[idx] }) else { continue }
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse(let id, let name, let json, let sig):
                let decoded = StreamedToolArguments.decode(json)
                let call = ToolCall(
                    id: id,
                    name: name,
                    arguments: decoded.arguments,
                    thoughtSignature: sig,
                    unparsedArguments: decoded.unparsed
                )
                emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
            }
            _ = state.withLockedValue { $0.endedIndices.insert(idx) }
        }
    }

    func finalize() -> AssistantMessage {
        buildMessage(parseToolArgs: true)
    }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        var m = buildMessage(parseToolArgs: true)
        m.errorMessage = "Request was aborted"
        return m
    }
}
