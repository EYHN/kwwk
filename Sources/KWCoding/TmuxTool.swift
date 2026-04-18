import Foundation
import KWAI
import KWAgent

/// Exposes `TmuxSessionManager` to the agent as a single multiplexed tool.
/// The tool is only meaningful when tmux is available on PATH — the factory
/// returns nil otherwise so the agent doesn't see a tool it can't actually
/// use.
///
/// Schema (five actions):
/// ```json
/// { "action": "start", "command": "...", "work_dir": "...", "name": "..." }
/// { "action": "send_keys", "pane_id": "%3", "keys": "C-c Enter", "literal": false }
/// { "action": "capture", "pane_id": "%3", "lines": 40 }
/// { "action": "kill", "pane_id": "%3" }
/// { "action": "list" }
/// ```
public func createTmuxTool(manager: TmuxSessionManager = .shared) async -> AgentTool? {
    guard await manager.isAvailable else { return nil }

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
        execute: { _, args, _, _ in
            guard case .object(let obj) = args,
                  case .string(let action) = obj["action"] ?? .null else {
                throw CodingToolError.invalidArgument("tmux: `action` is required")
            }

            switch action {
            case "start":
                guard case .string(let command) = obj["command"] ?? .null else {
                    throw CodingToolError.invalidArgument("tmux: `command` is required for action=start")
                }
                let workDir: String? = {
                    if case .string(let s) = obj["work_dir"] ?? .null { return s }
                    return nil
                }()
                let name: String? = {
                    if case .string(let s) = obj["name"] ?? .null { return s }
                    return nil
                }()
                let info = try await manager.startPane(command: command, workDir: workDir, name: name)
                let msg = "Started pane \(info.paneId) running: \(command)"
                return AgentToolResult(
                    content: [.text(TextContent(text: msg))],
                    details: .object([
                        "pane_id": .string(info.paneId),
                        "name": .string(info.name),
                        "command": .string(info.command),
                    ])
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
