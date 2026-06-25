import Foundation
import KWWKAI

/// Which coding tools to register on a freshly-built agent. Use `.all` for the
/// full set, `.readOnly` for a sandboxed reviewer-style agent, or compose
/// an arbitrary subset (`[.read, .grep, .bash]`).
///
/// `.tmux` is only honored when `tmux` is on PATH; otherwise the tool is
/// silently omitted so the model doesn't see something it can't use.
/// `.taskStatus` and `.waitTask` are only honored when a `backgroundManager`
/// is supplied. `.bash` works without a manager (legacy pipe executor) —
/// it just loses `run_in_background` and the auto-background-on-timeout flip.
public struct CodingTools: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read       = CodingTools(rawValue: 1 << 0)
    public static let write      = CodingTools(rawValue: 1 << 1)
    public static let edit       = CodingTools(rawValue: 1 << 2)
    public static let bash       = CodingTools(rawValue: 1 << 3)
    public static let grep       = CodingTools(rawValue: 1 << 4)
    public static let find       = CodingTools(rawValue: 1 << 5)
    public static let ls         = CodingTools(rawValue: 1 << 6)
    public static let taskStatus = CodingTools(rawValue: 1 << 7)
    public static let tmux       = CodingTools(rawValue: 1 << 8)
    public static let waitTask   = CodingTools(rawValue: 1 << 9)

    /// Filesystem-scan only — no write, no edit, no shell, no PTY.
    public static let readOnly: CodingTools = [.read, .grep, .find, .ls]

    /// Everything.
    public static let all: CodingTools = [
        .read, .write, .edit, .bash, .grep, .find, .ls, .taskStatus, .waitTask, .tmux,
    ]
}

/// Configuration for `makeCodingAgent`. Bundles the model, working directory,
/// tool selection, optional background task manager, and an optional
/// system-prompt override.
public struct CodingAgentConfig: Sendable {
    public var model: Model
    public var cwd: String
    public var tools: CodingTools
    /// If nil, a default system prompt is synthesized. Pass a non-nil string
    /// to fully override.
    public var systemPrompt: String?
    /// When non-nil, wired into both the bash tool (for
    /// `run_in_background` + auto-background-on-timeout) and the
    /// agent's notification bridge (so `<task-notification>` user messages
    /// appear at turn boundaries).
    public var backgroundManager: BackgroundTaskManager?
    /// Programmatic subagents available to the model through the `agent` tool.
    /// When empty, no `agent` tool is registered.
    public var subagents: [SubagentDefinition]
    public var sessionId: String
    public var authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)?
    public var autoCompactThreshold: Double?
    public var autoCompactConfig: AgentContextCompactionConfig
    /// Soft foreground timeout for bash commands. The command auto-moves to
    /// the background on this deadline when a `backgroundManager` is attached.
    public var bashDefaultTimeoutSeconds: Int
    public var bashMaxTimeoutSeconds: Int

    public init(
        model: Model,
        cwd: String,
        tools: CodingTools = .all,
        systemPrompt: String? = nil,
        backgroundManager: BackgroundTaskManager? = nil,
        subagents: [SubagentDefinition] = [],
        sessionId: String = UUID().uuidString,
        authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
        autoCompactThreshold: Double? = 0.75,
        autoCompactConfig: AgentContextCompactionConfig = .init(),
        bashDefaultTimeoutSeconds: Int = 120,
        bashMaxTimeoutSeconds: Int = 600
    ) {
        self.model = model
        self.cwd = cwd
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.backgroundManager = backgroundManager
        self.subagents = subagents
        self.sessionId = sessionId
        self.authResolver = authResolver
        self.autoCompactThreshold = autoCompactThreshold
        self.autoCompactConfig = autoCompactConfig
        self.bashDefaultTimeoutSeconds = bashDefaultTimeoutSeconds
        self.bashMaxTimeoutSeconds = bashMaxTimeoutSeconds
    }
}

public extension CodingAgentConfig {
    func withBuiltinSubagents(
        _ selection: BuiltinSubagentSelection = .all
    ) -> CodingAgentConfig {
        var copy = self
        copy.subagents = SubagentDefinition.builtins(for: copy.tools, selection: selection)
        return copy
    }

    mutating func useBuiltinSubagents(
        _ selection: BuiltinSubagentSelection = .all
    ) {
        subagents = SubagentDefinition.builtins(for: tools, selection: selection)
    }
}

