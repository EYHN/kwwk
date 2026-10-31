import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages streaming provider. Implements the `anthropic-messages`
/// API against a pluggable `HTTPClient`. Supports API-key and OAuth bearer auth
/// (via `authHeaderBuilder`), `anthropic-beta` opt-in headers, prompt-cache
/// breakpoints, and extended/adaptive thinking.
///
/// Reports structured failures and retry hints; the Agent/one-shot caller owns
/// retry scheduling so provider and caller budgets cannot multiply.
///
/// The provider is testable via a stub `HTTPClient` and produces the standard
/// AssistantMessageEvent stream.
public final class AnthropicProvider: APIProvider, NativeCompactionProvider, @unchecked Sendable {
    public typealias AuthHeaderBuilder = @Sendable (String) -> [String: String]
    public static let claudeCodeMaximumOutputTokens = 64_000

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
    /// Route-level output ceiling (Claude Code OAuth uses 64k). API-key
    /// providers leave this nil and use the model capability directly.
    public let maximumOutputTokens: Int?

    public init(
        api: String = "anthropic-messages",
        client: HTTPClient = URLSessionHTTPClient(),
        defaultBaseURL: URL = URL(string: "https://api.anthropic.com")!,
        defaultAPIKey: String? = nil,
        apiVersion: String = "2023-06-01",
        extraHeaders: [String: String] = [:],
        authHeaderBuilder: AuthHeaderBuilder? = nil,
        systemPromptPrefix: String? = nil,
        maximumOutputTokens: Int? = nil
    ) {
        self.api = api
        self.client = client
        self.defaultBaseURL = defaultBaseURL
        self.defaultAPIKey = defaultAPIKey
        self.apiVersion = apiVersion
        self.extraHeaders = extraHeaders
        self.authHeaderBuilder = authHeaderBuilder ?? { key in ["x-api-key": key] }
        self.systemPromptPrefix = systemPromptPrefix
        self.maximumOutputTokens = maximumOutputTokens
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached {
            await self.run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    public func compact(
        model: Model,
        context: Context,
        instructions: String,
        options: StreamOptions?
    ) async throws -> NativeCompactionResult? {
        let base = model.baseURL.isEmpty ? defaultBaseURL.absoluteString : model.baseURL
        let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages")!
        guard Self.supportsNativeCompaction(model: model, baseURL: base) else { return nil }
        let fallbackEnabled = Self.usesServerSideFallback(model: model, url: url, options: options)
        var nativeContext = context
        if case .assistant? = nativeContext.messages.last {
            // Do not let an assistant-final transcript become an unsupported
            // prefill. This synthetic control message is not persisted.
            nativeContext.messages.append(.user(UserMessage(
                text: "Compact the preceding conversation; do not continue the task."
            )))
        }
        let encoded = try Self.encodeBody(
            model: model,
            context: nativeContext,
            options: options,
            systemPromptPrefix: systemPromptPrefix,
            maximumOutputTokens: maximumOutputTokens,
            fallbackEnabled: fallbackEnabled
        )
        var body = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
        body["stream"] = false
        body["context_management"] = ["edits": [[
            "type": "compact_20260112", "trigger": ["type": "input_tokens", "value": 50_000],
            "pause_after_compaction": true, "instructions": .string(instructions),
        ]]]
        var headers = makeHeaders(model: model, context: context, options: options, fallbackEnabled: fallbackEnabled)
        headers["accept"] = "application/json"
        let beta = headers["anthropic-beta"].map { $0 + "," } ?? ""
        headers["anthropic-beta"] = beta + "compact-2026-01-12"
        let json = try await client.compactionJSON(
            url: url,
            headers: headers,
            body: JSONEncoder().encode(body),
            cancellation: options?.cancellation
        )
        guard json["stop_reason"] == "compaction" else {
            throw ProviderFailure(
                message: "Invalid Anthropic compaction completion: expected compaction stop reason",
                rawStopReason: json["stop_reason"].flatMap { value in
                    if case .string(let reason) = value { return reason }; return nil
                }
            )
        }
        guard case .array(let content) = json["content"],
              let block = content.first(where: {
                  guard case .object(let item) = $0 else { return false }
                  return item["type"] == .string("compaction")
              }), case .object(let item) = block,
              case .string(let summary) = item["content"],
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderFailure(message: "Anthropic compaction returned no summary")
        }
        return NativeCompactionResult(
            summary: summary,
            payload: NativeCompactionPayload(model: model, items: [block])
        )
    }

    static func supportsNativeCompaction(model: Model, baseURL: String? = nil) -> Bool {
        if let explicit = model.compat?.supportsServerCompaction { return explicit }
        let base = baseURL ?? (model.baseURL.isEmpty ? "https://api.anthropic.com" : model.baseURL)
        return URL(string: base)?.host == "api.anthropic.com" && model.id.range(
            of: "claude-(opus|sonnet)-(4[.-][6-9]|[5-9])|claude-(fable|mythos)-[5-9]",
            options: .regularExpression) != nil
    }

    private func makeHeaders(
        model: Model,
        context: Context,
        options: StreamOptions?,
        fallbackEnabled: Bool = false
    ) -> [String: String] {
        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "text/event-stream",
            "anthropic-version": apiVersion,
        ]
        for (k, v) in model.headers ?? [:] { headers[k] = v }
        for (k, v) in extraHeaders { headers[k] = v }
        if let auth = options?.resolvedAuth {
            applyResolvedAuth(auth, to: &headers)
        } else if let key = options?.apiKey ?? defaultAPIKey {
            for (k, v) in authHeaderBuilder(key) { headers[k] = v }
        }
        if let extra = options?.headers {
            for (k, v) in extra { headers[k] = v }
        }
        // Append a beta flag to any existing `anthropic-beta` value (e.g. the
        // OAuth `claude-code-20250219,oauth-2025-04-20` seed) rather than
        // clobbering it. Anthropic treats `anthropic-beta` as an unordered set.
        func appendBeta(_ name: String) {
            var betas: [String] = []
            for key in headers.keys.sorted() where key.lowercased() == "anthropic-beta" {
                for value in (headers.removeValue(forKey: key) ?? "").split(separator: ",") {
                    let value = value.trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty && !betas.contains(value) { betas.append(value) }
                }
            }
            if !betas.contains(name) { betas.append(name) }
            headers["anthropic-beta"] = betas.joined(separator: ",")
        }
        if fallbackEnabled { appendBeta("server-side-fallback-2026-06-01") }
        if context.messages.contains(where: {
            if case .user(let user) = $0, let native = user.nativeCompaction {
                return native.api == api && native.canReplay(with: model)
            }
            return false
        }) { appendBeta("compact-2026-01-12") }
        // 1h prompt-cache TTL requires the extended-cache-ttl beta.
        if (options?.cacheRetention ?? .short) == .long,
           model.compat?.supportsLongCacheRetention != false {
            appendBeta("extended-cache-ttl-2025-04-11")
        }
        // Fine-grained tool streaming beta is required only when eager tool
        // input streaming is NOT supported and tools are present (pi inversion,
        // anthropic-messages.ts:1182-1184).
        let hasTools = !(context.tools?.isEmpty ?? true)
        let supportsEager = model.compat?.supportsEagerToolInputStreaming != false
        if hasTools && !supportsEager {
            appendBeta("fine-grained-tool-streaming-2025-05-14")
        }
        // Interleaved thinking beta, unless the model forces adaptive thinking
        // or the caller opts out. pi defaults `interleavedThinking` to true.
        let adaptive = model.compat?.forceAdaptiveThinking == true
        let interleaved = options?.interleavedThinking ?? true
        if interleaved && !adaptive {
            appendBeta("interleaved-thinking-2025-05-14")
        }
        if Self.toolChangePlan(model: model, context: context).anchorsChanges {
            appendBeta(Self.inlineToolsBeta)
        }

        return headers
    }

