import Foundation
import KWWKAI

/// Exposes `TmuxSessionManager` to the agent as a single multiplexed tool.
/// The tool is only meaningful when the caller supplied a `TmuxSessionManager`
/// whose explicit `tmuxPath` is executable. The factory returns nil otherwise
/// so the agent doesn't see a tool it can't actually use.
///
/// Schema (five actions):
/// ```json
/// { "action": "start", "command": "...", "work_dir": "...", "name": "..." }
/// { "action": "send_keys", "pane_id": "%3", "keys": "C-c Enter", "literal": false }
/// { "action": "capture", "pane_id": "%3", "lines": 40 }
/// { "action": "kill", "pane_id": "%3" }
/// { "action": "list" }
/// ```
public func createTmuxTool(
    manager: TmuxSessionManager,
    cwd: String,
    bgManager: BackgroundTaskManager? = nil,
    sessionId: String? = nil
) async -> AgentTool? {
    guard await manager.isAvailable else { return nil }
    // `bgManager` and `sessionId` wire the tmux pane into the
    // background-task registry so panes appear in task_status / wait_task.

    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("start"),
                    .string("send_keys"),
                    .string("capture"),
                    .string("kill"),
                    .string("list"),
                ]),
                "description": .string("Which tmux action to perform."),
            ]),
            "command": .object([
                "type": .string("string"),
                "description": .string("Command to run inside the new pane (for action=start)."),
            ]),
            "work_dir": .object([
                "type": .string("string"),
                "description": .string("Working directory for the new pane (for action=start)."),
            ]),
            "name": .object([
                "type": .string("string"),
                "description": .string("Optional pane/window name (for action=start)."),
            ]),
            "pane_id": .object([
                "type": .string("string"),
                "description": .string("Pane id returned by action=start (required for send_keys / capture / kill)."),
            ]),
            "keys": .object([
                "type": .string("string"),
                "description": .string("Keys to send. In tmux notation: space-separated key names like `C-c`, `Enter`, `Up`, or literal text with literal=true."),
            ]),
            "literal": .object([
                "type": .string("boolean"),
                "description": .string("If true, the `keys` string is typed character-by-character instead of being parsed as key names. Use this to enter text like passwords or filenames."),
            ]),
            "lines": .object([
                "type": .string("integer"),
                "description": .string("How many lines of the visible pane buffer to capture. Defaults to the current pane height."),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    let description = """
    Interact with long-lived terminal UI programs (vim, htop, less, interactive wizards, …) through tmux. Use action=start to launch a program in a pane and get back a pane id. Then use action=send_keys to type keystrokes into it and action=capture to read the current visible screen. action=kill closes a pane when you're done.

    Prefer the `bash` tool for non-interactive commands — tmux is for programs that need a real terminal (keyboard input, full-screen cursor addressing, alt-screen).

    Keys use tmux notation: `Enter`, `C-c`, `Escape`, `Up`, `Down`, `BSpace`, `Tab`. Multiple keys separated by spaces. Set literal=true to type a string as text instead of interpreting it as key names.
    """

    return AgentTool(
        name: "tmux",
        label: "tmux",
        description: description,
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let action) = obj["action"] ?? .null else {
                throw CodingToolError.invalidArgument("tmux: `action` is required")
            }

            switch action {
            case "start":
                guard case .string(let command) = obj["command"] ?? .null else {
                    throw CodingToolError.invalidArgument("tmux: `command` is required for action=start")
                }
                let workDir: String?
                if case .string(let s) = obj["work_dir"] ?? .null {
                    workDir = PathUtils.resolveToCwd(s, cwd: cwd)
                } else {
                    workDir = cwd
                }
                let name: String? = {
                    if case .string(let s) = obj["name"] ?? .null { return s }
                    return nil
                }()
                let info = try await manager.startPane(command: command, workDir: workDir, name: name)

                var details: [String: JSONValue] = [
                    "pane_id": .string(info.paneId),
                    "name": .string(info.name),
                    "command": .string(info.command),
                ]
                var msg = "Started pane \(info.paneId) running: \(command)"

                // Bridge to BackgroundTaskManager so the pane shows up in
                // task_status / wait_task and emits a completion notification.
                if let bgManager {
                    let outputFile = bgManager.outputDir
                        .appendingPathComponent("tmux_\(info.paneId).log")
                    try? await manager.pipePaneOutput(paneId: info.paneId, toFile: outputFile)

                    let spec = BackgroundTaskSpec(
                        kind: "tmux",
                        label: info.command,
                        description: "tmux pane \(info.paneId)",
                        hardTimeoutSeconds: 1800
                    )

                    let (taskId, _) = await bgManager.adopt(
                        spec: spec,
                        outputFile: outputFile,
                        sessionId: sessionId,
                        waitForCompletion: { cancellation in
                            let pollInterval: UInt64 = 250_000_000
                            while true {
                                if cancellation.isCancelled {
                                    try? await manager.killPane(info.paneId)
                                    return BackgroundTaskOutcome(
                                        success: false,
                                        summary: "killed",
                                        details: nil,
                                        errorMessage: nil
                                    )
                                }
                                let dead = await manager.isPaneDead(info.paneId)
                                if dead {
                                    let exitCode = await manager.paneExitStatus(info.paneId)
                                    let success = exitCode == 0
                                    return BackgroundTaskOutcome(
                                        success: success,
                                        summary: exitCode != nil ? "exit \(exitCode!)" : "pane closed",
                                        details: exitCode.map { .object(["exitCode": .int($0)]) },
                                        errorMessage: nil
                                    )
                                }
                                try? await Task.sleep(nanoseconds: pollInterval)
                            }
                        }
                    )
                    details["task_id"] = .string(taskId)
                    msg += "\nTask ID: \(taskId) (track with task_status / wait_task)"
                }

                return AgentToolResult(
                    content: [.text(TextContent(text: msg))],
                    details: .object(details)
                )

            case "send_keys":
                guard case .string(let paneId) = obj["pane_id"] ?? .null else {
                    throw CodingToolError.invalidArgument("tmux: `pane_id` is required for action=send_keys")
                }
                guard case .string(let keys) = obj["keys"] ?? .null else {
                    throw CodingToolError.invalidArgument("tmux: `keys` is required for action=send_keys")
                }
                let literal: Bool = {
                    if case .bool(let b) = obj["literal"] ?? .null { return b }
                    return false
                }()
                try await manager.sendKeys(paneId, keys: keys, literal: literal)
                return AgentToolResult(
                    content: [.text(TextContent(text: "sent keys to \(paneId)"))],
                    details: .object([
                        "pane_id": .string(paneId),
                        "literal": .bool(literal),
                    ])
                )

            case "capture":
                guard case .string(let paneId) = obj["pane_id"] ?? .null else {
                    throw CodingToolError.invalidArgument("tmux: `pane_id` is required for action=capture")
                }
                let lines: Int? = {
                    if case .int(let v) = obj["lines"] ?? .null { return v }
                    if case .double(let v) = obj["lines"] ?? .null { return Int(v) }
                    return nil
                }()
                let text = try await manager.capture(paneId, lines: lines)
                return AgentToolResult(
                    content: [.text(TextContent(text: text))],
                    details: .object([
                        "pane_id": .string(paneId),
                        "bytes": .int(text.utf8.count),
                    ])
                )

            case "kill":
                guard case .string(let paneId) = obj["pane_id"] ?? .null else {
                    throw CodingToolError.invalidArgument("tmux: `pane_id` is required for action=kill")
                }
                try await manager.killPane(paneId)
                return AgentToolResult(
                    content: [.text(TextContent(text: "killed pane \(paneId)"))],
                    details: .object(["pane_id": .string(paneId)])
                )

            case "list":
                let panes = await manager.list()
                if panes.isEmpty {
                    return AgentToolResult(
                        content: [.text(TextContent(text: "No tmux panes."))],
                        details: .object(["count": .int(0), "panes": .array([])])
                    )
                }
                let body = panes.map { "- \($0.paneId) [\($0.name)] \($0.command)" }.joined(separator: "\n")
                let paneJson = panes.map { p -> JSONValue in
                    .object([
                        "pane_id": .string(p.paneId),
                        "name": .string(p.name),
                        "command": .string(p.command),
                    ])
                }
                return AgentToolResult(
                    content: [.text(TextContent(text: body))],
                    details: .object([
                        "count": .int(panes.count),
                        "panes": .array(paneJson),
                    ])
                )

            default:
                throw CodingToolError.invalidArgument("tmux: unknown action \(action) (expected: start | send_keys | capture | kill | list)")
            }
        }
    )
}
