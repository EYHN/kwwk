import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI /v1/chat/completions streaming provider. Also usable against any
/// wire-compatible endpoint — Groq, xAI, OpenRouter, Cerebras, HuggingFace,
/// Ollama, and OpenAI-compat proxies all work by swapping `model.baseUrl`.
///
/// Differences from Anthropic:
///  - Single SSE event stream, `data: {json}` lines, terminated by
///    `data: [DONE]`.
///  - `choices[0].delta.content` streams text; `delta.tool_calls[i]` streams
///    tool calls; `delta.reasoning` / `delta.reasoning_content` streams
///    thinking (some backends, like Groq/OpenRouter/Ollama, expose this).
///  - Tool calls arrive as `tool_calls: [{index, id, function: {name,
///    arguments}}]` — arguments are incremental JSON strings that must be
///    concatenated across deltas.
///  - `tool_choice` and `parallel_tool_calls` live at the request root.
public final class OpenAICompletionsProvider: APIProvider, @unchecked Sendable {
    public typealias URLBuilder = @Sendable (Model, StreamOptions?, URL) -> URL
    public typealias AuthHeaderBuilder = @Sendable (String) -> [String: String]
    /// Hook that receives the already-encoded JSON request body (as a mutable
    /// dictionary) and lets callers inject extra fields. Used by the Copilot
    /// variant to stamp per-turn headers that depend on the messages.
    public typealias BodyDecorator = @Sendable (inout [String: Any], Model, Context, StreamOptions?) -> Void
    public typealias HeadersDecorator = @Sendable (inout [String: String], Model, Context, StreamOptions?) -> Void

    public let api: String
    public let client: HTTPClient
    public let defaultBaseURL: URL
    public let defaultAPIKey: String?
    public let extraHeaders: [String: String]
    public let urlBuilder: URLBuilder
    public let authHeaderBuilder: AuthHeaderBuilder
    public let bodyDecorator: BodyDecorator?
    public let headersDecorator: HeadersDecorator?

