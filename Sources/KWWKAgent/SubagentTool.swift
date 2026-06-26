import Foundation
import KWWKAI

public func createAgentTool(
    cwd: String,
    subagents: [SubagentDefinition],
    parentModel: Model,
    parentTools: CodingTools,
    parentThinkingLevel: ThinkingLevel = .off,
    parentThinkingBudgets: ThinkingBudgets? = nil,
    parentMaxRetryDelayMs: Int? = nil,
    parentAutoCompact: AgentAutoCompactOptions? = nil,
    backgroundManager: BackgroundTaskManager? = nil,
    sessionId: String? = nil,
    authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
    bashEnvironment: [String: String],
    bashDefaultTimeoutSeconds: Int = 120,
    bashMaxTimeoutSeconds: Int = 600,
    bashShellPath: String = kwwkDefaultShellPath,
    tmuxManager: TmuxSessionManager? = nil
) -> AgentTool {
    let snapshot = SubagentParentSnapshot(
        model: parentModel,
        tools: parentTools,
        thinkingLevel: parentThinkingLevel,
        thinkingBudgets: parentThinkingBudgets,
        maxRetryDelayMs: parentMaxRetryDelayMs,
        autoCompact: parentAutoCompact,
        authResolver: authResolver
    )
    return _createAgentTool(
        cwd: cwd,
        subagents: subagents,
        backgroundManager: backgroundManager,
        sessionId: sessionId,
        parentSnapshot: { snapshot },
        bashEnvironment: bashEnvironment,
        bashDefaultTimeoutSeconds: bashDefaultTimeoutSeconds,
        bashMaxTimeoutSeconds: bashMaxTimeoutSeconds,
        bashShellPath: bashShellPath,
        tmuxManager: tmuxManager
    )
}

public func createAgentTool(
    cwd: String,
    subagents: [SubagentDefinition],
    parentAgent: Agent,
    parentTools: CodingTools,
    backgroundManager: BackgroundTaskManager? = nil,
    sessionId: String? = nil,
    fallbackAuthResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
    bashEnvironment: [String: String],
    bashDefaultTimeoutSeconds: Int = 120,
    bashMaxTimeoutSeconds: Int = 600,
    bashShellPath: String = kwwkDefaultShellPath,
    tmuxManager: TmuxSessionManager? = nil
) -> AgentTool {
    let parentBox = SubagentParentBox(
        fallbackModel: parentAgent.state.model,
        fallbackTools: parentTools,
        fallbackThinkingLevel: parentAgent.state.thinkingLevel,
        fallbackThinkingBudgets: parentAgent.thinkingBudgets,
        fallbackMaxRetryDelayMs: parentAgent.maxRetryDelayMs,
        fallbackAutoCompact: parentAgent.autoCompact,
        fallbackAuthResolver: parentAgent.authResolver ?? fallbackAuthResolver
    )
    parentBox.attach(parentAgent)
    return _createAgentTool(
        cwd: cwd,
        subagents: subagents,
        backgroundManager: backgroundManager,
        sessionId: sessionId,
        parentSnapshot: { parentBox.snapshot() },
        bashEnvironment: bashEnvironment,
        bashDefaultTimeoutSeconds: bashDefaultTimeoutSeconds,
        bashMaxTimeoutSeconds: bashMaxTimeoutSeconds,
        bashShellPath: bashShellPath,
        tmuxManager: tmuxManager
    )
}

internal struct SubagentParentSnapshot: Sendable {
    var model: Model
    var tools: CodingTools
    var thinkingLevel: ThinkingLevel
    var thinkingBudgets: ThinkingBudgets?
    var maxRetryDelayMs: Int?
    var autoCompact: AgentAutoCompactOptions?
    var authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)?
}

internal final class SubagentParentBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var agent: Agent?
    private let fallbackModel: Model
    private let fallbackTools: CodingTools
    private let fallbackThinkingLevel: ThinkingLevel
    private let fallbackThinkingBudgets: ThinkingBudgets?
    private let fallbackMaxRetryDelayMs: Int?
    private let fallbackAutoCompact: AgentAutoCompactOptions?
    private let fallbackAuthResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)?

    init(
        fallbackModel: Model,
        fallbackTools: CodingTools,
        fallbackThinkingLevel: ThinkingLevel,
        fallbackThinkingBudgets: ThinkingBudgets?,
        fallbackMaxRetryDelayMs: Int?,
        fallbackAutoCompact: AgentAutoCompactOptions?,
        fallbackAuthResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)?
    ) {
        self.fallbackModel = fallbackModel
        self.fallbackTools = fallbackTools
        self.fallbackThinkingLevel = fallbackThinkingLevel
        self.fallbackThinkingBudgets = fallbackThinkingBudgets
        self.fallbackMaxRetryDelayMs = fallbackMaxRetryDelayMs
        self.fallbackAutoCompact = fallbackAutoCompact
        self.fallbackAuthResolver = fallbackAuthResolver
    }

    func attach(_ agent: Agent) {
        lock.withLock { self.agent = agent }
    }

    func snapshot() -> SubagentParentSnapshot {
        lock.withLock {
            guard let agent else {
                return SubagentParentSnapshot(
                    model: fallbackModel,
                    tools: fallbackTools,
                    thinkingLevel: fallbackThinkingLevel,
                    thinkingBudgets: fallbackThinkingBudgets,
                    maxRetryDelayMs: fallbackMaxRetryDelayMs,
                    autoCompact: fallbackAutoCompact,
                    authResolver: fallbackAuthResolver
                )
            }
            return SubagentParentSnapshot(
                model: agent.state.model,
                tools: fallbackTools,
                thinkingLevel: agent.state.thinkingLevel,
                thinkingBudgets: agent.thinkingBudgets,
                maxRetryDelayMs: agent.maxRetryDelayMs,
                autoCompact: agent.autoCompact,
                authResolver: agent.authResolver ?? fallbackAuthResolver
            )
        }
    }
}

