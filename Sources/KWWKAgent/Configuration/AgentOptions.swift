import Foundation
import KWWKAI

public struct AgentInitialState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var thinkingDisplay: ThinkingDisplay
    public var verboseEnabled: Bool
    public var tools: [AgentTool]
    public var messages: [Message]

    public init(
        systemPrompt: String = "",
        model: Model,
        thinkingLevel: ThinkingLevel = .off,
        thinkingDisplay: ThinkingDisplay = .collapsed,
        verboseEnabled: Bool = false,
        tools: [AgentTool] = [],
        messages: [Message] = []
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.thinkingDisplay = thinkingDisplay
        self.verboseEnabled = verboseEnabled
        self.tools = tools
        self.messages = messages
    }
}

public struct AgentAutoCompactOptions: Sendable {
    public var threshold: Double?
    public var config: AgentContextCompactionConfig
    public var backgroundManager: BackgroundTaskManager?
    /// Compact early when the prompt cache has expired. `nil` turns it off.
    public var coldCache: AgentColdCacheCompactOptions?

    public init(
        threshold: Double? = 0.75,
        config: AgentContextCompactionConfig = .init(),
        backgroundManager: BackgroundTaskManager? = nil,
        coldCache: AgentColdCacheCompactOptions? = .init()
    ) {
        self.threshold = threshold
        self.config = config
        self.backgroundManager = backgroundManager
        self.coldCache = coldCache
    }
}

/// Before a request, when the provider's prompt cache has certainly expired
/// and the context is already large, compact first. The request would
/// re-write the whole context to the cache anyway; a summary (sent without
/// caching, its input pruned) plus a small context costs less than that,
/// and every later turn reads less. Native compaction is skipped: on a cold
/// cache it re-writes the whole context too.
///
/// The cache counts as expired once the newest assistant message is older
/// than the TTL plus `margin`. The context must have reached
/// `thresholdFraction` of `AgentAutoCompactOptions.threshold`, so it scales
/// with the model's window.
public struct AgentColdCacheCompactOptions: Sendable, Equatable {
    /// The retention the agent's requests ask for: nil and `.short` mean the
    /// 5-minute TTL, `.long` 1 hour, `.none` never triggers.
    public var cacheRetention: CacheRetention?
    public var margin: TimeInterval
    public var thresholdFraction: Double

    public init(
        cacheRetention: CacheRetention? = nil,
        margin: TimeInterval = 30,
        thresholdFraction: Double = 2.0 / 3.0
    ) {
        self.cacheRetention = cacheRetention
        self.margin = margin
        self.thresholdFraction = thresholdFraction
    }

    /// Seconds a prompt-cache entry lives for, or nil with caching off.
    public var ttl: TimeInterval? {
        switch cacheRetention ?? .short {
        case .none: nil
        case .short: 300
        case .long: 3_600
        }
    }

    /// Whether a request sent `now` (unix ms) after `messages` finds the
    /// cache expired and `usage` large enough to compact first.
    func isDue(
        messages: [Message],
        usage: AgentContextUsage,
        autoCompactThreshold: Double,
        now: Int64
    ) -> Bool {
        guard let ttl, usage.window > 0, thresholdFraction > 0,
              usage.ratio >= autoCompactThreshold * thresholdFraction,
              let last = messages.last(where: {
                  if case .assistant = $0 { return true }
                  return false
              }), case .assistant(let assistant) = last else { return false }
        return Double(now - assistant.timestamp) > (ttl + margin) * 1_000
    }
}

/// Compact the transcript after the agent has sat idle for a while, so the
/// next prompt starts from a small context instead of re-sending (and, once
/// the provider's prompt cache has expired, re-billing) a large one.
///
/// The countdown starts whenever the agent becomes idle — a run or a
/// maintenance window ends — and is cancelled by the next run. Hosts with
/// their own notion of activity (keystrokes, an open dialog) push it back with
/// `Agent.noteIdleActivity()` and veto a due compaction with `canCompact`.
///
/// An agent waiting on background tasks is not idle: if
/// `autoCompact.backgroundManager` reports active tasks for the session, the
/// compaction is skipped so their completion notifications continue from the
/// full context. Idle compaction reuses `autoCompact`'s compaction config and
/// reports through the same `compactStart` / `compactEnd` events.
/// How full the context must be before an idle agent is compacted.
public enum AgentIdleCompactThreshold: Sendable, Equatable {
    /// Fraction of the current model's context window, e.g. `0.5`.
    case ratio(Double)
    /// Absolute estimated prompt tokens, independent of the model's window —
    /// the natural unit when the concern is the cost of re-sending an uncached
    /// prompt. A value above the window never triggers.
    case tokens(Int)

