import Foundation

public struct Context: Sendable, Hashable, Codable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [Tool]?

    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [Tool]? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

// MARK: - Stream options

public enum CacheRetention: String, Codable, Sendable {
    case none
    case short
    case long
}

public enum Transport: String, Codable, Sendable {
    case sse
    case websocket
    case auto
}

public enum ReasoningLevel: String, Codable, Sendable, Hashable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}

/// OpenAI Responses reasoning-summary verbosity. `nil` (field absent) ⇒
/// provider default (`auto`); `.omit` drops the `summary` key entirely so the
/// endpoint streams reasoning start/end with no summary body.
public enum ReasoningSummary: String, Codable, Sendable, Hashable {
    case auto
    case concise
    case detailed
    case omit
}

/// OpenAI Responses processing tier. `nil` (field absent) ⇒ provider default.
/// pi additionally allows `null`; in Swift `nil` already means "field absent".
public enum ServiceTier: String, Codable, Sendable, Hashable {
    case auto
    case `default`
    case flex
    case scale
    case priority
}

/// Bedrock reasoning display mode for the `thinking.display` field. `summarized`
/// is the default; `omitted` hides the reasoning trace. Suppressed entirely on
/// GovCloud targets.
public enum BedrockThinkingDisplay: String, Codable, Sendable, Hashable {
    case summarized
    case omitted
}

public struct ThinkingBudgets: Codable, Sendable, Hashable {
    public var minimal: Int?
    public var low: Int?
    public var medium: Int?
    public var high: Int?

    public init(minimal: Int? = nil, low: Int? = nil, medium: Int? = nil, high: Int? = nil) {
        self.minimal = minimal
        self.low = low
        self.medium = medium
        self.high = high
    }
}

public enum AuthScheme: Sendable, Hashable {
    case none
    case bearer
    case apiKeyHeader(name: String)
    case queryKey(name: String)
}

public struct ResolvedProviderAuth: Sendable, Hashable {
    public var token: String?
    public var scheme: AuthScheme
    public var headers: [String: String]
    public var baseURL: String?
    public var metadata: [String: JSONValue]

    public init(
        token: String? = nil,
        scheme: AuthScheme = .none,
        headers: [String: String] = [:],
        baseURL: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.token = token
        self.scheme = scheme
        self.headers = headers
        self.baseURL = baseURL
        self.metadata = metadata
    }
}

/// Whether the model is allowed/required to call tools. Providers that don't
/// support a direct analog ignore this. Matches the common shape across
/// Anthropic, OpenAI Responses, and OpenAI Completions.
public enum ToolChoice: Sendable, Hashable {
    /// Model chooses whether and which tool to call (default).
    case auto
    /// Model may not call tools — must return a text response.
    case none
    /// Model must call a tool, but chooses which one.
    case required
    /// Model must call this specific tool.
    case tool(name: String)
}

/// Bridge that lets the Cursor provider execute the caller's tools inline
/// during a stream. Cursor's protocol is server-driven: the server sends exec
/// requests (shell/read/grep/... and MCP calls for advertised tools) over the
/// open stream and blocks the turn until the client replies, so tool execution
/// cannot wait for the agent loop. The agent loop supplies this bridge; the
/// provider synthesizes matching `toolCall` blocks marked
/// `cursorExecResolved` and the loop appends each returned result to the
/// transcript after the assistant message closes.
public struct CursorExecBridge: Sendable {
    /// Workspace root reported to Cursor's server through the requestContext
    /// handshake (`RequestContextEnv.workspace_paths`). Without it the
    /// server-side harness has no authoritative cwd and the model guesses
    /// paths until a `pwd` corrects it.
    public var cwd: String?

    /// Execute one tool call and return its result. Failures are folded into
    /// an `isError` result by the implementation — this never throws.
    public var execute: @Sendable (ToolCall) async -> ToolResultMessage

    public init(cwd: String? = nil, execute: @escaping @Sendable (ToolCall) async -> ToolResultMessage) {
        self.cwd = cwd
        self.execute = execute
    }
}

