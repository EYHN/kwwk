import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages streaming provider. Implements the `anthropic-messages`
/// API against a pluggable `HTTPClient`. Supports API-key and OAuth bearer auth
/// (via `authHeaderBuilder`), `anthropic-beta` opt-in headers, prompt-cache
/// breakpoints, and extended/adaptive thinking.
///
/// Non-goals for this implementation:
///  - Rate-limit retry with `retry-after` parsing (handled by the agent loop)
///
/// The provider is testable via a stub `HTTPClient` and produces the standard
/// AssistantMessageEvent stream.
public final class AnthropicProvider: APIProvider, @unchecked Sendable {
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

    // MARK: - Driver

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

        let body: Data
        do {
            body = try Self.encodeBody(
                model: model,
                context: context,
                options: options,
                systemPromptPrefix: systemPromptPrefix,
                maximumOutputTokens: maximumOutputTokens
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
            if let existing = headers["anthropic-beta"], !existing.isEmpty {
                if !existing.contains(name) { headers["anthropic-beta"] = existing + "," + name }
            } else {
                headers["anthropic-beta"] = name
            }
        }
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

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: body,
                cancellation: options?.cancellation
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
            // Bridge external cancellation to the in-flight request: cancelling
            // the drive task tears down the SSE/byte streams, which aborts the
            // underlying URLSession task even during a silent stream gap.
            let driveTask = Task { try await self.drive(events: parseSSE(bytes: stream), out: out, state: state) }
            let cancelReg = options?.cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelReg?.cancel() }
            try await driveTask.value
        } catch {
            if options?.cancellation?.isCancelled == true {
                let aborted = Self.makeAborted(model: model, api: api)
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let msg = Self.makeError(model: model, api: api, text: "\(error)")
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
                    state.startBlock(index: index, type: blockType, raw: block)
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
                    let mapped = mapStopReason(reason)
                    state.stopReason = mapped
                    // A `refusal`/`sensitive`/unknown stop reason is not a clean
                    // completion — record it so `message_stop` surfaces `.error`.
                    if mapped == .error {
                        state.errorMessage = "Anthropic stop reason: \(reason)"
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
                let err = state.asError(text: text)
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

    // MARK: - Helpers

    private static func encodeBody(
        model: Model,
        context: Context,
        options: StreamOptions?,
        systemPromptPrefix: String? = nil,
        maximumOutputTokens: Int? = nil
    ) throws -> Data {
        var context = context
        context.messages = TransformMessages.normalize(context.messages, model: model)
        let modelCeiling = OutputTokenPolicy.maximumAllowedLimit(for: model)
        let routeCeiling = maximumOutputTokens.map { min(modelCeiling, $0) }
            ?? modelCeiling
        var maxTokens = min(
            OutputTokenPolicy.effectiveLimit(for: model, requested: options?.maxTokens) ?? 0,
            routeCeiling
        )
        guard maxTokens > 0 else {
            throw AnthropicRequestEncodingError.invalidMaxTokens(maxTokens)
        }
        var root: [String: Any] = [
            "model": model.id,
            "stream": true,
        ]
        // Extended thinking: Claude only returns `thinking` content blocks
        // when the request body opts in via `thinking: {type, budget_tokens}`.
        // When the caller requested a reasoning level, translate it to a
        // token budget (via `ThinkingBudgets.budget(for:)` if supplied,
        // else a sensible default per level). Temperature is deliberately
        // dropped in this branch — the Messages API rejects any value
        // other than 1.0 when thinking is enabled.
        let adaptive = model.compat?.forceAdaptiveThinking == true
        let thinkingEnabled: Bool
        if let reasoning = options?.reasoning {
            if adaptive {
                // Adaptive thinking (Opus 4.6/4.7/4.8, Fable 5): Claude decides
                // when/how much to think; we only pass an effort level via
                // `output_config`. Newer catalogs distinguish native `xhigh`
                // from the unconstrained `max` effort.
                root["thinking"] = ["type": "adaptive", "display": "summarized"]
                root["output_config"] = ["effort": adaptiveEffort(model, reasoning)]
                thinkingEnabled = true
            } else {
                var thinkingBudget = options?.thinkingBudgets?.budget(for: reasoning)
                    ?? defaultThinkingBudget(for: reasoning)
                guard thinkingBudget >= minimumThinkingBudgetTokens else {
                    throw AnthropicRequestEncodingError.invalidThinkingBudget(thinkingBudget)
                }

                // Match OMP's interleaved-thinking policy: maxTokens is raised
                // when necessary so a low caller cap cannot leave the thinking
                // budget with no answer space. The model/OAuth ceiling still
                // wins; if it is too small, shrink thinking rather than emit an
                // invalid `budget_tokens >= max_tokens` request.
                let requiredMaxTokens = addingWithoutOverflow(
                    thinkingBudget,
                    minimumAnswerHeadroomTokens
                )
                maxTokens = min(max(maxTokens, requiredMaxTokens), routeCeiling)
                if requiredMaxTokens > maxTokens {
                    thinkingBudget = maxTokens - minimumAnswerHeadroomTokens
                }
                guard thinkingBudget >= minimumThinkingBudgetTokens else {
                    throw AnthropicRequestEncodingError.thinkingBudgetDoesNotFit(
                        maxTokens: maxTokens,
                        answerHeadroom: minimumAnswerHeadroomTokens
                    )
                }
                root["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": thinkingBudget,
                ]
                thinkingEnabled = true
            }
        } else {
            thinkingEnabled = false
            // pi parity (anthropic-messages.ts:981-983): explicitly disable
            // thinking on reasoning-capable models when reasoning is off,
            // unless `thinkingLevelMap` pins `off` to null (meaning the model
            // does not support an explicit off level).
            if model.reasoning, supportsExplicitThinkingOff(model) {
                root["thinking"] = ["type": "disabled"]
            }
        }
        // Temperature is dropped when thinking is on (Messages API rejects any
        // value != 1) and whenever the model declares it unsupported (Opus 4.7+).
        let temperatureAllowed = model.compat?.supportsTemperature != false
        if !thinkingEnabled, temperatureAllowed, let temp = options?.temperature { root["temperature"] = temp }
        root["max_tokens"] = maxTokens

        // Prompt caching: emit Anthropic-style `cache_control` breakpoints
        // unless the caller opted out (`.none`). Default is short (5-min
        // ephemeral); `.long` upgrades to a 1h TTL when the model supports it
        // (the matching `anthropic-beta` header is added in `stream`). Markers
        // go on the system prompt, the last tool definition, and the final
        // message content block — pi's "anthropic" cache format.
        let retention = options?.cacheRetention ?? .short
        let cacheOn = retention != .none
        let useLong = retention == .long && (model.compat?.supportsLongCacheRetention != false)
        let cacheControl: [String: Any]? = cacheOn
            ? (useLong ? ["type": "ephemeral", "ttl": "1h"] : ["type": "ephemeral"])
            : nil
        let cacheOnTools = cacheOn && (model.compat?.supportsCacheControlOnTools != false)

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
            if let cc = cacheControl, !blocks.isEmpty {
                blocks[blocks.count - 1]["cache_control"] = cc
            }
            root["system"] = blocks
        } else if let userSystem {
            if let cc = cacheControl {
                root["system"] = [["type": "text", "text": userSystem, "cache_control": cc]]
            } else {
                root["system"] = userSystem
            }
        }
        // pi default for `supportsEagerToolInputStreaming` is `true`.
        let supportsEager = model.compat?.supportsEagerToolInputStreaming != false
        if let tools = context.tools, !tools.isEmpty {
            var toolEntries = tools.map { tool -> [String: Any] in
                var entry: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                ]
                if supportsEager { entry["eager_input_streaming"] = true }
                if let params = anyFromJSONValue(tool.parameters) {
                    entry["input_schema"] = params
                }
                return entry
            }
            if cacheOnTools, let cc = cacheControl, !toolEntries.isEmpty {
                toolEntries[toolEntries.count - 1]["cache_control"] = cc
            }
            root["tools"] = toolEntries
            // Anthropic folds the parallel-tool-call switch into `tool_choice`
            // via a `disable_parallel_tool_use` flag. The default remains
            // parallel-on, so we only emit the block when the caller picks a
            // non-default choice OR disables parallel.
            if let toolChoice = buildToolChoice(options) {
                root["tool_choice"] = toolChoice
            }
        }
        // pi default for `allowEmptySignature` is `false`.
        let allowEmptySig = model.compat?.allowEmptySignature == true
        var messages = context.messages.compactMap { Self.encodeMessage($0, allowEmptySignature: allowEmptySig) }
        if let cc = cacheControl, !messages.isEmpty {
            applyCacheControl(cc, toLastBlockOf: &messages[messages.count - 1])
        }
        root["messages"] = messages
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Attach a `cache_control` marker to the final content block of a message,
    /// closing the cached prefix at the end of the conversation.
    private static func applyCacheControl(_ cc: [String: Any], toLastBlockOf message: inout [String: Any]) {
        guard var content = message["content"] as? [[String: Any]], !content.isEmpty else { return }
        content[content.count - 1]["cache_control"] = cc
        message["content"] = content
    }

    /// Map a reasoning level to an Anthropic adaptive-thinking effort, honoring
    /// the per-model `thinkingLevelMap`. Falls back to pi's defaults:
    /// minimal/low→low, medium→medium, and extended levels→high.
    /// Valid efforts are low/medium/high/xhigh/max.
    private static func adaptiveEffort(_ model: Model, _ reasoning: ReasoningLevel) -> String {
        let level = clampThinkingLevel(model, ModelThinkingLevel(reasoning: reasoning))
        if let map = model.thinkingLevelMap, let entry = map[level.rawValue], let mapped = entry {
            return mapped
        }
        switch level {
        case .minimal, .low: return "low"
        case .medium: return "medium"
        case .off, .high, .xhigh, .max: return "high"
        }
    }

    private static let minimumThinkingBudgetTokens = 1024
    private static let minimumAnswerHeadroomTokens = 4000

    private static func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func supportsExplicitThinkingOff(_ model: Model) -> Bool {
        guard let map = model.thinkingLevelMap, map.keys.contains("off") else { return true }
        return map["off"]! != nil
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
        case .max: return 16_384
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

    private static func encodeMessage(_ message: Message, allowEmptySignature: Bool) -> [String: Any]? {
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
                    // pi parity (anthropic-messages.ts:1072-1104).
                    if th.redacted == true {
                        blocks.append(["type": "redacted_thinking", "data": th.thinkingSignature ?? ""])
                        break
                    }
                    let sig = th.thinkingSignature
                    let hasSignature = !(sig ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    // A signed thinking block must be replayed even when its
                    // visible text is empty (interleaved thinking can emit
                    // signature-only blocks); dropping it invalidates the turn.
                    if th.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !hasSignature { break }
                    if !hasSignature {
                        if allowEmptySignature {
                            blocks.append(["type": "thinking", "thinking": th.thinking, "signature": ""])
                        } else {
                            // The Messages API rejects a thinking block without a
                            // valid signature; degrade to plain text instead.
                            blocks.append(["type": "text", "text": th.thinking])
                        }
                    } else {
                        blocks.append(["type": "thinking", "thinking": th.thinking, "signature": sig!])
                    }
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

    private static func makeAborted(model: Model, api: String) -> AssistantMessage {
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

private enum AnthropicRequestEncodingError: LocalizedError, CustomStringConvertible {
    case invalidMaxTokens(Int)
    case invalidThinkingBudget(Int)
    case thinkingBudgetDoesNotFit(maxTokens: Int, answerHeadroom: Int)

    var errorDescription: String? {
        switch self {
        case .invalidMaxTokens(let value):
            return "Anthropic max_tokens must be positive; got \(value)"
        case .invalidThinkingBudget(let value):
            return "Anthropic thinking budget must be at least 1024; got \(value)"
        case .thinkingBudgetDoesNotFit(let maxTokens, let answerHeadroom):
            return "Anthropic thinking budget requires max_tokens greater than \(answerHeadroom); got \(maxTokens)"
        }
    }

    var description: String {
        errorDescription ?? "Invalid Anthropic request"
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
        // pi parity: 1h cache-write subset (message_start) and reasoning tokens
        // (message_delta). Reading both at every usage event is harmless.
        if case .object(let cc) = obj["cache_creation"] ?? .null,
           case .int(let v) = cc["ephemeral_1h_input_tokens"] ?? .null { usage.cacheWrite1h = v }
        if case .object(let d) = obj["output_tokens_details"] ?? .null,
           case .int(let v) = d["thinking_tokens"] ?? .null { usage.reasoning = v }
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
    }

    func startBlock(index: Int, type: String, raw: [String: JSONValue]) {
        lock.withLock {
            if !orderedIndices.contains(index) { orderedIndices.append(index) }
            switch type {
            case "text": blocks[index] = .text(TextContent(text: ""))
            case "thinking": blocks[index] = .thinking(ThinkingContent(thinking: ""))
            case "redacted_thinking":
                let data: String = {
                    if case .string(let v) = raw["data"] ?? .null { return v } else { return "" }
                }()
                blocks[index] = .thinking(ThinkingContent(
                    thinking: "[Reasoning redacted]",
                    thinkingSignature: data,
                    redacted: true))
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
                let call = ToolCall(id: id, name: name, arguments: Self.parseToolJSON(json))
                blocks[index] = .toolUse(id: id, name: name, json: json)
                return .toolCall(call)
            }
        }
    }

    static func parseToolJSON(_ json: String) -> JSONValue {
        if let data = json.data(using: .utf8),
           let v = try? JSONDecoder().decode(JSONValue.self, from: data) { return v }
        return .object([:])
    }

    /// Streaming snapshot. In-progress tool calls are represented with an empty
    /// object rather than re-parsing the (usually incomplete) argument buffer on
    /// every delta — that reparse is O(n) per delta, O(n^2) over a tool call.
    /// The complete arguments are parsed once in `finishBlock`/`finalize`.
    func snapshot() -> AssistantMessage { buildMessage(parseToolArgs: false) }

    private func buildMessage(parseToolArgs: Bool) -> AssistantMessage {
        lock.withLock {
            var content: [AssistantBlock] = []
            for i in orderedIndices.sorted() {
                guard let block = blocks[i] else { continue }
                switch block {
                case .text(let t): content.append(.text(t))
                case .thinking(let th): content.append(.thinking(th))
                case .toolUse(let id, let name, let json):
                    let args: JSONValue = parseToolArgs ? Self.parseToolJSON(json) : .object([:])
                    content.append(.toolCall(ToolCall(id: id, name: name, arguments: args)))
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
        var m = buildMessage(parseToolArgs: true)
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
    case "end_turn", "stop_sequence": return .stop
    case "max_tokens": return .length
    case "tool_use": return .toolUse
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
