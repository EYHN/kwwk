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
            // Cloudflare catalog entries carry literal `{CLOUDFLARE_ACCOUNT_ID}`
            // / `{CLOUDFLARE_GATEWAY_ID}` placeholders in `baseUrl`; expand them
            // from the environment before building the request URL. No-op for
            // every other provider (the tokens never appear in their baseUrls).
            base = substituteCloudflarePlaceholders(in: base)
            // Tolerate catalog entries that bake `/v1` into baseUrl
            // (pi-mono's models.generated.ts does this for OpenAI).
            // Without this, the session baseUrl `https://api.openai.com`
            // → `/v1/chat/completions`, but a `/model` swap pulls in
            // `https://api.openai.com/v1` and we'd double-suffix.
            let versioned = base.hasSuffix("/v1") ? base : "\(base)/v1"
            return URL(string: "\(versioned)/chat/completions")
                ?? fallback.appendingPathComponent("v1/chat/completions")
        }
        self.authHeaderBuilder = authHeaderBuilder ?? { key in ["Authorization": bearerHeaderValue(key)] }
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
        for (k, v) in model.headers ?? [:] { headers[k] = v }
        for (k, v) in extraHeaders { headers[k] = v }
        if let auth = options?.resolvedAuth {
            applyResolvedAuth(auth, to: &headers)
        } else if let key = options?.apiKey ?? defaultAPIKey {
            for (k, v) in authHeaderBuilder(key) { headers[k] = v }
        }
        let compat = Self.resolveCompat(model)
        let retention = options?.cacheRetention ?? .short
        if retention != .none,
           let sid = options?.sessionId, !sid.isEmpty,
           compat.sendSessionAffinityHeaders {
            headers["session_id"] = sid
            headers["x-client-request-id"] = sid
            headers["x-session-affinity"] = sid
        }
        headersDecorator?(&headers, model, context, options)
        for (k, v) in options?.headers ?? [:] { headers[k] = v }

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: body
            )
            if response.statusCode >= 400 {
                let bodyText = await Self.errorBodyPreview(from: stream)
                let msg = Self.makeError(
                    api: api, model: model,
                    text: "OpenAI returned status \(response.statusCode)\(bodyText)"
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
                // Reasoning content delta (provider-specific key). Probe in pi's
                // order — `reasoning_content` (DeepSeek/chutes) first, then
                // `reasoning` (OpenRouter), then `reasoning_text`. The matched
                // field name is stashed as the thinking block's signature so the
                // encoder can round-trip prior reasoning under the same key.
                let reasoningField: (field: String, text: String)? = {
                    if case .string(let r) = delta["reasoning_content"] ?? .null { return ("reasoning_content", r) }
                    if case .string(let r) = delta["reasoning"] ?? .null { return ("reasoning", r) }
                    if case .string(let r) = delta["reasoning_text"] ?? .null { return ("reasoning_text", r) }
                    return nil
                }()
                if let (field, reasoning) = reasoningField, !reasoning.isEmpty {
                    let (index, firstSeen) = state.noteThinkingBlock()
                    if !emittedStart {
                        out.push(.start(partial: state.snapshot()))
                        emittedStart = true
                    }
                    if firstSeen {
                        state.setThinkingSignature(index: index, signature: field)
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
        let compat = resolveCompat(model)
        var context = context
        context.messages = TransformMessages.normalize(context.messages, model: model)
        var root: [String: Any] = [
            "model": model.id,
            "stream": true,
            "messages": encodeMessages(model: model, context: context, compat: compat),
        ]
        if compat.supportsUsageInStreaming {
            root["stream_options"] = ["include_usage": true]
        }
        if compat.supportsStore {
            root["store"] = false
        }
        if let maxTokens = options?.maxTokens ?? (model.maxTokens > 0 ? model.maxTokens : nil) {
            root[compat.maxTokensField] = maxTokens
        }
        if let temp = options?.temperature { root["temperature"] = temp }
        var toolEntries: [[String: Any]]?
        if let tools = context.tools, !tools.isEmpty {
            toolEntries = encodeTools(tools, compat: compat)
            root["tools"] = toolEntries
            if let choice = encodeToolChoice(options?.toolChoice) {
                root["tool_choice"] = choice
            }
            if options?.parallelToolCalls == false {
                root["parallel_tool_calls"] = false
            }
            if compat.zaiToolStream {
                root["tool_stream"] = true
            }
        } else if hasToolHistory(context.messages) {
            root["tools"] = [[String: Any]]()
        }
        applyReasoning(&root, model: model, options: options, compat: compat)
        applyRouting(&root, compat: compat)
        if let meta = options?.metadata, let any = anyFromJSONValue(.object(meta)) {
            root["metadata"] = any
        }
        let retention = options?.cacheRetention ?? .short
        if let cacheControl = compatCacheControl(compat: compat, retention: retention) {
            var messages = root["messages"] as? [[String: Any]] ?? []
            var tools = root["tools"] as? [[String: Any]]
            applyAnthropicCacheControl(cacheControl, messages: &messages, tools: &tools)
            root["messages"] = messages
            if let tools { root["tools"] = tools }
        }
        // OpenAI-style `prompt_cache_key`/`prompt_cache_retention` must not be
        // mixed onto an endpoint that already took Anthropic `cache_control`
        // (e.g. OpenRouter `anthropic/*`) — those are different, conflicting wire
        // shapes. Only apply native cache when we did NOT apply the anthropic one.
        let openAINativeCache = compat.cacheControlFormat != "anthropic"
            && (model.baseUrl.contains("api.openai.com")
                || (retention == .long && compat.supportsLongCacheRetention))
        if openAINativeCache, retention != .none,
           let sid = clampOpenAIPromptCacheKey(options?.sessionId) {
            root["prompt_cache_key"] = sid
            if retention == .long, compat.supportsLongCacheRetention {
                root["prompt_cache_retention"] = "24h"
            }
        }
        return root
    }

    // MARK: - Reasoning / thinking format

    /// Subset of pi's resolved OpenAI-completions compat that the reasoning
    /// encoder needs. Auto-detected from provider/baseUrl, then overlaid with
    /// any explicit `model.compat`.
    struct ResolvedCompletionsCompat {
        var supportsStore: Bool
        var supportsDeveloperRole: Bool
        var supportsReasoningEffort: Bool
        var supportsUsageInStreaming: Bool
        var maxTokensField: String
        var requiresToolResultName: Bool
        var requiresAssistantAfterToolResult: Bool
        var requiresThinkingAsText: Bool
        var requiresReasoningContentOnAssistantMessages: Bool
        var thinkingFormat: String
        var chatTemplateKwargs: [String: JSONValue]
        var openRouterRouting: JSONValue?
        var vercelGatewayRouting: JSONValue?
        var zaiToolStream: Bool
        var supportsStrictMode: Bool
        var cacheControlFormat: String?
        var sendSessionAffinityHeaders: Bool
        var supportsLongCacheRetention: Bool
    }

    static func resolveCompat(_ model: Model) -> ResolvedCompletionsCompat {
        let url = model.baseUrl.lowercased()
        let provider = model.provider
        func has(_ s: String) -> Bool { url.contains(s) }
        let isZai = provider == "zai" || provider == "zai-coding-cn" || has("api.z.ai") || has("bigmodel.cn")
        let isTogether = provider == "together" || has("api.together.ai") || has("api.together.xyz")
        let isMoonshot = provider == "moonshotai" || provider == "moonshotai-cn" || has("api.moonshot.")
        let isOpenRouter = provider == "openrouter" || has("openrouter.ai")
        let isCloudflareWorkers = provider == "cloudflare-workers-ai" || has("api.cloudflare.com")
        let isNvidia = provider == "nvidia" || has("integrate.api.nvidia.com")
        let isAntLing = provider == "ant-ling" || has("api.ant-ling.com")
        let isDeepSeek = provider == "deepseek" || has("deepseek.com")
        let isGrok = provider == "xai" || has("api.x.ai")
        let isCfGateway = provider == "cloudflare-ai-gateway" || has("gateway.ai.cloudflare.com")
        let isCerebras = provider == "cerebras" || has("cerebras.ai")
        let isChutes = has("chutes.ai")
        let isOpencode = provider == "opencode" || has("opencode.ai")
        let isNonStandard = isNvidia || isCerebras || isGrok || isTogether || isChutes
            || isDeepSeek || isZai || isMoonshot || isOpencode || isCloudflareWorkers
            || isCfGateway || isAntLing
        let openRouterDeveloperRole = isOpenRouter && (model.id.hasPrefix("anthropic/") || model.id.hasPrefix("openai/"))
        let useMaxTokens = isChutes || isMoonshot || isCfGateway || isTogether || isNvidia || isAntLing

        let detectedReasoningEffort = !isGrok && !isZai && !isMoonshot && !isTogether && !isCfGateway && !isNvidia && !isAntLing
        let detectedFormat: String = isDeepSeek ? "deepseek"
            : isZai ? "zai"
            : isTogether ? "together"
            : isAntLing ? "ant-ling"
            : isOpenRouter ? "openrouter"
            : "openai"

        let c = model.compat
        return ResolvedCompletionsCompat(
            supportsStore: c?.supportsStore ?? !isNonStandard,
            supportsDeveloperRole: c?.supportsDeveloperRole ?? (openRouterDeveloperRole || (!isNonStandard && !isOpenRouter)),
            supportsReasoningEffort: c?.supportsReasoningEffort ?? detectedReasoningEffort,
            supportsUsageInStreaming: c?.supportsUsageInStreaming ?? true,
            maxTokensField: c?.maxTokensField ?? (useMaxTokens ? "max_tokens" : "max_completion_tokens"),
            requiresToolResultName: c?.requiresToolResultName ?? false,
            requiresAssistantAfterToolResult: c?.requiresAssistantAfterToolResult ?? false,
            requiresThinkingAsText: c?.requiresThinkingAsText ?? false,
            requiresReasoningContentOnAssistantMessages: c?.requiresReasoningContentOnAssistantMessages ?? isDeepSeek,
            thinkingFormat: c?.thinkingFormat ?? detectedFormat,
            chatTemplateKwargs: jsonObject(c?.chatTemplateKwargs) ?? [:],
            openRouterRouting: c?.openRouterRouting,
            vercelGatewayRouting: c?.vercelGatewayRouting,
            zaiToolStream: c?.zaiToolStream ?? false,
            supportsStrictMode: c?.supportsStrictMode ?? (!isMoonshot && !isTogether && !isCfGateway && !isNvidia),
            cacheControlFormat: c?.cacheControlFormat ?? ((provider == "openrouter" && model.id.hasPrefix("anthropic/")) ? "anthropic" : nil),
            sendSessionAffinityHeaders: c?.sendSessionAffinityHeaders ?? false,
            supportsLongCacheRetention: c?.supportsLongCacheRetention ?? !(isTogether || isCloudflareWorkers || isCfGateway || isNvidia || isAntLing)
        )
    }

    /// Encode the reasoning/thinking request fields for the model's
    /// `thinkingFormat`, honoring `thinkingLevelMap` remapping and clamping.
    /// Ports pi's openai-completions reasoning branch.
    static func applyReasoning(
        _ root: inout [String: Any], model: Model, options: StreamOptions?, compat: ResolvedCompletionsCompat
    ) {
        guard model.reasoning else { return }

        let requested: ModelThinkingLevel? = options?.reasoning.map {
            clampThinkingLevel(model, ModelThinkingLevel(reasoning: $0))
        }
        let hasEffort: Bool = { if let r = requested, r != .off { return true }; return false }()
        let level = requested ?? .off

        // Wire value for a level: mapped string if present & non-null, else raw.
        func wire(_ l: ModelThinkingLevel) -> String {
            if let map = model.thinkingLevelMap, let entry = map[l.rawValue], let v = entry { return v }
            return l.rawValue
        }
        let offEntry = model.thinkingLevelMap?["off"]            // absent / explicit-null / string
        let offIsExplicitNull = (offEntry != nil && offEntry! == nil)
        let offString: String? = { if let e = offEntry, let v = e { return v }; return nil }()

        switch compat.thinkingFormat {
        case "zai":
            root["thinking"] = ["type": hasEffort ? "enabled" : "disabled"]
            if hasEffort, compat.supportsReasoningEffort { root["reasoning_effort"] = wire(level) }
        case "qwen":
            root["enable_thinking"] = hasEffort
        case "qwen-chat-template":
            root["chat_template_kwargs"] = ["enable_thinking": hasEffort, "preserve_thinking": true]
        case "chat-template":
            if let kwargs = buildChatTemplateKwargs(
                model: model,
                requestedLevel: level,
                hasEffort: hasEffort,
                compat: compat
            ) {
                root["chat_template_kwargs"] = kwargs
            }
        case "deepseek":
            if hasEffort { root["thinking"] = ["type": "enabled"] }
            else if !offIsExplicitNull { root["thinking"] = ["type": "disabled"] }
            if hasEffort, compat.supportsReasoningEffort { root["reasoning_effort"] = wire(level) }
        case "openrouter":
            if hasEffort { root["reasoning"] = ["effort": wire(level)] }
            else if !offIsExplicitNull { root["reasoning"] = ["effort": offString ?? "none"] }
        case "ant-ling":
            if hasEffort, let map = model.thinkingLevelMap, let entry = map[level.rawValue], let v = entry {
                root["reasoning"] = ["effort": v]
            }
        case "together":
            root["reasoning"] = ["enabled": hasEffort]
            if hasEffort, compat.supportsReasoningEffort { root["reasoning_effort"] = wire(level) }
        case "string-thinking":
            if hasEffort { root["thinking"] = wire(level) }
            else if !offIsExplicitNull { root["thinking"] = offString ?? "none" }
        default: // "openai"
            if hasEffort, compat.supportsReasoningEffort {
                root["reasoning_effort"] = wire(level)
            } else if !hasEffort, compat.supportsReasoningEffort, let off = offString {
                root["reasoning_effort"] = off
            }
        }
    }

    private static func buildChatTemplateKwargs(
        model: Model,
        requestedLevel: ModelThinkingLevel,
        hasEffort: Bool,
        compat: ResolvedCompletionsCompat
    ) -> [String: Any]? {
        var kwargs: [String: Any] = [:]
        for (key, value) in compat.chatTemplateKwargs {
            guard let resolved = resolveChatTemplateKwarg(
                value,
                model: model,
                requestedLevel: requestedLevel,
                hasEffort: hasEffort
            ) else { continue }
            kwargs[key] = anyFromJSONValue(resolved) ?? NSNull()
        }
        return kwargs.isEmpty ? nil : kwargs
    }

    private static func resolveChatTemplateKwarg(
        _ value: JSONValue,
        model: Model,
        requestedLevel: ModelThinkingLevel,
        hasEffort: Bool
    ) -> JSONValue? {
        guard case .object(let object) = value else { return value }
        guard case .string(let variable)? = object["$var"] else { return value }
        if case .bool(true)? = object["omitWhenOff"], !hasEffort {
            return nil
        }
        switch variable {
        case "thinking.enabled":
            return .bool(hasEffort)
        case "thinking.effort":
            if hasEffort {
                return thinkingMapValue(model, requestedLevel.rawValue, fallback: requestedLevel.rawValue)
            }
            return thinkingMapValue(model, "off", fallback: nil)
        default:
            return nil
        }
    }

    private static func thinkingMapValue(
        _ model: Model,
        _ key: String,
        fallback: String?
    ) -> JSONValue? {
        if let map = model.thinkingLevelMap, map.keys.contains(key) {
            guard let value = map[key] ?? nil else { return nil }
            return .string(value)
        }
        return fallback.map(JSONValue.string)
    }

    private static func applyRouting(_ root: inout [String: Any], compat: ResolvedCompletionsCompat) {
        if let routing = compat.openRouterRouting,
           let object = jsonObject(routing),
           !object.isEmpty,
           let any = anyFromJSONValue(.object(object)) {
            root["provider"] = any
        }
        if let routing = compat.vercelGatewayRouting,
           let gateway = vercelGatewayOptions(routing) {
            root["providerOptions"] = ["gateway": gateway]
        }
    }

    private static func vercelGatewayOptions(_ routing: JSONValue) -> [String: Any]? {
        guard case .object(let object) = routing else { return nil }
        var gateway: [String: Any] = [:]
        if let only = object["only"], let any = anyFromJSONValue(only) {
            gateway["only"] = any
        }
        if let order = object["order"], let any = anyFromJSONValue(order) {
            gateway["order"] = any
        }
        return gateway.isEmpty ? nil : gateway
    }

    private static func jsonObject(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private static func encodeMessages(
        model: Model, context: Context, compat: ResolvedCompletionsCompat
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let sys = context.systemPrompt, !sys.isEmpty {
            let role = model.reasoning && compat.supportsDeveloperRole ? "developer" : "system"
            out.append(["role": role, "content": sys])
        }
        var lastRole: Role?
        for message in context.messages {
            if compat.requiresAssistantAfterToolResult, lastRole == .toolResult, message.role == .user {
                out.append(["role": "assistant", "content": "I have processed the tool results."])
            }
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
                lastRole = .user
            case .assistant(let a):
                var entry: [String: Any] = ["role": "assistant"]
                let textBlocks = a.content.compactMap { block -> TextContent? in
                    if case .text(let t) = block, !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return t
                    }
                    return nil
                }
                let thinkingBlocks = a.content.compactMap { block -> ThinkingContent? in
                    if case .thinking(let t) = block, !t.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return t
                    }
                    return nil
                }
                let textBody = textBlocks.map(\.text).joined()
                if compat.requiresThinkingAsText, !thinkingBlocks.isEmpty {
                    var parts = thinkingBlocks.map { ["type": "text", "text": $0.thinking] }
                    parts.append(contentsOf: textBlocks.map { ["type": "text", "text": $0.text] })
                    entry["content"] = parts
                } else {
                    entry["content"] = textBody.isEmpty
                        ? (compat.requiresAssistantAfterToolResult ? "" : NSNull())
                        : textBody
                    if let signature = thinkingBlocks.first?.thinkingSignature, !signature.isEmpty {
                        // Round-trip prior reasoning under the same field the
                        // stream decoder reads it from (`reasoning_content`).
                        // Using the signature *value* as the key produced a
                        // bogus JSON field and dropped the reasoning text.
                        entry["reasoning_content"] = thinkingBlocks.map(\.thinking).joined(separator: "\n")
                    }
                }
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
                if compat.requiresReasoningContentOnAssistantMessages, model.reasoning,
                   entry["reasoning_content"] == nil {
                    entry["reasoning_content"] = ""
                }
                let content = entry["content"]
                let hasContent: Bool = {
                    if content is NSNull { return false }
                    if let s = content as? String { return !s.isEmpty }
                    if let arr = content as? [[String: Any]] { return !arr.isEmpty }
                    return content != nil
                }()
                if !hasContent && calls.isEmpty {
                    continue
                }
                out.append(entry)
                lastRole = .assistant
            case .toolResult(let tr):
                let text = tr.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined(separator: "\n")
                var entry: [String: Any] = [
                    "role": "tool",
                    "tool_call_id": tr.toolCallId,
                    "content": text,
                ]
                if compat.requiresToolResultName, !tr.toolName.isEmpty {
                    entry["name"] = tr.toolName
                }
                out.append(entry)
                lastRole = .toolResult
            }
        }
        return out
    }

    private static func encodeTools(_ tools: [Tool], compat: ResolvedCompletionsCompat) -> [[String: Any]] {
        tools.map { tool -> [String: Any] in
            var fn: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
            ]
            if let params = anyFromJSONValue(tool.parameters) {
                fn["parameters"] = params
            }
            if compat.supportsStrictMode {
                fn["strict"] = false
            }
            return ["type": "function", "function": fn]
        }
    }

    private static func hasToolHistory(_ messages: [Message]) -> Bool {
        messages.contains { message in
            switch message {
            case .toolResult:
                return true
            case .assistant(let a):
                return a.content.contains { if case .toolCall = $0 { return true }; return false }
            case .user:
                return false
            }
        }
    }

    private static func compatCacheControl(
        compat: ResolvedCompletionsCompat, retention: CacheRetention
    ) -> [String: Any]? {
        guard compat.cacheControlFormat == "anthropic", retention != .none else { return nil }
        if retention == .long, compat.supportsLongCacheRetention {
            return ["type": "ephemeral", "ttl": "1h"]
        }
        return ["type": "ephemeral"]
    }

    private static func applyAnthropicCacheControl(
        _ cacheControl: [String: Any],
        messages: inout [[String: Any]],
        tools: inout [[String: Any]]?
    ) {
        for index in messages.indices {
            guard ["system", "developer"].contains(messages[index]["role"] as? String) else { continue }
            if addCacheControl(cacheControl, toTextContentOf: &messages[index]) { break }
        }
        if var toolEntries = tools, !toolEntries.isEmpty {
            toolEntries[toolEntries.count - 1]["cache_control"] = cacheControl
            tools = toolEntries
        }
        for index in messages.indices.reversed() {
            guard ["user", "assistant"].contains(messages[index]["role"] as? String) else { continue }
            if addCacheControl(cacheControl, toTextContentOf: &messages[index]) { break }
        }
    }

    @discardableResult
    private static func addCacheControl(
        _ cacheControl: [String: Any], toTextContentOf message: inout [String: Any]
    ) -> Bool {
        if let text = message["content"] as? String, !text.isEmpty {
            message["content"] = [["type": "text", "text": text, "cache_control": cacheControl]]
            return true
        }
        guard var parts = message["content"] as? [[String: Any]] else { return false }
        for index in parts.indices.reversed() where parts[index]["type"] as? String == "text" {
            parts[index]["cache_control"] = cacheControl
            message["content"] = parts
            return true
        }
        return false
    }

    static func clampOpenAIPromptCacheKey(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let chars = Array(key)
        if chars.count <= 64 { return key }
        return String(chars.prefix(64))
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
        case "stop", "end": return .stop
        case "length", "max_tokens": return .length
        case "tool_calls", "function_call": return .toolUse
        // pi surfaces these as errors rather than a clean stop so the agent
        // doesn't treat a filtered/aborted turn as a successful completion.
        case "content_filter", "network_error": return .error
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

    private static func errorBodyPreview(
        from stream: AsyncThrowingStream<UInt8, Error>,
        limit: Int = 4096
    ) async -> String {
        var data = Data()
        do {
            for try await byte in stream {
                data.append(byte)
                if data.count >= limit {
                    break
                }
            }
        } catch {
            return ": failed to read error body: \(error)"
        }
        guard !data.isEmpty else { return "" }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return ": \(text)"
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

    func setThinkingSignature(index: Int, signature: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index], th.thinkingSignature == nil {
                th.thinkingSignature = signature
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

/// Expand Cloudflare base-URL placeholders (`{CLOUDFLARE_ACCOUNT_ID}` /
/// `{CLOUDFLARE_GATEWAY_ID}`) from a value source (defaults to the process
/// environment). Mirrors pi's `resolveCloudflareBaseUrl`: the catalog stores
/// the literal tokens in `model.baseUrl` and they are substituted at request
/// time. Unknown/missing values collapse to the empty string.
func substituteCloudflarePlaceholders(
    in baseUrl: String,
    value: (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
) -> String {
    guard baseUrl.contains("{CLOUDFLARE_") else { return baseUrl }
    var result = baseUrl
    for token in ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_GATEWAY_ID"] {
        let needle = "{\(token)}"
        guard result.contains(needle) else { continue }
        result = result.replacingOccurrences(of: needle, with: value(token) ?? "")
    }
    return result
}
