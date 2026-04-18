import Foundation

/// OpenAI /v1/responses streaming provider — the newer native API for the
/// GPT-5 / Codex model family. Wire format differs substantially from
/// Completions:
///
///  - Request body uses `input` (not `messages`), `instructions` (not a
///    system message), `tools: [{type: "function", name, description,
///    parameters}]`, and `reasoning: {effort}`.
///  - SSE events have structured types: `response.created`,
///    `response.output_item.added`, `response.output_text.delta`,
///    `response.function_call_arguments.delta`, `response.output_item.done`,
///    `response.completed`, `response.error`, etc.
///  - Output items are typed (`message`, `function_call`, `reasoning`) and
///    carry `output_index` + `content_index` for nested content.
///  - `parallel_tool_calls` is a top-level boolean.
public final class OpenAIResponsesProvider: APIProvider, @unchecked Sendable {
    public typealias URLBuilder = @Sendable (Model, StreamOptions?, URL) -> URL
    public typealias AuthHeaderBuilder = @Sendable (String) -> [String: String]

    public let api: String
    public let client: HTTPClient
    public let defaultBaseURL: URL
    public let defaultAPIKey: String?
    public let extraHeaders: [String: String]
    public let urlBuilder: URLBuilder
    public let authHeaderBuilder: AuthHeaderBuilder

