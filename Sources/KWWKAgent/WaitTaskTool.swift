import Foundation
import KWWKAI

/// `wait_task` — block the agent until a specific background task reaches
/// a terminal state (`completed` / `failed` / `killed`) or until the
/// supplied timeout elapses. Returns the task's final snapshot + a tail
/// of its output in either case; the `waited` flag tells the model
/// whether it hit the deadline or actually saw completion.
///
/// Schema:
/// ```json
/// { "task_id": "bg_...", "timeout_seconds": 30 }
/// ```
///
/// Design notes:
///   - Poll interval is 250ms. Fast enough that a short-lived task is
///     picked up almost immediately; cheap enough that 10 minutes of
///     polling costs a few thousand dict lookups on the actor.
///   - Timeout is clamped to [1s, 600s]. Going above 10 minutes would
///     tie up a single tool-use slot for a long time; if the agent
///     genuinely needs to wait that long it can call wait_task again.
///   - Cancellation from `AgentLoop` (Esc during a tool call) aborts
///     the wait with `CodingToolError.aborted`.
///   - Session-scoped: if the tool was built with a `sessionId`, it
///     refuses to inspect tasks that belong to other sessions.
///
/// Inspired by Claude Code's `TaskOutputTool` — same "block until
/// done or timeout" shape, same poll loop, but plugged into our
/// `BackgroundTaskManager` instead of their TaskState table.
public func createWaitTaskTool(
    manager: BackgroundTaskManager,
    sessionId: String? = nil
) -> AgentTool {
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "task_id": .object([
                "type": .string("string"),
                "description": .string("ID of a background task previously returned by another tool."),
            ]),
            "timeout_seconds": .object([
                "type": .string("integer"),
                "description": .string("Maximum time to block waiting, in seconds. Defaults to 30, max 600."),
                "minimum": .int(1),
                "maximum": .int(600),
            ]),
        ]),
        "required": .array([.string("task_id")]),
    ])

    let description = """
    Wait for a background task to finish (up to `timeout_seconds`, default 30). Returns the task's final status + output tail once it exits, or the current tail if the wait times out.

    Prefer this over polling with `task_status` in a loop — it's cheaper and doesn't flood the transcript with intermediate snapshots. Call `task_status` for a one-shot check instead.

    Useful immediately after kicking off a long-running bash task whose output you need before you can proceed. The `waited` field in the result tells you whether the task actually finished (true) or the timeout fired first (false).
    """

    var tool = AgentTool(
        name: "wait_task",
        label: "wait_task",
        description: description,
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            guard case .object(let obj) = args,
                  case .string(let taskId) = obj["task_id"] ?? .null else {
                throw CodingToolError.invalidArgument("wait_task: `task_id` is required")
            }
            let timeout = clampTimeout(extractTimeout(obj["timeout_seconds"]))

            // Session scoping — same rule task_status applies.
            guard let snap0 = await manager.get(taskId) else {
                throw CodingToolError.invalidArgument("task not found: \(taskId)")
            }
            if let sessionId, snap0.sessionId != sessionId {
                throw CodingToolError.invalidArgument("task not found in this session: \(taskId)")
            }
            // Fast path — already terminal. Still pay the snapshot read
            // so the model gets the tail, but skip the poll loop.
            if snap0.status.isTerminal {
                return buildResult(snap: snap0, waited: true, timedOut: false)
            }

            // Poll loop. 250ms granularity is invisible to humans but
            // ensures a quick-exiting task flips the wait within a
            // quarter second. We check cancellation each tick so an
            // Esc during a long wait surfaces a clean aborted error.
            let start = Date()
            let deadline = start.addingTimeInterval(Double(timeout))
            let pollInterval: UInt64 = 250_000_000   // 250ms

            while Date() < deadline {
                if cancellation?.isCancelled ?? false {
                    throw CodingToolError.aborted
                }
                try? await Task.sleep(nanoseconds: pollInterval)
                if let snap = await manager.get(taskId),
                   snap.status.isTerminal {
                    return buildResult(snap: snap, waited: true, timedOut: false)
                }
            }

            // Deadline hit. Return current snapshot so the agent can
            // decide to re-wait, kill, or keep working in parallel.
            let final = await manager.get(taskId)
            return buildResult(
                snap: final,
                waited: false,
                timedOut: true,
                timeoutSeconds: timeout
            )
        }
    )
    tool.codingToolCapabilities = .job
    return tool
}

// MARK: - Helpers

private func extractTimeout(_ value: JSONValue?) -> Int? {
    guard let value else { return nil }
    switch value {
    case .int(let n): return n
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func clampTimeout(_ raw: Int?) -> Int {
    let value = raw ?? 30
    return max(1, min(600, value))
}

private func buildResult(
    snap: BackgroundTaskSnapshot?,
    waited: Bool,
    timedOut: Bool,
    timeoutSeconds: Int? = nil
) -> AgentToolResult {
    guard let snap else {
        // The task was GC'd mid-wait (only happens if cleanup ran
        // between the initial lookup and the poll tick). Surface as
        // an error result — the model shouldn't pretend the work
        // finished when we literally lost track of it.
        return AgentToolResult(
            content: [.text(TextContent(text: "wait_task: task vanished mid-wait"))],
            details: .object(["waited": .bool(false), "error": .string("task vanished")])
        )
    }

    var body = "task \(snap.id): \(snap.status.rawValue)"
    if timedOut, let timeoutSeconds {
        body += " (still running after \(timeoutSeconds)s; use wait_task again or kill via task_status)"
    }
    body += "\nkind: \(snap.spec.kind)\n"
    body += "label: \(snap.spec.label)\n"
    if let desc = snap.spec.description {
        body += "description: \(desc)\n"
    }
    if let file = snap.outputFile {
        body += "output_file: \(file)  (Read it for full stdout/stderr)\n"
    }
    if let outcome = snap.outcome {
        body += "summary: \(outcome.summary)\n"
        if let err = outcome.errorMessage {
            body += "error: \(err)\n"
        }
    }
    if !snap.outputTail.isEmpty {
        body += "output_tail:\n"
        body += snap.outputTail.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    var details: [String: JSONValue] = [
        "task_id": .string(snap.id),
        "status": .string(snap.status.rawValue),
        "waited": .bool(waited),
        "timed_out": .bool(timedOut),
    ]
    if let outcome = snap.outcome {
        details["summary"] = .string(outcome.summary)
        if let d = outcome.details { details["outcome_details"] = d }
        if let e = outcome.errorMessage { details["error"] = .string(e) }
    }
    if let file = snap.outputFile {
        details["output_file"] = .string(file)
    }

    return AgentToolResult(
        content: [.text(TextContent(text: body))],
        details: .object(details)
    )
}
