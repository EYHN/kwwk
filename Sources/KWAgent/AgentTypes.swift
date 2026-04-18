import Foundation
import KWAI

/// Thinking/reasoning level passed to the model on each turn.
public enum ThinkingLevel: String, Sendable, Hashable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
}

/// Streaming function used by the agent loop. Implementations must encode all
/// failures as stream events ending in an assistant message with stopReason
/// `.error` or `.aborted` — never throw.
public typealias StreamFn = @Sendable (Model, Context, StreamOptions?) async throws -> AssistantMessageStream

/// Partial or final result returned by an `AgentTool.execute` call.
public struct AgentToolResult: Sendable, Hashable {
    public var content: [ToolResultBlock]
    public var details: JSONValue?
    public init(content: [ToolResultBlock], details: JSONValue? = nil) {
        self.content = content
        self.details = details
    }
}

public typealias AgentToolUpdate = @Sendable (AgentToolResult) -> Void

/// Tool executed by the agent. Throwing from `execute` is how tools report
/// failures — the agent loop will turn the error into an error tool result.
public struct AgentTool: Sendable {
    public var name: String
    public var label: String
    public var description: String
    public var parameters: JSONValue
    public var execute: @Sendable (
        _ toolCallId: String,
        _ args: JSONValue,
        _ cancellation: CancellationHandle?,
        _ onUpdate: AgentToolUpdate?
    ) async throws -> AgentToolResult

    public init(
        name: String,
        label: String,
        description: String,
        parameters: JSONValue,
        execute: @escaping @Sendable (
            _ toolCallId: String,
            _ args: JSONValue,
            _ cancellation: CancellationHandle?,
            _ onUpdate: AgentToolUpdate?
        ) async throws -> AgentToolResult
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.parameters = parameters
        self.execute = execute
    }
}

/// Events emitted by the agent runtime. Mirrors pi-agent-core's AgentEvent.
public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd(messages: [Message])

    case turnStart
    case turnEnd(message: Message, toolResults: [ToolResultMessage])

    case messageStart(message: Message)
    case messageUpdate(message: AssistantMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: Message)

    case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: JSONValue, partialResult: AgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)

    public var type: String {
        switch self {
        case .agentStart: return "agent_start"
        case .agentEnd: return "agent_end"
        case .turnStart: return "turn_start"
        case .turnEnd: return "turn_end"
        case .messageStart: return "message_start"
        case .messageUpdate: return "message_update"
        case .messageEnd: return "message_end"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        }
    }
}

public enum ToolExecutionMode: String, Sendable { case sequential, parallel }

/// How queued steering/follow-up messages are drained between turns.
public enum QueueMode: String, Sendable { case oneAtATime, all }

// MARK: - Tool call hooks

public struct BeforeToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCall
    public var args: JSONValue
    public var context: AgentContext
}

public struct BeforeToolCallResult: Sendable {
    public var block: Bool
    public var reason: String?
    public init(block: Bool = false, reason: String? = nil) {
        self.block = block
        self.reason = reason
    }
}

public struct AfterToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCall
    public var args: JSONValue
    public var result: AgentToolResult
    public var isError: Bool
    public var context: AgentContext
}

public struct AfterToolCallResult: Sendable {
    public var content: [ToolResultBlock]?
    public var details: JSONValue?
    public var isError: Bool?
    public init(content: [ToolResultBlock]? = nil, details: JSONValue? = nil, isError: Bool? = nil) {
        self.content = content
        self.details = details
        self.isError = isError
    }
}

public typealias BeforeToolCallHook = @Sendable (BeforeToolCallContext, CancellationHandle?) async -> BeforeToolCallResult?
public typealias AfterToolCallHook = @Sendable (AfterToolCallContext, CancellationHandle?) async -> AfterToolCallResult?

/// Transform the message list the LLM sees. Return nil to reuse the default
/// pass-through behavior. Mirrors pi-agent-core's `convertToLlm` /
/// `transformContext` hooks combined — use `transformContext` for pruning
/// (AgentMessage→AgentMessage) and `convertToLlm` for projecting to LLM
/// messages.
public typealias ConvertToLlmHook = @Sendable ([Message]) async -> [Message]
public typealias TransformContextHook = @Sendable ([Message], CancellationHandle?) async -> [Message]
