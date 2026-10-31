import Foundation
import Crypto
import NIOConcurrencyHelpers
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
public final class OpenAIResponsesProvider:
    APIProvider,
    APIProviderSessionLifecycle,
    NativeCompactionProvider,
    @unchecked Sendable
{
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
        webSocketClient: WebSocketClient? = URLSessionWebSocketClient.platformDefault,
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

    public func compact(
        model: Model,
        context: Context,
        instructions: String,
        options: StreamOptions?
    ) async throws -> NativeCompactionResult? {
        guard model.compat?.supportsServerCompaction != false,
              model.api == "chatgpt-codex" || model.compat?.supportsServerCompaction == true else { return nil }
        let codex = model.api == "chatgpt-codex"
        let responsesURL = urlBuilder(model, options, defaultBaseURL)
        let url = codex ? responsesURL : responsesURL.appendingPathComponent("compact")
        var nativeContext = context
        // Compaction sends the full tool list; in-place tool changes would
        // otherwise leave later tools out of both `tools` and `input`.
        let refusedSeals = sessions.session(for: options?.sessionId).refusedSeals
        nativeContext.messages = TransformMessages.normalize(
            Self.unsealingRefusedCompactions(
                TranscriptTools.withoutSystemMessages(context.messages),
                refusedSeals: refusedSeals
            ),
            model: model
        )
        let input = Self.encodeInput(context: nativeContext, model: model, refusedSeals: refusedSeals)
        var body: [String: JSONValue] = [
            "model": .string(model.id),
            "input": .array(input),
            "instructions": .string(context.systemPrompt ?? ""),
        ]
        if codex {
            // ChatGPT subscriptions expose V2 on /responses, not V1's
            // /responses/compact. Reuse the live request serializer.
            let request = try Self.makeRequest(
                model: model,
                context: nativeContext,
                options: options,
                bodyOverrides: bodyOverrides,
                refusedSeals: refusedSeals
            )
            body = request.fields
            body["input"] = .array(input + [["type": "compaction_trigger"]])
            body["store"] = false
            body["stream"] = true
        }
        var headers = model.headers ?? [:]
        for (key, value) in makeHeaders(options: options, accept: codex ? "text/event-stream" : "application/json") {
            mergeHeader(&headers, name: key, value: value, append: false)
        }
        if let sessionId = options?.sessionId { headers["session_id"] = sessionId }
        let json: [String: JSONValue]
        if codex {
            let compacted = try await client.compactionSSE(
                url: url,
                headers: headers,
                body: JSONEncoder().encode(body),
                cancellation: options?.cancellation
            )
            // V2 compacts assistant history; original user messages remain
            // part of the replacement input, as in omp/Codex.
            let retained = input.filter { $0["role"] == .string("user") }
            json = ["output": .array(retained + [compacted])]
        } else {
            json = try await client.compactionJSON(
                url: url,
                headers: headers,
                body: JSONEncoder().encode(body),
                cancellation: options?.cancellation
            )
        }
        guard case .array(let output) = json["output"], output.contains(where: {
            guard case .object(let item) = $0 else { return false }
            if item["type"] == .string("compaction"), case .string(let data) = item["encrypted_content"] {
                return !data.isEmpty
            }
            if item["type"] == .string("compaction_summary"), case .string(let text) = item["summary"] {
                return !text.isEmpty
            }
            return false
        }) else { throw ProviderFailure(message: "Codex compaction returned no compaction item") }
        // Response-only statuses must not be replayed as input fields.
        let items = output.map { item -> JSONValue in
            guard case .object(var object) = item else { return item }
            object.removeValue(forKey: "status")
            return .object(object)
        }
        return NativeCompactionResult(
            summary: "Earlier conversation is preserved in provider-native compacted context.",
            payload: NativeCompactionPayload(
                model: model,
                items: items,
                fallbackMessages: TransformMessages.expandNativeCompaction(context.messages)
            )
        )
    }

    private func run(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        let session = sessions.session(for: options?.sessionId)
        // A refusal of replayed sealed items is answered once by asking again
        // without them (see `isForeignSeal`).
        if await attempt(out: out, model: model, context: context, options: options,
                         session: session, holdSealRefusal: true) == .sealsRefused {
            await options?.emitVerbose(
                source: "openai.responses",
                message: "replayed encrypted content was refused; asking again without it"
            )
            _ = await attempt(
                out: out,
                model: model,
                context: context,
                options: options,
                session: session,
                holdSealRefusal: false
            )
        }
    }

    private enum AttemptResult {
        case finished
        /// Nothing reached `out`; the seals of the request are now recorded
        /// on the session and the next request leaves them out.
        case sealsRefused
    }

    private func attempt(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?,
        session: OpenAIResponsesSessionState,
        holdSealRefusal: Bool
    ) async -> AttemptResult {
        let url = urlBuilder(model, options, defaultBaseURL)

        let request: OpenAIResponsesRequest
        do {
            request = try Self.makeRequest(
                model: model,
                context: context,
                options: options,
                bodyOverrides: bodyOverrides,
                refusedSeals: session.refusedSeals
            )
        } catch {
            let msg = AssistantMessage.makeError(api: api, model: model, text: "Failed to encode request: \(error.displayDescription)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return .finished
        }

        // Only a request that carries seals can be asked again without them.
        let seals = Self.seals(in: request.input)
        let holdSealRefusal = holdSealRefusal && !seals.isEmpty
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
                session: session,
                holdSealRefusal: holdSealRefusal
            )
            switch wsResult {
            case .completed:
                return .finished
            case .sealsRefused:
                session.refuse(seals: seals)
                return .sealsRefused
            case .fallbackToHTTP:
                await options?.emitVerbose(
                    source: "openai.responses.http",
                    message: "falling back to HTTP stream"
                )
                break
            case .failedWithoutFallback:
                return .finished
            }
        } else if transport != .sse, session.webSocketDisabled {
            await options?.emitVerbose(
                source: "openai.responses.websocket",
                message: "WebSocket disabled after repeated failures; using HTTP"
            )
        }

        if await runHTTP(
            url: url,
            request: request,
            out: out,
            model: model,
            options: options,
            holdSealRefusal: holdSealRefusal
        ) {
            session.refuse(seals: seals)
            return .sealsRefused
        }
        return .finished
    }

    /// Returns true when the request was refused over its sealed items and
    /// `holdSealRefusal` kept that refusal off `out`.
    private func runHTTP(
        url: URL,
        request: OpenAIResponsesRequest,
        out: AssistantMessageStream,
        model: Model,
        options: StreamOptions?,
        holdSealRefusal: Bool
    ) async -> Bool {
        var headers = makeHeaders(options: options, accept: "text/event-stream")
        Self.nameXaiConversation(&headers, model: model, options: options)
        await options?.emitVerbose(
            source: "openai.responses.http",
            message: "starting HTTP stream",
            metadata: ["url": .string(url.absoluteString)]
        )

        do {
            var (response, stream) = try await client.stream(
                url: url,
                method: "POST",
                headers: headers,
                body: try request.data(),
                cancellation: options?.cancellation
            )
            if response.statusCode >= 400 {
                let failure = Self.readingDetail(await ProviderFailure.http(response, body: stream))
                if holdSealRefusal, Self.isForeignSeal(failure) { return true }
                let msg = AssistantMessage.makeError(api: api, model: model, text: failure.message, failure: failure)
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return false
            }
            if let failure = try await Self.notAnEventStream(response, body: &stream) {
                let msg = AssistantMessage.makeError(api: api, model: model, text: failure.message, failure: failure)
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return false
            }
            let state = OpenAIResponsesState(api: api, provider: model.provider, modelId: model.id)
            state.signal = options?.cancellation
            // Bridge external cancellation to the in-flight request (see
            // AnthropicProvider.run for the rationale).
            let driveTask = Task {
                try await self.drive(
                    events: parseSSE(bytes: stream),
                    out: out,
                    state: state,
                    holdSealRefusal: holdSealRefusal
                ).sealsRefused
            }
            let cancelReg = options?.cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelReg?.cancel() }
            return try await driveTask.value
        } catch {
            if options?.cancellation?.isCancelled == true {
                let aborted = AssistantMessage.makeAborted(api: api, model: model)
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let failure = ProviderFailure.capture(error)
                let msg = AssistantMessage.makeError(api: api, model: model, text: failure.message, failure: failure)
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
            }
            return false
        }
    }

    private enum WebSocketRunResult {
        case completed
        case fallbackToHTTP
        case failedWithoutFallback
        case sealsRefused
    }

    private func runWebSocket(
        client: WebSocketClient,
        url: URL,
        request: OpenAIResponsesRequest,
        out: AssistantMessageStream,
        model: Model,
        options: StreamOptions?,
        session: OpenAIResponsesSessionState,
        holdSealRefusal: Bool = false
    ) async -> WebSocketRunResult {
        var headers = makeHeaders(options: options, accept: nil)
        Self.nameXaiConversation(&headers, model: model, options: options)
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
            let err = AssistantMessage.makeError(
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
            if !Self.permitsWebSocketFallback(error) {
                session.resetWebSocketState()
                Self.finishWebSocketFailure(error, out: out, state: state)
                return .failedWithoutFallback
            }
            let failure = session.recordWebSocketFailure(maxFailures: maxWebSocketFailures)
            await options?.emitVerbose(
                source: verboseSource,
                message: "WebSocket setup failed; falling back to HTTP",
                metadata: [
                    "disabled": .bool(failure.disabled),
                    "error": .string(error.displayDescription),
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
                finishOnStreamEnd: false,
                holdSealRefusal: holdSealRefusal
            )
            if result.sealsRefused {
                // The refused request must not stay the baseline the next
                // one is sent as an increment of.
                session.resetWebSocketState()
                return .sealsRefused
            }
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
                let err = AssistantMessage.makeError(
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
                    metadata: ["error": .string(error.displayDescription)]
                )
                Self.finishAborted(out: out, state: state)
                return .completed
            }
            if !Self.permitsWebSocketFallback(error) {
                session.resetWebSocketState()
                Self.finishWebSocketFailure(error, out: out, state: state)
                return .failedWithoutFallback
            }
            let failure = session.recordWebSocketFailure(maxFailures: maxWebSocketFailures)
            if !progress.hasReceivedEvent {
                await options?.emitVerbose(
                    source: verboseSource,
                    message: "WebSocket failed before response event; falling back to HTTP",
                    metadata: [
                        "disabled": .bool(failure.disabled),
                        "error": .string(error.displayDescription),
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
                    "error": .string(error.displayDescription),
                    "failure_count": .int(failure.count),
                ]
            )
            let err = AssistantMessage.makeError(
                api: api,
                model: model,
                text: "WebSocket stream failed: \(error.displayDescription)",
                failure: .capture(error)
            )
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
        // The ChatGPT backend finds a conversation's prompt cache by its
        // session headers, not by the body's `prompt_cache_key`. Measured
        // 2026-10-11 on a 5.4K-token prompt with 13 tools: key in the body
        // only, cached 0 on three requests; with these headers 0, 4608, 4608
        // (magpie #1473 saw the same). The names are the ones Codex CLI
        // 0.162 sends; the WebSocket handshake takes them too.
        if api == "chatgpt-codex", (options?.cacheRetention ?? .short) != .none,
           let sid = OpenAICompletionsProvider.clampOpenAIPromptCacheKey(options?.sessionId) {
            headers["session-id"] = sid
            headers["thread-id"] = sid
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

    // MARK: - xAI

    /// xAI's own API, by provider or host. Its rules below are the ones the
    /// Grok Build backend applies too (magpie-plugins packages/grok).
    static func isXai(_ model: Model) -> Bool {
        model.provider == "xai" || model.baseURL.lowercased().contains("api.x.ai")
    }

    /// Grok keys a conversation's prompt cache by the `x-grok-conv-id`
    /// header: the Grok Build CLI sends the request's `prompt_cache_key`
    /// there (magpie-plugins packages/grok index.mjs, README "Requests").
    /// Sent on the same terms as the body's key; a caller's own header wins.
    static func nameXaiConversation(_ headers: inout [String: String], model: Model, options: StreamOptions?) {
        guard isXai(model), (options?.cacheRetention ?? .short) != .none,
              let sid = OpenAICompletionsProvider.clampOpenAIPromptCacheKey(options?.sessionId),
              !headers.keys.contains(where: { $0.lowercased() == "x-grok-conv-id" }) else { return }
        headers["x-grok-conv-id"] = sid
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
        finishOnStreamEnd: Bool = true,
        holdSealRefusal: Bool = false
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
                            outputIndex: outputIndex,
                            callId: callId,
                            name: name,
                            arguments: arguments
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

            case "response.reasoning_summary_part.added":
                // Each summary part opens with its own bold title; set the
                // parts apart as paragraphs rather than running them together.
                if case .int(let outputIndex) = obj["output_index"] ?? .null,
                   case .int(let summaryIndex) = obj["summary_index"] ?? .null,
                   summaryIndex > 0,
                   let index = state.reasoningIndex(for: outputIndex) {
                    let separator = "\n\n"
                    state.appendThinking(at: index, text: separator)
                    out.push(.thinkingDelta(contentIndex: index, delta: separator, partial: state.snapshot()))
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
                    if case .array(let outputItems) = response["output"] ?? .null {
                        Self.backfillReasoningSignatures(outputItems, state: state)
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
                    if case .object(let details) = response["incomplete_details"],
                       case .string(let reason) = details["reason"], reason != "max_output_tokens" {
                        var error = state.asError(text: "OpenAI Responses incomplete: \(reason)")
                        error.failure = ProviderFailure(
                            message: error.errorMessage!,
                            rawStopReason: reason,
                            stopDetails: .object(details)
                        )
                        out.push(.error(reason: .error, error: error))
                        out.end(error)
                        return OpenAIResponsesDriveResult(message: error, completed: false)
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
                var err = state.asError(text: text)
                err.failure = ProviderFailure.payload(obj["response"] ?? .object(obj), fallback: text)
                if holdSealRefusal, !emittedStart, let failure = err.failure, Self.isForeignSeal(failure) {
                    return OpenAIResponsesDriveResult(message: err, completed: false, sealsRefused: true)
                }
                out.push(.error(reason: .error, error: err))
                out.end(err)
                return OpenAIResponsesDriveResult(message: err, completed: false)

            case "error":
                // Two shapes: the error nested, as the ChatGPT backend sends
                // it ({"type":"error","error":{…},"status":400}, measured over
                // WebSocket 2026-10-11), and the API's own with code and
                // message at the top level.
                let text: String = {
                    if case .object(let err) = obj["error"] ?? .null,
                       case .string(let m) = err["message"] ?? .null { return m }
                    if case .string(let m) = obj["message"] ?? .null { return m }
                    return "OpenAI Responses error"
                }()
                var err = state.asError(text: text)
                err.failure = ProviderFailure.payload(obj["response"] ?? .object(obj), fallback: text)
                if holdSealRefusal, !emittedStart, let failure = err.failure, Self.isForeignSeal(failure) {
                    return OpenAIResponsesDriveResult(message: err, completed: false, sealsRefused: true)
                }
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
        let final: AssistantMessage
        if finishOnStreamEnd {
            final = state.asError(text: "OpenAI Responses stream ended before a terminal response event")
            out.push(.error(reason: .error, error: final))
            out.end(final)
        } else { final = state.finalize() }
        return OpenAIResponsesDriveResult(
            message: final,
            completed: false,
            endedWithoutTerminalEvent: true
        )
    }

    // MARK: - Encoding

    /// A transport switch is not a second chance at a rejected API request.
    /// Explicit HTTP/provider failures go to the shared policy, which also
    /// honors Retry-After. Only pre-output transport/setup failures may fall back.
    private static func permitsWebSocketFallback(_ error: any Error) -> Bool {
        let failure = ProviderFailure.capture(error)
        guard failure.httpStatus == nil, failure.providerCode == nil, failure.shouldRetry != false else { return false }
        switch failure.category {
        case .transport, .timeout, .unknown: return true
        default: return false
        }
    }

    private static func finishWebSocketFailure(
        _ error: any Error,
        out: AssistantMessageStream,
        state: OpenAIResponsesState
    ) {
        let failure = ProviderFailure.capture(error)
        if failure.category == .cancelled {
            finishAborted(out: out, state: state)
            return
        }
        var message = state.asError(text: failure.message)
        message.failure = failure
        out.push(.error(reason: .error, error: message))
        out.end(message)
    }

    // MARK: - Refused seals

    /// OpenAI and the ChatGPT backend refuse reasoning or a compaction that
    /// another account or organisation sealed, and anything altered since:
    /// 400 `invalid_encrypted_content`, "The encrypted content for item rs_…
    /// could not be verified. Reason: Encrypted content could not be
    /// decrypted or parsed." (measured 2026-10-11 over HTTP and, as an
    /// `error` event with `status: 400`, over WebSocket). xAI words it "Could
    /// not decrypt the provided encrypted_content" (magpie affinity.go). The
    /// items ride on every later request, so the conversation stays refused
    /// until they are left out (magpie #63).
    static func isForeignSeal(_ failure: ProviderFailure) -> Bool {
        if let status = failure.httpStatus, status != 400 { return false }
        if failure.providerCode == "invalid_encrypted_content" { return true }
        return failure.message.range(
            of: #"invalid_encrypted_content|encrypted[ _]content.{0,80}could not be (verified|decrypted)|could not (decrypt|verify).{0,40}encrypted[ _]content"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What a sealed input item is remembered by.
    private static func seal(of item: JSONValue) -> String? {
        guard case .string(let type) = item["type"],
              ["reasoning", "compaction", "compaction_summary"].contains(type),
              case .string(let sealed) = item["encrypted_content"], !sealed.isEmpty else { return nil }
        return SHA256.hash(data: Data(sealed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func seals(in input: [JSONValue]) -> Set<String> {
        Set(input.compactMap(seal(of:)))
    }

    private static func isRefused(_ item: JSONValue, _ refusedSeals: Set<String>) -> Bool {
        guard !refusedSeals.isEmpty, let seal = seal(of: item) else { return false }
        return refusedSeals.contains(seal)
    }

    /// A refused compaction gives way to the messages it was made from (or
    /// its recap when none were kept), as it does for a foreign provider.
    private static func unsealingRefusedCompactions(_ messages: [Message], refusedSeals: Set<String>) -> [Message] {
        guard !refusedSeals.isEmpty else { return messages }
        return messages.flatMap { message -> [Message] in
            guard case .user(let user) = message, let native = user.nativeCompaction,
                  native.items.contains(where: { isRefused($0, refusedSeals) }) else { return [message] }
            return TransformMessages.expandNativeCompaction([message])
        }
    }

    // MARK: - Replies that are not the API's

    /// The ChatGPT backend's own refusals are `{"detail":"…"}` — 400
    /// "Stream must be set to true", "The 'gpt-5.4' model is not supported
    /// when using Codex with a ChatGPT account." (measured 2026-10-11) — or
    /// `{"detail":{"message":…,"code":…}}`. Show the sentence, not the JSON.
    static func readingDetail(_ failure: ProviderFailure) -> ProviderFailure {
        guard case .object(let root)? = parseJSONObject(failure.message) else { return failure }
        var failure = failure
        switch root["detail"] {
        case .string(let text) where !text.isEmpty:
            failure.message = text
        case .object(let detail):
            guard case .string(let text) = detail["message"], !text.isEmpty else { return failure }
            failure.message = text
            if failure.providerCode == nil, case .string(let code) = detail["code"] { failure.providerCode = code }
        default: break
        }
        return failure
    }

    /// A 200 that says it is a web page or JSON and begins as one is not an
    /// event stream: a relay's sign-in or challenge page, or an error sent
    /// as a plain body. Parsed as SSE it yields no event and reads as a
    /// dropped stream (magpie #1012: a relay answered Codex 200 text/html).
    /// Name what came back instead. Anything else, a mislabelled stream
    /// included, is handed back untouched in `body`.
    static func notAnEventStream(
        _ response: HTTPURLResponse,
        body: inout AsyncThrowingStream<Data, Error>
    ) async throws -> ProviderFailure? {
        let type = (response.value(forHTTPHeaderField: "content-type") ?? "").lowercased()
        let page = type.hasPrefix("text/html")
        guard page || type.contains("json") else { return nil }
        var head: [Data] = []
        var bytes = Data()
        let opening = UInt8(ascii: page ? "<" : "{")
        let blank: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF]
        for try await chunk in body {
            head.append(chunk)
            bytes.append(chunk)
            if bytes.count >= 4096 { break }
            // A mislabelled stream shows in its first byte; reading on would
            // hold its events back until 4K of them had arrived.
            if let first = bytes.first(where: { !blank.contains($0) }), first != opening { break }
        }
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
        if page, text.hasPrefix("<") {
            let title = text.range(of: #"(?<=<title>)[^<]{1,200}"#, options: [.regularExpression, .caseInsensitive])
                .map { ": " + text[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            // A challenge or an edge's error page can pass; the dropped
            // stream it used to read as was retried too.
            return ProviderFailure(
                message: "The server answered HTTP 200 with a web page, not an event stream\(title)",
                shouldRetry: true
            )
        }
        if !page, text.hasPrefix("{") {
            if case .object(let root)? = parseJSONObject(text), root["error"] != nil || root["detail"] != nil {
                return readingDetail(ProviderFailure.payload(.object(root), fallback: text))
            }
            return ProviderFailure(
                message: "The server answered HTTP 200 with JSON, not an event stream",
                shouldRetry: false
            )
        }
        let rest = body
        let buffered = head
        body = AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in buffered { continuation.yield(chunk) }
                do {
                    for try await chunk in rest { continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return nil
    }

    /// The tier a request for `model` carries. The ChatGPT Codex backend
    /// honours only the tiers its catalog lists for a model: it refuses some
    /// others and quietly ignores the rest. Measured 2026-10-23: `flex`
    /// answers 400 "Unsupported service_tier: flex", while `ultrafast` on
    /// gpt-6-sol, which does not list it, is accepted and runs at standard
    /// speed (95 tok/s standard, 105 ultrafast; gpt-6.1-sol, which lists it:
    /// 48 standard, 84 priority, 330 ultrafast). The response's
    /// `service_tier` reads `default` either way. As in Codex CLI
    /// (`service_tier_for_request`), only a listed tier is sent, so the
    /// request names the tier the turn actually runs at.
    static func requestServiceTier(_ tier: ServiceTier?, for model: Model) -> ServiceTier? {
        guard let tier, model.api == "chatgpt-codex" else { return tier }
        return (model.compat?.serviceTiers ?? [.priority]).contains(tier) ? tier : nil
    }

    private static func makeRequest(
        model: Model,
        context: Context,
        options: StreamOptions?,
        bodyOverrides: [String: JSONValue] = [:],
        refusedSeals: Set<String> = []
    ) throws -> OpenAIResponsesRequest {
        var context = context
        context.messages = TransformMessages.normalize(
            unsealingRefusedCompactions(context.messages, refusedSeals: refusedSeals),
            model: model
        )
        // Tools added mid-conversation are loaded in place (pi
        // openai-responses-shared.ts) so the cached prefix, which starts with
        // the top-level tool list, survives the change. Removals and
        // redefinitions cannot be expressed this way and fall back to sending
        // the full current tool list.
        let toolChanges = TranscriptTools.resolve(
            messages: context.messages,
            tools: context.tools,
            supportsChanges: model.compat?.supportsAdditionalTools == true
                || model.compat?.supportsToolSearch == true,
            allowsNonAdditive: false
        )
        context.tools = toolChanges.requestTools
        var root: [String: JSONValue] = [
            "model": .string(model.id),
            "stream": .bool(true),
            "input": .array(encodeInput(
                context: context,
                model: model,
                anchorsToolChanges: toolChanges.anchorsChanges,
                refusedSeals: refusedSeals
            )),
        ]
        if let maxTokens = OutputTokenPolicy.effectiveLimit(
            for: model,
            requested: options?.maxTokens
        ) {
            root["max_output_tokens"] = .int(maxTokens)
        }
        // The ChatGPT Codex backend answers 400 "Unsupported parameter" to a
        // temperature (measured 2026-10-09), so it never reaches it.
        let codex = model.api == "chatgpt-codex"
        if let temp = options?.temperature, !codex { root["temperature"] = .double(temp) }
        // Processing-tier pass-through (pi openai-responses.ts:253-255). Cost
        // multipliers are computed downstream in AgentLoop, which has no
        // service-tier awareness, so only the request field is ported here.
        if let serviceTier = Self.requestServiceTier(options?.serviceTier, for: model) {
            root["service_tier"] = .string(serviceTier.rawValue)
        }
        if let sys = context.systemPrompt, !sys.isEmpty {
            root["instructions"] = .string(sys)
        }
        if let tools = context.tools, !tools.isEmpty {
            // xAI answers 400 "[invalid_client_tool_schema] ... tool parameter
            // root must be an object type (root schema is an anyOf/oneOf union
            // with a non-object branch)" to a union at a tool's root, and one
            // such tool fails every request (magpie #1271; magpie-plugins
            // packages/grok schema.test.mjs sends Codex desktop's
            // automation_update schema).
            let objectRoot = isXai(model)
            root["tools"] = .array(tools.map { encodeTool($0, objectRoot: objectRoot) })
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
        // An empty dictionary says nothing, and ChatGPT's Codex backend
        // refuses `"metadata": {}` as an unsupported parameter.
        if let meta = options?.metadata, !meta.isEmpty {
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
        if retention == .long, !codex, model.compat?.supportsLongCacheRetention != false {
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

    /// One Responses function tool definition. Tools loaded through a
    /// client `tool_search_output` carry `defer_loading`.
    static func encodeTool(_ tool: Tool, deferLoading: Bool = false, objectRoot: Bool = false) -> JSONValue {
        var entry: [String: JSONValue] = [
            "type": .string("function"),
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": objectRoot ? ToolSchemaRoot.objectRoot(tool.parameters) : tool.parameters,
        ]
        if deferLoading { entry["defer_loading"] = .bool(true) }
        return .object(entry)
    }

    /// Encode the tools a system message adds as input items: an
    /// `additional_tools` item when the model accepts one, otherwise a
    /// synthetic client-executed tool search that "found" exactly those tools.
    static func encodeToolAdditions(_ system: SystemMessage, model: Model, seed: String) -> [JSONValue] {
        let tools = system.toolsAdded ?? []
        guard !tools.isEmpty else { return [] }
        // A tool added mid-conversation is held to the same root rule as one
        // in `tools`: xAI refuses the request over either.
        let objectRoot = isXai(model)
        if model.compat?.supportsAdditionalTools == true {
            return [.object([
                "type": .string("additional_tools"),
                "role": .string("developer"),
                "tools": .array(tools.map { encodeTool($0, objectRoot: objectRoot) }),
            ])]
        }
        guard model.compat?.supportsToolSearch == true else { return [] }
        let names = tools.map(\.name)
        let digest = SHA256.hash(data: Data("\(seed):\(names.joined(separator: ","))".utf8))
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let callId = "kwwk_tool_load_\(hash)"
        return [
            .object([
                "type": .string("tool_search_call"),
                "call_id": .string(callId),
                "execution": .string("client"),
                "status": .string("completed"),
                "arguments": .object([
                    "query": .string(names.joined(separator: " ")),
                    "limit": .int(names.count),
                ]),
            ]),
            .object([
                "type": .string("tool_search_output"),
                "call_id": .string(callId),
                "execution": .string("client"),
                "status": .string("completed"),
                "tools": .array(tools.map { encodeTool($0, deferLoading: true, objectRoot: objectRoot) }),
            ]),
        ]
    }

    /// Convert our Message transcript into OpenAI Responses' `input` array.
    /// Each element is a typed item (`reasoning`, `message`, `function_call`,
    /// or `function_call_output`). Assistant messages with tool calls expand
    /// into multiple items.
    /// A call id as the Responses API takes one: as it is when it fits its
    /// 64 characters (400 `string_above_max_length` otherwise), else the
    /// sha256 of it in hex — 64 characters. A transcript carried over from
    /// another provider can hold longer ids; hashing the same id the same way
    /// keeps each call paired with its output.
    static func boundCallId(_ id: String) -> String {
        guard id.count > 64 else { return id }
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeInput(
        context: Context,
        model: Model,
        anchorsToolChanges: Bool = false,
        refusedSeals: Set<String> = []
    ) -> [JSONValue] {
        var out: [JSONValue] = []
        let initialDeclaration = TranscriptTools.initialDeclarationIndex(in: context.messages)
        for (index, message) in context.messages.enumerated() {
            switch message {
            case .system(let system):
                // The initial declaration is the top-level tool list. Later
                // ones only reach the wire when the request anchors changes;
                // otherwise the top-level list already holds every tool.
                guard anchorsToolChanges, index != initialDeclaration else { continue }
                out.append(contentsOf: encodeToolAdditions(system, model: model, seed: "system:\(index)"))
            case .user(let u):
                if let native = u.nativeCompaction, native.canReplay(with: model) {
                    out.append(contentsOf: native.items)
                }
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
                              var item = Self.parseReasoningItem(sig),
                              !Self.isRefused(.object(item), refusedSeals) else { continue }
                        // Grok cannot read the encrypted reasoning beside a
                        // `"content": null` and refuses the request ("Could
                        // not decode the compaction blob", magpie grok.go
                        // grokBody; the plugin's rewrite drops it the same).
                        if isXai(model), item["content"] == .null { item["content"] = nil }
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
                            "call_id": .string(boundCallId(tc.id)),
                            "name": .string(tc.name),
                            "arguments": .string(argsString),
                        ]))
                    }
                }

            case .toolResult(let tr):
                let text = tr.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined(separator: "\n")
                let imageParts: [JSONValue] = model.input.contains(.image)
                    ? tr.content.compactMap { block in
                        guard case .image(let i) = block else { return nil }
                        return .object([
                            "type": .string("input_image"),
                            "image_url": .string("data:\(i.mimeType);base64,\(i.data)"),
                        ])
                    }
                    : []
                out.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(boundCallId(tr.toolCallId)),
                    "output": .string(text.isEmpty && !imageParts.isEmpty ? "(see attached image)" : text),
                ]))
                // `function_call_output.output` is a plain string on every
                // Responses-compatible endpoint we speak to (OpenAI, Codex,
                // OpenRouter), so tool-result images ride on a user message
                // right after the output — the same carrier the Completions
                // provider uses. Without this the model only ever saw the
                // "[image/webp, 1254x1254, ...]" note and went looking for OCR.
                if !imageParts.isEmpty {
                    var carrier: [JSONValue] = [
                        .object([
                            "type": .string("input_text"),
                            "text": .string("Attached image(s) from tool result:")
                        ]),
                    ]
                    carrier.append(contentsOf: imageParts)
                    out.append(.object([
                        "type": .string("message"),
                        "role": .string("user"),
                        "content": .array(carrier),
                    ]))
                }
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

    /// Azure OpenAI can omit `reasoning.encrypted_content` from
    /// `response.output_item.done` and provide it only in
    /// `response.completed`'s `response.output`. Backfill the persisted
    /// reasoning signature from the terminal response so `store: false`
    /// multi-turn replay stays stateless. Output array positions correspond
    /// to `output_index`. Ports pi #6608.
    private static func backfillReasoningSignatures(
        _ outputItems: [JSONValue],
        state: OpenAIResponsesState
    ) {
        for (outputIndex, entry) in outputItems.enumerated() {
            guard case .object(let item) = entry,
                  case .string("reasoning")? = item["type"],
                  case .string = item["encrypted_content"] ?? .null,
                  let index = state.reasoningIndex(for: outputIndex) else { continue }
            // Preserve a signature that already carries encrypted content.
            if let existing = state.thinkingSignature(at: index),
               let parsed = parseReasoningItem(existing),
               case .string = parsed["encrypted_content"] ?? .null { continue }
            if let serialized = serializeReasoningItem(item) {
                state.setThinkingSignature(at: index, signature: serialized)
            }
        }
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
}

private struct OpenAIResponsesDriveResult: Sendable {
    var message: AssistantMessage
    var completed: Bool
    var endedWithoutTerminalEvent = false
    /// The request was refused over its sealed items and nothing was pushed.
    var sealsRefused = false
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

private final class WebSocketStreamProgress: Sendable {
    private let receivedEvent = NIOLockedValueBox(false)

    var hasReceivedEvent: Bool {
        receivedEvent.withLockedValue { $0 }
    }

    func markReceivedEvent() {
        receivedEvent.withLockedValue { $0 = true }
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

private final class OpenAIResponsesSessionStore: Sendable {
    private let sessions = NIOLockedValueBox([String: OpenAIResponsesSessionState]())

    func session(for sessionId: String?) -> OpenAIResponsesSessionState {
        guard let sessionId, !sessionId.isEmpty else {
            return OpenAIResponsesSessionState()
        }
        return sessions.withLockedValue { sessions in
            if let existing = sessions[sessionId] { return existing }
            let created = OpenAIResponsesSessionState()
            sessions[sessionId] = created
            return created
        }
    }

    func closeSession(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let session = sessions.withLockedValue { $0.removeValue(forKey: sessionId) }
        session?.close()
    }
}

private final class OpenAIResponsesSessionState: Sendable {
    private struct State {
        var connection: (any WebSocketConnection)?
        var lastRequest: OpenAIResponsesRequest?
        var lastResponse: OpenAIResponsesLastResponse?
        var webSocketFailureCount = 0
        var disabled = false
        var webSocketInFlight = false
        var closed = false
        var refused: Set<String> = []
    }
    private let state = NIOLockedValueBox(State())

    /// Sealed items this conversation was refused over; later requests leave
    /// them out up front instead of being refused and asked again each turn.
    var refusedSeals: Set<String> { state.withLockedValue { $0.refused } }

    func refuse(seals: Set<String>) {
        state.withLockedValue { $0.refused.formUnion(seals) }
    }

    deinit {
        close()
    }

    var webSocketDisabled: Bool {
        state.withLockedValue { $0.disabled || $0.closed }
    }

    func beginWebSocketRun() -> OpenAIResponsesWebSocketRunLease {
        state.withLockedValue { state in
            if state.disabled || state.closed { return .disabled }
            if state.webSocketInFlight { return .busy }
            state.webSocketInFlight = true
            return .acquired
        }
    }

    func endWebSocketRun() {
        state.withLockedValue { $0.webSocketInFlight = false }
    }

    func takeConnection() -> (any WebSocketConnection)? {
        state.withLockedValue { state in
            let existing = state.connection
            state.connection = nil
            return existing
        }
    }

    func storeConnection(_ next: any WebSocketConnection) {
        let shouldClose = state.withLockedValue { state -> Bool in
            guard !state.closed else { return true }
            state.connection = next
            return false
        }
        if shouldClose {
            next.close()
        }
    }

    @discardableResult
    func recordWebSocketFailure(maxFailures: Int) -> OpenAIResponsesWebSocketFailureStatus {
        let result = state.withLockedValue { state -> (old: (any WebSocketConnection)?, status: OpenAIResponsesWebSocketFailureStatus) in
            state.webSocketFailureCount += 1
            if state.webSocketFailureCount >= max(1, maxFailures) {
                state.disabled = true
            }
            let old = state.connection
            state.connection = nil
            state.lastRequest = nil
            state.lastResponse = nil
            return (
                old,
                OpenAIResponsesWebSocketFailureStatus(
                    count: state.webSocketFailureCount,
                    disabled: state.disabled
                )
            )
        }
        result.old?.close()
        return result.status
    }

    func resetWebSocketState(disable: Bool = false, resetFailureCount: Bool = false) {
        let old = state.withLockedValue { state -> (any WebSocketConnection)? in
            if disable { state.disabled = true }
            if resetFailureCount { state.webSocketFailureCount = 0 }
            let old = state.connection
            state.connection = nil
            state.lastRequest = nil
            state.lastResponse = nil
            return old
        }
        old?.close()
    }

    func close() {
        let old = state.withLockedValue { state -> (any WebSocketConnection)? in
            state.closed = true
            state.disabled = true
            state.webSocketInFlight = false
            let old = state.connection
            state.connection = nil
            state.lastRequest = nil
            state.lastResponse = nil
            return old
        }
        old?.close()
    }

    func prepareWebSocketPayload(from request: OpenAIResponsesRequest) throws -> OpenAIResponsesWebSocketPayload {
        let payload = state.withLockedValue { state -> (previousResponseId: String?, input: [JSONValue]?) in
            defer { state.lastRequest = request }
            guard let previous = state.lastRequest,
                  let response = state.lastResponse,
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
        state.withLockedValue { state in
            state.webSocketFailureCount = 0
            state.lastResponse = OpenAIResponsesLastResponse(
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