    // MARK: - Driver

    // Opt-in only (owner 2026-10-31): a refusal ends the turn as a refusal
    // instead of being answered by another model. When asked for, current
    // Fable/Mythos aliases follow omp's family policy and Opus 5 follows pi's
    // explicit allowedFallbackModels entry. Keep unknown/future models out.
    private static let serverFallbackModels: Set<String> = [
        "claude-fable-5", "claude-fable-5-1",
        "claude-mythos-5", "claude-mythos-5-1", "claude-opus-5",
    ]

    private static func usesServerSideFallback(model: Model, url: URL, options: StreamOptions?) -> Bool {
        options?.anthropicServerSideFallback == true
            && url.scheme == "https" && url.host?.lowercased() == "api.anthropic.com"
            && model.provider == "anthropic" && model.api == "anthropic-messages"
            && serverFallbackModels.contains(model.id)
    }

    private func run(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        let url: URL = {
            var base = model.baseURL.isEmpty ? defaultBaseURL.absoluteString : model.baseURL
            while base.hasSuffix("/") { base.removeLast() }
            return URL(string: "\(base)/v1/messages") ?? defaultBaseURL.appendingPathComponent("v1/messages")
        }()

        let fallbackEnabled = Self.usesServerSideFallback(model: model, url: url, options: options)

        let body: Data
        do {
            body = try Self.encodeBody(
                model: model,
                context: context,
                options: options,
                systemPromptPrefix: systemPromptPrefix,
                maximumOutputTokens: maximumOutputTokens,
                fallbackEnabled: fallbackEnabled
            )
        } catch {
            out.push(.error(reason: .error, error: AssistantMessage.makeError(
                api: api,
                model: model,
                text: "Failed to encode request: \(error.displayDescription)"
            )))
            out.end(AssistantMessage.makeError(api: api, model: model, text: "Failed to encode request: \(error.displayDescription)"))
            return
        }

        let headers = makeHeaders(model: model, context: context, options: options, fallbackEnabled: fallbackEnabled)

        do {
            let (response, stream) = try await client.stream(
                url: url,
                method: "POST",
                headers: headers,
                body: body,
                cancellation: options?.cancellation
            )
            if response.statusCode >= 400 {
                let failure = await ProviderFailure.http(response, body: stream)
                let msg = AssistantMessage.makeError(api: api, model: model, text: failure.message, failure: failure)
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
            state.requestModel = model
            state.fallbackEnabled = fallbackEnabled
            // Bridge external cancellation to the in-flight request: cancelling
            // the drive task tears down the SSE/byte streams, which aborts the
            // underlying URLSession task even during a silent stream gap.
            let driveTask = Task { try await self.drive(events: parseSSE(bytes: stream), out: out, state: state) }
            let cancelReg = options?.cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelReg?.cancel() }
            try await driveTask.value
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
                    if blockType == "fallback" {
                        guard state.fallbackEnabled,
                              case .object(let from) = block["from"],
                              case .string(let source) = from["model"], !source.isEmpty,
                              case .object(let to) = block["to"],
                              case .string(let target) = to["model"], !target.isEmpty else { continue }
                        state.startFallback(index: index, from: source, to: target)
                        state.responseModel = target
                        continue
                    }
                    state.startBlock(index: index, type: blockType, raw: block)
                    let index = state.contentIndex(for: index)
                    switch blockType {
                    case "text":
                        out.push(.textStart(contentIndex: index, partial: state.snapshot()))
                    case "thinking", "redacted_thinking":
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
                                contentIndex: state.contentIndex(for: index),
                                delta: text,
                                partial: state.snapshot()
                            ))
                        }
                    case "thinking_delta":
                        if case .string(let thinking) = delta["thinking"] ?? .null {
                            state.appendThinking(index: index, text: thinking)
                            out.push(.thinkingDelta(
                                contentIndex: state.contentIndex(for: index),
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
                                contentIndex: state.contentIndex(for: index),
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
                    let index = state.contentIndex(for: index)
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
                    let mapped = mapStopReason(reason)
                    state.stopReason = mapped
                    // A `refusal`/`sensitive`/unknown stop reason is not a clean
                    // completion — record it so `message_stop` surfaces `.error`.
                    if mapped == .error {
                        state.errorMessage = "Anthropic stop reason: \(reason)"
                        state.failure = ProviderFailure(
                            message: state.errorMessage!,
                            rawStopReason: reason,
                            stopDetails: delta["stop_details"] ?? obj["stop_details"]
                        )
                    }
                }
                if case .object(let usage) = obj["usage"] ?? .null {
                    state.applyUsageDelta(usage)
                }

            case "message_stop":
                let final = state.finalize()
                if final.stopReason == .error {
                    out.push(.error(reason: .error, error: final))
                } else {
                    out.push(.done(reason: final.stopReason, message: final))
                }
                out.end(final)
                return

            case "error":
                let text: String = {
                    if case .object(let err) = obj["error"] ?? .null,
                       case .string(let m) = err["message"] ?? .null { return m }
                    return "Unknown Anthropic error"
                }()
                var err = state.asError(text: text)
                err.failure = ProviderFailure.payload(.object(obj), fallback: text)
                out.push(.error(reason: .error, error: err))
                out.end(err)
                return

            default: break
            }
        }