    public init(
        api: String = "openai-completions",
        client: HTTPClient = URLSessionHTTPClient(),
        defaultBaseURL: URL = URL(string: "https://api.openai.com")!,
        defaultAPIKey: String? = nil,
        extraHeaders: [String: String] = [:],
        urlBuilder: URLBuilder? = nil,
        authHeaderBuilder: AuthHeaderBuilder? = nil,
        bodyDecorator: BodyDecorator? = nil,
        headersDecorator: HeadersDecorator? = nil
    ) {
        self.api = api
        self.client = client
        self.defaultBaseURL = defaultBaseURL
        self.defaultAPIKey = defaultAPIKey
        self.extraHeaders = extraHeaders
        self.urlBuilder = urlBuilder ?? { model, _, fallback in
            var base = model.baseUrl.isEmpty ? fallback.absoluteString : model.baseUrl
            while base.hasSuffix("/") { base.removeLast() }
            // Tolerate catalog entries that bake `/v1` into baseUrl
            // (pi-mono's models.generated.ts does this for OpenAI).
            // Without this, the session baseUrl `https://api.openai.com`
            // → `/v1/chat/completions`, but a `/model` swap pulls in
            // `https://api.openai.com/v1` and we'd double-suffix.
            let versioned = base.hasSuffix("/v1") ? base : "\(base)/v1"
            return URL(string: "\(versioned)/chat/completions")
                ?? fallback.appendingPathComponent("v1/chat/completions")
        }
        self.authHeaderBuilder = authHeaderBuilder ?? { key in ["authorization": "Bearer \(key)"] }
        self.bodyDecorator = bodyDecorator
        self.headersDecorator = headersDecorator
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached {
            await self.run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    private func run(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        let url = urlBuilder(model, options, defaultBaseURL)

        let body: Data
        do {
            var root = try Self.encodeBodyDict(model: model, context: context, options: options)
            bodyDecorator?(&root, model, context, options)
            body = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        } catch {
            let msg = Self.makeError(api: api, model: model, text: "Failed to encode request: \(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }

        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "text/event-stream",
        ]
        for (k, v) in extraHeaders { headers[k] = v }
        if let auth = options?.resolvedAuth {
            applyResolvedAuth(auth, to: &headers)
        } else if let key = options?.apiKey ?? defaultAPIKey {
            for (k, v) in authHeaderBuilder(key) { headers[k] = v }
        }
        headersDecorator?(&headers, model, context, options)
        for (k, v) in options?.headers ?? [:] { headers[k] = v }

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: body
            )
            if response.statusCode >= 400 {
                let msg = Self.makeError(
                    api: api, model: model,
                    text: "OpenAI returned status \(response.statusCode)"
                )
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }
            let state = OpenAICompletionsState(api: api, provider: model.provider, modelId: model.id)
            state.signal = options?.cancellation
            try await drive(events: parseSSE(bytes: stream), out: out, state: state)
        } catch {
            let msg = Self.makeError(api: api, model: model, text: "\(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
        }
    }

    private func drive(
        events: AsyncThrowingStream<SSEMessage, Error>,
        out: AssistantMessageStream,
        state: OpenAICompletionsState
    ) async throws {
        var emittedStart = false
        for try await sse in events {
            if state.signal?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            // `[DONE]` sentinel ends the stream.
            if sse.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                let final = state.finalize()
                out.push(.done(reason: final.stopReason, message: final))
                out.end(final)
                return
            }
            guard case .object(let obj)? = parseJSONObject(sse.data) else { continue }

            // Usage is sent on the final chunk of some providers.
            if case .object(let usage) = obj["usage"] ?? .null {
                state.applyUsage(usage)
            }
            // Response ID: set on first chunk.
            if state.responseId == nil,
               case .string(let id) = obj["id"] ?? .null {
                state.responseId = id
            }

            // choices[0].delta carries incremental content.
            guard case .array(let choices) = obj["choices"] ?? .null,
                  let first = choices.first,
                  case .object(let choice) = first else { continue }

            if case .object(let delta) = choice["delta"] ?? .null {
                // Text content delta.
                if case .string(let text) = delta["content"] ?? .null, !text.isEmpty {
                    let (index, firstSeen) = state.noteTextBlock()
                    if !emittedStart {
                        out.push(.start(partial: state.snapshot()))
                        emittedStart = true
                    }
                    if firstSeen {
                        out.push(.textStart(contentIndex: index, partial: state.snapshot()))
                    }
                    state.appendText(index: index, text: text)
                    out.push(.textDelta(contentIndex: index, delta: text, partial: state.snapshot()))
                }
                // Reasoning content delta (provider-specific key).
                let reasoning: String? = {
                    if case .string(let r) = delta["reasoning"] ?? .null { return r }
                    if case .string(let r) = delta["reasoning_content"] ?? .null { return r }
                    return nil
                }()
                if let reasoning, !reasoning.isEmpty {
                    let (index, firstSeen) = state.noteThinkingBlock()
                    if !emittedStart {
                        out.push(.start(partial: state.snapshot()))
                        emittedStart = true
                    }
                    if firstSeen {
                        out.push(.thinkingStart(contentIndex: index, partial: state.snapshot()))
                    }
                    state.appendThinking(index: index, text: reasoning)
                    out.push(.thinkingDelta(contentIndex: index, delta: reasoning, partial: state.snapshot()))
                }
                // Tool calls — each entry is indexed by `index` and may
                // partially populate id/name/arguments.
                if case .array(let toolCalls) = delta["tool_calls"] ?? .null {
                    for entry in toolCalls {
                        guard case .object(let call) = entry,
                              case .int(let rawIndex) = call["index"] ?? .null else { continue }
                        let (contentIndex, firstSeen) = state.noteToolCallBlock(at: rawIndex)
                        if !emittedStart {
                            out.push(.start(partial: state.snapshot()))
                            emittedStart = true
                        }
                        if case .string(let id) = call["id"] ?? .null {
                            state.updateToolCallID(rawIndex: rawIndex, id: id)
                        }
                        if case .object(let function) = call["function"] ?? .null {
                            if case .string(let name) = function["name"] ?? .null {
                                state.updateToolCallName(rawIndex: rawIndex, name: name)
                            }
                            if firstSeen {
                                out.push(.toolCallStart(contentIndex: contentIndex, partial: state.snapshot()))
                            }
                            if case .string(let args) = function["arguments"] ?? .null, !args.isEmpty {
                                state.appendToolCallArgs(rawIndex: rawIndex, chunk: args)
                                out.push(.toolCallDelta(
                                    contentIndex: contentIndex,
                                    delta: args,
                                    partial: state.snapshot()
                                ))
                            }
                        }
                    }
                }
            }

            if case .string(let reason) = choice["finish_reason"] ?? .null {
                state.stopReason = Self.mapStopReason(reason)
                state.finalizeStreamingBlocks(emit: { event in out.push(event) })
            }
        }

        state.finalizeStreamingBlocks(emit: { event in out.push(event) })
        let final = state.finalize()
        out.push(.done(reason: final.stopReason, message: final))
        out.end(final)
    }

    // MARK: - Encoding

    static func encodeBodyDict(
        model: Model, context: Context, options: StreamOptions?
    ) throws -> [String: Any] {
        var root: [String: Any] = [
            "model": model.id,
            "stream": true,
            "messages": encodeMessages(context: context),
        ]
        if let maxTokens = options?.maxTokens ?? (model.maxTokens > 0 ? model.maxTokens : nil) {
            root["max_tokens"] = maxTokens
        }
        if let temp = options?.temperature { root["temperature"] = temp }
        if let tools = context.tools, !tools.isEmpty {
            root["tools"] = tools.map { tool -> [String: Any] in
                var fn: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                ]
                if let params = anyFromJSONValue(tool.parameters) {
                    fn["parameters"] = params
                }
                return ["type": "function", "function": fn]
            }
            if let choice = encodeToolChoice(options?.toolChoice) {
                root["tool_choice"] = choice
            }
            if options?.parallelToolCalls == false {
                root["parallel_tool_calls"] = false
            }
        }
        if let reasoning = options?.reasoning {
            root["reasoning_effort"] = reasoning.rawValue
        }
        if let meta = options?.metadata, let any = anyFromJSONValue(.object(meta)) {
            root["metadata"] = any
        }
        return root
    }

