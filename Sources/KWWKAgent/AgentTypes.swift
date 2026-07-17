import Foundation
import KWWKAI

/// Thinking/reasoning level passed to the model on each turn.
public enum ThinkingLevel: String, Sendable, Hashable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}

/// How the transcript UI should surface assistant thinking blocks. Orthogonal
/// to `ThinkingLevel` (which controls what the provider is asked to
/// produce) — this is purely a display preference.
///
///  - `collapsed` (default): show a one-line marker with elapsed time —
///    `[thinking 2s…]` while in progress, `[thought for 3.4s]` once done.
///    Tidier, keeps focus on the answer.
///  - `expanded`: show the full thinking body dimmed inline.
public enum ThinkingDisplay: String, Sendable, Hashable {
    case collapsed
    case expanded
}

/// Streaming function used by the agent loop. Implementations must encode all
/// failures as stream events ending in an assistant message with stopReason
/// `.error` or `.aborted` — never throw.
public typealias StreamFn = @Sendable (Model, Context, StreamOptions?) async throws -> AssistantMessageStream

/// Partial or final result returned by an `AgentTool.execute` call.
public struct AgentToolResult: Sendable, Hashable {
    public var content: [ToolResultBlock]
    public var details: JSONValue?
    /// Structured runtime events produced by the tool. The agent loop
    /// forwards these as `AgentEvent.runtimeEvent` after the corresponding
    /// tool update/end event. They are process-local telemetry; providers
    /// never see them.
    public var runtimeEvents: [AgentRuntimeEvent]?
    /// Optional UI-only display lines. When non-nil, the TUI renderer
    /// prefers these over its default truncated preview of `content`.
    /// Tools use this to summarize noisy output for the user (e.g.
    /// "listed 847 paths", "matched 3 files", "exit 0 · 2.3s") while
    /// still handing the full `content` to the LLM.
    ///
    /// Pure UI-side data — never leaves the process, never seen by any
    /// provider. Doesn't affect `content` → wire serialization.
    public var uiDisplay: [String]?
    /// Process-local delivery transaction carried by results that replace an
    /// automatic runtime notification. It is deliberately internal: providers,
    /// persisted transcripts, and SDK callers only see the paired tool result.
    var retentionLease: AgentToolRetentionLease?

    public init(
        content: [ToolResultBlock],
        details: JSONValue? = nil,
        runtimeEvents: [AgentRuntimeEvent]? = nil,
        uiDisplay: [String]? = nil
    ) {
        self.content = content
        self.details = details
        self.runtimeEvents = runtimeEvents
        self.uiDisplay = uiDisplay
        self.retentionLease = nil
    }
}

/// A tiny commit/rollback token for side-channel delivery ownership. Identity
/// hashing keeps `AgentToolResult` Hashable without comparing closures.
final class AgentToolRetentionLease: @unchecked Sendable, Hashable {
    private let id = UUID()
    private let lock = NSLock()
    private var resolution: Resolution?
    private let onCommit: @Sendable () -> Void
    private let onRollback: @Sendable () -> Void

    private enum Resolution {
        case committed
        case rolledBack
    }

    init(
        onCommit: @escaping @Sendable () -> Void,
        onRollback: @escaping @Sendable () -> Void
    ) {
        self.onCommit = onCommit
        self.onRollback = onRollback
    }

    deinit {
        rollback()
    }

    func commit() {
        let shouldRun = lock.withLock { () -> Bool in
            guard resolution == nil else { return false }
            resolution = .committed
            return true
        }
        if shouldRun { onCommit() }
    }

    func rollback() {
        let shouldRun = lock.withLock { () -> Bool in
            guard resolution == nil else { return false }
            resolution = .rolledBack
            return true
        }
        if shouldRun { onRollback() }
    }

    static func == (lhs: AgentToolRetentionLease, rhs: AgentToolRetentionLease) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public typealias AgentToolUpdate = @Sendable (AgentToolResult) -> Void

public enum SubagentLifecycleKind: String, Sendable, Hashable {
    case started = "subagent_started"
    case toolUpdate = "subagent_tool_update"
    case backgroundStarted = "subagent_background_started"
    case completed = "subagent_completed"
    case failed = "subagent_failed"
}

public struct SubagentLifecycleEvent: Sendable, Hashable {
    public var kind: SubagentLifecycleKind
    public var toolCallId: String?
    public var subagentType: String
    public var childSessionId: String
    public var description: String?
    public var model: String?
    public var stopReason: StopReason?
    public var usage: Usage?
    public var usageEstimated: Bool
    public var turns: Int?
    public var cost: Cost?
    public var durationMs: Int?
    public var backgroundTaskId: String?
    public var outputFile: String?
    public var message: String?
    public var errorMessage: String?

