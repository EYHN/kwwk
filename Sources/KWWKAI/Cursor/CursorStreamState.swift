import Foundation

/// Accumulates the assistant message as Cursor `InteractionUpdate`s arrive and
/// emits the corresponding `AssistantMessageEvent`s. Text, thinking, and tool
/// calls open/close as interleaved blocks, matching oh-my-pi's streaming state
/// machine: a new block is opened whenever a delta arrives with no block of
/// that kind currently open, and starting a tool call closes any open text or
/// thinking block.
final class CursorStreamState: @unchecked Sendable {
    private let api: String
    private let model: Model
    private let lock = NSLock()

    private var blocks: [AssistantBlock] = []
    private var textIndex: Int?
    private var thinkingIndex: Int?

    private var toolCallIndex: Int?
    /// Cumulative JSON-text snapshot of the streaming MCP args so far.
    private var toolCallArgsBuffer = ""
    /// Whether the open tool call streams MCP args (todo blocks don't).
    private var toolCallIsMcp = false

    private var outputTokens = 0
    private var sawTokenDelta = false
    private var stopReason: StopReason = .stop

    init(api: String, model: Model) {
        self.api = api
        self.model = model
    }

    // MARK: - Text / thinking

    func appendText(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        let (index, isNew): (Int, Bool) = lock.withLock {
            if let idx = textIndex { return (idx, false) }
            let idx = blocks.count
            textIndex = idx
            blocks.append(.text(TextContent(text: "")))
            return (idx, true)
        }
        if isNew {
            emit(.textStart(contentIndex: index, partial: snapshot()))
        }
        lock.withLock {
            if case .text(var t) = blocks[index] {
                t.text += delta
                blocks[index] = .text(t)
            }
        }
        emit(.textDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    func appendThinking(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        let (index, isNew): (Int, Bool) = lock.withLock {
            if let idx = thinkingIndex { return (idx, false) }
            let idx = blocks.count
            thinkingIndex = idx
            blocks.append(.thinking(ThinkingContent(thinking: "")))
            return (idx, true)
        }
        if isNew {
            emit(.thinkingStart(contentIndex: index, partial: snapshot()))
        }
        lock.withLock {
            if case .thinking(var t) = blocks[index] {
                t.thinking += delta
                blocks[index] = .thinking(t)
            }
        }
        emit(.thinkingDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    func endText(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = lock.withLock {
            guard let idx = textIndex, case .text(let t) = blocks[idx] else { return nil }
            textIndex = nil
            return (idx, t.text)
        }
        if let (index, content) = closed {
            emit(.textEnd(contentIndex: index, content: content, partial: snapshot()))
        }
    }

    func endThinking(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = lock.withLock {
            guard let idx = thinkingIndex, case .thinking(let t) = blocks[idx] else { return nil }
            thinkingIndex = nil
            return (idx, t.thinking)
        }
        if let (index, content) = closed {
            emit(.thinkingEnd(contentIndex: index, content: content, partial: snapshot()))
        }
    }

    // MARK: - Tool calls

    /// Open a streaming MCP tool-call block (`tool_call_started` with an
    /// `mcp_tool_call`). Args accumulate via `args_text_delta` snapshots until
    /// `completeToolCall`.
    func startMcpToolCall(id: String, name: String, emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let index: Int = lock.withLock {
            let idx = blocks.count
            toolCallIndex = idx
            toolCallArgsBuffer = ""
            toolCallIsMcp = true
            blocks.append(.toolCall(ToolCall(id: id, name: name, arguments: .object([:]))))
            return idx
        }
        emit(.toolCallStart(contentIndex: index, partial: snapshot()))
    }

    /// Open a todo tool-call block (Cursor's server-native todo tool). The
    /// server already applied the update, so the block is marked resolved.
    func startTodoToolCall(id: String, arguments: JSONValue, emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let index: Int = lock.withLock {
            let idx = blocks.count
            toolCallIndex = idx
            toolCallArgsBuffer = ""
            toolCallIsMcp = false
            blocks.append(.toolCall(ToolCall(
                id: id, name: "todo", arguments: arguments, cursorExecResolved: true
            )))
            return idx
        }
        emit(.toolCallStart(contentIndex: index, partial: snapshot()))
    }

    /// Apply a cumulative `args_text_delta` snapshot: strip the prefix we
    /// already have and emit only the new suffix (falling back to treating a
    /// non-extending snapshot as an incremental fragment, like oh-my-pi).
    func appendToolCallArgs(snapshot argsSnapshot: String, emit: (AssistantMessageEvent) -> Void) {
        let update: (index: Int, chunk: String)? = lock.withLock {
            guard let idx = toolCallIndex, toolCallIsMcp else { return nil }
            let chunk = argsSnapshot.hasPrefix(toolCallArgsBuffer)
                ? String(argsSnapshot.dropFirst(toolCallArgsBuffer.count))
                : argsSnapshot
            guard !chunk.isEmpty else { return nil }
            toolCallArgsBuffer += chunk
            return (idx, chunk)
        }
        if let (index, chunk) = update {
            emit(.toolCallDelta(contentIndex: index, delta: chunk, partial: snapshot()))
        }
    }

    /// Close the open tool-call block. The accumulated JSON-text buffer is the
    /// primary source of args; `completionArgs` (decoded from the completion
    /// frame's `McpArgs` map) fills in per-key, except where the completion
    /// downgraded a structured streamed value to a raw string.
    func completeToolCall(completionArgs: JSONValue?, emit: (AssistantMessageEvent) -> Void) {
        let completed: (index: Int, call: ToolCall)? = lock.withLock {
            guard let idx = toolCallIndex, case .toolCall(var call) = blocks[idx] else { return nil }
            if toolCallIsMcp {
                let streamed = (try? JSONDecoder().decode(
                    JSONValue.self, from: Data(toolCallArgsBuffer.utf8)
                )) ?? JSONValue.object([:])
                call.arguments = Self.mergeMcpArgs(streamed: streamed, completion: completionArgs)
            } else if let completionArgs {
                call.arguments = completionArgs
            }
            blocks[idx] = .toolCall(call)
            toolCallIndex = nil
            toolCallArgsBuffer = ""
            return (idx, call)
        }
        if let (index, call) = completed {
            emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
        }
    }

    /// Append a completed `toolCall` block for a tool the provider already
    /// executed over the exec channel (native bridge, or an MCP exec without a
    /// matching streamed block). Marked resolved so the agent loop skips it.
    func synthesizeResolvedToolCall(
        id: String, name: String, arguments: JSONValue, emit: (AssistantMessageEvent) -> Void
    ) {
        endText(emit: emit)
        endThinking(emit: emit)
        let (index, call): (Int, ToolCall) = lock.withLock {
            let call = ToolCall(id: id, name: name, arguments: arguments, cursorExecResolved: true)
            blocks.append(.toolCall(call))
            return (blocks.count - 1, call)
        }
        emit(.toolCallStart(contentIndex: index, partial: snapshot()))
        emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
    }

    /// Mark the tool-call block with `id` as resolved (the provider executed it
    /// inline via the exec channel). Returns whether a block matched.
    func markToolCallResolved(id: String) -> Bool {
        lock.withLock {
            for (idx, block) in blocks.enumerated() {
                guard case .toolCall(var call) = block, call.id == id else { continue }
                call.cursorExecResolved = true
                blocks[idx] = .toolCall(call)
                return true
            }
            return false
        }
    }

    /// Merge completion-frame args into streamed args per key: absent → keep
    /// streamed; string over structured → keep streamed (the completion frame
    /// downgraded it); otherwise completion wins.
    static func mergeMcpArgs(streamed: JSONValue, completion: JSONValue?) -> JSONValue {
        guard case .object(let completionObj)? = completion else { return streamed }
        guard case .object(var merged) = streamed else {
            return completion ?? streamed
        }
        for (key, value) in completionObj {
            if case .string = value {
                switch merged[key] {
                case .object, .array: continue
                default: break
                }
            }
            merged[key] = value
        }
        return .object(merged)
    }

    // MARK: - Usage

    func addOutputTokens(_ tokens: Int) {
        lock.withLock {
            sawTokenDelta = true
            outputTokens += tokens
        }
    }

    /// Conversation-wide `used_tokens` from a checkpoint. Only a fallback for
    /// when the stream carried no `token_delta` updates — it measures total
    /// context occupancy, not this turn's output, so it must never override
    /// delta-accumulated counts.
    func applyCheckpointUsedTokens(_ used: Int) {
        lock.withLock {
            guard !sawTokenDelta, used > 0 else { return }
            outputTokens = used
        }
    }

    // MARK: - Finalization

    /// Emit end events for any blocks still open at end of stream.
    func closeOpenBlocks(emit: (AssistantMessageEvent) -> Void) {
        completeToolCall(completionArgs: nil, emit: emit)
        endThinking(emit: emit)
        endText(emit: emit)
    }

    func snapshot() -> AssistantMessage {
        lock.withLock {
            AssistantMessage(
                content: blocks, api: api, provider: model.provider, model: model.id,
                usage: usageLocked(), stopReason: stopReason, timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage {
        snapshot()
    }

    func aborted() -> AssistantMessage {
        lock.withLock { stopReason = .aborted }
        var m = finalize()
        m.errorMessage = "Request was aborted"
        return m
    }

    private func usageLocked() -> Usage {
        var usage = Usage()
        usage.output = outputTokens
        usage.totalTokens = outputTokens
        usage.cost = calculateCost(model: model, usage: usage)
        return usage
    }
}