internal func _createAgentTool(
    cwd: String,
    subagents: [SubagentDefinition],
    backgroundManager: BackgroundTaskManager?,
    sessionId: String?,
    parentSnapshot: @escaping @Sendable () -> SubagentParentSnapshot,
    bashEnvironment: [String: String],
    bashDefaultTimeoutSeconds: Int = 120,
    bashMaxTimeoutSeconds: Int = 600,
    bashShellPath: String = kwwkDefaultShellPath,
    tmuxManager: TmuxSessionManager? = nil
) -> AgentTool {
    let registry = SubagentRegistry(subagents)
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "description": .object([
                "type": .string("string"),
                "description": .string("A short 3-5 word description of the task."),
            ]),
            "prompt": .object([
                "type": .string("string"),
                "description": .string("Complete task instructions for the subagent. Fresh subagents do not inherit the parent transcript."),
            ]),
            "subagent_type": .object([
                "type": .string("string"),
                "enum": .array(registry.names.map { .string($0) }),
                "description": .string("The specialized subagent to run. Omit to use the general subagent when configured."),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional model id override. Omit to use the subagent definition's model or inherit the parent model."),
            ]),
            "run_in_background": .object([
                "type": .string("boolean"),
                "description": .string("Run this independent subagent in the background. You will be notified when it completes."),
            ]),
        ]),
        "required": .array([.string("description"), .string("prompt")]),
    ])

    return AgentTool(
        name: "agent",
        label: "agent",
        description: buildAgentToolDescription(registry: registry),
        parameters: parameters,
        execute: { toolCallId, args, cancellation, onUpdate in
            try cancellation?.throwIfCancelled()
            let input = try parseAgentToolInput(args)
            let requestedType = input.subagentType ?? SubagentRegistry.defaultFallbackName
            guard let definition = registry.definition(named: requestedType) else {
                if input.subagentType == nil {
                    throw CodingToolError.invalidArgument(
                        "agent: `subagent_type` was omitted but no '\(SubagentRegistry.defaultFallbackName)' subagent is configured. Available subagents: \(registry.names.joined(separator: ", "))"
                    )
                }
                throw CodingToolError.invalidArgument(
                    "agent: unknown subagent_type '\(requestedType)'. Available subagents: \(registry.names.joined(separator: ", "))"
                )
            }

            let childSessionId = makeSubagentSessionId(parent: sessionId, name: definition.name)
            let runner = SubagentInvocationRunner(
                cwd: cwd,
                definition: definition,
                taskPrompt: input.prompt,
                modelOverride: input.modelOverride,
                parentSnapshot: parentSnapshot,
                backgroundManager: backgroundManager,
                childSessionId: childSessionId,
                bashDefaultTimeoutSeconds: bashDefaultTimeoutSeconds,
                bashMaxTimeoutSeconds: bashMaxTimeoutSeconds,
                bashEnvironment: bashEnvironment,
                bashShellPath: bashShellPath,
                tmuxManager: tmuxManager
            )
            let shouldRunBackground = input.runInBackground ?? definition.runInBackgroundByDefault
            if shouldRunBackground {
                guard let backgroundManager else {
                    throw CodingToolError.invalidArgument("agent: run_in_background requires a BackgroundTaskManager")
                }
                let bgRunner = SubagentBackgroundRunner(
                    runner: runner,
                    subagentType: definition.name,
                    description: input.description
                )
                let (taskId, outputFile) = await backgroundManager.spawn(
                    runner: bgRunner,
                    sessionId: sessionId
                )
                let body = """
                Started subagent \(definition.name) in the background.
                task_id: \(taskId)
                output_file: \(outputFile.path)
                """
                let display = "agent \(definition.name) background · \(taskId) · \(outputFile.path)"
                return AgentToolResult(
                    content: [.text(TextContent(text: body))],
                    details: .object([
                        "status": .string("background_started"),
                        "task_id": .string(taskId),
                        "output_file": .string(outputFile.path),
                        "subagent_type": .string(definition.name),
                        "child_session_id": .string(childSessionId),
                        "description": .string(input.description),
                    ]),
                    runtimeEvents: [
                        .subagent(SubagentLifecycleEvent(
                            kind: .backgroundStarted,
                            toolCallId: toolCallId,
                            subagentType: definition.name,
                            childSessionId: childSessionId,
                            description: input.description,
                            backgroundTaskId: taskId,
                            outputFile: outputFile.path,
                            message: "started in background"
                        )),
                    ],
                    uiDisplay: [display]
                )
            }

            onUpdate?(AgentToolResult(
                content: [.text(TextContent(text: "Starting subagent \(definition.name)..."))],
                details: .object([
                    "status": .string("starting"),
                    "subagent_type": .string(definition.name),
                    "child_session_id": .string(childSessionId),
                    "description": .string(input.description),
                ]),
                runtimeEvents: [
                    .subagent(SubagentLifecycleEvent(
                        kind: .started,
                        toolCallId: toolCallId,
                        subagentType: definition.name,
                        childSessionId: childSessionId,
                        description: input.description,
                        message: "starting"
                    )),
                ],
                uiDisplay: ["agent \(definition.name) starting · 0 tokens"]
            ))
            let result: SubagentResult
            do {
                result = try await runner.run(
                    cancellation: cancellation,
                    onUpdate: onUpdate,
                    toolCallId: toolCallId
                )
            } catch {
                let message = subagentErrorMessage(error)
                throw StructuredToolExecutionError(
                    message: message,
                    details: subagentFailureDetails(
                        definition: definition,
                        input: input,
                        childSessionId: childSessionId,
                        message: message
                    ),
                    runtimeEvents: [
                        .subagent(SubagentLifecycleEvent(
                            kind: .failed,
                            toolCallId: toolCallId,
                            subagentType: definition.name,
                            childSessionId: childSessionId,
                            description: input.description,
                            errorMessage: message
                        )),
                    ]
                )
            }
            let body = """
            Subagent \(definition.name) completed.

            \(result.text)
            """
            return AgentToolResult(
                content: [.text(TextContent(text: body))],
                details: .object([
                    "status": .string("completed"),
                    "subagent_type": .string(definition.name),
                    "description": .string(input.description),
                    "child_session_id": .string(childSessionId),
                    "model": .string(result.model.id),
                    "stop_reason": .string(result.stopReason.rawValue),
                    "usage": usageDetails(result.usage),
                    "turns": .int(result.turns),
                    "cost": costDetails(result.cost),
                    "duration_ms": .int(result.durationMs),
                ]),
                runtimeEvents: [
                    .subagent(SubagentLifecycleEvent(
                        kind: .completed,
                        toolCallId: toolCallId,
                        subagentType: definition.name,
                        childSessionId: childSessionId,
                        description: input.description,
                        model: result.model.id,
                        stopReason: result.stopReason,
                        usage: result.usage,
                        turns: result.turns,
                        cost: result.cost,
                        durationMs: result.durationMs,
                        message: shortSubagentSummary(result.text)
                    )),
                ],
                uiDisplay: ["agent \(definition.name) completed · \(formatUsage(result.usage))"]
            )
        }
    )
}