    public init(
        kind: SubagentLifecycleKind,
        toolCallId: String? = nil,
        subagentType: String,
        childSessionId: String,
        description: String? = nil,
        model: String? = nil,
        stopReason: StopReason? = nil,
        usage: Usage? = nil,
        usageEstimated: Bool = false,
        turns: Int? = nil,
        cost: Cost? = nil,
        durationMs: Int? = nil,
        backgroundTaskId: String? = nil,
        outputFile: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.toolCallId = toolCallId
        self.subagentType = subagentType
        self.childSessionId = childSessionId
        self.description = description
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
        self.usageEstimated = usageEstimated
        self.turns = turns
        self.cost = cost
        self.durationMs = durationMs
        self.backgroundTaskId = backgroundTaskId
        self.outputFile = outputFile
        self.message = message
        self.errorMessage = errorMessage
    }
}

public enum AgentRuntimeEvent: Sendable, Hashable {
    case subagent(SubagentLifecycleEvent)

    public var type: String {
        switch self {
        case .subagent(let event):
            return event.kind.rawValue
        }
    }
}

/// Tool executed by the agent. Throwing from `execute` is how tools report
/// failures — the agent loop will turn the error into an error tool result.
public struct AgentTool: Sendable {
    public var name: String
    public var label: String
    public var description: String
    public var parameters: JSONValue
    /// Long-running, side-effect-free waits may opt in so queued user
    /// steering can end the wait without aborting the whole agent run.
    public var interruptible: Bool
    /// Internal marker for the built-in blocking background-task poll.
    /// Name matching is insufficient because SDK tools may reuse the name.
    var isBackgroundTaskPollTool: Bool
    /// Filesystem boundary attached to the registered write capability so
    /// provider-native file operations (notably Cursor delete) cannot bypass
    /// the same policy.
    var fileAccessPolicy: FileAccessPolicy?
    var fileAccessCwd: String?
    /// Unforgeable-by-name marker set only by kwwk's built-in coding-tool
    /// factories. Security decisions must use this marker, never `name`.
    var codingToolCapabilities: CodingTools
    /// Shared with the Agent's background attachment so explicit task results
    /// and automatic runtime asides coordinate in the same consumer mailbox.
    var backgroundDeliveryConsumer: BackgroundTaskDeliveryConsumer?
    /// Manager identity paired with `backgroundDeliveryConsumer`. An Agent may
    /// attach several managers under the same session id; matching both keeps
    /// one manager's detach from disabling another manager's wake path.
    var backgroundTaskManager: BackgroundTaskManager?
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
        interruptible: Bool = false,
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
        self.interruptible = interruptible
        self.isBackgroundTaskPollTool = false
        self.fileAccessPolicy = nil
        self.fileAccessCwd = nil
        self.codingToolCapabilities = []
        self.backgroundDeliveryConsumer = nil
        self.backgroundTaskManager = nil
        self.execute = execute
    }
}

/// Per-run aggregate surfaced on `agentEnd`. Mirrors the SDK's
/// `ResultMessage` — consumers (TUI, cost dashboards, audit logs) can
/// read this once at the end of a run instead of re-deriving totals
/// from the message delta.
public struct AgentRunSummary: Sendable {
    /// Number of assistant turns that actually streamed in this run.
    /// Zero if the run was capped out before any request fired.
    public var turns: Int
    /// Summed token counts across every assistant message in this run.
    /// `totalTokens` is the provider-reported sum where available,
    /// otherwise the naive `input + output`.
    public var usage: Usage
    /// USD cost derived from `usage` and the configured model's
    /// per-1M-token pricing. Zero for models without cost metadata.
    public var cost: Cost
    /// Wall-clock duration from `agentStart` to `agentEnd`, in ms.
    public var durationMs: Int
    /// Stop reason of the final assistant message in this run.
    /// `.stop` for normal completion, `.aborted` on user cancel,
    /// `.error` on retries-exhausted / turn-cap / synthetic failures,
    /// or the provider's native reason. Nil if the run emitted no
    /// assistant messages at all.
    public var finalStopReason: StopReason?
    /// True only when the loop itself synthesized the max-turn terminal
    /// message. This keeps downstream failure classification independent of
    /// provider/localized error text.
    public var reachedMaxTurns: Bool
    /// Subagent invocations observed during this run. Foreground subagents
    /// carry final usage; background subagents are recorded at spawn time and
    /// report completion through background-task notifications.
    public var subagents: [SubagentRunSummary]

