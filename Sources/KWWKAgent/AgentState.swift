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
    private var _toolCatalog: ToolCatalog?
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

    /// Deferred tools (e.g. MCP) this agent can load with `tool_search`.
    /// Its loaded tools join every provider request after `tools`; `tools`
    /// wins on a name clash. Loading is not a context edit: it never
    /// invalidates a compaction in flight. Subagents that may mutate inherit
    /// a child of it.
    public var toolCatalog: ToolCatalog? {
        get { lock.withLock { _toolCatalog } }
        set { lock.withLock { _toolCatalog = newValue } }
    }

    /// The tools the next provider request declares: `tools`, then the
    /// catalog's `tool_search` (unless `tools` has one) and loaded tools.
    public var effectiveTools: [AgentTool] {
        let (tools, catalog) = lock.withLock { (_tools, _toolCatalog) }
        return Self.merge(tools, catalog)
    }

    /// The system prompt the next provider request sends: `systemPrompt`
    /// plus the catalog's instructions.
    public var effectiveSystemPrompt: String {
        let (prompt, catalog) = lock.withLock { (_systemPrompt, _toolCatalog) }
        return Self.compose(prompt, catalog)
    }

    private static func merge(_ tools: [AgentTool], _ catalog: ToolCatalog?) -> [AgentTool] {
        guard let catalog else { return tools }
        var names = Set(tools.map(\.name))
        var result = tools
        if !names.contains(toolSearchToolName) {
            result.append(catalog.searchTool)
            names.insert(toolSearchToolName)
        }
        result.append(contentsOf: catalog.tools.filter { !names.contains($0.name) })
        return result
    }

    private static func compose(_ prompt: String, _ catalog: ToolCatalog?) -> String {
        guard let instructions = catalog?.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
              !instructions.isEmpty
        else { return prompt }
        return prompt.isEmpty ? instructions : prompt + "\n\n" + instructions
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
        let catalog = lock.withLock { _toolCatalog }
        // Read the catalog outside the state lock: it takes its own locks.
        let extra = catalog.map { (tools: $0.tools, search: $0.searchTool, instructions: $0.instructions) }
        return lock.withLock {
            var tools = _tools
            var systemPrompt = _systemPrompt
            if let extra {
                var names = Set(tools.map(\.name))
                if !names.contains(toolSearchToolName) {
                    tools.append(extra.search)
                    names.insert(toolSearchToolName)
                }
                tools.append(contentsOf: extra.tools.filter { !names.contains($0.name) })
                if let instructions = extra.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
                    systemPrompt = systemPrompt.isEmpty ? instructions : systemPrompt + "\n\n" + instructions
                }
            }
            return (
                _contextRevision,
                AgentContext(systemPrompt: systemPrompt, messages: _messages, tools: tools),
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