private struct SubagentRegistry: Sendable {
    static let defaultFallbackName = "general"

    let names: [String]
    private let definitions: [String: SubagentDefinition]

    init(_ subagents: [SubagentDefinition]) {
        var names: [String] = []
        var definitions: [String: SubagentDefinition] = [:]
        for definition in subagents {
            let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if definitions[name] == nil {
                names.append(name)
            }
            definitions[name] = definition
        }
        self.names = names
        self.definitions = definitions
    }

    func definition(named name: String) -> SubagentDefinition? {
        definitions[name]
    }
}

private struct AgentToolInput {
    var description: String
    var prompt: String
    var subagentType: String?
    var modelOverride: String?
    var runInBackground: Bool?
}

private func parseAgentToolInput(_ args: JSONValue) throws -> AgentToolInput {
    guard case .object(let obj) = args else {
        throw CodingToolError.invalidArgument("agent: expected object input")
    }
    guard case .string(let description) = obj["description"] ?? .null,
          !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CodingToolError.invalidArgument("agent: `description` is required")
    }
    guard case .string(let prompt) = obj["prompt"] ?? .null,
          !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CodingToolError.invalidArgument("agent: `prompt` is required")
    }
    let subagentType: String? = {
        switch obj["subagent_type"] ?? .null {
        case .null:
            return nil
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }()
    let modelOverride: String? = {
        guard case .string(let raw) = obj["model"] ?? .null else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()
    let runInBackground: Bool? = {
        guard case .bool(let value) = obj["run_in_background"] ?? .null else { return nil }
        return value
    }()
    return AgentToolInput(
        description: description,
        prompt: prompt,
        subagentType: subagentType,
        modelOverride: modelOverride,
        runInBackground: runInBackground
    )
}

private enum SubagentPromptBuilder {
    static func agentToolDescription(registry: SubagentRegistry) -> String {
        let agents = registry.names.map { name -> String in
            guard let definition = registry.definition(named: name) else { return "- \(name)" }
            return "- \(name): \(definition.description) (Tools: \(subagentToolsDescription(definition.tools)))"
        }.joined(separator: "\n")

        return """
        Launch a fresh-context subagent for a specialized task.

        Available subagents:
        \(agents.isEmpty ? "(none)" : agents)

        Usage notes:
        - Omit `subagent_type` to use `general` when it is available; otherwise set it to one of the available subagents.
        - Always include a short `description` summarizing the work.
        - The subagent does not inherit the parent transcript. Put all necessary file paths, errors, goals, and constraints in `prompt`.
        - The subagent's output is returned only to you as this tool result; summarize it for the user when relevant.
        - Background tasks started by the subagent's own tools are scoped to the subagent and are killed when that subagent ends.
        - Use foreground mode by default when you need the result before continuing.
        - Use `run_in_background` only for independent work. You will be notified when it completes; do not poll in a loop.
        - Subagents cannot spawn other subagents.
        """
    }

    static func systemPrompt(
        definition: SubagentDefinition,
        cwd: String,
        tools: [AgentTool]
    ) -> String {
        let instructions = """

        # Subagent Instructions

        You are running as the `\(definition.name)` subagent.

        \(definition.prompt)

        Any background tasks you start are scoped to your subagent lifecycle and will be killed when you finish. If their output matters, wait for them before giving your final answer.

        You cannot spawn other subagents. Complete the assigned task yourself with the tools available to you.
        """
        return buildSystemPrompt(SystemPromptOptions(
            cwd: cwd,
            appendSystemPrompt: instructions
        ))
    }
}

private func buildAgentToolDescription(registry: SubagentRegistry) -> String {
    SubagentPromptBuilder.agentToolDescription(registry: registry)
}

private func subagentToolsDescription(_ tools: CodingTools?) -> String {
    guard let tools else { return "Inherits parent tools" }
    var names: [String] = []
    if tools.contains(.read) { names.append("read") }
    if tools.contains(.write) { names.append("write") }
    if tools.contains(.edit) { names.append("edit") }
    if tools.contains(.bash) { names.append("bash") }
    if tools.contains(.grep) { names.append("grep") }
    if tools.contains(.find) { names.append("find") }
    if tools.contains(.ls) { names.append("ls") }
    if tools.contains(.taskStatus) { names.append("task_status") }
    if tools.contains(.waitTask) { names.append("wait_task") }
    if tools.contains(.tmux) { names.append("tmux") }
    return names.isEmpty ? "None" : names.joined(separator: ", ")
}

public struct SubagentResult: Sendable {
    public var text: String
    public var model: Model
    public var stopReason: StopReason
    public var usage: Usage
    public var turns: Int
    public var cost: Cost
    public var durationMs: Int

    public init(
        text: String,
        model: Model,
        stopReason: StopReason,
        usage: Usage,
        turns: Int = 0,
        cost: Cost = Cost(),
        durationMs: Int = 0
    ) {
        self.text = text
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
        self.turns = turns
        self.cost = cost
        self.durationMs = durationMs
    }
}

public struct StartedSubagentTask: Sendable {
    public var taskId: String
    public var outputFile: URL
    public var childSessionId: String
    public var subagentType: String
    public var description: String

    public init(
        taskId: String,
        outputFile: URL,
        childSessionId: String,
        subagentType: String,
        description: String
    ) {
        self.taskId = taskId
        self.outputFile = outputFile
        self.childSessionId = childSessionId
        self.subagentType = subagentType
        self.description = description
    }
}

/// SDK-facing runner for invoking configured subagents directly, without
/// asking a parent model to call the `agent` tool.
public struct SubagentRunner: Sendable {
    private var cwd: String
    private var subagents: [SubagentDefinition]
    private var backgroundManager: BackgroundTaskManager?
    private var parentSessionId: String?
    private var parentSnapshot: @Sendable () -> SubagentParentSnapshot
    private var bashDefaultTimeoutSeconds: Int
    private var bashMaxTimeoutSeconds: Int
    private var bashEnvironment: [String: String]
    private var bashShellPath: String
    private var tmuxManager: TmuxSessionManager?

    public init(
        cwd: String,
        subagents: [SubagentDefinition],
        parentModel: Model,
        parentTools: CodingTools,
        parentThinkingLevel: ThinkingLevel = .off,
        parentThinkingBudgets: ThinkingBudgets? = nil,
        parentMaxRetryDelayMs: Int? = nil,
        parentAutoCompact: AgentAutoCompactOptions? = nil,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String? = nil,
        authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
        bashEnvironment: [String: String],
        bashDefaultTimeoutSeconds: Int = 120,
        bashMaxTimeoutSeconds: Int = 600,
        bashShellPath: String = kwwkDefaultShellPath,
        tmuxManager: TmuxSessionManager? = nil
    ) {
        let snapshot = SubagentParentSnapshot(
            model: parentModel,
            tools: parentTools,
            thinkingLevel: parentThinkingLevel,
            thinkingBudgets: parentThinkingBudgets,
            maxRetryDelayMs: parentMaxRetryDelayMs,
            autoCompact: parentAutoCompact,
            authResolver: authResolver
        )
        self.cwd = cwd
        self.subagents = subagents
        self.backgroundManager = backgroundManager
        self.parentSessionId = sessionId
        self.parentSnapshot = { snapshot }
        self.bashDefaultTimeoutSeconds = bashDefaultTimeoutSeconds
        self.bashMaxTimeoutSeconds = bashMaxTimeoutSeconds
        self.bashEnvironment = bashEnvironment
        self.bashShellPath = bashShellPath
        self.tmuxManager = tmuxManager
    }

    public init(
        cwd: String,
        subagents: [SubagentDefinition],
        parentAgent: Agent,
        parentTools: CodingTools,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String? = nil,
        fallbackAuthResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
        bashEnvironment: [String: String],
        bashDefaultTimeoutSeconds: Int = 120,
        bashMaxTimeoutSeconds: Int = 600,
        bashShellPath: String = kwwkDefaultShellPath,
        tmuxManager: TmuxSessionManager? = nil
    ) {
        let parentBox = SubagentParentBox(
            fallbackModel: parentAgent.state.model,
            fallbackTools: parentTools,
            fallbackThinkingLevel: parentAgent.state.thinkingLevel,
            fallbackThinkingBudgets: parentAgent.thinkingBudgets,
            fallbackMaxRetryDelayMs: parentAgent.maxRetryDelayMs,
            fallbackAutoCompact: parentAgent.autoCompact,
            fallbackAuthResolver: parentAgent.authResolver ?? fallbackAuthResolver
        )
        parentBox.attach(parentAgent)
        self.cwd = cwd
        self.subagents = subagents
        self.backgroundManager = backgroundManager
        self.parentSessionId = sessionId ?? parentAgent.sessionId
        self.parentSnapshot = { parentBox.snapshot() }
        self.bashDefaultTimeoutSeconds = bashDefaultTimeoutSeconds
        self.bashMaxTimeoutSeconds = bashMaxTimeoutSeconds
        self.bashEnvironment = bashEnvironment
        self.bashShellPath = bashShellPath
        self.tmuxManager = tmuxManager
    }

    public func run(
        type: String,
        prompt: String,
        modelOverride: String? = nil,
        cancellation: CancellationHandle? = nil,
        onUpdate: AgentToolUpdate? = nil
    ) async throws -> SubagentResult {
        let definition = try definition(named: type)
        let runner = makeInvocationRunner(
            definition: definition,
            prompt: prompt,
            modelOverride: modelOverride
        )
        return try await runner.run(cancellation: cancellation, onUpdate: onUpdate)
    }

    public func startBackground(
        type: String,
        prompt: String,
        description: String,
        modelOverride: String? = nil
    ) async throws -> StartedSubagentTask {
        guard let backgroundManager else {
            throw CodingToolError.invalidArgument("SubagentRunner.startBackground requires a BackgroundTaskManager")
        }
        let definition = try definition(named: type)
        let runner = makeInvocationRunner(
            definition: definition,
            prompt: prompt,
            modelOverride: modelOverride
        )
        let bgRunner = SubagentBackgroundRunner(
            runner: runner,
            subagentType: definition.name,
            description: description
        )
        let (taskId, outputFile) = await backgroundManager.spawn(
            runner: bgRunner,
            sessionId: parentSessionId
        )
        return StartedSubagentTask(
            taskId: taskId,
            outputFile: outputFile,
            childSessionId: runner.childSessionId,
            subagentType: definition.name,
            description: description
        )
    }

    private func definition(named rawName: String) throws -> SubagentDefinition {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let definition = subagents.first(where: { $0.name == trimmed }) {
            return definition
        }
        let names = subagents
            .map(\.name)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
        throw CodingToolError.invalidArgument(
            "subagent: unknown type '\(rawName)'. Available subagents: \(names)"
        )
    }

    private func makeInvocationRunner(
        definition: SubagentDefinition,
        prompt: String,
        modelOverride: String?
    ) -> SubagentInvocationRunner {
        SubagentInvocationRunner(
            cwd: cwd,
            definition: definition,
            taskPrompt: prompt,
            modelOverride: modelOverride,
            parentSnapshot: parentSnapshot,
            backgroundManager: backgroundManager,
            childSessionId: makeSubagentSessionId(parent: parentSessionId, name: definition.name),
            bashDefaultTimeoutSeconds: bashDefaultTimeoutSeconds,
            bashMaxTimeoutSeconds: bashMaxTimeoutSeconds,
            bashEnvironment: bashEnvironment,
            bashShellPath: bashShellPath,
            tmuxManager: tmuxManager
        )
    }
}

private struct SubagentUsageSnapshot: Sendable, Equatable {
    var usage: Usage
    var estimated: Bool
}

private actor SubagentProgressEmitter {
    private let subagentName: String
    private let childSessionId: String
    private let toolCallId: String?
    private let onUpdate: AgentToolUpdate?
    private var completedUsage = Usage()
    private var lastSnapshot: SubagentUsageSnapshot?

    init(
        subagentName: String,
        childSessionId: String,
        toolCallId: String?,
        onUpdate: AgentToolUpdate?
    ) {
        self.subagentName = subagentName
        self.childSessionId = childSessionId
        self.toolCallId = toolCallId
        self.onUpdate = onUpdate
    }

    func observe(_ event: AgentEvent) {
        guard let onUpdate else { return }
        let snapshot: SubagentUsageSnapshot?
        switch event {
        case .messageUpdate(let assistant, _):
            let live = liveUsage(for: assistant)
            snapshot = SubagentUsageSnapshot(
                usage: addUsage(completedUsage, live.usage),
                estimated: live.estimated
            )

        case .messageEnd(let message):
            guard case .assistant(let assistant) = message else { return }
            completedUsage = addUsage(completedUsage, finalizedUsage(for: assistant))
            snapshot = SubagentUsageSnapshot(usage: completedUsage, estimated: false)

        case .agentEnd(_, let summary):
            completedUsage = summary.usage
            snapshot = SubagentUsageSnapshot(usage: completedUsage, estimated: false)

        default:
            return
        }

        guard let snapshot, snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onUpdate(subagentProgressResult(
            subagentName: subagentName,
            childSessionId: childSessionId,
            toolCallId: toolCallId,
            snapshot: snapshot
        ))
    }
}

private actor SubagentSummaryCapture {
    private var summary: AgentRunSummary?

    func observe(_ event: AgentEvent) {
        guard case .agentEnd(_, let summary) = event else { return }
        self.summary = summary
    }

    func snapshot() -> AgentRunSummary? {
        summary
    }
}

private struct SubagentInvocationRunner: Sendable {
    var cwd: String
    var definition: SubagentDefinition
    var taskPrompt: String
    var modelOverride: String?
    var parentSnapshot: @Sendable () -> SubagentParentSnapshot
    var backgroundManager: BackgroundTaskManager?
    var childSessionId: String
    var bashDefaultTimeoutSeconds: Int
    var bashMaxTimeoutSeconds: Int
    var bashEnvironment: [String: String]
    var bashShellPath: String
    var tmuxManager: TmuxSessionManager?

    func run(
        cancellation: CancellationHandle?,
        onUpdate: AgentToolUpdate?,
        toolCallId: String? = nil
    ) async throws -> SubagentResult {
        do {
            let result = try await runChild(
                cancellation: cancellation,
                onUpdate: onUpdate,
                toolCallId: toolCallId
            )
            await closeChildSession()
            return result
        } catch {
            await closeChildSession()
            throw error
        }
    }

    private func runChild(
        cancellation: CancellationHandle?,
        onUpdate: AgentToolUpdate?,
        toolCallId: String?
    ) async throws -> SubagentResult {
        try cancellation?.throwIfCancelled()
        let parent = parentSnapshot()
        let model = resolveSubagentModel(
            parent: parent.model,
            definitionModel: definition.model,
            toolOverride: modelOverride
        )
        let selectedTools = definition.tools ?? parent.tools
        let tools = await buildCodingToolList(
            cwd: cwd,
            selected: selectedTools,
            backgroundManager: backgroundManager,
            sessionId: childSessionId,
            bashDefaultTimeoutSeconds: bashDefaultTimeoutSeconds,
            bashMaxTimeoutSeconds: bashMaxTimeoutSeconds,
            bashEnvironment: bashEnvironment,
            bashShellPath: bashShellPath,
            tmuxManager: tmuxManager
        )
        let systemPrompt = buildSubagentSystemPrompt(
            definition: definition,
            cwd: cwd,
            tools: tools
        )
        let child = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                systemPrompt: systemPrompt,
                model: model,
                thinkingLevel: parent.thinkingLevel,
                tools: tools
            ),
            sessionId: childSessionId,
            thinkingBudgets: parent.thinkingBudgets,
            maxRetryDelayMs: parent.maxRetryDelayMs,
            autoCompact: inheritedAutoCompact(
                parent.autoCompact,
                backgroundManager: backgroundManager
            ),
            authResolver: parent.authResolver
        ))
        let progress = SubagentProgressEmitter(
            subagentName: definition.name,
            childSessionId: childSessionId,
            toolCallId: toolCallId,
            onUpdate: onUpdate
        )
        let summaryCapture = SubagentSummaryCapture()
        let unsubscribeProgress = child.subscribe { event, _ in
            await progress.observe(event)
            await summaryCapture.observe(event)
        }
        let detachBackground: (@Sendable () async -> Void)?
        if let backgroundManager {
            detachBackground = await child.attachBackgroundManager(
                backgroundManager,
                sessionId: childSessionId
            )
        } else {
            detachBackground = nil
        }
        let cancelRegistration = cancellation?.onCancel { _ in child.abort() }
        do {
            try await child.prompt(taskPrompt)
        } catch {
            cancelRegistration?.cancel()
            unsubscribeProgress()
            if let detachBackground {
                await detachBackground()
            }
            throw error
        }
        cancelRegistration?.cancel()
        unsubscribeProgress()
        if let detachBackground {
            await detachBackground()
        }
        if cancellation?.isCancelled ?? false {
            throw CodingToolError.aborted
        }
        let childSummary = await summaryCapture.snapshot()
        return try extractSubagentResult(
            messages: child.state.messages,
            model: model,
            summary: childSummary
        )
    }

    private func closeChildSession() async {
        await KWWKAI.closeProviderSession(sessionId: childSessionId)
        guard let backgroundManager else { return }
        await backgroundManager.closeSession(sessionId: childSessionId)
    }
}