    public init(
        api: String = "openai-responses",
        client: HTTPClient = URLSessionHTTPClient(),
        defaultBaseURL: URL = URL(string: "https://api.openai.com")!,
        defaultAPIKey: String? = nil,
        extraHeaders: [String: String] = [:],
        urlBuilder: URLBuilder? = nil,
        authHeaderBuilder: AuthHeaderBuilder? = nil
    ) {
        self.api = api
        self.client = client
        self.defaultBaseURL = defaultBaseURL
        self.defaultAPIKey = defaultAPIKey
        self.extraHeaders = extraHeaders
        self.urlBuilder = urlBuilder ?? { model, _, fallback in
            var base = model.baseUrl.isEmpty ? fallback.absoluteString : model.baseUrl
            while base.hasSuffix("/") { base.removeLast() }
            return URL(string: "\(base)/v1/responses") ?? fallback.appendingPathComponent("v1/responses")
        }
        self.authHeaderBuilder = authHeaderBuilder ?? { key in ["authorization": "Bearer \(key)"] }
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { await self.run(out: out, model: model, context: context, options: options) }
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
            body = try Self.encodeBody(model: model, context: context, options: options)
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
        if let key = options?.apiKey ?? defaultAPIKey {
            for (k, v) in authHeaderBuilder(key) { headers[k] = v }
        }
        for (k, v) in options?.headers ?? [:] { headers[k] = v }

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: body
            )
            if response.statusCode >= 400 {
                let msg = Self.makeError(
                    api: api, model: model,
                    text: "OpenAI Responses returned status \(response.statusCode)"
                )
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }
            let state = OpenAIResponsesState(api: api, provider: model.provider, modelId: model.id)
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
        state: OpenAIResponsesState
    ) async throws {
        var emittedStart = false
        for try await sse in events {
            if state.signal?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            guard case .object(let obj)? = parseJSONObject(sse.data),
                  case .string(let type) = obj["type"] ?? .null else { continue }

            switch type {
            case "response.created":
                if case .object(let response) = obj["response"] ?? .null,
                   case .string(let id) = response["id"] ?? .null {
                    state.responseId = id
                }
                if !emittedStart {
                    out.push(.start(partial: state.snapshot()))
                    emittedStart = true
                }

            case "response.output_item.added":
                if case .int(let outputIndex) = obj["output_index"] ?? .null,
                   case .object(let item) = obj["item"] ?? .null,
                   case .string(let itemType) = item["type"] ?? .null {
                    switch itemType {
                    case "message":
                        // Plain message wrapper. Individual text parts come
                        // via content_part.added events below.
                        state.noteMessageItem(outputIndex: outputIndex)
                    case "reasoning":
                        let index = state.noteReasoningItem(outputIndex: outputIndex)
                        if !emittedStart {
                            out.push(.start(partial: state.snapshot()))
                            emittedStart = true
                        }
                        out.push(.thinkingStart(contentIndex: index, partial: state.snapshot()))
                    case "function_call":
                        let name: String = {
                            if case .string(let v) = item["name"] ?? .null { return v } else { return "" }
                        }()
                        let callId: String = {
                            if case .string(let v) = item["call_id"] ?? .null { return v }
                            if case .string(let v) = item["id"] ?? .null { return v }
                            return ""
                        }()
                        let index = state.noteFunctionCallItem(
                            outputIndex: outputIndex, callId: callId, name: name
                        )
                        if !emittedStart {
                            out.push(.start(partial: state.snapshot()))
                            emittedStart = true
                        }
                        out.push(.toolCallStart(contentIndex: index, partial: state.snapshot()))
                    default: break
                    }
                }

            case "response.content_part.added":
                if case .int(let outputIndex) = obj["output_index"] ?? .null,
                   case .object(let part) = obj["part"] ?? .null,
                   case .string(let partType) = part["type"] ?? .null,
                   partType == "output_text" {
                    let index = state.noteTextPart(outputIndex: outputIndex)
                    if !emittedStart {
                        out.push(.start(partial: state.snapshot()))
                        emittedStart = true
                    }
                    out.push(.textStart(contentIndex: index, partial: state.snapshot()))
                }

            case "response.output_text.delta":
                if case .int(let outputIndex) = obj["output_index"] ?? .null,
                   case .string(let delta) = obj["delta"] ?? .null {
                    if let index = state.textIndex(for: outputIndex) {
                        state.appendText(at: index, text: delta)
                        out.push(.textDelta(contentIndex: index, delta: delta, partial: state.snapshot()))
                    }
                }

            case "response.reasoning_summary_text.delta",
                 "response.reasoning.delta",
                 "response.reasoning_text.delta":
                if case .int(let outputIndex) = obj["output_index"] ?? .null,
                   case .string(let delta) = obj["delta"] ?? .null {
                    if let index = state.reasoningIndex(for: outputIndex) {
                        state.appendThinking(at: index, text: delta)
                        out.push(.thinkingDelta(contentIndex: index, delta: delta, partial: state.snapshot()))
                    }
                }

            case "response.function_call_arguments.delta":
                if case .int(let outputIndex) = obj["output_index"] ?? .null,
                   case .string(let delta) = obj["delta"] ?? .null {
                    if let index = state.toolCallIndex(for: outputIndex) {
                        state.appendToolCallArgs(at: index, chunk: delta)
                        out.push(.toolCallDelta(contentIndex: index, delta: delta, partial: state.snapshot()))
                    }
                }

            case "response.content_part.done":
                if case .int(let outputIndex) = obj["output_index"] ?? .null,
                   let index = state.textIndex(for: outputIndex) {
                    let content = state.textValue(at: index)
                    out.push(.textEnd(contentIndex: index, content: content, partial: state.snapshot()))
                }

            case "response.output_item.done":
                if case .int(let outputIndex) = obj["output_index"] ?? .null {
                    if let index = state.reasoningIndex(for: outputIndex) {
                        let content = state.thinkingValue(at: index)
                        out.push(.thinkingEnd(contentIndex: index, content: content, partial: state.snapshot()))
                    }
                    if let index = state.toolCallIndex(for: outputIndex),
                       let call = state.toolCallValue(at: index) {
                        out.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: state.snapshot()))
                    }
                }

            case "response.completed":
                if case .object(let response) = obj["response"] ?? .null {
                    if case .object(let usage) = response["usage"] ?? .null {
                        state.applyUsage(usage)
                    }
                    if case .string(let status) = response["status"] ?? .null {
                        state.stopReason = Self.mapStatus(status)
                    }
                    // When finish is due to a function call, map to toolUse.
                    if state.hasToolCalls() {
                        state.stopReason = .toolUse
                    }
                }
                let final = state.finalize()
                out.push(.done(reason: final.stopReason, message: final))
                out.end(final)
                return

            case "response.failed", "response.error":
                let text: String = {
                    if case .object(let err) = obj["error"] ?? .null,
                       case .string(let m) = err["message"] ?? .null { return m }
                    if case .object(let response) = obj["response"] ?? .null,
                       case .object(let err) = response["error"] ?? .null,
                       case .string(let m) = err["message"] ?? .null { return m }
                    return "OpenAI Responses error"
                }()
                let err = state.asError(text: text)
                out.push(.error(reason: .error, error: err))
                out.end(err)
                return

            default: break
            }
        }

        // Stream closed without explicit `response.completed`.
        let final = state.finalize()
        out.push(.done(reason: final.stopReason, message: final))
        out.end(final)
    }

    // MARK: - Encoding

    private static func encodeBody(
        model: Model, context: Context, options: StreamOptions?
    ) throws -> Data {
        var root: [String: Any] = [
            "model": model.id,
            "stream": true,
            "input": encodeInput(context: context),
        ]
        if let maxTokens = options?.maxTokens ?? (model.maxTokens > 0 ? model.maxTokens : nil) {
            root["max_output_tokens"] = maxTokens
        }
        if let temp = options?.temperature { root["temperature"] = temp }
        if let sys = context.systemPrompt, !sys.isEmpty {
            root["instructions"] = sys
        }
        if let tools = context.tools, !tools.isEmpty {
            root["tools"] = tools.map { tool -> [String: Any] in
                var entry: [String: Any] = [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                ]
                if let params = anyFromJSONValue(tool.parameters) {
                    entry["parameters"] = params
                }
                return entry
            }
            if let choice = encodeToolChoice(options?.toolChoice) {
                root["tool_choice"] = choice
            }
            if options?.parallelToolCalls == false {
                root["parallel_tool_calls"] = false
            }
        }
        if let reasoning = options?.reasoning {
            root["reasoning"] = ["effort": reasoning.rawValue]
        }
        if let meta = options?.metadata, let any = anyFromJSONValue(.object(meta)) {
            root["metadata"] = any
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Convert our Message transcript into OpenAI Responses' `input` array.
    /// Each element is a typed item (`message`, `function_call`, or
    /// `function_call_output`). Assistant messages with tool calls expand
    /// into multiple items.
    private static func encodeInput(context: Context) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in context.messages {
            switch message {
            case .user(let u):
                var parts: [[String: Any]] = []
                for block in u.content {
                    switch block {
                    case .text(let t):
                        parts.append(["type": "input_text", "text": t.text])
                    case .image(let i):
                        parts.append([
                            "type": "input_image",
                            "image_url": "data:\(i.mimeType);base64,\(i.data)",
                        ])
                    }
                }
                out.append(["type": "message", "role": "user", "content": parts])

            case .assistant(let a):
                let textParts: [[String: Any]] = a.content.compactMap { block in
                    guard case .text(let t) = block, !t.text.isEmpty else { return nil }
                    return ["type": "output_text", "text": t.text]
                }
                if !textParts.isEmpty {
                    out.append(["type": "message", "role": "assistant", "content": textParts])
                }
                for block in a.content {
                    if case .toolCall(let tc) = block {
                        let argsString: String = {
                            if let data = try? JSONSerialization.data(
                                withJSONObject: anyFromJSONValue(tc.arguments) ?? [:] as Any,
                                options: [.sortedKeys]
                            ) {
                                return String(data: data, encoding: .utf8) ?? "{}"
                            }
                            return "{}"
                        }()
                        out.append([
                            "type": "function_call",
                            "call_id": tc.id,
                            "name": tc.name,
                            "arguments": argsString,
                        ])
                    }
                }

            case .toolResult(let tr):
                let text = tr.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined(separator: "\n")
                out.append([
                    "type": "function_call_output",
                    "call_id": tr.toolCallId,
                    "output": text,
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
            return ["type": "function", "name": name]
        }
    }

    private static func mapStatus(_ raw: String) -> StopReason {
        switch raw {
        case "completed": return .stop
        case "incomplete": return .length
        case "failed": return .error
        case "cancelled": return .aborted
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

// MARK: - Mutable state

final class OpenAIResponsesState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?

    var responseId: String?
    var usage = Usage()
    var stopReason: StopReason = .stop
    var errorMessage: String?

    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String)
    }
    private let lock = NSLock()
    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    /// Output-index → content-index for each kind of item. Kept separate so
    /// that a reasoning + message + function_call under the same output_index
    /// can coexist (rare, but legal).
    private var textByOutput: [Int: Int] = [:]
    private var reasoningByOutput: [Int: Int] = [:]
    private var toolCallByOutput: [Int: Int] = [:]

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func noteMessageItem(outputIndex: Int) {
        // Text content parts arrive separately; nothing to do here.
        _ = outputIndex
    }

    func noteTextPart(outputIndex: Int) -> Int {
        lock.withLock {
            if let existing = textByOutput[outputIndex] { return existing }
            let idx = order.count
            textByOutput[outputIndex] = idx
            order.append(idx)
            blocks[idx] = .text(TextContent(text: ""))
            return idx
        }
    }

    func noteReasoningItem(outputIndex: Int) -> Int {
        lock.withLock {
            if let existing = reasoningByOutput[outputIndex] { return existing }
            let idx = order.count
            reasoningByOutput[outputIndex] = idx
            order.append(idx)
            blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return idx
        }
    }

    func noteFunctionCallItem(outputIndex: Int, callId: String, name: String) -> Int {
        lock.withLock {
            if let existing = toolCallByOutput[outputIndex] { return existing }
            let idx = order.count
            toolCallByOutput[outputIndex] = idx
            order.append(idx)
            blocks[idx] = .toolUse(id: callId, name: name, json: "")
            return idx
        }
    }

    func textIndex(for outputIndex: Int) -> Int? {
        lock.withLock { textByOutput[outputIndex] }
    }
    func reasoningIndex(for outputIndex: Int) -> Int? {
        lock.withLock { reasoningByOutput[outputIndex] }
    }
    func toolCallIndex(for outputIndex: Int) -> Int? {
        lock.withLock { toolCallByOutput[outputIndex] }
    }

    func appendText(at index: Int, text: String) {
        lock.withLock {
            if case .text(var t) = blocks[index] {
                t.text += text
                blocks[index] = .text(t)
            }
        }
    }

    func appendThinking(at index: Int, text: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinking += text
                blocks[index] = .thinking(th)
            }
        }
    }

    func appendToolCallArgs(at index: Int, chunk: String) {
        lock.withLock {
            if case .toolUse(let id, let name, let json) = blocks[index] {
                blocks[index] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    func textValue(at index: Int) -> String {
        lock.withLock {
            if case .text(let t) = blocks[index] { return t.text } else { return "" }
        }
    }

    func thinkingValue(at index: Int) -> String {
        lock.withLock {
            if case .thinking(let th) = blocks[index] { return th.thinking } else { return "" }
        }
    }

    func toolCallValue(at index: Int) -> ToolCall? {
        lock.withLock {
            guard case .toolUse(let id, let name, let json) = blocks[index] else { return nil }
            return ToolCall(id: id, name: name, arguments: parseArguments(json))
        }
    }

    func hasToolCalls() -> Bool {
        lock.withLock { !toolCallByOutput.isEmpty }
    }

    func applyUsage(_ obj: [String: JSONValue]) {
        if case .int(let v) = obj["input_tokens"] ?? .null { usage.input = v }
        if case .int(let v) = obj["output_tokens"] ?? .null { usage.output = v }
        if case .object(let details) = obj["input_tokens_details"] ?? .null {
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
                        return .toolCall(ToolCall(id: id, name: name, arguments: parseArguments(json)))
                    case .none: return nil
                    }
                },
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

    func finalize() -> AssistantMessage { snapshot() }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        errorMessage = "Request was aborted"
        return snapshot()
    }

    func asError(text: String) -> AssistantMessage {
        stopReason = .error
        errorMessage = text
        return snapshot()
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
