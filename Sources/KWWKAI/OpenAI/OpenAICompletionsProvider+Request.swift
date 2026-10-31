import Foundation

extension OpenAICompletionsProvider {
    // MARK: - Encoding

    static func encodeBodyDict(
        model: Model,
        context: Context,
        options: StreamOptions?
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
        if let maxTokens = OutputTokenPolicy.effectiveLimit(
            for: model,
            requested: options?.maxTokens
        ) {
            root[compat.maxTokensField] = maxTokens
        }
        // Kimi locks the sampling temperature on kimi-k2.5 and later and
        // refuses any other value with 400 "invalid temperature: only 1 is
        // allowed for this model" (magpie #1197), so the caller's is left out
        // and the server fills in the one the model and mode take.
        if let temp = options?.temperature,
           !(compat.isKimi && kimiLocksSampling(model.id)) {
            root["temperature"] = temp
        }
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
        if let meta = options?.metadata, !meta.isEmpty, let any = anyFromJSONValue(.object(meta)) {
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
            && (model.baseURL.contains("api.openai.com")
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
    /// encoder needs. Auto-detected from provider/baseURL, then overlaid with
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
        var sessionAffinityFormat: String
        var supportsLongCacheRetention: Bool
        /// xAI's API: a tool's parameters must be an object at the root.
        var requiresObjectSchemaRoot: Bool
        /// xAI's API, by provider or host.
        var isXai: Bool
        /// Moonshot's API or Kimi's coding host.
        var isKimi: Bool
    }

    static func resolveCompat(_ model: Model) -> ResolvedCompletionsCompat {
        let url = model.baseURL.lowercased()
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
        let openRouterDeveloperRole = isOpenRouter
            && (model.id.hasPrefix("anthropic/") || model.id.hasPrefix("openai/"))
        let useMaxTokens = isChutes || isMoonshot || isCfGateway || isTogether || isNvidia || isAntLing

        let detectedReasoningEffort = !isGrok && !isZai && !isMoonshot && !isTogether
            && !isCfGateway && !isNvidia && !isAntLing
        let detectedFormat: String = isDeepSeek ? "deepseek"
            : isZai ? "zai"
            : isTogether ? "together"
            : isAntLing ? "ant-ling"
            : isOpenRouter ? "openrouter"
            : "openai"

        let c = model.compat
        return ResolvedCompletionsCompat(
            supportsStore: c?.supportsStore ?? !isNonStandard,
            supportsDeveloperRole: c?.supportsDeveloperRole
                ?? (openRouterDeveloperRole || (!isNonStandard && !isOpenRouter)),
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
            cacheControlFormat: c?.cacheControlFormat
                ?? ((provider == "openrouter" && model.id.hasPrefix("anthropic/")) ? "anthropic" : nil),
            // OpenRouter uses the session id to keep provider/model routing
            // sticky across an agent run. Built-in OpenRouter catalog entries
            // do not repeat this flag per model, so enable it from provider /
            // base-URL detection while preserving an explicit opt-out.
            sendSessionAffinityHeaders: c?.sendSessionAffinityHeaders ?? isOpenRouter,
            sessionAffinityFormat: c?.sessionAffinityFormat ?? (isOpenRouter ? "openrouter" : "openai"),
            supportsLongCacheRetention: c?.supportsLongCacheRetention
                ?? !(isTogether || isCloudflareWorkers || isCfGateway || isNvidia || isAntLing),
            requiresObjectSchemaRoot: isGrok,
            isXai: isGrok,
            isKimi: isMoonshot || has("api.kimi.com") || has("api.kimi.ai")
        )
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
        model: Model,
        context: Context,
        compat: ResolvedCompletionsCompat
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let sys = context.systemPrompt, !sys.isEmpty {
            let role = model.reasoning && compat.supportsDeveloperRole ? "developer" : "system"
            out.append(["role": role, "content": sys])
        }
        var lastRole: Role?
        // Chat Completions has no mid-conversation tool changes: the request's
        // top-level tool list already holds every current tool.
        let msgs = TranscriptTools.withoutSystemMessages(context.messages)
        var i = 0
        while i < msgs.count {
            let message = msgs[i]
            if compat.requiresAssistantAfterToolResult, lastRole == .toolResult, message.role == .user {
                out.append(["role": "assistant", "content": "I have processed the tool results."])
            }
            switch message {
            case .system:
                break
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
                if !calls.isEmpty {
                    // Re-emit encrypted reasoning details stored on tool calls'
                    // thoughtSignature (serialized JSON of the detail object).
                    let details: [Any] = a.content.compactMap { block -> Any? in
                        guard case .toolCall(let tc) = block,
                              let sig = tc.thoughtSignature, !sig.isEmpty,
                              let data = sig.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data),
                              let dict = obj as? [String: Any],
                              (dict["type"] as? String) == "reasoning.encrypted" else { return nil }
                        return dict
                    }
                    if !details.isEmpty { entry["reasoning_details"] = details }
                }
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
                    i += 1
                    continue
                }
                out.append(entry)
                lastRole = .assistant
            case .toolResult:
                // Aggregate consecutive tool results so trailing tool-result
                // images can be forwarded together as a single user carrier.
                var imageParts: [[String: Any]] = []
                var j = i
                while j < msgs.count, case .toolResult(let tr) = msgs[j] {
                    let text = tr.content.compactMap { block -> String? in
                        if case .text(let t) = block { return t.text } else { return nil }
                    }.joined(separator: "\n")
                    let hasImages = tr.content.contains {
                        if case .image = $0 { return true }; return false
                    }
                    var entry: [String: Any] = [
                        "role": "tool",
                        "tool_call_id": tr.toolCallId,
                        "content": text.isEmpty ? "(see attached image)" : text,
                    ]
                    if compat.requiresToolResultName, !tr.toolName.isEmpty {
                        entry["name"] = tr.toolName
                    }
                    out.append(entry)
                    if hasImages, model.input.contains(.image) {
                        for block in tr.content {
                            if case .image(let img) = block {
                                imageParts.append([
                                    "type": "image_url",
                                    "image_url": ["url": "data:\(img.mimeType);base64,\(img.data)"],
                                ])
                            }
                        }
                    }
                    j += 1
                }
                i = j
                if !imageParts.isEmpty {
                    if compat.requiresAssistantAfterToolResult {
                        out.append(["role": "assistant", "content": "I have processed the tool results."])
                    }
                    var carrier: [[String: Any]] = [["type": "text", "text": "Attached image(s) from tool result:"]]
                    carrier.append(contentsOf: imageParts)
                    out.append(["role": "user", "content": carrier])
                    lastRole = .user
                } else {
                    lastRole = .toolResult
                }
                continue
            }
            i += 1
        }
        if DeepSeekToolTurnReasoning.appliesToChat(model) {
            // DeepSeek refuses a tool turn without reasoning_content, on
            // any host that serves its models (magpie #1462, #1822).
            out = DeepSeekToolTurnReasoning.chatMessages(out)
        }
        return out
    }

