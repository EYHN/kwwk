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
    /// If nil, a system prompt is synthesized from the selected tools +
    /// `DefaultToolSnippets.all`. Pass a non-nil string to fully override.
    public var systemPrompt: String?
    /// When non-nil, wired into both the bash tool (for
    /// `run_in_background` + auto-background-on-timeout) and the
    /// agent's notification bridge (so `<task-notification>` user messages
    /// appear at turn boundaries).
    public var backgroundManager: BackgroundTaskManager?
    public var sessionId: String
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
        sessionId: String = UUID().uuidString,
        bashDefaultTimeoutSeconds: Int = 120,
        bashMaxTimeoutSeconds: Int = 600
    ) {
        self.model = model
        self.cwd = cwd
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.backgroundManager = backgroundManager
        self.sessionId = sessionId
        self.bashDefaultTimeoutSeconds = bashDefaultTimeoutSeconds
        self.bashMaxTimeoutSeconds = bashMaxTimeoutSeconds
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

    var tools: [AgentTool] = []
    if config.tools.contains(.read)  { tools.append(createReadTool(cwd: cwd)) }
    if config.tools.contains(.write) { tools.append(createWriteTool(cwd: cwd)) }
    if config.tools.contains(.edit)  { tools.append(createEditTool(cwd: cwd)) }
    if config.tools.contains(.bash) {
        tools.append(createBashTool(cwd: cwd, options: BashToolOptions(
            defaultTimeoutSeconds: config.bashDefaultTimeoutSeconds,
            maxTimeoutSeconds: config.bashMaxTimeoutSeconds,
            manager: bgManager,
            sessionId: sessionId,
            autoBackgroundOnTimeout: true
        )))
    }
    if config.tools.contains(.grep) { tools.append(createGrepTool(cwd: cwd)) }
    if config.tools.contains(.find) { tools.append(createFindTool(cwd: cwd)) }
    if config.tools.contains(.ls)   { tools.append(createLSTool(cwd: cwd)) }
    if config.tools.contains(.taskStatus), let bgManager {
        tools.append(createTaskStatusTool(manager: bgManager, sessionId: sessionId))
    }
    if config.tools.contains(.waitTask), let bgManager {
        tools.append(createWaitTaskTool(manager: bgManager, sessionId: sessionId))
    }
    if config.tools.contains(.tmux), let tmuxTool = await createTmuxTool(bgManager: bgManager, sessionId: sessionId) {
        tools.append(tmuxTool)
    }

    let systemPrompt = config.systemPrompt ?? buildSystemPrompt(SystemPromptOptions(
        cwd: cwd,
        selectedToolNames: tools.map { $0.name },
        toolSnippets: DefaultToolSnippets.all
    ))

    let agent = Agent(
        initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: config.model,
            tools: tools
        ),
        sessionId: sessionId
    )

    if let bgManager {
        _ = await agent.attachBackgroundManager(bgManager, sessionId: sessionId)
    }

    return agent
}