private struct SubagentBackgroundRunner: BackgroundTaskRunner {
    var runner: SubagentInvocationRunner
    var subagentType: String
    var description: String

    var spec: BackgroundTaskSpec {
        BackgroundTaskSpec(
            kind: "agent",
            label: "agent:\(subagentType)",
            description: description
        )
    }

    func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    ) {
        Task.detached {
            do {
                let result = try await runner.run(cancellation: cancellation, onUpdate: nil)
                let outputBytes = try writeSubagentOutput(result.text, to: outputFile)
                onDone(BackgroundTaskOutcome(
                    success: true,
                    summary: "completed",
                    details: .object([
                        "status": .string("completed"),
                        "subagent_type": .string(subagentType),
                        "child_session_id": .string(runner.childSessionId),
                        "model": .string(result.model.id),
                        "stop_reason": .string(result.stopReason.rawValue),
                        "usage": usageDetails(result.usage),
                        "turns": .int(result.turns),
                        "cost": costDetails(result.cost),
                        "duration_ms": .int(result.durationMs),
                        "output_bytes": .int(outputBytes),
                    ])
                ))
            } catch {
                let message = subagentErrorMessage(error)
                let outputBytes = try? writeSubagentOutput(
                    "Subagent \(subagentType) failed: \(message)\n",
                    to: outputFile
                )
                onDone(BackgroundTaskOutcome(
                    success: false,
                    summary: cancellation.isCancelled ? "aborted" : "failed",
                    details: .object([
                        "status": .string("failed"),
                        "subagent_type": .string(subagentType),
                        "child_session_id": .string(runner.childSessionId),
                        "error_message": .string(message),
                        "output_bytes": .int(outputBytes ?? 0),
                    ]),
                    errorMessage: message
                ))
            }
        }
    }
}