    private static func encodeTools(_ tools: [Tool], compat: ResolvedCompletionsCompat) -> [[String: Any]] {
        tools.map { tool -> [String: Any] in
            var fn: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
            ]
            var schema = tool.parameters
            // xAI refuses a root union with 400 "[invalid_client_tool_schema]
            // ... tool parameter root must be an object type", and one such
            // tool fails the whole request (magpie #1271).
            if compat.requiresObjectSchemaRoot { schema = ToolSchemaRoot.objectRoot(schema) }
            // Moonshot refuses an enum with no type, 400 "tools.function.
            // parameters is not a valid moonshot flavored json schema ...
            // type is not defined" (magpie #886), though the tool is never
            // called.
            if compat.isKimi { schema = kimiTypedEnums(schema) }
            if let params = anyFromJSONValue(schema) {
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
            case .user, .system:
                return false
            }
        }
    }

    private static func compatCacheControl(
        compat: ResolvedCompletionsCompat,
        retention: CacheRetention
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
        _ cacheControl: [String: Any],
        toTextContentOf message: inout [String: Any]
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
}

/// `schema` with a `type` written into each schema of it that has an `enum`
/// (or a `const`) and none: the type every value has. Values of mixed types,
/// or a null among them, are left as they were.
func kimiTypedEnums(_ schema: JSONValue) -> JSONValue {
    guard case .object(var object) = schema else { return schema }
    if object["type"] == nil {
        let values: [JSONValue]? = {
            if case .array(let values)? = object["enum"] { return values }
            return object["const"].map { [$0] }
        }()
        if let type = kimiValuesType(values ?? []) { object["type"] = .string(type) }
    }
    for (key, value) in object {
        switch key {
        case "properties", "$defs", "definitions", "dependentSchemas", "patternProperties":
            guard case .object(let members) = value else { continue }
            object[key] = .object(members.mapValues(kimiTypedEnums))
        case "items", "additionalProperties", "contains", "propertyNames", "not", "if", "then", "else",
             "allOf", "anyOf", "oneOf", "prefixItems", "unevaluatedProperties", "unevaluatedItems",
             "contentSchema":
            if case .array(let members) = value {
                object[key] = .array(members.map(kimiTypedEnums))
            } else {
                object[key] = kimiTypedEnums(value)
            }
        default:
            continue
        }
    }
    return .object(object)
}

private func kimiValuesType(_ values: [JSONValue]) -> String? {
    var type: String?
    for value in values {
        let own: String
        switch value {
        case .string: own = "string"
        case .bool: own = "boolean"
        case .int: own = "integer"
        case .double: own = "number"
        default: return nil
        }
        guard let seen = type, seen != own else {
            type = own
            continue
        }
        // whole numbers among fractions make them number
        let numeric: Set<String> = ["integer", "number"]
        guard numeric.contains(seen), numeric.contains(own) else { return nil }
        type = "number"
    }
    return type
}

/// Whether Kimi's server locks the model's temperature: kimi-for-coding*
/// and k3* on Kimi Code, kimi-k2.5 and later on either platform. Models that
/// take a range (moonshot-v1-*, kimi-k2-0905-preview, kimi-k2-thinking,
/// kimi-latest) keep the caller's. A leading "vendor/" is ignored.
func kimiLocksSampling(_ modelId: String) -> Bool {
    let id = modelId.lowercased().split(separator: "/").last.map(String.init) ?? ""
    if id.hasPrefix("kimi-for-coding") { return true }
    let version: Substring
    if id.hasPrefix("kimi-k") {
        version = id.dropFirst("kimi-k".count)
    } else if id.hasPrefix("k") {
        version = id.dropFirst()
    } else {
        return false
    }
    let majorDigits = version.prefix(while: \.isNumber)
    guard let major = Int(majorDigits) else { return false }
    if major != 2 { return major >= 3 }
    let rest = version.dropFirst(majorDigits.count)
    guard rest.hasPrefix(".") else { return false }
    return (Int(rest.dropFirst().prefix(while: \.isNumber)) ?? -1) >= 5
}
