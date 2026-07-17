import Foundation
import KWWKAI

/// Model selection for a subagent.
public enum SubagentModel: Sendable {
    case inherit
    case override(Model)
}

/// Programmatic definition for a fresh-context subagent.
///
/// `description` is routing metadata shown to the parent model. `prompt` is
/// appended to the child agent's system prompt and should define role,
/// boundaries, process, and output format.
public struct SubagentDefinition: Sendable {
    public var name: String
    public var description: String
    public var prompt: String
    public var tools: CodingTools?
    /// Runtime restriction for a child Bash capability. This is evaluated
    /// after inherited hooks rewrite tool arguments, so a hook cannot bypass
    /// the selected specialist boundary.
    public var bashCommandPolicy: BashCommandPolicy
    /// Optional path boundary for built-in file tools. Nil inherits the
    /// parent's policy. This does not constrain Bash or custom tools.
    public var fileAccessPolicy: FileAccessPolicy?
    public var model: SubagentModel
    public var runInBackgroundByDefault: Bool
    /// Optional per-run assistant-turn ceiling. The effective value is the
    /// minimum of this value, the parent ceiling, and `SubagentLimits`.
    public var maxTurns: Int?
    /// Optional wall-clock deadline for both foreground and background runs.
    /// The effective value is capped by `SubagentLimits`.
    public var timeoutSeconds: Int?

    public init(
        name: String,
        description: String,
        prompt: String,
        tools: CodingTools? = nil,
        bashCommandPolicy: BashCommandPolicy = .unrestricted,
        fileAccessPolicy: FileAccessPolicy? = nil,
        model: SubagentModel = .inherit,
        runInBackgroundByDefault: Bool = false,
        maxTurns: Int? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.tools = tools
        self.bashCommandPolicy = bashCommandPolicy
        self.fileAccessPolicy = fileAccessPolicy
        self.model = model
        self.runInBackgroundByDefault = runInBackgroundByDefault
        self.maxTurns = maxTurns
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Resource limits shared by all invocations launched through one `agent`
/// tool (or one `SubagentRunner`).
public struct SubagentLimits: Sendable, Equatable {
    public var maxConcurrent: Int
    public var maxConcurrentMutating: Int
    public var maxTotal: Int
    public var maxTurns: Int?
    public var timeoutSeconds: Int?

    public init(
        maxConcurrent: Int = 4,
        maxConcurrentMutating: Int = 1,
        maxTotal: Int = 64,
        maxTurns: Int? = 16,
        timeoutSeconds: Int? = 600
    ) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxConcurrentMutating = max(1, min(maxConcurrentMutating, self.maxConcurrent))
        self.maxTotal = max(1, maxTotal)
        self.maxTurns = maxTurns.map { max(1, $0) }
        self.timeoutSeconds = timeoutSeconds.map { max(1, $0) }
    }
}

/// Built-in subagent set used by convenience helpers and the CLI.
public struct BuiltinSubagentSelection: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let none: BuiltinSubagentSelection = []
    public static let general = BuiltinSubagentSelection(rawValue: 1 << 0)
    public static let explore = BuiltinSubagentSelection(rawValue: 1 << 1)
    public static let plan = BuiltinSubagentSelection(rawValue: 1 << 2)
    public static let testRunner = BuiltinSubagentSelection(rawValue: 1 << 3)
    public static let codeReviewer = BuiltinSubagentSelection(rawValue: 1 << 4)
    /// Least-privilege investigation/review bundle. Test execution is omitted
    /// because it requires a constrained Bash capability.
    public static let readOnly: BuiltinSubagentSelection = [
        .explore,
        .plan,
        .codeReviewer,
    ]
    public static let all: BuiltinSubagentSelection = [
        .general,
        .explore,
        .plan,
        .testRunner,
        .codeReviewer,
    ]

    public static func named(_ raw: String) -> BuiltinSubagentSelection? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "none", "off", "false", "0":
            return BuiltinSubagentSelection.none
        case "all", "default", "defaults":
            return .all
        case "general", "general-purpose":
            return .general
        case "explore":
            return .explore
        case "plan":
            return .plan
        case "test-runner", "test", "tests":
            return .testRunner
        case "code-reviewer", "review", "reviewer":
            return .codeReviewer
        case "read-only", "readonly":
            return .readOnly
        default:
            return nil
        }
    }

    public static func parseList(_ raw: String) -> BuiltinSubagentSelection? {
        let parts = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return BuiltinSubagentSelection.none }

        // Validate the complete list before applying meta selections. An early
        // return for `all` used to make `all,typo` succeed while `typo,all`
        // failed. Negative selections are intentionally exclusive: mixing
        // `none` (or one of its aliases) with a positive selection is almost
        // certainly a command-line mistake.
        let normalized = parts.map { $0.lowercased() }
        let noneAliases: Set<String> = ["none", "off", "false", "0"]
        let parsed = parts.map(named)
        guard parsed.allSatisfy({ $0 != nil }) else { return nil }
        if normalized.contains(where: noneAliases.contains) {
            return parts.count == 1 ? BuiltinSubagentSelection.none : nil
        }
        let values = parsed.compactMap { $0 }
        if values.contains(.all) { return .all }

        var selection: BuiltinSubagentSelection = .none
        for value in values {
            selection.insert(value)
        }
        return selection
    }

    public static let validNames = "general, explore, plan, test-runner, code-reviewer, read-only, all, none"
}