private func buildSubagentSystemPrompt(
    definition: SubagentDefinition,
    cwd: String,
    tools: [AgentTool]
) -> String {
    SubagentPromptBuilder.systemPrompt(definition: definition, cwd: cwd, tools: tools)
}

private func resolveSubagentModel(
    parent: Model,
    definitionModel: SubagentModel,
    toolOverride: String?
) -> Model {
    if let toolOverride {
        return resolveModelString(toolOverride, parent: parent)
    }
    switch definitionModel {
    case .inherit:
        return parent
    case .override(let model):
        return model
    }
}

private func resolveModelString(_ raw: String, parent: Model) -> Model {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty || value.lowercased() == "inherit" {
        return parent
    }
    if let sameProvider = ModelsCatalog.model(provider: parent.provider, id: value) {
        return adoptRuntimeFields(from: parent, into: sameProvider)
    }
    var fallback = parent
    fallback.id = value
    fallback.name = value
    return fallback
}

private func inheritedAutoCompact(
    _ parent: AgentAutoCompactOptions?,
    backgroundManager: BackgroundTaskManager?
) -> AgentAutoCompactOptions? {
    guard var inherited = parent else { return nil }
    inherited.backgroundManager = backgroundManager
    return inherited
}

private func adoptRuntimeFields(from current: Model, into picked: Model) -> Model {
    var rebuilt = picked
    rebuilt.api = current.api
    rebuilt.provider = current.provider
    rebuilt.baseUrl = current.baseUrl
    rebuilt.headers = current.headers
    return rebuilt
}