    private static func encodeMessages(context: Context) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let sys = context.systemPrompt, !sys.isEmpty {
            out.append(["role": "system", "content": sys])
        }
        for message in context.messages {
            switch message {
            case .user(let u):
                let strings = u.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }
                let images = u.content.compactMap { block -> ImageContent? in
                    if case .image(let i) = block { return i } else { return nil }
                }
                if images.isEmpty {
                    out.append(["role": "user", "content": strings.joined(separator: "\n")])
                } else {
                    var parts: [[String: Any]] = []
                    for s in strings where !s.isEmpty {
                        parts.append(["type": "text", "text": s])
                    }
                    for i in images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(i.mimeType);base64,\(i.data)"],
                        ])
                    }
                    out.append(["role": "user", "content": parts])
                }
            case .assistant(let a):
                var entry: [String: Any] = ["role": "assistant"]
                let textBody = a.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined()
                entry["content"] = textBody.isEmpty ? NSNull() : textBody
                let calls = a.content.compactMap { block -> [String: Any]? in
                    guard case .toolCall(let tc) = block else { return nil }
                    let argsString: String = {
                        if let data = try? JSONSerialization.data(
                            withJSONObject: anyFromJSONValue(tc.arguments) ?? [:] as Any,
                            options: [.sortedKeys]
                        ) {
                            return String(data: data, encoding: .utf8) ?? "{}"
                        }
                        return "{}"
                    }()
                    return [
                        "id": tc.id,
                        "type": "function",
                        "function": ["name": tc.name, "arguments": argsString],
                    ]
                }
                if !calls.isEmpty { entry["tool_calls"] = calls }
                out.append(entry)
            case .toolResult(let tr):
                let text = tr.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined(separator: "\n")
                out.append([
                    "role": "tool",
                    "tool_call_id": tr.toolCallId,
                    "content": text,
                ])
            }
        }
        return out
    }

    private static func encodeToolChoice(_ choice: ToolChoice?) -> Any? {
        guard let choice else { return nil }
        switch choice {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        case .tool(let name):
            return ["type": "function", "function": ["name": name]]
        }
    }

    private static func mapStopReason(_ raw: String) -> StopReason {
        switch raw {
        case "stop": return .stop
        case "length": return .length
        case "tool_calls", "function_call": return .toolUse
        default: return .stop
        }
    }

    private static func makeError(api: String, model: Model, text: String) -> AssistantMessage {
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

/// Mutable state for OpenAI Completions stream. Tracks content block order
/// and incremental tool-call JSON buffers.
final class OpenAICompletionsState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?

    var responseId: String?
    var usage = Usage()
    var stopReason: StopReason = .stop

    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String)
    }
    private let lock = NSLock()
    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private var textBlockIndex: Int?
    private var thinkingBlockIndex: Int?
    /// Map from OpenAI `tool_calls[i].index` → our content index.
    private var toolCallIndexMap: [Int: Int] = [:]
    private var endedIndices: Set<Int> = []

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    // MARK: Block book-keeping

    func noteTextBlock() -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = textBlockIndex { return (idx, false) }
            let idx = order.count
            textBlockIndex = idx
            order.append(idx)
            blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock() -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = thinkingBlockIndex { return (idx, false) }
            let idx = order.count
            thinkingBlockIndex = idx
            order.append(idx)
            blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    func noteToolCallBlock(at rawIndex: Int) -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = toolCallIndexMap[rawIndex] { return (idx, false) }
            let idx = order.count
            toolCallIndexMap[rawIndex] = idx
            order.append(idx)
            blocks[idx] = .toolUse(id: "", name: "", json: "")
            return (idx, true)
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

    func updateToolCallID(rawIndex: Int, id: String) {
        lock.withLock {
            guard let contentIndex = toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(_, let name, let json) = blocks[contentIndex] {
                blocks[contentIndex] = .toolUse(id: id, name: name, json: json)
            }
        }
    }

    func updateToolCallName(rawIndex: Int, name: String) {
        lock.withLock {
            guard let contentIndex = toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let id, _, let json) = blocks[contentIndex] {
                blocks[contentIndex] = .toolUse(id: id, name: name, json: json)
            }
        }
    }

    func appendToolCallArgs(rawIndex: Int, chunk: String) {
        lock.withLock {
            guard let contentIndex = toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let id, let name, let json) = blocks[contentIndex] {
                blocks[contentIndex] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    // MARK: Stream events

    func applyUsage(_ obj: [String: JSONValue]) {
        if case .int(let v) = obj["prompt_tokens"] ?? .null { usage.input = v }
        if case .int(let v) = obj["completion_tokens"] ?? .null { usage.output = v }
        if case .object(let details) = obj["prompt_tokens_details"] ?? .null {
            if case .int(let v) = details["cached_tokens"] ?? .null {
                usage.cacheRead = v
                usage.input = max(0, usage.input - v)
            }
        }
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
    }

    func snapshot() -> AssistantMessage {
        lock.withLock {
            AssistantMessage(
                content: order.compactMap { idx -> AssistantBlock? in
                    switch blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(let id, let name, let json):
                        let args = parseArguments(json)
                        return .toolCall(ToolCall(id: id, name: name, arguments: args))
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
        let indices = lock.withLock { order }
        for idx in indices {
            if endedIndices.contains(idx) { continue }
            let partial = snapshot()
            guard let block = lock.withLock({ blocks[idx] }) else { continue }
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse(let id, let name, let json):
                let call = ToolCall(id: id, name: name, arguments: parseArguments(json))
                emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
            }
            _ = lock.withLock { endedIndices.insert(idx) }
        }
    }

    func finalize() -> AssistantMessage {
        snapshot()
    }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        var m = snapshot()
        m.errorMessage = "Request was aborted"
        return m
    }

    private func parseArguments(_ json: String) -> JSONValue {
        if json.isEmpty { return .object([:]) }
        if let data = json.data(using: .utf8),
           let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return v
        }
        return .object([:])
    }
}
