import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages streaming provider. Implements the `anthropic-messages`
/// API against a pluggable `HTTPClient`.
///
/// Non-goals for this implementation:
///  - OAuth bearer tokens, anthropic-beta opt-in headers
///  - Cache-control placement heuristics
///  - Rate-limit retry with `retry-after` parsing
///
/// These are tracked in follow-up work; for now the provider is testable via a
/// URLProtocol mock and produces the standard AssistantMessageEvent stream.
public final class AnthropicProvider: APIProvider, @unchecked Sendable {
    public typealias AuthHeaderBuilder = @Sendable (String) -> [String: String]

    public let api: String
    public let client: HTTPClient
    public let defaultBaseURL: URL
    public let defaultAPIKey: String?
    public let apiVersion: String
    /// Extra headers injected on every request (e.g. `anthropic-beta` for
    /// OAuth-mode access).
    public let extraHeaders: [String: String]
    /// Translator from resolved api key → auth headers. Defaults to the
    /// `x-api-key` scheme; OAuth bearer variants override this to emit an
    /// `authorization: Bearer …` header instead.
    public let authHeaderBuilder: AuthHeaderBuilder
    /// Prepended to `system` on every request. OAuth-mode (Claude Pro/Max
    /// subscription) requires the first system text to identify as Claude
    /// Code, otherwise the endpoint returns `rate_limit_error` regardless
    /// of remaining subscription quota.
    public let systemPromptPrefix: String?

    public init(
        api: String = "anthropic-messages",
        client: HTTPClient = URLSessionHTTPClient(),
        defaultBaseURL: URL = URL(string: "https://api.anthropic.com")!,
        defaultAPIKey: String? = nil,
        apiVersion: String = "2023-06-01",
        extraHeaders: [String: String] = [:],
        authHeaderBuilder: AuthHeaderBuilder? = nil,
        systemPromptPrefix: String? = nil
    ) {
        self.api = api
        self.client = client
        self.defaultBaseURL = defaultBaseURL
        self.defaultAPIKey = defaultAPIKey
        self.apiVersion = apiVersion
        self.extraHeaders = extraHeaders
        self.authHeaderBuilder = authHeaderBuilder ?? { key in ["x-api-key": key] }
        self.systemPromptPrefix = systemPromptPrefix
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached {
            await self.run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    // MARK: - Driver

    private func run(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        let url: URL = {
            var base = model.baseUrl.isEmpty ? defaultBaseURL.absoluteString : model.baseUrl
            while base.hasSuffix("/") { base.removeLast() }
            return URL(string: "\(base)/v1/messages") ?? defaultBaseURL.appendingPathComponent("v1/messages")
        }()

        let body: Data
        do {
            body = try Self.encodeBody(
                model: model,
                context: context,
                options: options,
                systemPromptPrefix: systemPromptPrefix
            )
        } catch {
            out.push(.error(reason: .error, error: Self.makeError(
                model: model, api: api, text: "Failed to encode request: \(error)"
            )))
            out.end(Self.makeError(model: model, api: api, text: "Failed to encode request: \(error)"))
            return
        }

        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "text/event-stream",
            "anthropic-version": apiVersion,
        ]
        for (k, v) in extraHeaders { headers[k] = v }
        if let auth = options?.resolvedAuth {
            applyResolvedAuth(auth, to: &headers)
        } else if let key = options?.apiKey ?? defaultAPIKey {
            for (k, v) in authHeaderBuilder(key) { headers[k] = v }
        }
        if let extra = options?.headers {
            for (k, v) in extra { headers[k] = v }
        }

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: body
            )
            if response.statusCode >= 400 {
                // Drain the stream to surface the real error body — without
                // this the user just sees "status 400" and has no signal
                // whether it's the `thinking` field, max_tokens, or the
                // Copilot proxy rejecting a shape. Trim to keep the
                // notification readable; full body is still captured below.
                var bodyBytes = Data()
                for try await chunk in stream {
                    bodyBytes.append(chunk)
                    if bodyBytes.count > 4096 { break }
                }
                let bodyText = String(data: bodyBytes, encoding: .utf8) ?? ""
                let preview = bodyText.isEmpty
                    ? ""
                    : " — " + bodyText.replacingOccurrences(of: "\n", with: " ").prefix(500)
                let msg = Self.makeError(
                    model: model,
                    api: api,
                    text: "Anthropic returned status \(response.statusCode)\(preview)"
                )
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }

            let state = AnthropicStreamState(
                api: api,
                provider: model.provider,
                modelId: model.id
            )
            state.signal = options?.cancellation
            try await drive(events: parseSSE(bytes: stream), out: out, state: state)
        } catch {
            let msg = Self.makeError(model: model, api: api, text: "\(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
        }
    }