    public init(
        turns: Int = 0,
        usage: Usage = Usage(),
        cost: Cost = Cost(),
        durationMs: Int = 0,
        finalStopReason: StopReason? = nil,
        reachedMaxTurns: Bool = false,
        subagents: [SubagentRunSummary] = []
    ) {
        self.turns = turns
        self.usage = usage
        self.cost = cost
        self.durationMs = durationMs
        self.finalStopReason = finalStopReason
        self.reachedMaxTurns = reachedMaxTurns
        self.subagents = subagents
    }
}

public enum SubagentRunStatus: String, Sendable, Hashable {
    case completed
    case backgroundStarted = "background_started"
    case failed
}

public struct SubagentRunSummary: Sendable, Hashable {
    public var subagentType: String
    public var childSessionId: String?
    public var description: String?
    public var status: SubagentRunStatus
    public var model: String?
    public var stopReason: StopReason?
    public var usage: Usage?
    public var turns: Int?
    public var cost: Cost?
    public var durationMs: Int?
    public var backgroundTaskId: String?
    public var outputFile: String?
    public var errorMessage: String?

    public init(
        subagentType: String,
        childSessionId: String? = nil,
        description: String? = nil,
        status: SubagentRunStatus,
        model: String? = nil,
        stopReason: StopReason? = nil,
        usage: Usage? = nil,
        turns: Int? = nil,
        cost: Cost? = nil,
        durationMs: Int? = nil,
        backgroundTaskId: String? = nil,
        outputFile: String? = nil,
        errorMessage: String? = nil
    ) {
        self.subagentType = subagentType
        self.childSessionId = childSessionId
        self.description = description
        self.status = status
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
        self.turns = turns
        self.cost = cost
        self.durationMs = durationMs
        self.backgroundTaskId = backgroundTaskId
        self.outputFile = outputFile
        self.errorMessage = errorMessage
    }
}

/// Events emitted by the agent runtime. Mirrors pi-agent-core's AgentEvent.
public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd(messages: [Message], summary: AgentRunSummary)

    case turnStart
    case turnEnd(message: Message, toolResults: [ToolResultMessage])

    case messageStart(message: Message)
    case messageUpdate(message: AssistantMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: Message)

    case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: JSONValue, partialResult: AgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
    case runtimeEvent(AgentRuntimeEvent)

    case compactStart(messagesCount: Int, usage: AgentContextUsage)
    case compactEnd(outcome: AgentContextCompactionOutcome)

    /// Emitted just before the agent loop sleeps to back off after a
    /// retryable stream failure. `attempt` is zero-indexed and counts the
    /// attempt that just failed (so `attempt: 0` means "first attempt failed,
    /// retry #1 scheduled"). `delayMs` is the upcoming sleep duration.
    case streamRetry(attempt: Int, delayMs: UInt64, reason: String)

    /// Emitted during retry to tell the UI to discard any in-progress live
    /// render for the current turn. The agent loop live-streams events so
    /// the user sees tokens as they arrive; when a retryable error kills
    /// the stream mid-flight, the partial text is no longer truthful and
    /// the renderer must reset (not commit). The retried stream then
    /// produces a fresh `messageStart` + updates.
    case streamRewind

    /// Diagnostic event emitted only when verbose mode is enabled.
    case verbose(VerboseEvent)

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
        case .runtimeEvent(let event): return event.type
        case .compactStart: return "compact_start"
        case .compactEnd: return "compact_end"
        case .streamRetry: return "stream_retry"
        case .streamRewind: return "stream_rewind"
        case .verbose: return "verbose"
        }
    }
}

