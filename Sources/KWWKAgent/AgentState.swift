import Foundation
import KWWKAI

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
    private var _thinkingDisplay: ThinkingDisplay
    private var _verboseEnabled: Bool
    private var _tools: [AgentTool]
    private var _toolSource: (@Sendable () -> [AgentTool])?
    private var _messages: [Message]
    /// Advances whenever model-facing context changes. Compaction uses it as a
    /// compare-and-swap guard so a summary built from one prompt snapshot can
    /// never replace a newer one.
    private var _contextRevision: UInt64 = 0
    private var _isStreaming: Bool = false
    private var _streamingMessage: Message?
    private var _pendingToolCalls: Set<String> = []
    private var _errorMessage: String?

    public init(
        systemPrompt: String = "",
        model: Model,
        thinkingLevel: ThinkingLevel = .off,
        thinkingDisplay: ThinkingDisplay = .collapsed,
        verboseEnabled: Bool = false,
        tools: [AgentTool] = [],
        messages: [Message] = []
    ) {
        self._systemPrompt = systemPrompt
        self._model = model
        self._thinkingLevel = thinkingLevel
        self._thinkingDisplay = thinkingDisplay
        self._verboseEnabled = verboseEnabled
        self._tools = tools
        self._messages = messages
    }

    // MARK: - Public properties

    public var systemPrompt: String {
        get { lock.withLock { _systemPrompt } }
        set {
            lock.withLock {
                _systemPrompt = newValue
                _contextRevision &+= 1
            }
        }
    }

    public var model: Model {
        get { lock.withLock { _model } }
        set {
            lock.withLock {
                _model = newValue
                _contextRevision &+= 1
            }
        }
    }

    public var thinkingLevel: ThinkingLevel {
        get { lock.withLock { _thinkingLevel } }
        set { lock.withLock { _thinkingLevel = newValue } }
    }

    public var thinkingDisplay: ThinkingDisplay {
        get { lock.withLock { _thinkingDisplay } }
        set { lock.withLock { _thinkingDisplay = newValue } }
    }

    public var verboseEnabled: Bool {
        get { lock.withLock { _verboseEnabled } }
        set { lock.withLock { _verboseEnabled = newValue } }
    }

    /// Array setter copies to prevent external aliasing. Reads return a
    /// snapshot copy as well.
    public var tools: [AgentTool] {
        get { lock.withLock { _tools } }
        set {
            lock.withLock {
                _tools = Array(newValue)
                _contextRevision &+= 1
            }
        }
    }

    /// Tools that come and go on their own, such as a ``ToolCatalog``'s
    /// loaded MCP tools. Read before every provider request and merged after
    /// `tools`; `tools` wins on a name clash. Changing what the source
    /// returns is not a context edit: it never invalidates a compaction in
    /// flight.
    public var toolSource: (@Sendable () -> [AgentTool])? {
        get { lock.withLock { _toolSource } }
        set { lock.withLock { _toolSource = newValue } }
    }

    /// The tools the next provider request declares: `tools` plus the
    /// source's tools.
    public var effectiveTools: [AgentTool] {
        let (tools, source) = lock.withLock { (_tools, _toolSource) }
        return Self.merge(tools, source?())
    }

    private static func merge(_ tools: [AgentTool], _ extra: [AgentTool]?) -> [AgentTool] {
        guard let extra, !extra.isEmpty else { return tools }
        let names = Set(tools.map(\.name))
        return tools + extra.filter { !names.contains($0.name) }
    }

    public var messages: [Message] {
        get { lock.withLock { _messages } }
        set {
            lock.withLock {
                _messages = Array(newValue)
                _contextRevision &+= 1
            }
        }
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
        lock.withLock {
            _messages.append(message)
            _contextRevision &+= 1
        }
    }

    func snapshotModelContext() -> (revision: UInt64, context: AgentContext, model: Model) {
        let source = lock.withLock { _toolSource }
        let extra = source?()
        return lock.withLock {
            (
                _contextRevision,
                AgentContext(
                    systemPrompt: _systemPrompt,
                    messages: _messages,
                    tools: Self.merge(_tools, extra)
                ),
                _model
            )
        }
    }

    func hasContextRevision(_ expectedRevision: UInt64) -> Bool {
        lock.withLock { _contextRevision == expectedRevision }
    }

    func replaceMessages(_ messages: [Message], ifRevision expectedRevision: UInt64) -> Bool {
        lock.withLock {
            guard _contextRevision == expectedRevision else { return false }
            _messages = Array(messages)
            _contextRevision &+= 1
            return true
        }
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
