import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
public final class OpenAIResponsesProvider: APIProvider, APIProviderSessionLifecycle, @unchecked Sendable {
    public typealias URLBuilder = @Sendable (Model, StreamOptions?, URL) -> URL
    public typealias AuthHeaderBuilder = @Sendable (String) -> [String: String]
    public typealias WebSocketURLBuilder = @Sendable (URL) -> URL

    public let api: String
    public let client: HTTPClient
    public let webSocketClient: WebSocketClient?
    public let defaultBaseURL: URL
    public let defaultAPIKey: String?
    public let extraHeaders: [String: String]
    public let urlBuilder: URLBuilder
    public let webSocketURLBuilder: WebSocketURLBuilder
    public let authHeaderBuilder: AuthHeaderBuilder
    public let maxWebSocketFailures: Int
    /// Request-body fields merged in last (so they override defaults). Use
    /// for vendor quirks like ChatGPT Codex requiring `store: false`.
    public let bodyOverrides: [String: JSONValue]
    private let sessions = OpenAIResponsesSessionStore()

    public init(
        api: String = "openai-responses",
        client: HTTPClient = URLSessionHTTPClient(),
        webSocketClient: WebSocketClient? = URLSessionWebSocketClient(),
        defaultBaseURL: URL = URL(string: "https://api.openai.com")!,
        defaultAPIKey: String? = nil,
        extraHeaders: [String: String] = [:],
        bodyOverrides: [String: JSONValue] = [:],
        urlBuilder: URLBuilder? = nil,
        webSocketURLBuilder: WebSocketURLBuilder? = nil,
        maxWebSocketFailures: Int = 3,
        authHeaderBuilder: AuthHeaderBuilder? = nil
    ) {
        self.api = api
        self.client = client
        self.webSocketClient = webSocketClient
        self.defaultBaseURL = defaultBaseURL
        self.defaultAPIKey = defaultAPIKey
        self.extraHeaders = extraHeaders
        self.bodyOverrides = bodyOverrides
        self.maxWebSocketFailures = max(1, maxWebSocketFailures)
        self.urlBuilder = urlBuilder ?? { model, _, fallback in
            var base = model.baseUrl.isEmpty ? fallback.absoluteString : model.baseUrl
            while base.hasSuffix("/") { base.removeLast() }
            // Tolerate catalog entries that bake `/v1` into baseUrl
            // (pi-mono's models.generated.ts does this for OpenAI).
            let versioned = base.hasSuffix("/v1") ? base : "\(base)/v1"
            return URL(string: "\(versioned)/responses") ?? fallback.appendingPathComponent("v1/responses")
        }
        self.webSocketURLBuilder = webSocketURLBuilder ?? { httpURL in
            var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)
            switch components?.scheme {
            case "https": components?.scheme = "wss"
            case "http": components?.scheme = "ws"
            default: break
            }
            return components?.url ?? httpURL
        }
        self.authHeaderBuilder = authHeaderBuilder ?? { key in ["Authorization": bearerHeaderValue(key)] }
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { await self.run(out: out, model: model, context: context, options: options) }
        return out
    }

    public func closeSession(sessionId: String) async {
        sessions.closeSession(sessionId: sessionId)
    }

    private func run(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        let url = urlBuilder(model, options, defaultBaseURL)

        let request: OpenAIResponsesRequest
        do {
            request = try Self.makeRequest(
                model: model,
                context: context,
                options: options,
                bodyOverrides: bodyOverrides
            )
        } catch {
            let msg = Self.makeError(api: api, model: model, text: "Failed to encode request: \(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }

        let session = sessions.session(for: options?.sessionId)
        let transport = options?.transport ?? .auto
        if transport != .sse,
           let webSocketClient,
           !session.webSocketDisabled {
            let wsURL = webSocketURLBuilder(url)
            await options?.emitVerbose(
                source: "openai.responses.websocket",
                message: "attempting WebSocket stream",
                metadata: ["url": .string(wsURL.absoluteString)]
            )
            let wsResult = await runWebSocket(
                client: webSocketClient,
                url: wsURL,
                request: request,
                out: out,
                model: model,
                options: options,
                session: session
            )
            switch wsResult {
            case .completed:
                return
            case .fallbackToHTTP:
                await options?.emitVerbose(
                    source: "openai.responses.http",
                    message: "falling back to HTTP stream"
                )
                break
            case .failedWithoutFallback:
                return
            }
        } else if transport != .sse, session.webSocketDisabled {
            await options?.emitVerbose(
                source: "openai.responses.websocket",
                message: "WebSocket disabled after repeated failures; using HTTP"
            )
        }

        await runHTTP(
            url: url,
            request: request,
            out: out,
            model: model,
            options: options
        )
    }

    private func runHTTP(
        url: URL,
        request: OpenAIResponsesRequest,
        out: AssistantMessageStream,
        model: Model,
        options: StreamOptions?
    ) async {
        let headers = makeHeaders(options: options, accept: "text/event-stream")
        await options?.emitVerbose(
            source: "openai.responses.http",
            message: "starting HTTP stream",
            metadata: ["url": .string(url.absoluteString)]
        )

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: try request.data()
            )
            if response.statusCode >= 400 {
                // Collect whatever the server wrote (usually a small JSON
                // error body). Surface it so debugging doesn't require
                // network captures.
                var body = Data()
                do {
                    for try await byte in stream { body.append(byte) }
                } catch {
                    // ignore — best effort
                }
                let bodyText = String(data: body, encoding: .utf8) ?? ""
                let msg = Self.makeError(
                    api: api, model: model,
                    text: "OpenAI Responses returned status \(response.statusCode): \(bodyText)"
                )
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }
            let state = OpenAIResponsesState(api: api, provider: model.provider, modelId: model.id)
            state.signal = options?.cancellation
            _ = try await drive(events: parseSSE(bytes: stream), out: out, state: state)
        } catch {
            let msg = Self.makeError(api: api, model: model, text: "\(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
        }
    }

    private enum WebSocketRunResult {
        case completed
        case fallbackToHTTP
        case failedWithoutFallback
    }

    private func runWebSocket(
        client: WebSocketClient,
        url: URL,
        request: OpenAIResponsesRequest,
        out: AssistantMessageStream,
        model: Model,
        options: StreamOptions?,
        session: OpenAIResponsesSessionState
    ) async -> WebSocketRunResult {
        var headers = makeHeaders(options: options, accept: nil)
        // Match Codex's WebSocket transport: the Responses WebSocket beta
        // header replaces the HTTP/SSE `responses=experimental` beta.
        mergeHeader(&headers, name: "OpenAI-Beta", value: "responses_websockets=2026-02-06", append: false)
        let verboseSource = "openai.responses.websocket"

        switch session.beginWebSocketRun() {
        case .acquired:
            break
        case .disabled:
            await options?.emitVerbose(
                source: verboseSource,
                message: "WebSocket disabled after repeated failures; using HTTP"
            )
            return .fallbackToHTTP
        case .busy:
            await options?.emitVerbose(
                source: verboseSource,
                message: "WebSocket session already has an in-flight response; returning stream error"
            )
            let err = Self.makeError(
                api: api,
                model: model,
                text: "OpenAI Responses WebSocket session already has an in-flight response for this sessionId. Use a distinct sessionId for parallel runs."
            )
            out.push(.error(reason: .error, error: err))
            out.end(err)
            return .failedWithoutFallback
        }
        defer { session.endWebSocketRun() }

        var connection: (any WebSocketConnection)?
        var cancellationRegistration: CancellationRegistration?
        defer { cancellationRegistration?.cancel() }
        do {
            if let existing = session.takeConnection() {
                connection = existing
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "reusing WebSocket connection"
                )
            } else {
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "connecting",
                    metadata: ["url": .string(url.absoluteString)]
                )
                connection = try await client.connect(url: url, headers: headers)
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "connected"
                )
            }
            if let connection {
                session.storeConnection(connection)
                cancellationRegistration = options?.cancellation?.onCancel { _ in connection.close() }
            }
            let payload = try session.prepareWebSocketPayload(from: request)
            try await connection?.send(.text(payload.text))
            var metadata: [String: JSONValue] = [
                "input_count": .int(payload.inputCount),
                "incremental": .bool(payload.previousResponseId != nil),
            ]
            if let previousResponseId = payload.previousResponseId {
                metadata["previous_response_id"] = .string(previousResponseId)
            }
            await options?.emitVerbose(
                source: verboseSource,
                message: "sent response.create",
                metadata: metadata
            )
        } catch {
            let failure = session.recordWebSocketFailure(maxFailures: maxWebSocketFailures)
            await options?.emitVerbose(
                source: verboseSource,
                message: "WebSocket setup failed; falling back to HTTP",
                metadata: [
                    "disabled": .bool(failure.disabled),
                    "error": .string("\(error)"),
                    "failure_count": .int(failure.count),
                ]
            )
            return .fallbackToHTTP
        }
        guard let connection else {
            let failure = session.recordWebSocketFailure(maxFailures: maxWebSocketFailures)
            await options?.emitVerbose(
                source: verboseSource,
                message: "WebSocket setup failed; falling back to HTTP",
                metadata: [
                    "disabled": .bool(failure.disabled),
                    "error": .string("connection was nil"),
                    "failure_count": .int(failure.count),
                ]
            )
            return .fallbackToHTTP
        }

        let state = OpenAIResponsesState(api: api, provider: model.provider, modelId: model.id)
        state.signal = options?.cancellation
        let progress = WebSocketStreamProgress()
        do {
            let result = try await drive(
                events: webSocketEvents(from: connection),
                out: out,
                state: state,
                progress: progress,
                finishOnStreamEnd: false
            )
            if result.completed, let responseId = result.message.responseId {
                session.recordCompletedResponse(
                    responseId: responseId,
                    itemsAdded: Self.encodeAssistantOutputItems(result.message)
                )
                session.storeConnection(connection)
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "WebSocket response completed; failure count reset",
                    metadata: ["response_id": .string(responseId)]
                )
            } else if result.endedWithoutTerminalEvent {
                let failure = session.recordWebSocketFailure(maxFailures: maxWebSocketFailures)
                if !progress.hasReceivedEvent {
                    await options?.emitVerbose(
                        source: verboseSource,
                        message: "WebSocket closed before response event; falling back to HTTP",
                        metadata: [
                            "disabled": .bool(failure.disabled),
                            "failure_count": .int(failure.count),
                        ]
                    )
                    return .fallbackToHTTP
                }
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "WebSocket closed before completed response; returning stream error",
                    metadata: [
                        "disabled": .bool(failure.disabled),
                        "failure_count": .int(failure.count),
                    ]
                )
                let err = Self.makeError(
                    api: api,
                    model: model,
                    text: "WebSocket stream closed before response.completed"
                )
                out.push(.error(reason: .error, error: err))
                out.end(err)
                return .failedWithoutFallback
            } else {
                session.resetWebSocketState(resetFailureCount: progress.hasReceivedEvent)
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "WebSocket closed without completed response",
                    metadata: ["received_response_event": .bool(progress.hasReceivedEvent)]
                )
            }
            return .completed
        } catch {
            let failure = session.recordWebSocketFailure(maxFailures: maxWebSocketFailures)
            if !progress.hasReceivedEvent {
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "WebSocket failed before response event; falling back to HTTP",
                    metadata: [
                        "disabled": .bool(failure.disabled),
                        "error": .string("\(error)"),
                        "failure_count": .int(failure.count),
                    ]
                )
                return .fallbackToHTTP
            }
            await options?.emitVerbose(
                source: verboseSource,
                message: "WebSocket failed after response event; returning stream error",
                metadata: [
                    "disabled": .bool(failure.disabled),
                    "error": .string("\(error)"),
                    "failure_count": .int(failure.count),
                ]
            )
            let err = Self.makeError(api: api, model: model, text: "WebSocket stream failed: \(error)")
            out.push(.error(reason: .error, error: err))
            out.end(err)
            return .failedWithoutFallback
        }
    }

    private func makeHeaders(options: StreamOptions?, accept: String?) -> [String: String] {
        var headers: [String: String] = ["content-type": "application/json"]
        if let accept {
            headers["accept"] = accept
        }
        for (k, v) in extraHeaders { mergeHeader(&headers, name: k, value: v, append: false) }
        if let auth = options?.resolvedAuth {
            applyResolvedAuth(auth, to: &headers) { headers, name, value in
                mergeHeader(&headers, name: name, value: value, append: false)
            }
        } else if let key = options?.apiKey ?? defaultAPIKey {
            for (k, v) in authHeaderBuilder(key) {
                mergeHeader(&headers, name: k, value: v, append: false)
            }
        }
        for (k, v) in options?.headers ?? [:] {
            mergeHeader(&headers, name: k, value: v, append: false)
        }
        return headers
    }

    private func webSocketEvents(
        from connection: any WebSocketConnection
    ) -> WebSocketSSESequence {
        WebSocketSSESequence(connection: connection)
    }

    private func drive<S: AsyncSequence>(
        events: S,
        out: AssistantMessageStream,
        state: OpenAIResponsesState,
        progress: WebSocketStreamProgress? = nil,
        finishOnStreamEnd: Bool = true
    ) async throws -> OpenAIResponsesDriveResult where S.Element == SSEMessage {
        var emittedStart = false
        for try await sse in events {
            if state.signal?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return OpenAIResponsesDriveResult(message: aborted, completed: false)
            }
            guard case .object(let obj)? = parseJSONObject(sse.data),
                  case .string(let type) = obj["type"] ?? .null else { continue }
            if type.hasPrefix("response.") {
                progress?.markReceivedEvent()
            }

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
                        let arguments: String = {
                            if case .string(let v) = item["arguments"] ?? .null { return v }
                            return ""
                        }()
                        let index = state.noteFunctionCallItem(
                            outputIndex: outputIndex, callId: callId, name: name, arguments: arguments
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
                    if case .object(let item) = obj["item"] ?? .null,
                       case .string(let itemType) = item["type"] ?? .null,
                       itemType == "function_call" {
                        let callId: String? = {
                            if case .string(let v) = item["call_id"] ?? .null { return v }
                            if case .string(let v) = item["id"] ?? .null { return v }
                            return nil
                        }()
                        let name: String? = {
                            if case .string(let v) = item["name"] ?? .null { return v }
                            return nil
                        }()
                        let arguments: String? = {
                            if case .string(let v) = item["arguments"] ?? .null { return v }
                            return nil
                        }()
                        state.updateFunctionCallItem(
                            outputIndex: outputIndex,
                            callId: callId,
                            name: name,
                            arguments: arguments
                        )
                    }
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
                return OpenAIResponsesDriveResult(message: final, completed: true)

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
                return OpenAIResponsesDriveResult(message: err, completed: false)

            case "error":
                let text: String = {
                    if case .object(let err) = obj["error"] ?? .null,
                       case .string(let m) = err["message"] ?? .null { return m }
                    return "OpenAI Responses WebSocket error"
                }()
                let err = state.asError(text: text)
                out.push(.error(reason: .error, error: err))
                out.end(err)
                return OpenAIResponsesDriveResult(message: err, completed: false)

            default: break
            }
        }

        // Stream closed without explicit `response.completed`.
        let final = state.finalize()
        if finishOnStreamEnd {
            out.push(.done(reason: final.stopReason, message: final))
            out.end(final)
        }
        return OpenAIResponsesDriveResult(
            message: final,
            completed: false,
            endedWithoutTerminalEvent: true
        )
    }

    // MARK: - Encoding

    private static func makeRequest(
        model: Model, context: Context, options: StreamOptions?,
        bodyOverrides: [String: JSONValue] = [:]
    ) throws -> OpenAIResponsesRequest {
        var context = context
        context.messages = TransformMessages.normalize(context.messages, model: model)
        var root: [String: JSONValue] = [
            "model": .string(model.id),
            "stream": .bool(true),
            "input": .array(encodeInput(context: context)),
        ]
        if let maxTokens = options?.maxTokens ?? (model.maxTokens > 0 ? model.maxTokens : nil) {
            root["max_output_tokens"] = .int(maxTokens)
        }
        if let temp = options?.temperature { root["temperature"] = .double(temp) }
        if let sys = context.systemPrompt, !sys.isEmpty {
            root["instructions"] = .string(sys)
        }
        if let tools = context.tools, !tools.isEmpty {
            root["tools"] = .array(tools.map { tool -> JSONValue in
                var entry: [String: JSONValue] = [
                    "type": .string("function"),
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                ]
                entry["parameters"] = tool.parameters
                return .object(entry)
            })
            if let choice = encodeToolChoice(options?.toolChoice) {
                root["tool_choice"] = choice
            }
            if options?.parallelToolCalls == false {
                root["parallel_tool_calls"] = .bool(false)
            }
        }
        if let reasoning = options?.reasoning {
            // `summary: auto` opts into reasoning-summary deltas on the
            // stream (`response.reasoning_summary_text.delta`). Without
            // it, the endpoint still runs internal reasoning for the
            // requested `effort`, but the reasoning block streams as
            // start → end with no body — so the UI has nothing to show
            // under `[thinking]`.
            root["reasoning"] = .object([
                "effort": .string(reasoning.rawValue),
                "summary": .string("auto"),
            ])
        }
        if let meta = options?.metadata {
            root["metadata"] = .object(meta)
        }
        // Prompt caching: pin same-session requests to the same cache via
        // `prompt_cache_key`, and opt into 24h retention on `.long` when the
        // provider supports it. Skipped entirely on `.none`.
        let retention = options?.cacheRetention ?? .short
        if retention != .none, let sid = options?.sessionId, !sid.isEmpty {
            root["prompt_cache_key"] = .string(sid)
        }
        if retention == .long, model.compat?.supportsLongCacheRetention != false {
            root["prompt_cache_retention"] = .string("24h")
        }
        // Apply vendor-specific overrides last so they win against defaults.
        for (key, value) in bodyOverrides {
            root[key] = value
        }
        return OpenAIResponsesRequest(fields: root)
    }

    /// Convert our Message transcript into OpenAI Responses' `input` array.
    /// Each element is a typed item (`message`, `function_call`, or
    /// `function_call_output`). Assistant messages with tool calls expand
    /// into multiple items.
    private static func encodeInput(context: Context) -> [JSONValue] {
        var out: [JSONValue] = []
        for message in context.messages {
            switch message {
            case .user(let u):
                var parts: [JSONValue] = []
                for block in u.content {
                    switch block {
                    case .text(let t):
                        parts.append(.object(["type": .string("input_text"), "text": .string(t.text)]))
                    case .image(let i):
                        parts.append(.object([
                            "type": .string("input_image"),
                            "image_url": .string("data:\(i.mimeType);base64,\(i.data)"),
                        ]))
                    }
                }
                out.append(.object(["type": .string("message"), "role": .string("user"), "content": .array(parts)]))

            case .assistant(let a):
                let textParts: [JSONValue] = a.content.compactMap { block in
                    guard case .text(let t) = block, !t.text.isEmpty else { return nil }
                    return .object(["type": .string("output_text"), "text": .string(t.text)])
                }
                if !textParts.isEmpty {
                    out.append(.object([
                        "type": .string("message"),
                        "role": .string("assistant"),
                        "content": .array(textParts),
                    ]))
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
                        out.append(.object([
                            "type": .string("function_call"),
                            "call_id": .string(tc.id),
                            "name": .string(tc.name),
                            "arguments": .string(argsString),
                        ]))
                    }
                }

            case .toolResult(let tr):
                let text = tr.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined(separator: "\n")
                out.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(tr.toolCallId),
                    "output": .string(text),
                ]))
            }
        }
        return out
    }

    private static func encodeAssistantOutputItems(_ message: AssistantMessage) -> [JSONValue] {
        encodeInput(context: Context(messages: [.assistant(message)]))
    }

    private static func encodeToolChoice(_ choice: ToolChoice?) -> JSONValue? {
        guard let choice else { return nil }
        switch choice {
        case .auto: return .string("auto")
        case .none: return .string("none")
        case .required: return .string("required")
        case .tool(let name):
            return .object(["type": .string("function"), "name": .string(name)])
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

private struct OpenAIResponsesDriveResult: Sendable {
    var message: AssistantMessage
    var completed: Bool
    var endedWithoutTerminalEvent = false
}

private struct WebSocketSSESequence: AsyncSequence, Sendable {
    typealias Element = SSEMessage

    let connection: any WebSocketConnection

    func makeAsyncIterator() -> Iterator {
        Iterator(connection: connection)
    }

    struct Iterator: AsyncIteratorProtocol {
        let connection: any WebSocketConnection

        mutating func next() async throws -> SSEMessage? {
            while let message = try await connection.receive() {
                switch message {
                case .text(let text):
                    return SSEMessage(event: "message", data: text, id: nil)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        return SSEMessage(event: "message", data: text, id: nil)
                    }
                }
            }
            return nil
        }
    }
}

private final class WebSocketStreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedEvent = false

    var hasReceivedEvent: Bool {
        lock.withLock { receivedEvent }
    }

    func markReceivedEvent() {
        lock.withLock { receivedEvent = true }
    }
}

