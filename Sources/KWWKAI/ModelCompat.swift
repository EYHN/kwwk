import Foundation

/// Per-model compatibility overrides, ported from pi's `OpenAICompletionsCompat`,
/// `OpenAIResponsesCompat`, and `AnthropicMessagesCompat`. pi keys these by the
/// model's wire `api`; we flatten the three variants into a single optional
/// struct (every field nil = "provider default / auto-detect from baseUrl").
///
/// The bundled `models.json` ships a `compat` block on ~142 models; this struct
/// is what makes that data reachable from the Swift provider encoders.
public struct ModelCompat: Codable, Sendable, Hashable {
    // MARK: openai-completions
    public var supportsStore: Bool?
    public var supportsDeveloperRole: Bool?
    public var supportsReasoningEffort: Bool?
    public var supportsUsageInStreaming: Bool?
    /// "max_completion_tokens" | "max_tokens"
    public var maxTokensField: String?
    public var requiresToolResultName: Bool?
    public var requiresAssistantAfterToolResult: Bool?
    public var requiresThinkingAsText: Bool?
    public var requiresReasoningContentOnAssistantMessages: Bool?
    /// "openai" | "openrouter" | "deepseek" | "together" | "zai" | "qwen" |
    /// "chat-template" | "qwen-chat-template" | "string-thinking" | "ant-ling"
    public var thinkingFormat: String?
    public var chatTemplateKwargs: JSONValue?
    public var openRouterRouting: JSONValue?
    public var vercelGatewayRouting: JSONValue?
    public var zaiToolStream: Bool?
    public var supportsStrictMode: Bool?
    /// "anthropic" — apply Anthropic-style cache_control markers on an
    /// OpenAI-compatible request.
    public var cacheControlFormat: String?

    // MARK: shared (cache / session affinity)
    public var sendSessionAffinityHeaders: Bool?
    /// Session-affinity header format: "openai" sends `session_id`,
    /// `x-client-request-id`, and `x-session-affinity`; "openai-nosession"
    /// sends `x-client-request-id` and `x-session-affinity`; "openrouter"
    /// sends `x-session-id`. Does not affect the `prompt_cache_key` body
    /// param, which is governed by cache retention. Default: auto-detected.
    public var sessionAffinityFormat: String?
    public var supportsLongCacheRetention: Bool?

    // MARK: anthropic-messages
    public var supportsEagerToolInputStreaming: Bool?
    public var supportsCacheControlOnTools: Bool?
    public var supportsTemperature: Bool?
    public var forceAdaptiveThinking: Bool?
    public var allowEmptySignature: Bool?

    public init() {}
}

/// Thinking levels pi exposes per model. `off` is the only level for
/// non-reasoning models; the rest mirror `ReasoningLevel`.
public enum ModelThinkingLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    public init(reasoning: ReasoningLevel?) {
        guard let reasoning else { self = .off; return }
        switch reasoning {
        case .minimal: self = .minimal
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        case .xhigh: self = .xhigh
        case .max: self = .max
        }
    }

    /// The `ReasoningLevel` analog, or nil for `.off`.
    public var reasoningLevel: ReasoningLevel? {
        switch self {
        case .off: return nil
        case .minimal: return .minimal
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .xhigh: return .xhigh
        case .max: return .max
        }
    }
}

private let extendedThinkingLevels: [ModelThinkingLevel] = [
    .off, .minimal, .low, .medium, .high, .xhigh, .max,
]

/// Ported from pi `getSupportedThinkingLevels`. Honors `thinkingLevelMap`:
/// a level mapped to an explicit `null` is unsupported, while `xhigh` and
/// `max` require an explicit mapping entry to be offered at all.
public func supportedThinkingLevels(_ model: Model) -> [ModelThinkingLevel] {
    guard model.reasoning else { return [.off] }
    return extendedThinkingLevels.filter { level in
        guard let map = model.thinkingLevelMap, let entry = map[level.rawValue] else {
            // Extended levels need an explicit entry; lower levels use the
            // provider default when absent.
            return level != .xhigh && level != .max
        }
        // entry present: nil (NSNull) => unsupported
        if entry == nil { return false }
        return true
    }
}

/// Ported from pi `clampThinkingLevel`. Clamps a requested level to the nearest
/// supported one, searching upward first then falling back downward.
public func clampThinkingLevel(_ model: Model, _ level: ModelThinkingLevel) -> ModelThinkingLevel {
    let available = supportedThinkingLevels(model)
    if available.contains(level) { return level }
    guard let requestedIndex = extendedThinkingLevels.firstIndex(of: level) else {
        return available.first ?? .off
    }
    var i = requestedIndex
    while i < extendedThinkingLevels.count {
        if available.contains(extendedThinkingLevels[i]) { return extendedThinkingLevels[i] }
        i += 1
    }
    i = requestedIndex
    while i >= 0 {
        if available.contains(extendedThinkingLevels[i]) { return extendedThinkingLevels[i] }
        i -= 1
    }
    return available.first ?? .off
}

/// Resolves a requested level to the provider/model-specific wire value via
/// `thinkingLevelMap`, after clamping. Returns the mapped string (e.g. Bedrock
/// `xhigh` -> `"max"`), or the clamped level's raw value when unmapped, or nil
/// for `.off`.
public func resolveThinkingLevel(_ model: Model, _ requested: ModelThinkingLevel) -> String? {
    let clamped = clampThinkingLevel(model, requested)
    if clamped == .off { return nil }
    if let map = model.thinkingLevelMap, let entry = map[clamped.rawValue], let value = entry {
        return value
    }
    return clamped.rawValue
}