    func isReached(by usage: AgentContextUsage) -> Bool {
        switch self {
        case .ratio(let ratio):
            guard ratio.isFinite, ratio > 0, usage.window > 0 else { return false }
            return usage.ratio >= ratio
        case .tokens(let tokens):
            return tokens > 0 && usage.tokens >= tokens
        }
    }
}

public struct AgentIdleCompactOptions: Sendable {
    /// Typically lower than `AgentAutoCompactOptions.threshold`: idle time is
    /// free, a turn blocked on compaction is not.
    public var threshold: AgentIdleCompactThreshold
    /// Seconds of inactivity before compacting.
    public var delay: TimeInterval
    /// Host veto, consulted once the delay has elapsed and the built-in checks
    /// passed. Return `false` to skip this idle period (for example while the
    /// user has an unsent draft). The next activity re-arms the countdown.
    public var canCompact: (@Sendable () async -> Bool)?

    public init(
        threshold: AgentIdleCompactThreshold = .ratio(0.5),
        delay: TimeInterval = 300,
        canCompact: (@Sendable () async -> Bool)? = nil
    ) {
        self.threshold = threshold
        self.delay = delay
        self.canCompact = canCompact
    }
}

public struct AgentOptions: Sendable {
    public var initialState: AgentInitialState
    public var streamFn: StreamFn?
    public var toolExecution: ToolExecutionMode
    public var toolChoice: ToolChoice?
    public var parallelToolCalls: Bool?
    public var steeringMode: QueueMode
    public var followUpMode: QueueMode
    public var sessionId: String?
    /// Workspace root forwarded to server-driven providers (Cursor). Nil =
    /// don't report one.
    public var cwd: String?
    public var thinkingBudgets: ThinkingBudgets?
    public var maxRetryDelayMs: Int?
    /// Hard cap on assistant turns per run. Nil = unlimited.
    public var maxTurns: Int?
    /// See `Agent.streamsToIrreversibleSink`. Default false: a failed attempt
    /// with no side effect is retried even after it streamed partial output.
    public var streamsToIrreversibleSink = false
    /// Subagent-only lifecycle policy. Kept internal so the public Agent SDK's
    /// maxTurns contract remains a strict hard stop by default.
    var finalTextOnlyOnLastTurn = false
    var terminalToolName: String?
    var terminalToolReminderLimit = 0
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var userPromptSubmit: UserPromptSubmitHook?
    public var convertToLlm: ConvertToLlmHook?
    public var transformContext: TransformContextHook?
    public var betweenTurns: BetweenTurnsHook?
    public var beforeRunEnd: BeforeRunEndHook?
    /// Automatic context compaction. Enabled by default at 75% of the model's
    /// context window; pass `nil` to opt out of proactive compaction and
    /// provider-overflow recovery.
    public var autoCompact: AgentAutoCompactOptions?
    /// Idle-time context compaction. Off (`nil`) by default.
    public var idleCompact: AgentIdleCompactOptions?
    /// Optional model used only to generate context-compaction summaries.
    /// `nil` follows the agent's current `state.model` dynamically. Trigger
    /// thresholds and recovery targets always use the current model, even
    /// when summary generation is delegated to this model.
    public var compactionModel: Model?
    public var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?

    public init(
        initialState: AgentInitialState,
        streamFn: StreamFn? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        steeringMode: QueueMode = .oneAtATime,
        followUpMode: QueueMode = .oneAtATime,
        sessionId: String? = nil,
        cwd: String? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        maxRetryDelayMs: Int? = nil,
        maxTurns: Int? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        userPromptSubmit: UserPromptSubmitHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        transformContext: TransformContextHook? = nil,
        betweenTurns: BetweenTurnsHook? = nil,
        beforeRunEnd: BeforeRunEndHook? = nil,
        autoCompact: AgentAutoCompactOptions? = AgentAutoCompactOptions(),
        idleCompact: AgentIdleCompactOptions? = nil,
        compactionModel: Model? = nil,
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil
    ) {
        self.initialState = initialState
        self.streamFn = streamFn
        self.toolExecution = toolExecution
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.sessionId = sessionId
        self.cwd = cwd
        self.thinkingBudgets = thinkingBudgets
        self.maxRetryDelayMs = maxRetryDelayMs
        self.maxTurns = maxTurns
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.userPromptSubmit = userPromptSubmit
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.betweenTurns = betweenTurns
        self.beforeRunEnd = beforeRunEnd
        self.autoCompact = autoCompact
        self.idleCompact = idleCompact
        self.compactionModel = compactionModel
        self.authResolver = authResolver
    }
}