internal struct StructuredToolExecutionError: LocalizedError, @unchecked Sendable {
    let message: String
    /// Optional model-facing content when the concise error message is not
    /// enough. Callers use this for explicitly delimited, untrusted salvage
    /// evidence without making that evidence part of `errorDescription` or UI
    /// chrome.
    let content: [ToolResultBlock]?
    let details: JSONValue?
    let runtimeEvents: [AgentRuntimeEvent]?

    var errorDescription: String? { message }

    init(
        message: String,
        content: [ToolResultBlock]? = nil,
        details: JSONValue? = nil,
        runtimeEvents: [AgentRuntimeEvent]? = nil
    ) {
        self.message = message
        self.content = content
        self.details = details
        self.runtimeEvents = runtimeEvents
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
    /// Optional replacement for the tool's input args. When non-nil (and
    /// `block` is false), the tool receives these args instead of the
    /// ones the LLM emitted. Useful for auditing/sanitizing paths,
    /// redacting secrets, or expanding shorthand — the hook speaks the
    /// same JSON schema as the tool itself.
    public var modifiedArgs: JSONValue?
    public init(block: Bool = false, reason: String? = nil, modifiedArgs: JSONValue? = nil) {
        self.block = block
        self.reason = reason
        self.modifiedArgs = modifiedArgs
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

// MARK: - User-prompt-submit hook

public struct UserPromptSubmitContext: Sendable {
    public var message: UserMessage
    public var context: AgentContext
}

public struct UserPromptSubmitResult: Sendable {
    /// When true, drop this user message entirely — it will NOT be
    /// appended to the transcript, and if this was the only prompt
    /// queued the run will end cleanly. `reason` is surfaced to the
    /// caller via the synthetic stop message.
    public var block: Bool
    public var reason: String?
    /// Optional replacement for the submitted user message. Use this
    /// to inject extra context (system preambles, redacted attachments,
    /// instructions from a policy engine) without the user seeing two
    /// versions of their prompt. `nil` means "leave the message as-is".
    public var modifiedMessage: UserMessage?

    public init(block: Bool = false, reason: String? = nil, modifiedMessage: UserMessage? = nil) {
        self.block = block
        self.reason = reason
        self.modifiedMessage = modifiedMessage
    }
}

/// Fires once per user message about to enter the transcript — that
/// covers the initial `agent.prompt()` call, steering injections, and
/// follow-up drains. Mirrors the SDK's `UserPromptSubmit` hook. Returning
/// nil leaves the message unchanged; returning a result with `block=true`
/// drops it; `modifiedMessage` rewrites it in place.
public typealias UserPromptSubmitHook = @Sendable (UserPromptSubmitContext, CancellationHandle?) async -> UserPromptSubmitResult?

/// Transform the message list the LLM sees. Return nil to reuse the default
/// pass-through behavior. Mirrors pi-agent-core's `convertToLlm` /
/// `transformContext` hooks combined — use `transformContext` for pruning
/// (AgentMessage→AgentMessage) and `convertToLlm` for projecting to LLM
/// messages.
public typealias ConvertToLlmHook = @Sendable ([Message]) async -> [Message]
public typealias TransformContextHook = @Sendable ([Message], CancellationHandle?) async -> [Message]

/// Fires at every sub-turn boundary — right after `turnEnd` emits, before
/// the loop decides whether to make another LLM call. Returning a non-nil
/// context replaces the loop's running transcript (and optionally tools /
/// system prompt) for the next iteration. Use this for auto-compaction
/// mid-run: when the hook summarizes the transcript, the next request
/// goes out with the compacted version instead of the full history.
///
/// The hook runs synchronously within the agent loop — long work here
/// (e.g. an LLM summarization call) blocks the next LLM call, which is
/// usually what you want for a compact: the loop pauses, UI reflects the
/// compacting state, user input queues via `steer`, and when the hook
/// returns the loop resumes with the new context.
public typealias BetweenTurnsHook = @Sendable (AgentContext, CancellationHandle?) async -> AgentContext?

public enum AgentContextCompactionTrigger: Sendable, Hashable {
    case preflight(pendingMessages: [Message])
    case proactive
    case providerOverflow
}

/// Internal control-plane hook used before provider requests and for one-shot
/// input-overflow recovery. Returning nil leaves the context unchanged.
public typealias ContextCompactionHook = @Sendable (
    AgentContext,
    AgentContextCompactionTrigger,
    CancellationHandle?
) async throws -> AgentContext?