private func makeSubagentSessionId(parent: String?, name: String) -> String {
    let safeName = name.replacingOccurrences(of: " ", with: "-")
    if let parent, !parent.isEmpty {
        return "\(parent):subagent:\(safeName):\(UUID().uuidString)"
    }
    return "subagent:\(safeName):\(UUID().uuidString)"
}

private func subagentProgressResult(
    subagentName: String,
    childSessionId: String,
    toolCallId: String?,
    snapshot: SubagentUsageSnapshot
) -> AgentToolResult {
    let label = "agent \(subagentName) running · \(formatUsage(snapshot.usage, estimated: snapshot.estimated))"
    return AgentToolResult(
        content: [.text(TextContent(text: label))],
        details: .object([
            "status": .string("running"),
            "subagent_type": .string(subagentName),
            "child_session_id": .string(childSessionId),
            "usage": usageDetails(snapshot.usage),
            "estimated": .bool(snapshot.estimated),
        ]),
        runtimeEvents: [
            .subagent(SubagentLifecycleEvent(
                kind: .toolUpdate,
                toolCallId: toolCallId,
                subagentType: subagentName,
                childSessionId: childSessionId,
                usage: snapshot.usage,
                usageEstimated: snapshot.estimated,
                message: label
            )),
        ],
        uiDisplay: [label]
    )
}