        // Loop ended without message_stop.
        if state.signal?.isCancelled == true {
            let aborted = state.asAborted()
            out.push(.error(reason: .aborted, error: aborted))
            out.end(aborted)
            return
        }
        // A clean half-close mid-message is a truncated turn, not a success —
        // surface it as an error so the agent loop can retry, mirroring
        // OpenAICompletionsProvider's missing-finish_reason handling.
        let err = state.asError(text: "Anthropic stream ended before message_stop")
        out.push(.error(reason: .error, error: err))
        out.end(err)
    }
}

func mapStopReason(_ raw: String) -> StopReason {
    switch raw {
    case "end_turn", "stop_sequence": return .stop
    case "max_tokens": return .length
    case "tool_use": return .toolUse
    // An Anthropic-shaped relay in front of another vendor's model can pass
    // that vendor's finish reason through as it came (magpie c5b57b90, a
    // relay in front of Grok ending tool calls with `tool_calls`). Anthropic
    // itself never sends these, so its own replies read as before.
    case "stop": return .stop
    case "length": return .length
    case "tool_calls", "function_call": return .toolUse
    // pi maps a refused / safety-filtered turn to an error rather than a clean
    // stop; unknown reasons are surfaced the same way (rather than silently
    // masquerading as a successful completion) so new API values are caught.
    case "refusal", "sensitive": return .error
    default: return .error
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
