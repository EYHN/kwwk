import Foundation
import KWAI

/// Mutable public state exposed by `Agent`. Consumers read fields directly
/// and use the read/write setters to drive the agent. Array setters copy the
/// assigned array to prevent external aliasing.
///
/// This is a reference type so that the `Agent` actor and the consumer share
/// one view of state; all mutations funnel through locks.
public final class AgentState: @unchecked Sendable {
    private let lock = NSLock()

    private var _systemPrompt: String
    private var _model: Model
    private var _thinkingLevel: ThinkingLevel
    private var _tools: [AgentTool]
    private var _messages: [Message]
    private var _isStreaming: Bool = false
    private var _streamingMessage: Message?
    private var _pendingToolCalls: Set<String> = []
    private var _errorMessage: String?

    public init(
        systemPrompt: String = "",
        model: Model,
        thinkingLevel: ThinkingLevel = .off,
        tools: [AgentTool] = [],
        messages: [Message] = []
    ) {
        self._systemPrompt = systemPrompt
        self._model = model
        self._thinkingLevel = thinkingLevel
        self._tools = tools
        self._messages = messages
    }

    // MARK: - Public properties

    public var systemPrompt: String {
        get { lock.withLock { _systemPrompt } }
        set { lock.withLock { _systemPrompt = newValue } }
    }

    public var model: Model {
        get { lock.withLock { _model } }
        set { lock.withLock { _model = newValue } }
    }

    public var thinkingLevel: ThinkingLevel {
        get { lock.withLock { _thinkingLevel } }
        set { lock.withLock { _thinkingLevel = newValue } }
    }

    /// Array setter copies to prevent external aliasing. Reads return a
    /// snapshot copy as well.
    public var tools: [AgentTool] {
        get { lock.withLock { _tools } }
        set { lock.withLock { _tools = Array(newValue) } }
    }

    public var messages: [Message] {
        get { lock.withLock { _messages } }
        set { lock.withLock { _messages = Array(newValue) } }
    }

    public var isStreaming: Bool {
        lock.withLock { _isStreaming }
    }

    public var streamingMessage: Message? {
        lock.withLock { _streamingMessage }
    }

    public var pendingToolCalls: Set<String> {
        lock.withLock { _pendingToolCalls }
    }

    public var errorMessage: String? {
        lock.withLock { _errorMessage }
    }

    // MARK: - Internal mutators (used by Agent)

    func appendMessage(_ message: Message) {
        lock.withLock { _messages.append(message) }
    }

    func setStreaming(_ value: Bool) {
        lock.withLock { _isStreaming = value }
    }

    func setStreamingMessage(_ message: Message?) {
        lock.withLock { _streamingMessage = message }
    }

    func insertPendingToolCall(_ id: String) {
        lock.withLock { _ = _pendingToolCalls.insert(id) }
    }

    func removePendingToolCall(_ id: String) {
        lock.withLock { _ = _pendingToolCalls.remove(id) }
    }

    func clearPendingToolCalls() {
        lock.withLock { _pendingToolCalls.removeAll() }
    }

    func setErrorMessage(_ message: String?) {
        lock.withLock { _errorMessage = message }
    }
}