private func liveUsage(for assistant: AssistantMessage) -> SubagentUsageSnapshot {
    let usage = normalizedUsage(assistant.usage)
    if hasUsage(usage) {
        return SubagentUsageSnapshot(usage: usage, estimated: false)
    }
    let estimatedOutput = estimateTokens(assistantOutputText(assistant))
    guard estimatedOutput > 0 else {
        return SubagentUsageSnapshot(usage: Usage(), estimated: false)
    }
    return SubagentUsageSnapshot(
        usage: Usage(output: estimatedOutput, totalTokens: estimatedOutput),
        estimated: true
    )
}

private func finalizedUsage(for assistant: AssistantMessage) -> Usage {
    let usage = normalizedUsage(assistant.usage)
    if hasUsage(usage) { return usage }
    let estimatedOutput = estimateTokens(assistantOutputText(assistant))
    return Usage(output: estimatedOutput, totalTokens: estimatedOutput)
}

private func aggregateAssistantUsage(messages: [Message]) -> Usage {
    messages.reduce(into: Usage()) { partial, message in
        guard case .assistant(let assistant) = message else { return }
        partial = addUsage(partial, finalizedUsage(for: assistant))
    }
}

private func normalizedUsage(_ usage: Usage) -> Usage {
    var out = usage
    if out.totalTokens == 0 {
        out.totalTokens = out.input + out.output + out.cacheRead + out.cacheWrite
    }
    return out
}

private func hasUsage(_ usage: Usage) -> Bool {
    usage.input > 0
        || usage.output > 0
        || usage.cacheRead > 0
        || usage.cacheWrite > 0
        || usage.totalTokens > 0
}

