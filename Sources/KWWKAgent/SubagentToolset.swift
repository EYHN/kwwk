import Foundation
import KWWKAI

/// The subagent (`agent`) toolset for agents assembled outside
/// `makeCodingAgent` — e.g. kwwk-bot bots, which build their own `Agent`
/// with a custom system prompt and tool mix but still want to delegate work
/// to child agents.
///
/// Construction is two-phase because the tool needs the owning agent for
/// interactive steering: create the toolset first, register `tools` on the
/// agent, then call `attach(to:)` once the `Agent` exists.
public struct SubagentToolset: Sendable {
    /// The `agent` tool, plus `agent_history` when a background manager is
    /// supplied.
    public let tools: [AgentTool]
    let parent: SubagentParentBox

    /// Wires the owning agent in so subagent steering and yields reach the
    /// parent conversation. Call exactly once, right after the `Agent` is
    /// created.
    public func attach(to agent: Agent) {
        parent.attach(agent)
    }
}

/// Creates the subagent toolset with the same child-agent semantics
/// `makeCodingAgent` wires up: `subagents` defaults to the built-in set for
/// `childTools`, children run in `cwd`, and fall back to the parent's model.
public func createSubagentToolset(
    cwd: String,
    model: Model,
    childTools: CodingTools = .standard,
    subagents: [SubagentDefinition]? = nil,
    backgroundManager: BackgroundTaskManager? = nil,
    sessionId: String? = nil,
    limits: SubagentLimits = SubagentLimits(),
    bashEnvironment: [String: String],
    fileAccessPolicy: FileAccessPolicy = .unrestricted,
    contextFiles: [(path: String, content: String)] = [],
    authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
    bashDefaultTimeoutSeconds: Int = 120,
    bashMaxTimeoutSeconds: Int = 600,
    maxTaskTimeoutSeconds: Int? = nil,
    bashShellPath: String = kwwkDefaultShellPath
) -> SubagentToolset {
    let parent = SubagentParentBox(
        childCwd: cwd,
        fallbackModel: model,
        fallbackTools: childTools,
        fallbackThinkingLevel: .off,
        fallbackThinkingBudgets: nil,
        fallbackMaxRetryDelayMs: nil,
        fallbackMaxTurns: nil,
        fallbackBeforeToolCall: nil,
        fallbackAfterToolCall: nil,
        fallbackAutoCompact: nil,
        fallbackCompactionModel: nil,
        fallbackAuthResolver: authResolver,
        projectContextFiles: contextFiles,
        availableSkills: [],
        fallbackFileAccessPolicy: fileAccessPolicy,
        allowedModelOverrides: []
    )
    let definitions = subagents ?? SubagentDefinition.builtins(for: childTools)
    let historyStore = SubagentHistoryStore()
    var tools = [
        _createAgentTool(
            cwd: cwd,
            subagents: definitions,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            historyStore: historyStore,
            parentSnapshot: { parent.snapshot() },
            limits: limits,
            bashEnvironment: bashEnvironment,
            bashDefaultTimeoutSeconds: bashDefaultTimeoutSeconds,
            bashMaxTimeoutSeconds: bashMaxTimeoutSeconds,
            maxTaskTimeoutSeconds: maxTaskTimeoutSeconds,
            bashShellPath: bashShellPath
        ),
    ]
    if backgroundManager != nil {
        tools.append(createSubagentHistoryTool(store: historyStore, sessionId: sessionId))
    }
    return SubagentToolset(tools: tools, parent: parent)
}
