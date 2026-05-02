import Foundation

/// Diagnostic event emitted by providers or other internal components when
/// verbose mode is enabled. This is UI-only telemetry; providers must avoid
/// putting secrets or request bodies in these messages.
public struct VerboseEvent: Codable, Sendable, Hashable {
    public var timestamp: Int64
    public var source: String
    public var message: String
    public var metadata: [String: JSONValue]

    public init(
        source: String,
        message: String,
        metadata: [String: JSONValue] = [:],
        timestamp: Int64 = Timestamp.now()
    ) {
        self.timestamp = timestamp
        self.source = source
        self.message = message
        self.metadata = metadata
    }
}

/// Event emitted by `AssistantMessageStream`. Mirrors pi-ai's
/// `AssistantMessageEvent` discriminated union.
public enum AssistantMessageEvent: Sendable, Hashable {
    case start(partial: AssistantMessage)

    case textStart(contentIndex: Int, partial: AssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)

    case thinkingStart(contentIndex: Int, partial: AssistantMessage)
    case thinkingDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(contentIndex: Int, content: String, partial: AssistantMessage)

    case toolCallStart(contentIndex: Int, partial: AssistantMessage)
    case toolCallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case toolCallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)

    case done(reason: StopReason, message: AssistantMessage)
    case error(reason: StopReason, error: AssistantMessage)

    /// Discriminator string suitable for test assertions.
    public var type: String {
        switch self {
        case .start: return "start"
        case .textStart: return "text_start"
        case .textDelta: return "text_delta"
        case .textEnd: return "text_end"
        case .thinkingStart: return "thinking_start"
        case .thinkingDelta: return "thinking_delta"
        case .thinkingEnd: return "thinking_end"
        case .toolCallStart: return "toolcall_start"
        case .toolCallDelta: return "toolcall_delta"
        case .toolCallEnd: return "toolcall_end"
        case .done: return "done"
        case .error: return "error"
        }
    }
}