private struct OpenAIResponsesRequest: Sendable, Equatable {
    var fields: [String: JSONValue]

    var input: [JSONValue] {
        if case .array(let input) = fields["input"] ?? .null { return input }
        return []
    }

    func withoutInput() -> OpenAIResponsesRequest {
        var copy = self
        copy.fields["input"] = .array([])
        return copy
    }

    func data() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: anyFromJSONValue(.object(fields)) ?? [:],
            options: [.sortedKeys]
        )
    }

    func webSocketPayload(previousResponseId: String? = nil, input: [JSONValue]? = nil) throws -> String {
        var payload = fields
        payload["type"] = .string("response.create")
        if let previousResponseId {
            payload["previous_response_id"] = .string(previousResponseId)
        }
        if let input {
            payload["input"] = .array(input)
        }
        let data = try JSONSerialization.data(
            withJSONObject: anyFromJSONValue(.object(payload)) ?? [:],
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private struct OpenAIResponsesLastResponse: Sendable {
    var responseId: String
    var itemsAdded: [JSONValue]
}

private struct OpenAIResponsesWebSocketFailureStatus: Sendable {
    var count: Int
    var disabled: Bool
}

private struct OpenAIResponsesWebSocketPayload: Sendable {
    var text: String
    var previousResponseId: String?
    var inputCount: Int
}

private enum OpenAIResponsesWebSocketRunLease: Sendable {
    case acquired
    case busy
    case disabled
}

private final class OpenAIResponsesSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: OpenAIResponsesSessionState] = [:]

    func session(for sessionId: String?) -> OpenAIResponsesSessionState {
        guard let sessionId, !sessionId.isEmpty else {
            return OpenAIResponsesSessionState()
        }
        return lock.withLock {
            if let existing = sessions[sessionId] { return existing }
            let created = OpenAIResponsesSessionState()
            sessions[sessionId] = created
            return created
        }
    }

    func closeSession(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let session = lock.withLock { sessions.removeValue(forKey: sessionId) }
        session?.close()
    }
}