private func addUsage(_ lhs: Usage, _ rhs: Usage) -> Usage {
    Usage(
        input: lhs.input + rhs.input,
        output: lhs.output + rhs.output,
        cacheRead: lhs.cacheRead + rhs.cacheRead,
        cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
        totalTokens: normalizedUsage(lhs).totalTokens + normalizedUsage(rhs).totalTokens
    )
}

private func assistantOutputText(_ assistant: AssistantMessage) -> String {
    assistant.content.compactMap { block -> String? in
        switch block {
        case .text(let text):
            return text.text
        case .thinking(let thinking):
            return thinking.thinking
        case .toolCall(let call):
            return call.name
        }
    }.joined(separator: "\n")
}

private func estimateTokens(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return Int((Double(text.utf8.count) / 4.0).rounded(.up))
}

private func usageDetails(_ usage: Usage) -> JSONValue {
    let normalized = normalizedUsage(usage)
    return .object([
        "input": .int(normalized.input),
        "output": .int(normalized.output),
        "cache_read": .int(normalized.cacheRead),
        "cache_write": .int(normalized.cacheWrite),
        "total_tokens": .int(normalized.totalTokens),
    ])
}

private func costDetails(_ cost: Cost) -> JSONValue {
    .object([
        "input": .double(cost.input),
        "output": .double(cost.output),
        "cache_read": .double(cost.cacheRead),
        "cache_write": .double(cost.cacheWrite),
        "total": .double(cost.total),
    ])
}

private func formatUsage(_ usage: Usage, estimated: Bool = false) -> String {
    let normalized = normalizedUsage(usage)
    let prefix = estimated ? "~" : ""
    if normalized.input == 0, normalized.cacheRead == 0, normalized.cacheWrite == 0 {
        return "\(prefix)\(normalized.totalTokens) tokens"
    }
    var parts = [
        "in \(normalized.input)",
        "out \(normalized.output)",
    ]
    if normalized.cacheRead > 0 { parts.append("cache \(normalized.cacheRead)") }
    if normalized.cacheWrite > 0 { parts.append("cache write \(normalized.cacheWrite)") }
    return "\(prefix)\(normalized.totalTokens) tokens (\(parts.joined(separator: " · ")))"
}

private func extractSubagentResult(
    messages: [Message],
    model: Model,
    summary: AgentRunSummary?
) throws -> SubagentResult {
    guard let final = messages.reversed().compactMap({ message -> AssistantMessage? in
        if case .assistant(let assistant) = message { return assistant }
        return nil
    }).first else {
        throw CodingToolError.runtime("agent: subagent produced no assistant message")
    }
    if final.stopReason == .aborted {
        throw CodingToolError.aborted
    }
    if final.stopReason == .error {
        let message = final.errorMessage ?? "subagent stopped with error"
        if message.hasPrefix("Maximum turn limit") {
            throw CodingToolError.runtime("agent: subagent reached maxTurns before producing final text: \(message)")
        }
        throw CodingToolError.runtime("agent: \(message)")
    }
    if let error = final.errorMessage, !error.isEmpty {
        throw CodingToolError.runtime("agent: \(error)")
    }
    if final.stopReason == .toolUse {
        throw CodingToolError.runtime("agent: subagent stopped for tool use without a final answer")
    }
    if final.stopReason == .length {
        throw CodingToolError.runtime("agent: subagent hit the model length limit before producing final text")
    }
    let text = final.content.compactMap { block -> String? in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined()
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw CodingToolError.runtime(
            "agent: subagent produced no final text (stop_reason=\(final.stopReason.rawValue))"
        )
    }
    return SubagentResult(
        text: trimmed,
        model: model,
        stopReason: final.stopReason,
        usage: summary?.usage ?? aggregateAssistantUsage(messages: messages),
        turns: summary?.turns ?? 0,
        cost: summary?.cost ?? Cost(),
        durationMs: summary?.durationMs ?? 0
    )
}

private func writeSubagentOutput(
    _ text: String,
    to url: URL
) throws -> Int {
    let data = Data(text.utf8)
    try data.write(to: url, options: [])
    return data.count
}

private func subagentErrorMessage(_ error: Error) -> String {
    if error is CancellationError || (error as? CodingToolError) == .aborted {
        return "aborted by user"
    }
    return (error as? LocalizedError)?.errorDescription ?? "\(error)"
}

private func subagentFailureDetails(
    definition: SubagentDefinition,
    input: AgentToolInput,
    childSessionId: String,
    message: String
) -> JSONValue {
    .object([
        "status": .string("failed"),
        "failure_kind": .string(subagentFailureKind(message)),
        "subagent_type": .string(definition.name),
        "description": .string(input.description),
        "child_session_id": .string(childSessionId),
        "error_message": .string(message),
    ])
}

private func subagentFailureKind(_ message: String) -> String {
    let lower = message.lowercased()
    if lower.contains("maxturns") || lower.contains("maximum turn limit") {
        return "max_turns"
    }
    if lower.contains("timed out") {
        return "timeout"
    }
    if lower.contains("aborted") {
        return "aborted"
    }
    if lower.contains("no final text") || lower.contains("without a final answer") {
        return "no_final_text"
    }
    return "runtime"
}

private func shortSubagentSummary(_ text: String, limit: Int = 240) -> String {
    let oneLine = text
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ?? text
    let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "..."
}
