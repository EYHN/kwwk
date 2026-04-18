import Foundation

/// Google Gemini (Generative AI API) streaming provider —
/// `/v1beta/models/{model}:streamGenerateContent?alt=sse`.
///
/// Notable differences:
///  - Messages are `contents: [{role, parts: [...]}]`. Roles are `user` /
///    `model`. System messages go under a separate `systemInstruction` field.
///  - Tools are nested: `tools: [{functionDeclarations: [...]}]`.
///  - Function calls arrive as fully-formed `{functionCall: {name, args}}`
///    parts — no incremental JSON. So we emit a single `toolcall_delta` for
///    each call carrying the entire serialized args string.
///  - Thinking: `thinkingConfig: {thinkingBudget, includeThoughts}`. When
///    enabled, parts may carry `thought: true` flag alongside text.
///  - `parallel_tool_calls` is not a supported request field — Gemini always
///    allows multiple `functionCall` parts in one response.
public final class GoogleGeminiProvider: APIProvider, @unchecked Sendable {
    public typealias URLBuilder = @Sendable (Model, StreamOptions?, URL, String?) -> URL
    public typealias AuthHeaderBuilder = @Sendable (String) -> [String: String]

    public let api: String
    public let client: HTTPClient
    public let defaultBaseURL: URL
    public let defaultAPIKey: String?
    public let extraHeaders: [String: String]
    public let urlBuilder: URLBuilder
    /// When non-nil, auth travels as a header instead of the `?key=` URL
    /// parameter. Used by Vertex AI (Bearer OAuth token).
    public let authHeaderBuilder: AuthHeaderBuilder?