private final class OpenAIResponsesSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: (any WebSocketConnection)?
    private var lastRequest: OpenAIResponsesRequest?
    private var lastResponse: OpenAIResponsesLastResponse?
    private var webSocketFailureCount = 0
    private var disabled = false
    private var webSocketInFlight = false
    private var closed = false

    deinit {
        close()
    }

    var webSocketDisabled: Bool {
        lock.withLock { disabled || closed }
    }

    func beginWebSocketRun() -> OpenAIResponsesWebSocketRunLease {
        lock.withLock {
            if disabled || closed { return .disabled }
            if webSocketInFlight { return .busy }
            webSocketInFlight = true
            return .acquired
        }
    }

    func endWebSocketRun() {
        lock.withLock { webSocketInFlight = false }
    }

    func takeConnection() -> (any WebSocketConnection)? {
        lock.withLock {
            let existing = connection
            connection = nil
            return existing
        }
    }

    func storeConnection(_ next: any WebSocketConnection) {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return true }
            connection = next
            return false
        }
        if shouldClose {
            next.close()
        }
    }

    @discardableResult
    func recordWebSocketFailure(maxFailures: Int) -> OpenAIResponsesWebSocketFailureStatus {
        let result = lock.withLock { () -> (old: (any WebSocketConnection)?, status: OpenAIResponsesWebSocketFailureStatus) in
            webSocketFailureCount += 1
            if webSocketFailureCount >= max(1, maxFailures) {
                disabled = true
            }
            let old = connection
            connection = nil
            lastRequest = nil
            lastResponse = nil
            return (
                old,
                OpenAIResponsesWebSocketFailureStatus(
                    count: webSocketFailureCount,
                    disabled: disabled
                )
            )
        }
        result.old?.close()
        return result.status
    }

    func resetWebSocketState(disable: Bool = false, resetFailureCount: Bool = false) {
        let old = lock.withLock { () -> (any WebSocketConnection)? in
            if disable { disabled = true }
            if resetFailureCount { webSocketFailureCount = 0 }
            let old = connection
            connection = nil
            lastRequest = nil
            lastResponse = nil
            return old
        }
        old?.close()
    }

    func close() {
        let old = lock.withLock { () -> (any WebSocketConnection)? in
            closed = true
            disabled = true
            webSocketInFlight = false
            let old = connection
            connection = nil
            lastRequest = nil
            lastResponse = nil
            return old
        }
        old?.close()
    }

    func prepareWebSocketPayload(from request: OpenAIResponsesRequest) throws -> OpenAIResponsesWebSocketPayload {
        let payload = lock.withLock { () -> (previousResponseId: String?, input: [JSONValue]?) in
            defer { lastRequest = request }
            guard let previous = lastRequest,
                  let response = lastResponse,
                  !response.responseId.isEmpty,
                  previous.withoutInput() == request.withoutInput()
            else {
                return (nil, nil)
            }

            let baseline = previous.input + response.itemsAdded
            let input = request.input
            guard input.count >= baseline.count,
                  Array(input.prefix(baseline.count)) == baseline
            else {
                return (nil, nil)
            }

            return (response.responseId, Array(input.dropFirst(baseline.count)))
        }
        let text = try request.webSocketPayload(
            previousResponseId: payload.previousResponseId,
            input: payload.input
        )
        return OpenAIResponsesWebSocketPayload(
            text: text,
            previousResponseId: payload.previousResponseId,
            inputCount: payload.input?.count ?? request.input.count
        )
    }

    func recordCompletedResponse(responseId: String, itemsAdded: [JSONValue]) {
        lock.withLock {
            webSocketFailureCount = 0
            lastResponse = OpenAIResponsesLastResponse(
                responseId: responseId,
                itemsAdded: itemsAdded
            )
        }
    }
}