/// Build a coding agent with the selected coding tools pre-wired.
///
/// ```swift
/// let agent = await makeCodingAgent(CodingAgentConfig(
///     model: model,
///     cwd: "/Users/me/project",
///     tools: .all,
///     backgroundManager: BackgroundTaskManager()
/// ))
/// try await agent.prompt("list the swift files")
/// ```
///
/// If `config.backgroundManager` is non-nil, the agent is automatically
/// attached so completion notifications surface as steered user messages.
public func makeCodingAgent(_ config: CodingAgentConfig) async -> Agent {
    let cwd = config.cwd
    let bgManager = config.backgroundManager
    let sessionId = config.sessionId

    var tools = await buildCodingToolList(
        cwd: cwd,
        selected: config.tools,
        backgroundManager: bgManager,
        sessionId: sessionId,
        bashDefaultTimeoutSeconds: config.bashDefaultTimeoutSeconds,
        bashMaxTimeoutSeconds: config.bashMaxTimeoutSeconds
    )
    let subagentParent = SubagentParentBox(
        fallbackModel: config.model,
        fallbackThinkingLevel: .off,
        fallbackThinkingBudgets: nil,
        fallbackMaxRetryDelayMs: nil,
        fallbackAuthResolver: config.authResolver
    )
    if !config.subagents.isEmpty {
        tools.append(_createAgentTool(
            cwd: cwd,
            subagents: config.subagents,
            backgroundManager: bgManager,
            sessionId: sessionId,
            parentSnapshot: { subagentParent.snapshot() },
            bashDefaultTimeoutSeconds: config.bashDefaultTimeoutSeconds,
            bashMaxTimeoutSeconds: config.bashMaxTimeoutSeconds
        ))
    }

    let systemPrompt = config.systemPrompt ?? buildSystemPrompt(SystemPromptOptions(
        cwd: cwd,
        contextFiles: loadProjectContextFiles(cwd: cwd),
        availableSkills: Skills.discover(cwd: cwd).skills
    ))

    let agent = Agent(options: AgentOptions(
        initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: config.model,
            tools: tools
        ),
        sessionId: sessionId,
        autoCompact: config.autoCompactThreshold.map {
            AgentAutoCompactOptions(
                threshold: $0,
                config: config.autoCompactConfig,
                backgroundManager: bgManager
            )
        },
        authResolver: config.authResolver
    ))
    subagentParent.attach(agent)

    if let bgManager {
        _ = await agent.attachBackgroundManager(bgManager, sessionId: sessionId)
    }

    return agent
}

internal func buildCodingToolList(
    cwd: String,
    selected: CodingTools,
    backgroundManager: BackgroundTaskManager?,
    sessionId: String?,
    bashDefaultTimeoutSeconds: Int = 120,
    bashMaxTimeoutSeconds: Int = 600
) async -> [AgentTool] {
    var tools: [AgentTool] = []
    if selected.contains(.read)  { tools.append(createReadTool(cwd: cwd)) }
    if selected.contains(.write) { tools.append(createWriteTool(cwd: cwd)) }
    if selected.contains(.edit)  { tools.append(createEditTool(cwd: cwd)) }
    if selected.contains(.bash) {
        tools.append(createBashTool(cwd: cwd, options: BashToolOptions(
            defaultTimeoutSeconds: bashDefaultTimeoutSeconds,
            maxTimeoutSeconds: bashMaxTimeoutSeconds,
            manager: backgroundManager,
            sessionId: sessionId,
            autoBackgroundOnTimeout: true
        )))
    }
    if selected.contains(.grep) { tools.append(createGrepTool(cwd: cwd)) }
    if selected.contains(.find) { tools.append(createFindTool(cwd: cwd)) }
    if selected.contains(.ls)   { tools.append(createLSTool(cwd: cwd)) }
    if selected.contains(.taskStatus), let backgroundManager {
        tools.append(createTaskStatusTool(manager: backgroundManager, sessionId: sessionId))
    }
    if selected.contains(.waitTask), let backgroundManager {
        tools.append(createWaitTaskTool(manager: backgroundManager, sessionId: sessionId))
    }
    if selected.contains(.tmux),
       let tmuxTool = await createTmuxTool(bgManager: backgroundManager, sessionId: sessionId) {
        tools.append(tmuxTool)
    }
    return tools
}

/// Load project context files (`AGENTS.md`, `CLAUDE.md`) from `cwd` if present.
/// Returned in a stable order; missing or empty files are skipped. These are
/// injected into the system prompt under `# Project Context`.
internal func loadProjectContextFiles(cwd: String) -> [(path: String, content: String)] {
    let candidates = ["AGENTS.md", "CLAUDE.md"]
    var files: [(path: String, content: String)] = []
    for name in candidates {
        let full = (cwd as NSString).appendingPathComponent(name)
        guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        files.append((path: name, content: trimmed))
    }
    return files
}
