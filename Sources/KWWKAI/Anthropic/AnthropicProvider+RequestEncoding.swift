import Foundation

extension AnthropicProvider {
    // MARK: - Helpers

    static func encodeBody(
        model: Model,
        context: Context,
        options: StreamOptions?,
        systemPromptPrefix: String? = nil,
        maximumOutputTokens: Int? = nil,
        fallbackEnabled: Bool = false
    ) throws -> Data {
        var context = context
        context.messages = TransformMessages.normalize(
            context.messages,
            model: model,
            preserveAnthropicFallback: fallbackEnabled
        )
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
        if fallbackEnabled {
            root["fallbacks"] = [["model": "claude-opus-4-8"]]
        }
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
        // value != 1) and whenever the model declares it unsupported (Opus 4.7+)
        // or is a Claude known to refuse it under any catalog row.
        let temperatureAllowed = model.compat?.supportsTemperature != false
            && !refusesTemperature(model.id)
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
        // Native tool changes keep the top-level list fixed at the initial
        // tools and define every later change in place, so the cached prefix
        // survives tool loading (pi anthropic-messages.ts).
        let toolPlan = toolChangePlan(model: model, context: context)
        let requestTools = toolPlan.requestTools
        if !requestTools.isEmpty {
            var toolEntries = requestTools.map { encodeTool($0, supportsEager: supportsEager) }
            if cacheOnTools, let cc = cacheControl, !toolEntries.isEmpty {
                toolEntries[toolEntries.count - 1]["cache_control"] = cc
            }
            if toolPlan.anchorsChanges {
                toolEntries.append(deferredToolPlaceholder)
            }
            root["tools"] = toolEntries
            // Anthropic folds the parallel-tool-call switch into `tool_choice`
            // via a `disable_parallel_tool_use` flag. The default remains
            // parallel-on, so we only emit the block when the caller picks a
            // non-default choice OR disables parallel.
            if let toolChoice = buildToolChoice(options, model: model) {
                root["tool_choice"] = toolChoice
            }
        }
        // pi default for `allowEmptySignature` is `false`.
        let allowEmptySig = model.compat?.allowEmptySignature == true
        var messages: [[String: Any]] = []
        // Tool changes are held back and emitted directly before the next
        // assistant turn (or at the end): a system message between a
        // `tool_use` and its `tool_result` is rejected.
        var pendingToolChanges: [[String: Any]] = []
        let initialDeclaration = TranscriptTools.initialDeclarationIndex(in: context.messages)
        for (index, message) in context.messages.enumerated() {
            if case .system(let system) = message {
                guard toolPlan.anchorsChanges, index != initialDeclaration,
                      let encoded = encodeToolChanges(system, supportsEager: supportsEager) else { continue }
                pendingToolChanges.append(encoded)
                continue
            }
            guard let encoded = Self.encodeMessage(message, allowEmptySignature: allowEmptySig, fallbackEnabled: fallbackEnabled) else { continue }
            if encoded["role"] as? String == "assistant" {
                messages.append(contentsOf: pendingToolChanges)
                pendingToolChanges = []
            }
            // The results of parallel tool calls, and a user message that
            // follows them, go back as one user turn. Each is its own
            // transcript message, and two adjacent user messages are what
            // Claude merges but DeepSeek's Anthropic endpoint refuses with
            // 400 (YEL-514; omp collects consecutive results for z.ai,
            // magpie joins same-role turns). Results come first, as the
            // Messages API requires right after a tool_use turn.
            if encoded["role"] as? String == "user",
               let last = messages.last, last["role"] as? String == "user",
               let previous = last["content"] as? [[String: Any]],
               let next = encoded["content"] as? [[String: Any]] {
                messages[messages.count - 1]["content"] = previous + next
                continue
            }
            messages.append(encoded)
        }
        messages.append(contentsOf: pendingToolChanges)
        if context.messages.contains(where: {
            if case .user(let user) = $0 { return user.nativeCompaction?.api == "anthropic-messages" }
            return false
        }) {
            // Replaying a compaction block requires the strategy to remain
            // present, but only the agent decides when to compact again.
            root["context_management"] = ["edits": [[
                "type": "compact_20260112",
                "trigger": ["type": "input_tokens", "value": max(50_000, model.contextWindow)],
                "pause_after_compaction": true,
            ]]]
        }
        if DeepSeekToolTurnReasoning.appliesToAnthropic(model) {
            // DeepSeek refuses a tool turn without thinking, and Claude's
            // redacted thinking (magpie #1611, #1822).
            messages = DeepSeekToolTurnReasoning.anthropicMessages(messages)
        }
        if let cc = cacheControl, !messages.isEmpty {
            applyCacheControl(cc, toLastBlockOf: &messages[messages.count - 1])
        }
        root["messages"] = messages
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static let inlineToolsBeta = "inline-tools-2026-09-15"

    /// Declared whenever native tool changes are in use. Anthropic adds hidden
    /// prompt scaffolding for mid-conversation tool changes; declaring this
    /// deferred placeholder from the first request keeps that scaffolding in
    /// the cached prefix, so the first tool change does not invalidate the
    /// cache (pi measured a full miss without it). It is never activated.
    static var deferredToolPlaceholder: [String: Any] { [
        "name": "__kwwk_deferred_placeholder__",
        "description": "Reserved placeholder. Never available. Never call this.",
        "input_schema": ["type": "object", "properties": [String: Any](), "required": [String]()],
        "defer_loading": true,
    ] }

    /// Whether this request encodes transcript tool changes natively.
    static func toolChangePlan(model: Model, context: Context) -> TranscriptTools.Resolution {
        TranscriptTools.resolve(
            messages: context.messages,
            tools: context.tools,
            supportsChanges: model.compat?.supportsMidConvoSystemMessages == true
                && model.compat?.supportsMidConvoToolChanges == true,
            allowsNonAdditive: true
        )
    }

    static func encodeTool(_ tool: Tool, supportsEager: Bool) -> [String: Any] {
        var entry: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if supportsEager { entry["eager_input_streaming"] = true }
        if let params = anyFromJSONValue(ToolSchemaRoot.objectRoot(tool.parameters)) {
            entry["input_schema"] = params
        }
        return entry
    }

    /// A system-role message carrying `tool_removal` / `tool_addition`
    /// blocks. A new definition under an existing name replaces the old one,
    /// so it needs no removal.
    static func encodeToolChanges(_ system: SystemMessage, supportsEager: Bool) -> [String: Any]? {
        let added = system.toolsAdded ?? []
        let redefined = Set(added.map(\.name))
        var blocks: [[String: Any]] = []
        for name in system.toolsRemoved ?? [] where !redefined.contains(name) {
            blocks.append(["type": "tool_removal", "tool": ["type": "tool_reference", "name": name]])
        }
        for tool in added {
            blocks.append([
                "type": "tool_addition",
                "tool": ["type": "tool_definition", "definition": encodeTool(tool, supportsEager: supportsEager)],
            ])
        }
        return blocks.isEmpty ? nil : ["role": "system", "content": blocks]
    }

    /// Attach a `cache_control` marker to the final content block of a message,
    /// closing the cached prefix at the end of the conversation.
    private static func applyCacheControl(_ cc: [String: Any], toLastBlockOf message: inout [String: Any]) {
        guard var content = message["content"] as? [[String: Any]], !content.isEmpty else { return }
        guard let index = content.lastIndex(where: { !["fallback", "thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }) else { return }
        content[index]["cache_control"] = cc
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

    static func buildToolChoice(_ options: StreamOptions?, model: Model) -> [String: Any]? {
        let choice = options?.toolChoice
        let parallelOff = options?.parallelToolCalls == false
        if choice == nil && !parallelOff { return nil }
        let forced = !refusesForcedToolChoice(model.id)
        var out: [String: Any]
        switch choice ?? .auto {
        case .auto: out = ["type": "auto"]
        case .none: out = ["type": "none"]
        case .required: out = forced ? ["type": "any"] : ["type": "auto"]
        case .tool(let name): out = forced ? ["type": "tool", "name": name] : ["type": "auto"]
        }
        if parallelOff { out["disable_parallel_tool_use"] = true }
        return out
    }

    /// Claude Opus 5.5, Sonnet 5.5 and Fable 5.1 answer 400 `tool_choice:
    /// type "tool" and "any" are not supported for this model`; Fable 5,
    /// Opus 5, Sonnet 5 and everything 4.x still take a forced choice
    /// (measured 2026-10-10). So a Claude from 5.1 on gets `auto`, which
    /// calls the tool when it is the only one offered — as the agent loop's
    /// terminal turn offers it.
    static func refusesForcedToolChoice(_ modelId: String) -> Bool {
        guard let match = firstMatch(forcedToolChoicePattern, in: modelId.lowercased()),
              let major = match[1].flatMap({ Int($0) }),
              let minor = match[2].flatMap({ Int($0) }) else { return false }
        return (major, minor) >= (5, 1)
    }

    /// Claude Sonnet 5, Fable 5 and Fable 5.1 answer 400 "`temperature` is
    /// deprecated for this model." to any value (measured 2026-10-11, with
    /// catalog rows that do not say so); Opus from 4.7 does too, and Haiku 5.5
    /// takes only its default (magpie #1454, through a relay). Read off the id
    /// so a relay's or Bedrock's spelling of the same model is covered. Older
    /// Claudes and other vendors' models keep the caller's temperature.
    static func refusesTemperature(_ modelId: String) -> Bool {
        guard let match = firstMatch(temperaturePattern, in: modelId.lowercased()),
              let family = match[1], let major = match[2].flatMap({ Int($0) }) else { return false }
        let version = (major, match[3].flatMap { Int($0) } ?? 0)
        switch family {
        case "opus": return version >= (4, 7)
        case "sonnet": return version >= (5, 0)
        case "haiku": return version >= (5, 5)
        default: return true
        }
    }

    // NSRegularExpression rather than `Regex` literals, which need iOS 16.
    private static let forcedToolChoicePattern = try! NSRegularExpression(
        pattern: #"claude-[a-z]+-(\d)[-.](\d{1,2})(?!\d)"#
    )
    private static let temperaturePattern = try! NSRegularExpression(
        pattern: #"claude-(opus|sonnet|haiku|fable|mythos)-(\d)(?!\d)(?:[-.](\d{1,2})(?!\d))?"#
    )

    /// Capture groups of the first match, index 0 being the whole match; a
    /// group that did not participate is nil.
    private static func firstMatch(_ regex: NSRegularExpression, in string: String) -> [String?]? {
        let range = NSRange(string.startIndex..., in: string)
        guard let result = regex.firstMatch(in: string, range: range) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: string).map { String(string[$0]) }
        }
    }

    /// The Messages API takes an image's `media_type` only as exactly
    /// `image/jpeg`, `image/png`, `image/gif` or `image/webp`: `image/jpg`,
    /// `IMAGE/JPEG` and `image/jpeg; charset=binary` are each a 400 "Input
    /// should be 'image/jpeg', …" (measured 2026-10-11), and once such an
    /// image is in the transcript every later turn fails. MCP servers report
    /// whatever type they like, so it is put in Anthropic's spelling here.
    static func imageMediaType(_ mimeType: String) -> String {
        let type = mimeType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? mimeType
        return type == "image/jpg" ? "image/jpeg" : type
    }

    private static func encodeMessage(
        _ message: Message,
        allowEmptySignature: Bool,
        fallbackEnabled: Bool
    ) -> [String: Any]? {
        switch message {
        case .system:
            // Encoded by `encodeToolChanges` when the request anchors tool
            // changes; otherwise the top-level list holds every tool.
            return nil
        case .user(let u):
            if let native = u.nativeCompaction, native.api == "anthropic-messages" {
                var blocks = native.items.compactMap { anyFromJSONValue($0) as? [String: Any] }
                // The host recap also carries current background-task/fact
                // ledgers, which are not part of the provider's summary.
                for case .text(let text) in u.content {
                    blocks.append(["type": "text", "text": text.text])
                }
                return ["role": "assistant", "content": blocks]
            }
            let content = u.content.compactMap { block -> [String: Any]? in
                switch block {
                case .text(let t):
                    guard !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return ["type": "text", "text": t.text]
                case .image(let i):
                    return [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": imageMediaType(i.mimeType),
                            "data": i.data,
                        ],
                    ]
                }
            }
            guard !content.isEmpty else { return nil }
            return ["role": "user", "content": content]

        case .assistant(let a):
            var blocks: [[String: Any]] = []
            for block in a.content {
                switch block {
                case .fallback(let fallback):
                    if fallbackEnabled {
                        blocks.append([
                            "type": "fallback",
                            "from": ["model": fallback.from.model],
                            "to": ["model": fallback.to.model]
                        ])
                    }
                case .text(let t):
                    // Cross-provider history and tool-only turns can contain
                    // empty text. Kimi rejects these even beside valid blocks.
                    guard !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
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
            guard !blocks.isEmpty else { return nil }
            // Anthropic requires tool_use blocks at the end. Preserve the
            // signed thinking/fallback boundary order within the non-tool part.
            blocks = blocks.filter { $0["type"] as? String != "tool_use" }
                + blocks.filter { $0["type"] as? String == "tool_use" }
            return ["role": "assistant", "content": blocks]

        case .toolResult(let tr):
            var inner = tr.content.compactMap { block -> [String: Any]? in
                switch block {
                case .text(let t):
                    guard !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return ["type": "text", "text": t.text]
                case .image(let i):
                    return [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": imageMediaType(i.mimeType),
                            "data": i.data,
                        ],
                    ]
                }
            }
            // An empty tool result is valid and must still answer its tool
            // call. Kimi rejects omitted content with "Invalid request Error"
            // but accepts an explicit empty array. Do not send empty text.
            // A failed one is the exception: Anthropic answers 400 "content
            // cannot be empty if `is_error` is true" (measured 2026-10-11),
            // and the block is replayed on every later turn, so a failure
            // with nothing to say goes with a line that says so.
            if tr.isError, inner.isEmpty {
                inner = [["type": "text", "text": "(no output)"]]
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
