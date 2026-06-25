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

    /// Anthropic interleaved-thinking beta opt-in. `nil` ⇒ provider default
    /// (treated as `true`); set `false` to suppress the
    /// `interleaved-thinking-2025-05-14` beta header. Providers without an
    /// analog ignore this.
    public var interleavedThinking: Bool?

    /// Tool-use constraint. `nil` means provider default (usually `.auto`).
    public var toolChoice: ToolChoice?

    /// If false, the provider is asked to disable parallel tool calls —
    /// the assistant will emit at most one `tool_use` block per turn.
    /// `nil` means provider default (usually on).
    ///
    /// Providers that lack an analog ignore this.
    public var parallelToolCalls: Bool?

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
        interleavedThinking: Bool? = nil,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
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
        self.interleavedThinking = interleavedThinking
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
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
