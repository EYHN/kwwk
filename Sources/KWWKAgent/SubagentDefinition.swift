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
    public var model: SubagentModel
    public var runInBackgroundByDefault: Bool

    public init(
        name: String,
        description: String,
        prompt: String,
        tools: CodingTools? = nil,
        model: SubagentModel = .inherit,
        runInBackgroundByDefault: Bool = false
    ) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.tools = tools
        self.model = model
        self.runInBackgroundByDefault = runInBackgroundByDefault
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
    public static let all: BuiltinSubagentSelection = [
        .general,
        .explore,
        .plan,
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
        var selection: BuiltinSubagentSelection = .none
        for part in parts {
            guard let value = named(part) else { return nil }
            if value == .all { return .all }
            selection.insert(value)
        }
        return selection
    }

    public static let validNames = "general, explore, plan, all, none"
}

public extension SubagentDefinition {
    static func general(
        tools: CodingTools? = nil
    ) -> SubagentDefinition {
        SubagentDefinition(
            name: "general",
            description: "Use for broad code research, multi-step work, and tasks that do not need a narrower specialist.",
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
            tools: tools.intersection(.readOnly)
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
            tools: tools.intersection(.readOnly)
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
            tools: tools.intersection(.readOnly)
        )
    }

    static func testRunner(
        tools: CodingTools = [.read, .grep, .find, .ls, .bash]
    ) -> SubagentDefinition {
        var safeTools = tools.intersection(.readOnly)
        if tools.contains(.bash) { safeTools.insert(.bash) }
        if tools.contains(.taskStatus) { safeTools.insert(.taskStatus) }
        if tools.contains(.waitTask) { safeTools.insert(.waitTask) }
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
            - Prefer non-interactive commands and bounded timeouts.

            Output:
            - Command(s) run.
            - Result summary.
            - Failure analysis with relevant log excerpts.
            - Recommended next steps.
            """,
            tools: safeTools
        )
    }

    static func builtins(
        for tools: CodingTools,
        selection: BuiltinSubagentSelection = .all
    ) -> [SubagentDefinition] {
        guard selection != .none else { return [] }
        let readOnly = tools.intersection(.readOnly)

        var agents: [SubagentDefinition] = []
        if selection.contains(.general) {
            agents.append(.general())
        }
        if selection.contains(.explore) {
            guard !readOnly.isEmpty else { return agents }
            agents.append(.explore(tools: readOnly))
        }
        if selection.contains(.plan) {
            guard !readOnly.isEmpty else { return agents }
            agents.append(.plan(tools: readOnly))
        }
        return agents
    }
}