private func mergeHeader(
    _ headers: inout [String: String],
    name: String,
    value: String,
    append: Bool
) {
    if let existingKey = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
        if append, !headers[existingKey, default: ""].isEmpty {
            let existing = headers[existingKey] ?? ""
            if !existing
                .split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .contains(value) {
                headers[existingKey] = "\(existing), \(value)"
            }
        } else {
            headers[existingKey] = value
        }
    } else {
        headers[name] = value
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

    func noteFunctionCallItem(outputIndex: Int, callId: String, name: String, arguments: String = "") -> Int {
        lock.withLock {
            if let existing = toolCallByOutput[outputIndex] { return existing }
            let idx = order.count
            toolCallByOutput[outputIndex] = idx
            order.append(idx)
            blocks[idx] = .toolUse(id: callId, name: name, json: arguments)
            return idx
        }
    }

    func updateFunctionCallItem(outputIndex: Int, callId: String?, name: String?, arguments: String?) {
        lock.withLock {
            guard let index = toolCallByOutput[outputIndex],
                  case .toolUse(let currentId, let currentName, let currentJSON) = blocks[index]
            else { return }
            blocks[index] = .toolUse(
                id: callId ?? currentId,
                name: name ?? currentName,
                json: arguments ?? currentJSON
            )
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