    public init(
        api: String = "google-generative-ai",
        client: HTTPClient = URLSessionHTTPClient(),
        defaultBaseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
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
        self.urlBuilder = urlBuilder ?? { model, options, fallback, key in
            var base = model.baseUrl.isEmpty ? fallback.absoluteString : model.baseUrl
            while base.hasSuffix("/") { base.removeLast() }
            var path = "\(base)/v1beta/models/\(model.id):streamGenerateContent?alt=sse"
            if let key, !key.isEmpty {
                path += "&key=\(key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key)"
            }
            return URL(string: path) ?? fallback
        }
        self.authHeaderBuilder = authHeaderBuilder
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
        // When auth is a header (Vertex Bearer), build URL without the `?key=`.
        let queryKey: String? = authHeaderBuilder == nil
            ? (options?.apiKey ?? defaultAPIKey)
            : nil
        let url = urlBuilder(model, options, defaultBaseURL, queryKey)

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
        if let builder = authHeaderBuilder, let key = options?.apiKey ?? defaultAPIKey {
            for (k, v) in builder(key) { headers[k] = v }
        }
        for (k, v) in options?.headers ?? [:] { headers[k] = v }

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: body
            )
            if response.statusCode >= 400 {
                let msg = Self.makeError(
                    api: api, model: model,
                    text: "Gemini returned status \(response.statusCode)"
                )
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }
            let state = GoogleGeminiState(api: api, provider: model.provider, modelId: model.id)
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
        state: GoogleGeminiState
    ) async throws {
        var emittedStart = false
        for try await sse in events {
            if state.signal?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            guard case .object(let obj)? = parseJSONObject(sse.data) else { continue }

            // Usage appears on most chunks; record the latest.
            if case .object(let metadata) = obj["usageMetadata"] ?? .null {
                state.applyUsage(metadata)
            }
            if case .string(let id) = obj["responseId"] ?? .null, state.responseId == nil {
                state.responseId = id
            }

            guard case .array(let candidates) = obj["candidates"] ?? .null,
                  let firstCandidate = candidates.first,
                  case .object(let candidate) = firstCandidate else { continue }

            if case .string(let finishReason) = candidate["finishReason"] ?? .null,
               finishReason != "FINISH_REASON_UNSPECIFIED", finishReason != "NULL" {
                state.stopReason = Self.mapFinishReason(finishReason)
            }

            if case .object(let content) = candidate["content"] ?? .null,
               case .array(let parts) = content["parts"] ?? .null {
                for part in parts {
                    guard case .object(let p) = part else { continue }
                    let isThought: Bool = {
                        if case .bool(let v) = p["thought"] ?? .null { return v } else { return false }
                    }()

                    if case .string(let text) = p["text"] ?? .null, !text.isEmpty {
                        if !emittedStart {
                            out.push(.start(partial: state.snapshot()))
                            emittedStart = true
                        }
                        if isThought {
                            let (index, firstSeen) = state.noteThinkingBlock()
                            if firstSeen {
                                out.push(.thinkingStart(contentIndex: index, partial: state.snapshot()))
                            }
                            state.appendThinking(index: index, text: text)
                            out.push(.thinkingDelta(contentIndex: index, delta: text, partial: state.snapshot()))
                        } else {
                            let (index, firstSeen) = state.noteTextBlock()
                            if firstSeen {
                                out.push(.textStart(contentIndex: index, partial: state.snapshot()))
                            }
                            state.appendText(index: index, text: text)
                            out.push(.textDelta(contentIndex: index, delta: text, partial: state.snapshot()))
                        }
                    }

                    if case .object(let fc) = p["functionCall"] ?? .null {
                        let name: String = {
                            if case .string(let v) = fc["name"] ?? .null { return v } else { return "" }
                        }()
                        let argsValue: JSONValue = fc["args"] ?? .object([:])
                        let signature: String? = {
                            if case .string(let s) = p["thoughtSignature"] ?? .null { return s }
                            return nil
                        }()
                        let index = state.appendToolCall(name: name, args: argsValue, signature: signature)
                        if !emittedStart {
                            out.push(.start(partial: state.snapshot()))
                            emittedStart = true
                        }
                        out.push(.toolCallStart(contentIndex: index, partial: state.snapshot()))
                        // Gemini delivers args all at once; emit a single delta
                        // carrying the serialized JSON so downstream consumers
                        // can reconstruct progressively-parsed args if they want.
                        let argsJSON = (try? String(
                            data: JSONSerialization.data(
                                withJSONObject: anyFromJSONValue(argsValue) ?? [:] as Any,
                                options: [.sortedKeys]
                            ),
                            encoding: .utf8
                        )) ?? "{}"
                        out.push(.toolCallDelta(contentIndex: index, delta: argsJSON, partial: state.snapshot()))
                        let call = ToolCall(
                            id: state.toolCallId(at: index),
                            name: name,
                            arguments: argsValue,
                            thoughtSignature: signature
                        )
                        out.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: state.snapshot()))
                    }
                }
            }
        }

        // Finalize any streamed text/thinking blocks.
        state.finalizeStreamingBlocks(emit: { event in out.push(event) })
        // If tool calls are present, Gemini expects `toolUse` semantics.
        if state.hasToolCalls() {
            state.stopReason = .toolUse
        }
        let final = state.finalize()
        out.push(.done(reason: final.stopReason, message: final))
        out.end(final)
    }

    // MARK: - Encoding

    private static func encodeBody(
        model: Model, context: Context, options: StreamOptions?
    ) throws -> Data {
        var root: [String: Any] = [
            "contents": encodeContents(context: context),
        ]
        if let sys = context.systemPrompt, !sys.isEmpty {
            root["systemInstruction"] = [
                "role": "system",
                "parts": [["text": sys]],
            ]
        }
        if let tools = context.tools, !tools.isEmpty {
            root["tools"] = [[
                "functionDeclarations": tools.map { tool -> [String: Any] in
                    var entry: [String: Any] = [
                        "name": tool.name,
                        "description": tool.description,
                    ]
                    if let params = anyFromJSONValue(tool.parameters) {
                        entry["parameters"] = params
                    }
                    return entry
                }
            ]]
            if let cfg = encodeToolConfig(options?.toolChoice) {
                root["toolConfig"] = cfg
            }
        }

        var generationConfig: [String: Any] = [:]
        if let temp = options?.temperature { generationConfig["temperature"] = temp }
        if let maxTokens = options?.maxTokens ?? (model.maxTokens > 0 ? model.maxTokens : nil) {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let reasoning = options?.reasoning {
            var thinking: [String: Any] = ["includeThoughts": true]
            if let budget = options?.thinkingBudgets?.budget(for: reasoning) {
                thinking["thinkingBudget"] = budget
            }
            generationConfig["thinkingConfig"] = thinking
        }
        if !generationConfig.isEmpty {
            root["generationConfig"] = generationConfig
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func encodeContents(context: Context) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in context.messages {
            switch message {
            case .user(let u):
                let parts: [[String: Any]] = u.content.compactMap { block in
                    switch block {
                    case .text(let t): return ["text": t.text]
                    case .image(let i):
                        return [
                            "inlineData": [
                                "mimeType": i.mimeType,
                                "data": i.data,
                            ],
                        ]
                    }
                }
                out.append(["role": "user", "parts": parts])

            case .assistant(let a):
                var parts: [[String: Any]] = []
                for block in a.content {
                    switch block {
                    case .text(let t):
                        if !t.text.isEmpty { parts.append(["text": t.text]) }
                    case .thinking(let th):
                        if !th.thinking.isEmpty {
                            parts.append(["text": th.thinking, "thought": true])
                        }
                    case .toolCall(let tc):
                        var part: [String: Any] = [
                            "functionCall": [
                                "name": tc.name,
                                "args": anyFromJSONValue(tc.arguments) ?? [:] as Any,
                            ],
                        ]
                        if let sig = tc.thoughtSignature {
                            part["thoughtSignature"] = sig
                        }
                        parts.append(part)
                    }
                }
                if !parts.isEmpty {
                    out.append(["role": "model", "parts": parts])
                }

            case .toolResult(let tr):
                let text = tr.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined(separator: "\n")
                out.append([
                    "role": "function",
                    "parts": [[
                        "functionResponse": [
                            "name": tr.toolName,
                            "response": ["output": text],
                        ],
                    ]],
                ])
            }
        }
        return out
    }

    private static func encodeToolConfig(_ choice: ToolChoice?) -> Any? {
        guard let choice else { return nil }
        switch choice {
        case .auto: return ["functionCallingConfig": ["mode": "AUTO"]]
        case .none: return ["functionCallingConfig": ["mode": "NONE"]]
        case .required: return ["functionCallingConfig": ["mode": "ANY"]]
        case .tool(let name):
            return [
                "functionCallingConfig": [
                    "mode": "ANY",
                    "allowedFunctionNames": [name],
                ],
            ]
        }
    }

    private static func mapFinishReason(_ raw: String) -> StopReason {
        switch raw {
        case "STOP", "MODEL_STOP": return .stop
        case "MAX_TOKENS": return .length
        case "SAFETY", "PROHIBITED_CONTENT", "RECITATION", "BLOCKLIST", "SPII", "OTHER": return .error
        case "MALFORMED_FUNCTION_CALL": return .error
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

extension ThinkingBudgets {
    /// Budget lookup per reasoning level. Gemini only exposes an integer
    /// thinking budget, not a level.
    func budget(for level: ReasoningLevel) -> Int? {
        switch level {
        case .minimal: return minimal
        case .low: return low
        case .medium: return medium
        case .high, .xhigh: return high
        }
    }
}

// MARK: - Mutable state

final class GoogleGeminiState: @unchecked Sendable {
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
        case toolUse(id: String, call: ToolCall)
    }

    private let lock = NSLock()
    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private var textIndex: Int?
    private var thinkingIndex: Int?
    private var endedIndices: Set<Int> = []

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func noteTextBlock() -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = textIndex { return (idx, false) }
            let idx = order.count
            textIndex = idx
            order.append(idx)
            blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock() -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = thinkingIndex { return (idx, false) }
            let idx = order.count
            thinkingIndex = idx
            order.append(idx)
            blocks[idx] = .thinking(ThinkingContent(thinking: ""))
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

    func appendToolCall(name: String, args: JSONValue, signature: String?) -> Int {
        lock.withLock {
            let idx = order.count
            let id = "gemini-tool-\(idx)-\(Int(Date().timeIntervalSince1970 * 1000))"
            let call = ToolCall(id: id, name: name, arguments: args, thoughtSignature: signature)
            order.append(idx)
            blocks[idx] = .toolUse(id: id, call: call)
            endedIndices.insert(idx)   // Gemini delivers calls atomically.
            return idx
        }
    }

    func toolCallId(at index: Int) -> String {
        lock.withLock {
            if case .toolUse(let id, _) = blocks[index] { return id } else { return "" }
        }
    }

    func hasToolCalls() -> Bool {
        lock.withLock {
            blocks.values.contains { if case .toolUse = $0 { return true } else { return false } }
        }
    }

    func applyUsage(_ obj: [String: JSONValue]) {
        if case .int(let v) = obj["promptTokenCount"] ?? .null { usage.input = v }
        if case .int(let v) = obj["candidatesTokenCount"] ?? .null { usage.output = v }
        if case .int(let v) = obj["cachedContentTokenCount"] ?? .null { usage.cacheRead = v }
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
    }

    func snapshot() -> AssistantMessage {
        lock.withLock {
            AssistantMessage(
                content: order.compactMap { idx -> AssistantBlock? in
                    switch blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(_, let call): return .toolCall(call)
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

    func finalize() -> AssistantMessage { snapshot() }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        var m = snapshot()
        m.errorMessage = "Request was aborted"
        return m
    }

    func finalizeStreamingBlocks(emit: (AssistantMessageEvent) -> Void) {
        let indices = lock.withLock { order }
        for idx in indices {
            if endedIndices.contains(idx) { continue }
            guard let block = lock.withLock({ blocks[idx] }) else { continue }
            let partial = snapshot()
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse: break
            }
            _ = lock.withLock { endedIndices.insert(idx) }
        }
    }
}
