import Foundation
import KWWKAI

/// Which coding tools to register on a freshly-built agent. Use `.standard`
/// for the full set, `.readOnly` for a sandboxed reviewer-style agent, or
/// compose an arbitrary subset (`[.read, .grep, .bash]`).
///
/// `.taskStatus` and `.waitTask` are only honored when a `backgroundManager`
/// is supplied. `.bash` works without a manager (legacy pipe executor) —
/// it just loses `run_in_background` and the auto-background-on-timeout flip.
/// Interactive terminal sessions (tmux, screen) are driven through `.bash`
/// directly — there is no dedicated PTY tool.
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
    public static let waitTask   = CodingTools(rawValue: 1 << 8)

    /// Filesystem-scan only — no write, no edit, no shell, no PTY.
    public static let readOnly: CodingTools = [.read, .grep, .find, .ls]

    /// Common editing tools. Includes shell and mutation capabilities; SDK
    /// callers must opt in explicitly when they want those effects.
    public static let standard: CodingTools = [
        .read, .write, .edit, .bash, .grep, .find, .ls, .taskStatus, .waitTask,
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
    /// Project/user context files to inject into the synthesized system prompt.
    /// Empty by default so library callers do not implicitly read from `cwd`.
    public var contextFiles: [(path: String, content: String)]
    /// Skill directories to scan for `<available_skills>`. Empty by default so
    /// library callers do not implicitly read project or user config.
    public var skillDirectories: [String]
    /// When non-nil, wired into both the bash tool (for
    /// `run_in_background` + auto-background-on-timeout) and the
    /// agent's notification bridge (so `<task-notification>` user messages
    /// appear at turn boundaries).
    public var backgroundManager: BackgroundTaskManager?
    /// Programmatic subagents available to the model through the `agent` tool.
    /// When empty, no `agent` tool is registered.
    public var subagents: [SubagentDefinition]
    public var sessionId: String
    public var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    public var autoCompactThreshold: Double?
    public var autoCompactConfig: AgentContextCompactionConfig
    /// Soft foreground timeout for bash commands. The command auto-moves to
    /// the background on this deadline when a `backgroundManager` is attached.
    public var bashDefaultTimeoutSeconds: Int
    public var bashMaxTimeoutSeconds: Int
    /// Exact environment passed to bash tool processes. Empty by default so
    /// SDK callers do not expose host process environment variables.
    public var bashEnvironment: [String: String]
    /// Shell used by the bash tool.
    public var bashShellPath: String

    public init(
        model: Model,
        cwd: String,
        tools: CodingTools,
        systemPrompt: String? = nil,
        contextFiles: [(path: String, content: String)] = [],
        skillDirectories: [String] = [],
        backgroundManager: BackgroundTaskManager? = nil,
        subagents: [SubagentDefinition] = [],
        sessionId: String = UUID().uuidString,
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
        autoCompactThreshold: Double? = 0.75,
        autoCompactConfig: AgentContextCompactionConfig = .init(),
        bashEnvironment: [String: String],
        bashDefaultTimeoutSeconds: Int = 120,
        bashMaxTimeoutSeconds: Int = 600,
        bashShellPath: String = kwwkDefaultShellPath
    ) {
        self.model = model
        self.cwd = cwd
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.contextFiles = contextFiles
        self.skillDirectories = skillDirectories
        self.backgroundManager = backgroundManager
        self.subagents = subagents
        self.sessionId = sessionId
        self.authResolver = authResolver
        self.autoCompactThreshold = autoCompactThreshold
        self.autoCompactConfig = autoCompactConfig
        self.bashDefaultTimeoutSeconds = bashDefaultTimeoutSeconds
        self.bashMaxTimeoutSeconds = bashMaxTimeoutSeconds
        self.bashEnvironment = bashEnvironment
        self.bashShellPath = bashShellPath
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

/// Result of `makeCodingAgent`: the built agent plus an optional handle to
/// detach the auto-continue background bridge.
public struct CodingAgent: Sendable {
    public let agent: Agent
    /// Detaches the auto-continue background bridge that `makeCodingAgent`
    /// installs when a `backgroundManager` is supplied. `nil` when no manager
    /// was attached. The bridge autonomously starts a new (billable) model run
    /// when a background task completes while the agent is idle; call this to
    /// stop that behavior. In-flight background tasks keep running.
    public let detachBackground: (@Sendable () async -> Void)?

    public init(agent: Agent, detachBackground: (@Sendable () async -> Void)?) {
        self.agent = agent
        self.detachBackground = detachBackground
    }
}

/// Build a coding agent with the selected coding tools pre-wired.
///
/// ```swift
/// let agent = await makeCodingAgent(CodingAgentConfig(
///     model: model,
///     cwd: "/Users/me/project",
///     tools: .standard,
///     backgroundManager: BackgroundTaskManager(),
///     bashEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
/// )).agent
/// try await agent.prompt("list the swift files")
/// ```
///
/// If `config.backgroundManager` is non-nil, the agent is automatically
/// attached so completion notifications surface as steered user messages — and
/// that bridge will autonomously start new (billable) model runs when
/// background tasks complete. Call the returned `CodingAgent.detachBackground`
/// handle to stop that; ignore it to keep the default auto-continue behavior.
public func makeCodingAgent(_ config: CodingAgentConfig) async -> CodingAgent {
    let cwd = config.cwd
    let bgManager = config.backgroundManager
    let sessionId = config.sessionId

    let autoCompact = config.autoCompactThreshold.map {
        AgentAutoCompactOptions(
            threshold: $0,
            config: config.autoCompactConfig,
            backgroundManager: bgManager
        )
    }

    var tools = buildCodingToolList(
        cwd: cwd,
        selected: config.tools,
        backgroundManager: bgManager,
        sessionId: sessionId,
        bashDefaultTimeoutSeconds: config.bashDefaultTimeoutSeconds,
        bashMaxTimeoutSeconds: config.bashMaxTimeoutSeconds,
        bashEnvironment: config.bashEnvironment,
        bashShellPath: config.bashShellPath
    )
    let subagentParent = SubagentParentBox(
        fallbackModel: config.model,
        fallbackTools: config.tools,
        fallbackThinkingLevel: .off,
        fallbackThinkingBudgets: nil,
        fallbackMaxRetryDelayMs: nil,
        fallbackAutoCompact: autoCompact,
        fallbackAuthResolver: config.authResolver
    )
    if !config.subagents.isEmpty {
        tools.append(_createAgentTool(
            cwd: cwd,
            subagents: config.subagents,
            backgroundManager: bgManager,
            sessionId: sessionId,
            parentSnapshot: { subagentParent.snapshot() },
            bashEnvironment: config.bashEnvironment,
            bashDefaultTimeoutSeconds: config.bashDefaultTimeoutSeconds,
            bashMaxTimeoutSeconds: config.bashMaxTimeoutSeconds,
            bashShellPath: config.bashShellPath
        ))
    }

    let systemPrompt = config.systemPrompt ?? buildSystemPrompt(SystemPromptOptions(
        cwd: cwd,
        contextFiles: config.contextFiles,
        availableSkills: Skills.load(directories: config.skillDirectories).skills
    ))

    let agent = Agent(options: AgentOptions(
        initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: config.model,
            tools: tools
        ),
        sessionId: sessionId,
        autoCompact: autoCompact,
        authResolver: config.authResolver
    ))
    subagentParent.attach(agent)

    var detachBackground: (@Sendable () async -> Void)?
    if let bgManager {
        detachBackground = await agent.attachBackgroundManager(bgManager, sessionId: sessionId)
    }

    return CodingAgent(agent: agent, detachBackground: detachBackground)
}

internal func buildCodingToolList(
    cwd: String,
    selected: CodingTools,
    backgroundManager: BackgroundTaskManager?,
    sessionId: String?,
    bashDefaultTimeoutSeconds: Int = 120,
    bashMaxTimeoutSeconds: Int = 600,
    bashEnvironment: [String: String],
    bashShellPath: String = kwwkDefaultShellPath
) -> [AgentTool] {
    var tools: [AgentTool] = []
    if selected.contains(.read)  { tools.append(createReadTool(cwd: cwd)) }
    if selected.contains(.write) { tools.append(createWriteTool(cwd: cwd)) }
    if selected.contains(.edit)  { tools.append(createEditTool(cwd: cwd)) }
    if selected.contains(.bash) {
        tools.append(createBashTool(cwd: cwd, options: BashToolOptions(
            environment: bashEnvironment,
            defaultTimeoutSeconds: bashDefaultTimeoutSeconds,
            maxTimeoutSeconds: bashMaxTimeoutSeconds,
            manager: backgroundManager,
            sessionId: sessionId,
            autoBackgroundOnTimeout: true,
            shellPath: bashShellPath
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
    return tools
}

/// Load project context files (`AGENTS.md`, `CLAUDE.md`) from `cwd` if present.
/// Returned in a stable order; missing or empty files are skipped. These are
/// injected into the system prompt under `# Project Context`.
public func loadProjectContextFiles(cwd: String) -> [(path: String, content: String)] {
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