    private func drive(
        events: AsyncThrowingStream<SSEMessage, Error>,
        out: AssistantMessageStream,
        state: AnthropicStreamState
    ) async throws {
        var emittedStart = false
        for try await sse in events {
            if state.signal?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            guard let json = parseJSONObject(sse.data) else { continue }
            guard case .object(let obj) = json,
                  case .string(let type) = obj["type"] ?? .null else { continue }

            switch type {
            case "message_start":
                if case .object(let message) = obj["message"] ?? .null {
                    state.applyMessageStart(message)
                }
                if !emittedStart {
                    out.push(.start(partial: state.snapshot()))
                    emittedStart = true
                }

            case "content_block_start":
                if case .int(let index) = obj["index"] ?? .null,
                   case .object(let block) = obj["content_block"] ?? .null,
                   case .string(let blockType) = block["type"] ?? .null {
                    state.startBlock(index: index, type: blockType, raw: block)
                    switch blockType {
                    case "text":
                        out.push(.textStart(contentIndex: index, partial: state.snapshot()))
                    case "thinking":
                        out.push(.thinkingStart(contentIndex: index, partial: state.snapshot()))
                    case "tool_use":
                        out.push(.toolCallStart(contentIndex: index, partial: state.snapshot()))
                    default: break
                    }
                }

            case "content_block_delta":
                if case .int(let index) = obj["index"] ?? .null,
                   case .object(let delta) = obj["delta"] ?? .null,
                   case .string(let deltaType) = delta["type"] ?? .null {
                    switch deltaType {
                    case "text_delta":
                        if case .string(let text) = delta["text"] ?? .null {
                            state.appendText(index: index, text: text)
                            out.push(.textDelta(
                                contentIndex: index,
                                delta: text,
                                partial: state.snapshot()
                            ))
                        }
                    case "thinking_delta":
                        if case .string(let thinking) = delta["thinking"] ?? .null {
                            state.appendThinking(index: index, text: thinking)
                            out.push(.thinkingDelta(
                                contentIndex: index,
                                delta: thinking,
                                partial: state.snapshot()
                            ))
                        }
                    case "signature_delta":
                        if case .string(let sig) = delta["signature"] ?? .null {
                            state.appendSignature(index: index, signature: sig)
                        }
                    case "input_json_delta":
                        if case .string(let partial) = delta["partial_json"] ?? .null {
                            state.appendToolJSON(index: index, chunk: partial)
                            out.push(.toolCallDelta(
                                contentIndex: index,
                                delta: partial,
                                partial: state.snapshot()
                            ))
                        }
                    default: break
                    }
                }

            case "content_block_stop":
                if case .int(let index) = obj["index"] ?? .null {
                    let finalized = state.finishBlock(index: index)
                    switch finalized {
                    case .text(let text):
                        out.push(.textEnd(contentIndex: index, content: text, partial: state.snapshot()))
                    case .thinking(let text):
                        out.push(.thinkingEnd(contentIndex: index, content: text, partial: state.snapshot()))
                    case .toolCall(let call):
                        out.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: state.snapshot()))
                    case .none:
                        break
                    }
                }

            case "message_delta":
                if case .object(let delta) = obj["delta"] ?? .null,
                   case .string(let reason) = delta["stop_reason"] ?? .null {
                    state.stopReason = mapStopReason(reason)
                }
                if case .object(let usage) = obj["usage"] ?? .null {
                    state.applyUsageDelta(usage)
                }

            case "message_stop":
                let final = state.finalize()
                out.push(.done(reason: final.stopReason, message: final))
                out.end(final)
                return

            case "error":
                let text: String = {
                    if case .object(let err) = obj["error"] ?? .null,
                       case .string(let m) = err["message"] ?? .null { return m }
                    return "Unknown Anthropic error"
                }()
                let err = state.asError(text: text)
                out.push(.error(reason: .error, error: err))
                out.end(err)
                return

            default: break
            }
        }

        // Upstream closed without message_stop.
        let final = state.finalize()
        out.push(.done(reason: final.stopReason, message: final))
        out.end(final)
    }

    // MARK: - Helpers

    private static func encodeBody(
        model: Model,
        context: Context,
        options: StreamOptions?,
        systemPromptPrefix: String? = nil
    ) throws -> Data {
        var root: [String: Any] = [
            "model": model.id,
            "stream": true,
            "max_tokens": options?.maxTokens ?? model.maxTokens,
        ]
        // Extended thinking: Claude only returns `thinking` content blocks
        // when the request body opts in via `thinking: {type, budget_tokens}`.
        // When the caller requested a reasoning level, translate it to a
        // token budget (via `ThinkingBudgets.budget(for:)` if supplied,
        // else a sensible default per level). Temperature is deliberately
        // dropped in this branch — the Messages API rejects any value
        // other than 1.0 when thinking is enabled.
        let thinkingEnabled: Bool
        if let reasoning = options?.reasoning {
            let budget = options?.thinkingBudgets?.budget(for: reasoning) ?? defaultThinkingBudget(for: reasoning)
            root["thinking"] = [
                "type": "enabled",
                "budget_tokens": budget,
            ]
            thinkingEnabled = true
        } else {
            thinkingEnabled = false
        }
        if !thinkingEnabled, let temp = options?.temperature { root["temperature"] = temp }
        // `system` encoding. When a `systemPromptPrefix` is set (Anthropic
        // OAuth / Claude Pro subscription) the endpoint rejects any shape
        // where the Claude Code identifier isn't a standalone leading
        // system block — concatenated strings trip `rate_limit_error`
        // regardless of remaining quota. Emit array form so the prefix
        // rides as its own block. Without a prefix, keep the simple
        // string form that api-key callers have always used.
        let prefix = (systemPromptPrefix?.isEmpty == false) ? systemPromptPrefix : nil
        let userSystem = (context.systemPrompt?.isEmpty == false) ? context.systemPrompt : nil
        if let prefix {
            var blocks: [[String: Any]] = [["type": "text", "text": prefix]]
            if let userSystem {
                blocks.append(["type": "text", "text": userSystem])
            }
            root["system"] = blocks
        } else if let userSystem {
            root["system"] = userSystem
        }
        if let tools = context.tools, !tools.isEmpty {
            root["tools"] = tools.map { tool -> [String: Any] in
                var entry: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                ]
                if let params = anyFromJSONValue(tool.parameters) {
                    entry["input_schema"] = params
                }
                return entry
            }
            // Anthropic folds the parallel-tool-call switch into `tool_choice`
            // via a `disable_parallel_tool_use` flag. The default remains
            // parallel-on, so we only emit the block when the caller picks a
            // non-default choice OR disables parallel.
            if let toolChoice = buildToolChoice(options) {
                root["tool_choice"] = toolChoice
            }
        }
        root["messages"] = context.messages.compactMap(encodeMessage)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Fallback thinking budget per reasoning level when the caller didn't
    /// supply explicit `ThinkingBudgets`. Anthropic requires a minimum of
    /// 1024; these numbers are conservative enough to work across Claude
    /// 4.x Sonnet/Haiku/Opus without tripping per-model caps.
    private static func defaultThinkingBudget(for level: ReasoningLevel) -> Int {
        switch level {
        case .minimal: return 1024
        case .low: return 2048
        case .medium: return 8192
        case .high: return 16_384
        case .xhigh: return 24_576
        }
    }

    private static func buildToolChoice(_ options: StreamOptions?) -> [String: Any]? {
        let choice = options?.toolChoice
        let parallelOff = options?.parallelToolCalls == false
        if choice == nil && !parallelOff { return nil }
        var out: [String: Any]
        switch choice ?? .auto {
        case .auto: out = ["type": "auto"]
        case .none: out = ["type": "none"]
        case .required: out = ["type": "any"]
        case .tool(let name): out = ["type": "tool", "name": name]
        }
        if parallelOff { out["disable_parallel_tool_use"] = true }
        return out
    }

    private static func encodeMessage(_ message: Message) -> [String: Any]? {
        switch message {
        case .user(let u):
            let content = u.content.map { block -> [String: Any] in
                switch block {
                case .text(let t): return ["type": "text", "text": t.text]
                case .image(let i):
                    return [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": i.mimeType,
                            "data": i.data,
                        ],
                    ]
                }
            }
            return ["role": "user", "content": content]

        case .assistant(let a):
            var blocks: [[String: Any]] = []
            for block in a.content {
                switch block {
                case .text(let t):
                    blocks.append(["type": "text", "text": t.text])
                case .thinking(let th):
                    var entry: [String: Any] = ["type": "thinking", "thinking": th.thinking]
                    if let sig = th.thinkingSignature { entry["signature"] = sig }
                    blocks.append(entry)
                case .toolCall(let tc):
                    var entry: [String: Any] = [
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.name,
                    ]
                    entry["input"] = anyFromJSONValue(tc.arguments) ?? [:]
                    blocks.append(entry)
                }
            }
            return ["role": "assistant", "content": blocks]

        case .toolResult(let tr):
            let inner = tr.content.map { block -> [String: Any] in
                switch block {
                case .text(let t): return ["type": "text", "text": t.text]
                case .image(let i):
                    return [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": i.mimeType,
                            "data": i.data,
                        ],
                    ]
                }
            }
            var entry: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": tr.toolCallId,
                "content": inner,
            ]
            if tr.isError { entry["is_error"] = true }
            return ["role": "user", "content": [entry]]
        }
    }

    private static func makeError(model: Model, api: String, text: String) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: api,
            provider: model.provider,
            model: model.id,
            usage: Usage(),
            stopReason: .error,
            errorMessage: text,
            timestamp: Timestamp.now()
        )
    }
}

