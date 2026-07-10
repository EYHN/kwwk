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
            var base = model.baseURL.isEmpty ? fallback.absoluteString : model.baseURL
            while base.hasSuffix("/") { base.removeLast() }
            // Tolerate catalog entries that bake `/v1` into baseURL
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
                    for try await chunk in stream { body.append(chunk) }
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
            // Bridge external cancellation to the in-flight request (see
            // AnthropicProvider.run for the rationale).
            let driveTask = Task { _ = try await self.drive(events: parseSSE(bytes: stream), out: out, state: state) }
            let cancelReg = options?.cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelReg?.cancel() }
            try await driveTask.value
        } catch {
            if options?.cancellation?.isCancelled == true {
                let aborted = Self.makeAborted(api: api, model: model)
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let msg = Self.makeError(api: api, model: model, text: "\(error)")
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
            }
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
        let state = OpenAIResponsesState(api: api, provider: model.provider, modelId: model.id)
        state.signal = options?.cancellation
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
            if state.signal?.isCancelled == true {
                session.resetWebSocketState()
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "WebSocket stream cancelled during setup"
                )
                Self.finishAborted(out: out, state: state)
                return .completed
            }
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
                    itemsAdded: Self.encodeAssistantOutputItems(result.message, model: model)
                )
                session.storeConnection(connection)
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "WebSocket response completed; failure count reset",
                    metadata: ["response_id": .string(responseId)]
                )
            } else if result.endedWithoutTerminalEvent {
                if state.signal?.isCancelled == true {
                    session.resetWebSocketState()
                    await options?.emitVerbose(
                        source: verboseSource,
                        message: "WebSocket stream cancelled"
                    )
                    Self.finishAborted(out: out, state: state)
                    return .completed
                }
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
            if state.signal?.isCancelled == true {
                session.resetWebSocketState()
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "WebSocket stream cancelled",
                    metadata: ["error": .string("\(error)")]
                )
                Self.finishAborted(out: out, state: state)
                return .completed
            }
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

    private static func finishAborted(out: AssistantMessageStream, state: OpenAIResponsesState) {
        let aborted = state.asAborted()
        out.push(.error(reason: .aborted, error: aborted))
        out.end(aborted)
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
                        // Persist the full reasoning item (including
                        // `encrypted_content` and its `id`) on the thinking
                        // block's signature so encrypted reasoning round-trips
                        // across turns when the response isn't stored
                        // server-side (`store: false`). Mirrors pi.
                        if case .object(let item) = obj["item"] ?? .null,
                           case .string = item["encrypted_content"] ?? .null,
                           let serialized = Self.serializeReasoningItem(item) {
                            state.setThinkingSignature(at: index, signature: serialized)
                        }
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

            case "response.incomplete":
                // Terminal event when the response is truncated (e.g.
                // `max_output_tokens` reached). A length-truncated turn is a
                // normal completion, not a transport failure — finish via the
                // same success path as `response.completed` with `.length` so
                // it isn't misreported as `.stop` over HTTP or as a WebSocket
                // failure that eventually disables the transport.
                if case .object(let response) = obj["response"] ?? .null {
                    if case .object(let usage) = response["usage"] ?? .null {
                        state.applyUsage(usage)
                    }
                }
                state.stopReason = .length
                let incomplete = state.finalize()
                out.push(.done(reason: incomplete.stopReason, message: incomplete))
                out.end(incomplete)
                return OpenAIResponsesDriveResult(message: incomplete, completed: true)

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

        // Stream closed without an explicit terminal event. On the HTTP path a
        // cancellation during a silent gap tears the stream down here; surface
        // it as aborted rather than a clean stop. (The WebSocket path handles
        // its own cancellation via `endedWithoutTerminalEvent` in runWebSocket.)
        if finishOnStreamEnd, state.signal?.isCancelled == true {
            let aborted = state.asAborted()
            out.push(.error(reason: .aborted, error: aborted))
            out.end(aborted)
            return OpenAIResponsesDriveResult(
                message: aborted,
                completed: false,
                endedWithoutTerminalEvent: true
            )
        }
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
            "input": .array(encodeInput(context: context, model: model)),
        ]
        if let maxTokens = OutputTokenPolicy.effectiveLimit(
            for: model,
            requested: options?.maxTokens
        ) {
            root["max_output_tokens"] = .int(maxTokens)
        }
        if let temp = options?.temperature { root["temperature"] = .double(temp) }
        // Processing-tier pass-through (pi openai-responses.ts:253-255). Cost
        // multipliers are computed downstream in AgentLoop, which has no
        // service-tier awareness, so only the request field is ported here.
        if let serviceTier = options?.serviceTier {
            root["service_tier"] = .string(serviceTier.rawValue)
        }
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
        // Reasoning, mirroring pi's three-way structure (openai-responses.ts
        // :261-276). Only fires for reasoning-capable models. When an effort or
        // summary is requested we emit the active branch; otherwise we emit a
        // disabled `reasoning:{effort:off}` (unless the model maps `off` to
        // explicit null, or the provider is github-copilot).
        if model.reasoning {
            let requestedLevel: ModelThinkingLevel? = options?.reasoning.map {
                ModelThinkingLevel(reasoning: $0)
            }
            let hasEffort = requestedLevel != nil
            let summary = options?.reasoningSummary
            let hasSummary = summary != nil

            if hasEffort || hasSummary {
                // Remap the effort through `thinkingLevelMap` (e.g. a model that
                // aliases `xhigh`), matching pi, instead of sending the raw
                // level. Defaults to `medium` when only a summary was requested.
                let effort: String = {
                    if let lvl = requestedLevel {
                        return resolveThinkingLevel(model, lvl) ?? lvl.rawValue
                    }
                    return "medium"
                }()
                var reasoning: [String: JSONValue] = ["effort": .string(effort)]
                // `summary: auto` opts into reasoning-summary deltas on the
                // stream (`response.reasoning_summary_text.delta`). `.omit`
                // drops the key entirely so the reasoning block streams as
                // start → end with no body.
                switch summary {
                case nil, .some(.auto): reasoning["summary"] = .string("auto")
                case .some(.concise): reasoning["summary"] = .string("concise")
                case .some(.detailed): reasoning["summary"] = .string("detailed")
                case .some(.omit): break
                }
                root["reasoning"] = .object(reasoning)
                // Required so encrypted reasoning round-trips across turns when
                // the response isn't persisted server-side (`store: false`).
                root["include"] = .array([.string("reasoning.encrypted_content")])
            } else if model.provider != "github-copilot" {
                // Disabled-reasoning branch. `thinkingLevelMap.off`:
                // absent / explicit-null / string (matches Completions
                // OpenAICompletionsProvider.swift:504-506). Explicit null means
                // the model doesn't support a disabled state — omit entirely.
                let offEntry = model.thinkingLevelMap?["off"]
                let offIsExplicitNull = (offEntry != nil && offEntry! == nil)
                if !offIsExplicitNull {
                    let offString: String = {
                        if let e = offEntry, let v = e { return v }
                        return "none"
                    }()
                    root["reasoning"] = .object(["effort": .string(offString)])
                }
            }
        }
        if let meta = options?.metadata {
            root["metadata"] = .object(meta)
        }
        // Prompt caching: pin same-session requests to the same cache via
        // `prompt_cache_key`, and opt into 24h retention on `.long` when the
        // provider supports it. Skipped entirely on `.none`.
        let retention = options?.cacheRetention ?? .short
        if retention != .none,
           let sid = OpenAICompletionsProvider.clampOpenAIPromptCacheKey(options?.sessionId) {
            root["prompt_cache_key"] = .string(sid)
        }
        if retention == .long, model.compat?.supportsLongCacheRetention != false {
            root["prompt_cache_retention"] = .string("24h")
        }
        // Don't persist responses server-side — kwwk replays the full input each
        // turn, and ChatGPT/Codex proxies reject `store: true`. Matches pi.
        // Placed before overrides so callers can still opt back in.
        if root["store"] == nil { root["store"] = .bool(false) }
        // Apply vendor-specific overrides last so they win against defaults.
        for (key, value) in bodyOverrides {
            root[key] = value
        }
        return OpenAIResponsesRequest(fields: root)
    }

    /// Convert our Message transcript into OpenAI Responses' `input` array.
    /// Each element is a typed item (`reasoning`, `message`, `function_call`,
    /// or `function_call_output`). Assistant messages with tool calls expand
    /// into multiple items.
    private static func encodeInput(context: Context, model: Model) -> [JSONValue] {
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
                // Replay captured encrypted reasoning items so the model keeps
                // its prior chain-of-thought across turns. Only valid for the
                // same model/api/provider (encrypted_content is model-bound) and
                // only when the stored signature is an actual reasoning item.
                let sameModel = a.provider == model.provider
                    && a.api == model.api && a.model == model.id
                if sameModel {
                    for block in a.content {
                        guard case .thinking(let th) = block,
                              let sig = th.thinkingSignature, !sig.isEmpty,
                              let item = Self.parseReasoningItem(sig) else { continue }
                        out.append(.object(item))
                    }
                }
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

    private static func encodeAssistantOutputItems(_ message: AssistantMessage, model: Model) -> [JSONValue] {
        encodeInput(context: Context(messages: [.assistant(message)]), model: model)
    }

    /// Serialize a streamed reasoning item (the full `item` object from
    /// `response.output_item.done`, including `encrypted_content` and `id`) to a
    /// JSON string for storage on the thinking block's signature.
    private static func serializeReasoningItem(_ item: [String: JSONValue]) -> String? {
        guard let any = anyFromJSONValue(.object(item)),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Parse a stored reasoning-item signature back into its object form,
    /// validating that it is actually a `reasoning` item (so signatures from
    /// other providers' formats are never mis-replayed as reasoning).
    private static func parseReasoningItem(_ serialized: String) -> [String: JSONValue]? {
        guard let data = serialized.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = value,
              case .string("reasoning")? = obj["type"] else { return nil }
        return obj
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

    private static func makeAborted(api: String, model: Model) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: api,
            provider: model.provider,
            model: model.id,
            usage: Usage(),
            stopReason: .aborted,
            errorMessage: "Request was aborted",
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

    func setThinkingSignature(at index: Int, signature: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinkingSignature = signature
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

    /// Streaming snapshot. In-progress tool calls use an empty-object
    /// placeholder rather than re-parsing the growing JSON buffer on every
    /// delta (O(n^2)); full arguments are parsed once in `finalize`
    /// (and in `toolCallValue` for the `toolCallEnd` event).
    func snapshot() -> AssistantMessage { buildMessage(parseToolArgs: false) }

    private func buildMessage(parseToolArgs: Bool) -> AssistantMessage {
        lock.withLock {
            AssistantMessage(
                content: order.compactMap { idx -> AssistantBlock? in
                    switch blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(let id, let name, let json):
                        let args: JSONValue = parseToolArgs ? parseArguments(json) : .object([:])
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
                errorMessage: errorMessage,
                timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage { buildMessage(parseToolArgs: true) }

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
