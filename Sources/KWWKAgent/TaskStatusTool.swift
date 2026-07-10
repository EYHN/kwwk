import Foundation
import KWWKAI

/// Tool exposing `list` / `status` / `kill` actions on tasks tracked by a
/// `BackgroundTaskManager`. Paired with `createBashTool(... manager: ...)`.
///
/// Schema:
/// ```json
/// { "action": "list" | "status" | "kill", "task_id": "bg_..." }
/// ```
///
/// - `list`: returns an array of running + recent tasks scoped to the
///   optional `sessionId` this tool was created with
/// - `status`: detailed snapshot for one task, including the output file
///   path so the model can Read it for full output
/// - `kill`: cancels a running task; no-op for terminal states
public func createTaskStatusTool(
    manager: BackgroundTaskManager,
    sessionId: String? = nil
) -> AgentTool {
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("list"), .string("status"), .string("kill")]),
                "description": .string("Action to perform."),
            ]),
            "task_id": .object([
                "type": .string("string"),
                "description": .string("Task id (required for `status` and `kill`)."),
            ]),
        ]),
        "required": .array([.string("action")]),
        "additionalProperties": .bool(false),
    ])

    var tool = AgentTool(
        name: "task_status",
        label: "task_status",
        description: "Inspect and manage background tasks. Use action=list to see all tasks for this session, action=status with task_id for details on a single task, or action=kill with task_id to terminate a running task.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let action) = obj["action"] ?? .null else {
                throw CodingToolError.invalidArgument("task_status: `action` is required")
            }
            let allowedKeys: Set<String> = ["action", "task_id"]
            if let unknown = obj.keys.filter({ !allowedKeys.contains($0) }).sorted().first {
                throw CodingToolError.invalidArgument(
                    "task_status: unknown argument `\(unknown)`"
                )
            }
            let taskId: String? = {
                if case .string(let s) = obj["task_id"] ?? .null { return s }
                return nil
            }()

            switch action {
            case "list":
                let tasks = await manager.list(sessionId: sessionId)
                var entries: [JSONValue] = []
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime]
                for snap in tasks {
                    var entry: [String: JSONValue] = [
                        "task_id": .string(snap.id),
                        "kind": .string(snap.spec.kind),
                        "label": .string(snap.spec.label),
                        "status": .string(snap.status.rawValue),
                        "started_at": .string(fmt.string(from: snap.startedAt)),
                    ]
                    if let d = snap.spec.description {
                        entry["description"] = .string(d)
                    }
                    if let file = snap.outputFile {
                        entry["output_file"] = .string(file)
                    }
                    if let completedAt = snap.completedAt {
                        entry["completed_at"] = .string(fmt.string(from: completedAt))
                    }
                    if let outcome = snap.outcome {
                        entry["summary"] = .string(outcome.summary)
                    }
                    entries.append(.object(entry))
                }
                let body = formatListBody(entries: tasks)
                return AgentToolResult(
                    content: [.text(TextContent(text: body))],
                    details: .object([
                        "count": .int(tasks.count),
                        "tasks": .array(entries),
                    ])
                )

            case "status":
                guard let id = taskId else {
                    throw CodingToolError.invalidArgument("task_status: task_id is required for action=status")
                }
                guard let snap = await manager.get(id) else {
                    throw CodingToolError.invalidArgument("task not found: \(id)")
                }
                // Cross-session guard: if the tool was created with a session,
                // only surface tasks that belong to it.
                if let sessionId, snap.sessionId != sessionId {
                    throw CodingToolError.invalidArgument("task not found in this session: \(id)")
                }
                var details: [String: JSONValue] = [
                    "task_id": .string(snap.id),
                    "kind": .string(snap.spec.kind),
                    "label": .string(snap.spec.label),
                    "status": .string(snap.status.rawValue),
                ]
                if let desc = snap.spec.description {
                    details["description"] = .string(desc)
                }
                if let file = snap.outputFile {
                    details["output_file"] = .string(file)
                }
                if let outcome = snap.outcome {
                    details["summary"] = .string(outcome.summary)
                    if let d = outcome.details { details["outcome_details"] = d }
                    if let e = outcome.errorMessage { details["error"] = .string(e) }
                }
                let body = formatStatusBody(snap: snap)
                return AgentToolResult(
                    content: [.text(TextContent(text: body))],
                    details: .object(details)
                )

            case "kill":
                guard let id = taskId else {
                    throw CodingToolError.invalidArgument("task_status: task_id is required for action=kill")
                }
                guard let snap = await manager.get(id) else {
                    throw CodingToolError.invalidArgument("task not found: \(id)")
                }
                if let sessionId, snap.sessionId != sessionId {
                    throw CodingToolError.invalidArgument("task not found in this session: \(id)")
                }
                if snap.status.isTerminal {
                    return AgentToolResult(
                        content: [.text(TextContent(text: "Task \(id) is not running (status: \(snap.status.rawValue))."))],
                        details: .object([
                            "task_id": .string(id),
                            "status": .string(snap.status.rawValue),
                            "killed": .bool(false),
                        ])
                    )
                }
                try await manager.kill(id)
                return AgentToolResult(
                    content: [.text(TextContent(text: "Killed task \(id)."))],
                    details: .object([
                        "task_id": .string(id),
                        "killed": .bool(true),
                    ])
                )

            default:
                throw CodingToolError.invalidArgument("task_status: unknown action \(action) (expected: list | status | kill)")
            }
        }
    )
    tool.codingToolCapabilities = .taskStatus
    return tool
}