/// Mutable state the Anthropic stream driver mutates while consuming SSE.
final class AnthropicStreamState: @unchecked Sendable {
    private let lock = NSLock()
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?

    var responseId: String?
    var usage = Usage()
    var stopReason: StopReason = .stop
    var errorMessage: String?

    /// Content blocks. For text/thinking we accumulate a running string; for
    /// tool calls we keep an in-progress JSON buffer.
    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String)
    }
    private var blocks: [Int: Block] = [:]
    private var orderedIndices: [Int] = []

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func applyMessageStart(_ obj: [String: JSONValue]) {
        if case .string(let id) = obj["id"] ?? .null { responseId = id }
        if case .object(let u) = obj["usage"] ?? .null { applyUsageDelta(u) }
    }

    func applyUsageDelta(_ obj: [String: JSONValue]) {
        if case .int(let v) = obj["input_tokens"] ?? .null { usage.input = v }
        if case .int(let v) = obj["output_tokens"] ?? .null { usage.output = v }
        if case .int(let v) = obj["cache_read_input_tokens"] ?? .null { usage.cacheRead = v }
        if case .int(let v) = obj["cache_creation_input_tokens"] ?? .null { usage.cacheWrite = v }
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
    }

    func startBlock(index: Int, type: String, raw: [String: JSONValue]) {
        lock.withLock {
            if !orderedIndices.contains(index) { orderedIndices.append(index) }
            switch type {
            case "text": blocks[index] = .text(TextContent(text: ""))
            case "thinking": blocks[index] = .thinking(ThinkingContent(thinking: ""))
            case "tool_use":
                let id: String = {
                    if case .string(let v) = raw["id"] ?? .null { return v } else { return "" }
                }()
                let name: String = {
                    if case .string(let v) = raw["name"] ?? .null { return v } else { return "" }
                }()
                blocks[index] = .toolUse(id: id, name: name, json: "")
            default: break
            }
        }
    }

    func appendText(index: Int, text: String) {
        lock.withLock {
            if case .text(var t) = blocks[index] {
                t.text += text
                blocks[index] = .text(t)
            }
        }
    }

    func appendThinking(index: Int, text: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinking += text
                blocks[index] = .thinking(th)
            }
        }
    }

    func appendSignature(index: Int, signature: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinkingSignature = (th.thinkingSignature ?? "") + signature
                blocks[index] = .thinking(th)
            }
        }
    }

    func appendToolJSON(index: Int, chunk: String) {
        lock.withLock {
            if case .toolUse(let id, let name, let json) = blocks[index] {
                blocks[index] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    enum Finalized { case text(String); case thinking(String); case toolCall(ToolCall); case none }

    func finishBlock(index: Int) -> Finalized {
        lock.withLock {
            guard let block = blocks[index] else { return .none }
            switch block {
            case .text(let t): return .text(t.text)
            case .thinking(let th): return .thinking(th.thinking)
            case .toolUse(let id, let name, let json):
                let parsed: JSONValue = {
                    if let data = json.data(using: .utf8),
                       let v = try? JSONDecoder().decode(JSONValue.self, from: data) { return v }
                    return .object([:])
                }()
                let call = ToolCall(id: id, name: name, arguments: parsed)
                blocks[index] = .toolUse(id: id, name: name, json: json)
                return .toolCall(call)
            }
        }
    }

    func snapshot() -> AssistantMessage {
        lock.withLock {
            var content: [AssistantBlock] = []
            for i in orderedIndices.sorted() {
                guard let block = blocks[i] else { continue }
                switch block {
                case .text(let t): content.append(.text(t))
                case .thinking(let th): content.append(.thinking(th))
                case .toolUse(let id, let name, let json):
                    let parsed: JSONValue = {
                        if let data = json.data(using: .utf8),
                           let v = try? JSONDecoder().decode(JSONValue.self, from: data) { return v }
                        return .object([:])
                    }()
                    content.append(.toolCall(ToolCall(id: id, name: name, arguments: parsed)))
                }
            }
            return AssistantMessage(
                content: content,
                api: api,
                provider: provider,
                model: modelId,
                responseId: responseId,
                usage: usage,
                stopReason: stopReason,
                errorMessage: errorMessage,
                timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage {
        var m = snapshot()
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

func mapStopReason(_ raw: String) -> StopReason {
    switch raw {
    case "end_turn": return .stop
    case "max_tokens": return .length
    case "tool_use": return .toolUse
    case "stop_sequence": return .stop
    default: return .stop
    }
}

func parseJSONObject(_ text: String) -> JSONValue? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

/// Convert a JSONValue tree into a Foundation-compatible `Any` tree suitable
/// for `JSONSerialization`.
func anyFromJSONValue(_ value: JSONValue) -> Any? {
    switch value {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let arr): return arr.map { anyFromJSONValue($0) ?? NSNull() }
    case .object(let obj):
        var out: [String: Any] = [:]
        for (k, v) in obj { out[k] = anyFromJSONValue(v) ?? NSNull() }
        return out
    }
}