public extension SubagentDefinition {
    static func general(
        tools: CodingTools? = nil
    ) -> SubagentDefinition {
        SubagentDefinition(
            name: "general",
            description: "Use for implementation work that needs write/edit access and has no narrower specialist. Do not use for read-only exploration, planning, review, or build/test verification.",
            prompt: """
            You are a general-purpose coding agent.

            Strengths:
            - Searching for code, configurations, and patterns across large codebases.
            - Analyzing multiple files to understand architecture and behavior.
            - Executing multi-step implementation or investigation tasks.

            Guidelines:
            - Complete the assigned task fully, without unnecessary extra work.
            - Search broadly when you do not know where something lives; read specific files when paths are known.
            - Prefer editing existing files over creating new files when code changes are requested.
            - Do not create documentation files unless explicitly requested.

            Output:
            - Return a concise report covering what you did and any key findings.
            - Include important file paths, commands, or risks when relevant.
            """,
            tools: tools
        )
    }

    static func explore(
        tools: CodingTools = .readOnly
    ) -> SubagentDefinition {
        SubagentDefinition(
            name: "explore",
            description: "Use for read-only codebase exploration, file discovery, and call-chain analysis.",
            prompt: """
            You are a read-only code exploration specialist.

            Responsibilities:
            - Find relevant files, symbols, call paths, and existing patterns.
            - Read only the files needed to answer the assigned question.
            - Do not edit, create, delete, or move files.
            - Do not run destructive commands.
            - Prefer direct evidence from the repository over broad guesses.

            Output:
            - Start with the direct answer or concise summary.
            - Include important file paths, symbols, and why they matter.
            - Use line references when they are available and useful.
            - Mention uncertainty when evidence is incomplete.
            """,
            tools: tools.intersection(.readOnly),
            fileAccessPolicy: .workspaceOnly
        )
    }

    static func plan(
        tools: CodingTools = .readOnly
    ) -> SubagentDefinition {
        SubagentDefinition(
            name: "plan",
            description: "Use for read-only implementation planning before code changes.",
            prompt: """
            You are a read-only implementation planner.

            Responsibilities:
            - Inspect the relevant code and infer the smallest coherent implementation path.
            - Do not edit, create, delete, or move files.
            - Do not present code changes as already made.
            - Focus on sequencing, risk, and verification.

            Output:
            - Proposed approach.
            - Critical files for implementation.
            - Test or verification plan.
            - Rollback or compatibility risks when relevant.
            - Open questions only if they block execution.
            """,
            tools: tools.intersection(.readOnly),
            fileAccessPolicy: .workspaceOnly
        )
    }

    static func codeReviewer(
        tools: CodingTools = .readOnly
    ) -> SubagentDefinition {
        SubagentDefinition(
            name: "code-reviewer",
            description: "Use for read-only bug, risk, maintainability, and test coverage review.",
            prompt: """
            You are a senior code reviewer.

            Responsibilities:
            - Review for correctness, security, maintainability, and missing tests.
            - Do not edit, create, delete, or move files.
            - Prefer concrete findings over style commentary.

            Output:
            - Findings first, ordered by severity.
            - Include file paths, symbols, or line references as evidence.
            - Explain the user-visible impact for each real bug.
            - If no issues are found, say so and call out residual risk or test gaps.
            """,
            tools: tools.intersection(.readOnly),
            fileAccessPolicy: .workspaceOnly
        )
    }

    static func testRunner(
        tools: CodingTools = [.read, .grep, .find, .ls, .bash]
    ) -> SubagentDefinition {
        var safeTools = tools.intersection(.readOnly)
        if tools.contains(.bash) { safeTools.insert(.bash) }
        if tools.contains(.task) { safeTools.insert(.task) }
        return SubagentDefinition(
            name: "test-runner",
            description: "Use for running tests and analyzing test or build failures.",
            prompt: """
            You are a test-running specialist.

            Responsibilities:
            - Inspect project files to identify the appropriate test or build command before running it.
            - Run focused tests when possible.
            - Analyze failures and report likely causes.
            - Do not edit, create, delete, or move files.
            - Do not run destructive commands.
            - Bash is runtime-restricted to one direct build/test process per call. Shell composition, redirection, command substitution, cleanup commands, and unrelated executables are rejected before launch.
            - Prefer non-interactive commands and bounded timeouts.

            Output:
            - Command(s) run.
            - Result summary.
            - Failure analysis with relevant log excerpts.
            - Recommended next steps.
            """,
            tools: safeTools,
            bashCommandPolicy: .buildAndTestOnly,
            fileAccessPolicy: .workspaceOnly
        )
    }

    static func builtins(
        for tools: CodingTools,
        selection: BuiltinSubagentSelection = .all
    ) -> [SubagentDefinition] {
        guard selection != .none else { return [] }
        let readOnly = tools.intersection(.readOnly)

        var agents: [SubagentDefinition] = []
        if selection.contains(.explore) {
            if !readOnly.isEmpty { agents.append(.explore(tools: readOnly)) }
        }
        if selection.contains(.plan) {
            if !readOnly.isEmpty { agents.append(.plan(tools: readOnly)) }
        }
        if selection.contains(.codeReviewer) {
            if !readOnly.isEmpty { agents.append(.codeReviewer(tools: readOnly)) }
        }
        if selection.contains(.testRunner), tools.contains(.bash) {
            agents.append(.testRunner(tools: tools))
        }
        // Keep the broad, mutating agent last so the model sees narrower
        // specialists first and must make an explicit choice for full access.
        if selection.contains(.general) {
            agents.append(.general())
        }
        return agents
    }
}