// MARK: - Rendering

private func formatListBody(entries: [BackgroundTaskSnapshot]) -> String {
    if entries.isEmpty {
        return "No background tasks."
    }
    var lines: [String] = []
    for snap in entries {
        let status = taskStatusEscapeUntrustedOutput(snap.status.rawValue)
        let label = taskStatusEscapeUntrustedOutput(
            snap.spec.description ?? snap.spec.label
        )
        let file = taskStatusEscapeUntrustedOutput(snap.outputFile ?? "-")
        lines.append("- [\(taskStatusEscapeUntrustedOutput(snap.id))] (\(status)) <untrusted-task-label>\(label)</untrusted-task-label> — output=\(file)")
    }
    return lines.joined(separator: "\n")
}

private func formatStatusBody(snap: BackgroundTaskSnapshot) -> String {
    var out = "task \(taskStatusEscapeUntrustedOutput(snap.id)): \(taskStatusEscapeUntrustedOutput(snap.status.rawValue))\n"
    out += "<untrusted-task-metadata>\n"
    out += "kind: \(taskStatusEscapeUntrustedOutput(snap.spec.kind))\n"
    out += "label: \(taskStatusEscapeUntrustedOutput(snap.spec.label))\n"
    if let d = snap.spec.description {
        out += "description: \(taskStatusEscapeUntrustedOutput(d))\n"
    }
    if let file = snap.outputFile {
        out += "output_file: \(taskStatusEscapeUntrustedOutput(file))  (use job read with this task id for manager-authorized full output)\n"
    }
    if let outcome = snap.outcome {
        out += "summary: \(taskStatusEscapeUntrustedOutput(outcome.summary))\n"
        if let err = outcome.errorMessage {
            out += "error: \(taskStatusEscapeUntrustedOutput(err))\n"
        }
    }
    out += "</untrusted-task-metadata>\n"
    if !snap.outputTail.isEmpty {
        out += "output_tail:\n"
        out += "<untrusted-output>\n"
        out += taskStatusEscapeUntrustedOutput(
            snap.outputTail.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        )
        out += "\n</untrusted-output>"
    }
    if snap.outputTailTruncated {
        out += "\noutput_truncated: true (use the job tool's manager-owned output reader for the complete artifact)"
    }
    return out
}

private func taskStatusEscapeUntrustedOutput(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