/// Options passed into streaming calls. All fields are optional; providers
/// ignore fields they do not understand.
public struct StreamOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var apiKey: String?
    public var transport: Transport?
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var headers: [String: String]?
    public var maxRetryDelayMs: Int?
    public var metadata: [String: JSONValue]?
    public var resolvedAuth: ResolvedProviderAuth?
    public var reasoning: ReasoningLevel?
    public var thinkingBudgets: ThinkingBudgets?
    public var cancellation: CancellationHandle?

    /// OpenAI Responses reasoning-summary verbosity (`auto`/`concise`/`detailed`,
    /// or `.omit` to drop the field). `nil` ⇒ provider default (`auto`).
    /// Providers without an analog ignore this.
    public var reasoningSummary: ReasoningSummary?

    /// OpenAI Responses `service_tier` pass-through (`flex`/`priority`/etc.).
    /// `nil` ⇒ field absent. Providers without an analog ignore this.
    public var serviceTier: ServiceTier?

    /// Anthropic interleaved-thinking beta opt-in. `nil` ⇒ provider default
    /// (treated as `true`); set `false` to suppress the
    /// `interleaved-thinking-2025-05-14` beta header. Providers without an
    /// analog ignore this.
    public var interleavedThinking: Bool?

    /// Bedrock reasoning display mode (`thinking.display`). `nil` ⇒ provider
    /// default (`summarized`). Suppressed on GovCloud targets. Providers without
    /// an analog ignore this.
    public var thinkingDisplay: BedrockThinkingDisplay?

    /// Tool-use constraint. `nil` means provider default (usually `.auto`).
    public var toolChoice: ToolChoice?

    /// If false, the provider is asked to disable parallel tool calls —
    /// the assistant will emit at most one `tool_use` block per turn.
    /// `nil` means provider default (usually on).
    ///
    /// Providers that lack an analog ignore this.
    public var parallelToolCalls: Bool?

    /// Inline tool-execution bridge for the Cursor provider (see
    /// ``CursorExecBridge``). Providers without a server-driven exec channel
    /// ignore this.
    public var cursorExecBridge: CursorExecBridge?

    /// Enables provider/internal diagnostic logging for this stream.
    public var verbose: Bool?

    /// Optional sink used by providers to surface verbose diagnostics.
    public var onVerbose: (@Sendable (VerboseEvent) async -> Void)?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        apiKey: String? = nil,
        transport: Transport? = nil,
        cacheRetention: CacheRetention? = nil,
        sessionId: String? = nil,
        headers: [String: String]? = nil,
        maxRetryDelayMs: Int? = nil,
        metadata: [String: JSONValue]? = nil,
        resolvedAuth: ResolvedProviderAuth? = nil,
        reasoning: ReasoningLevel? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        cancellation: CancellationHandle? = nil,
        reasoningSummary: ReasoningSummary? = nil,
        serviceTier: ServiceTier? = nil,
        interleavedThinking: Bool? = nil,
        thinkingDisplay: BedrockThinkingDisplay? = nil,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        cursorExecBridge: CursorExecBridge? = nil,
        verbose: Bool? = nil,
        onVerbose: (@Sendable (VerboseEvent) async -> Void)? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.apiKey = apiKey
        self.transport = transport
        self.cacheRetention = cacheRetention
        self.sessionId = sessionId
        self.headers = headers
        self.maxRetryDelayMs = maxRetryDelayMs
        self.metadata = metadata
        self.resolvedAuth = resolvedAuth
        self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets
        self.cancellation = cancellation
        self.reasoningSummary = reasoningSummary
        self.serviceTier = serviceTier
        self.interleavedThinking = interleavedThinking
        self.thinkingDisplay = thinkingDisplay
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.cursorExecBridge = cursorExecBridge
        self.verbose = verbose
        self.onVerbose = onVerbose
    }

    public func emitVerbose(
        source: String,
        message: String,
        metadata: [String: JSONValue] = [:]
    ) async {
        guard verbose == true else { return }
        await onVerbose?(VerboseEvent(source: source, message: message, metadata: metadata))
    }
}
