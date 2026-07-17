import Foundation
import KWWKAI

private func taskDeliveryConsumer(
    sessionId: String?,
    explicit: BackgroundTaskDeliveryConsumer?
) -> BackgroundTaskDeliveryConsumer {
    if let explicit, explicit.sessionId == sessionId {
        return explicit
    }
    return BackgroundTaskDeliveryConsumer(sessionId: sessionId)
}

private func optionalTaskParameter(
    _ valueSchema: [String: JSONValue],
    description: String
) -> JSONValue {
    .object([
        "anyOf": .array([
            .object(valueSchema),
            .object(["type": .string("null")]),
        ]),
        "description": .string(description),
    ])
}

/// Creates the four background-task tools with one shared delivery consumer.
/// Filter this array when exposing a subset so the selected tools keep that shared consumer.
public func createTaskTools(
    manager: BackgroundTaskManager,
    sessionId: String? = nil,
    deliveryConsumer explicitConsumer: BackgroundTaskDeliveryConsumer? = nil
) -> [AgentTool] {
    let consumer = taskDeliveryConsumer(sessionId: sessionId, explicit: explicitConsumer)
    return [
        makeTaskListTool(manager: manager, sessionId: sessionId, deliveryConsumer: consumer),
        makeTaskReadTool(manager: manager, sessionId: sessionId, deliveryConsumer: consumer),
        makeTaskPollTool(manager: manager, sessionId: sessionId, deliveryConsumer: consumer),
        makeTaskCancelTool(manager: manager, sessionId: sessionId, deliveryConsumer: consumer),
    ]
}

func createTaskListTool(
    manager: BackgroundTaskManager,
    sessionId: String? = nil,
    deliveryConsumer explicitConsumer: BackgroundTaskDeliveryConsumer? = nil
) -> AgentTool {
    let consumer = taskDeliveryConsumer(sessionId: sessionId, explicit: explicitConsumer)
    return makeTaskListTool(manager: manager, sessionId: sessionId, deliveryConsumer: consumer)
}

func createTaskReadTool(
    manager: BackgroundTaskManager,
    sessionId: String? = nil,
    deliveryConsumer explicitConsumer: BackgroundTaskDeliveryConsumer? = nil
) -> AgentTool {
    let consumer = taskDeliveryConsumer(sessionId: sessionId, explicit: explicitConsumer)
    return makeTaskReadTool(manager: manager, sessionId: sessionId, deliveryConsumer: consumer)
}

func createTaskPollTool(
    manager: BackgroundTaskManager,
    sessionId: String? = nil,
    deliveryConsumer explicitConsumer: BackgroundTaskDeliveryConsumer? = nil
) -> AgentTool {
    let consumer = taskDeliveryConsumer(sessionId: sessionId, explicit: explicitConsumer)
    return makeTaskPollTool(manager: manager, sessionId: sessionId, deliveryConsumer: consumer)
}

func createTaskCancelTool(
    manager: BackgroundTaskManager,
    sessionId: String? = nil,
    deliveryConsumer explicitConsumer: BackgroundTaskDeliveryConsumer? = nil
) -> AgentTool {
    let consumer = taskDeliveryConsumer(sessionId: sessionId, explicit: explicitConsumer)
    return makeTaskCancelTool(manager: manager, sessionId: sessionId, deliveryConsumer: consumer)
}

private func makeTaskListTool(
    manager: BackgroundTaskManager,
    sessionId: String?,
    deliveryConsumer: BackgroundTaskDeliveryConsumer
) -> AgentTool {
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "include_all": optionalTaskParameter(
                ["type": .string("boolean")],
                description: "Include older terminal tasks."
            ),
            "offset": optionalTaskParameter(
                ["type": .string("integer"), "minimum": .int(0)],
                description: "Task offset."
            ),
            "limit": optionalTaskParameter(
                [
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(50),
                ],
                description: "Maximum tasks to return."
            ),
        ]),
        "additionalProperties": .bool(false),
    ])
    let tool = AgentTool(
        name: "task_list",
        label: "task_list",
        description: "List queued, running, and recent background tasks.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            let object = try taskObject(
                args,
                toolName: "task_list",
                allowedKeys: ["include_all", "offset", "limit"]
            )
            let includeAll = try taskBool(
                object["include_all"], field: "include_all", toolName: "task_list"
            )
            let offset = try taskBoundedInteger(
                object["offset"],
                field: "offset",
                toolName: "task_list",
                defaultValue: 0,
                range: 0...1_000_000_000
            )
            let limit = try taskBoundedInteger(
                object["limit"],
                field: "limit",
                toolName: "task_list",
                defaultValue: 20,
                range: 1...50
            )
            let page = await manager.listPage(
                sessionId: sessionId,
                includeAllTerminal: includeAll,
                offset: offset,
                limit: limit
            )
            return taskListResult(page: page)
        }
    )
    return configureTaskTool(tool, manager: manager, deliveryConsumer: deliveryConsumer)
}

private func makeTaskReadTool(
    manager: BackgroundTaskManager,
    sessionId: String?,
    deliveryConsumer: BackgroundTaskDeliveryConsumer
) -> AgentTool {
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "task_id": .object([
                "type": .string("string"),
                "description": .string("Task ID."),
            ]),
            "offset": optionalTaskParameter(
                ["type": .string("integer"), "minimum": .int(0)],
                description: "Byte offset."
            ),
            "limit": optionalTaskParameter(
                [
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(32_768),
                ],
                description: "Maximum bytes to return."
            ),
        ]),
        "required": .array([.string("task_id")]),
        "additionalProperties": .bool(false),
    ])
    let tool = AgentTool(
        name: "task_read",
        label: "task_read",
        description: "Read a byte range from a background task's output.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            let object = try taskObject(
                args,
                toolName: "task_read",
                allowedKeys: ["task_id", "offset", "limit"]
            )
            let taskId = try parsedTaskId(object["task_id"], toolName: "task_read")
            let offset = try taskBoundedInteger(
                object["offset"],
                field: "offset",
                toolName: "task_read",
                defaultValue: 0,
                range: 0...1_000_000_000
            )
            let limit = try taskBoundedInteger(
                object["limit"],
                field: "limit",
                toolName: "task_read",
                defaultValue: 8_192,
                range: 1...32_768
            )
            do {
                let chunk = try await manager.readOutput(
                    taskId: taskId,
                    sessionId: sessionId,
                    offset: offset,
                    limit: limit
                )
                return taskOutputReadResult(chunk)
            } catch let error as BackgroundTaskError {
                throw CodingToolError.invalidArgument(error.localizedDescription)
            }
        }
    )
    return configureTaskTool(tool, manager: manager, deliveryConsumer: deliveryConsumer)
}

private func makeTaskCancelTool(
    manager: BackgroundTaskManager,
    sessionId: String?,
    deliveryConsumer: BackgroundTaskDeliveryConsumer
) -> AgentTool {
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "task_ids": optionalTaskParameter(
                [
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ],
                description: "Task IDs to cancel."
            ),
        ]),
        "additionalProperties": .bool(false),
    ])
    let tool = AgentTool(
        name: "task_cancel",
        label: "task_cancel",
        description: "Cancel background tasks by ID.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            let object = try taskObject(
                args,
                toolName: "task_cancel",
                allowedKeys: ["task_ids"]
            )
            var seen: Set<String> = []
            let taskIds = try taskStringArray(
                object["task_ids"], field: "task_ids", toolName: "task_cancel"
            ).filter { seen.insert($0).inserted }
            guard !taskIds.isEmpty else {
                return taskActionResult(snapshots: [], cancelledIds: [])
            }

            // Validate the complete set before mutating any task.
            for id in taskIds {
                guard let snapshot = await manager.get(id),
                      taskIsVisible(snapshot, sessionId: sessionId) else {
                    throw CodingToolError.invalidArgument(
                        "task_cancel: task not found in this session: \(id)"
                    )
                }
            }

            _ = deliveryConsumer.beginWatching(taskIds: taskIds)
            var watchFinished = false
            defer {
                if !watchFinished {
                    deliveryConsumer.finishWatching(
                        taskIds: taskIds,
                        terminalTaskIds: []
                    )?.rollback()
                }
            }

            try cancellation?.throwIfCancelled()
            let batch = try await manager.killAtomically(taskIds, sessionId: sessionId)
            let snapshots = taskOrderedSnapshots(batch.snapshots, ids: taskIds)
            let terminalIds = Set(snapshots.filter(\.status.isTerminal).map(\.id))
            let lease = deliveryConsumer.finishWatching(
                taskIds: taskIds,
                terminalTaskIds: terminalIds
            )
            watchFinished = true
            var result = taskActionResult(
                snapshots: snapshots,
                cancelledIds: batch.cancelledIds,
                requestedCancelIds: Set(taskIds)
            )
            result.retentionLease = lease
            return result
        }
    )
    return configureTaskTool(tool, manager: manager, deliveryConsumer: deliveryConsumer)
}

private func makeTaskPollTool(
    manager: BackgroundTaskManager,
    sessionId: String?,
    deliveryConsumer: BackgroundTaskDeliveryConsumer
) -> AgentTool {
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "task_ids": optionalTaskParameter(
                [
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ],
                description: "Task IDs to watch; omit to watch all active tasks."
            ),
            "timeout_seconds": optionalTaskParameter(
                [
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(300),
                ],
                description: "Maximum wait in seconds."
            ),
        ]),
        "additionalProperties": .bool(false),
    ])
    var tool = AgentTool(
        name: "task_poll",
        label: "task_poll",
        description: "Wait until any watched background task finishes; use only when otherwise blocked.",
        parameters: parameters,
        interruptible: true,
        execute: { _, args, cancellation, onUpdate in
            try cancellation?.throwIfCancelled()
            let object = try taskObject(
                args,
                toolName: "task_poll",
                allowedKeys: ["task_ids", "timeout_seconds"]
            )
            var seen: Set<String> = []
            let requestedIds = try taskStringArray(
                object["task_ids"], field: "task_ids", toolName: "task_poll"
            ).filter { seen.insert($0).inserted }
            let timeoutSeconds = try taskTimeout(object["timeout_seconds"])
            let taskIds: [String]
            if requestedIds.isEmpty {
                taskIds = await manager.activeTaskIds(sessionId: sessionId)
            } else {
                do {
                    _ = try await manager.snapshots(
                        taskIds: requestedIds,
                        sessionId: sessionId,
                        includeOutputTails: false
                    )
                } catch let error as BackgroundTaskError {
                    throw CodingToolError.invalidArgument(error.localizedDescription)
                }
                taskIds = requestedIds
            }

            let alreadyDelivered = deliveryConsumer.beginWatching(taskIds: taskIds)
            var watchFinished = false
            defer {
                if !watchFinished {
                    deliveryConsumer.finishWatching(
                        taskIds: taskIds,
                        terminalTaskIds: []
                    )?.rollback()
                }
            }

            guard !taskIds.isEmpty else {
                _ = deliveryConsumer.finishWatching(taskIds: [], terminalTaskIds: [])
                watchFinished = true
                return AgentToolResult(
                    content: [.text(TextContent(text: "No queued or running background tasks."))],
                    details: .object([
                        "reason": .string("empty"),
                        "tasks": .array([]),
                    ])
                )
            }

            let watched: [BackgroundTaskSnapshot]
            do {
                watched = try await manager.snapshots(
                    taskIds: taskIds,
                    sessionId: sessionId,
                    includeOutputTails: false
                )
            } catch let error as BackgroundTaskError {
                throw CodingToolError.invalidArgument(error.localizedDescription)
            }

            var snapshots = taskOrderedSnapshots(watched, ids: taskIds)
            var reason = "completed"
            let pollStartedAt = Date()
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            var lastProgressAt = Date.distantPast

            func emitPollProgress(force: Bool = false) {
                guard let onUpdate else { return }
                let now = Date()
                guard force || now.timeIntervalSince(lastProgressAt) >= 0.75 else { return }
                lastProgressAt = now
                onUpdate(taskPollProgressResult(
                    snapshots: snapshots,
                    elapsedMs: Int(now.timeIntervalSince(pollStartedAt) * 1_000),
                    timeoutSeconds: timeoutSeconds
                ))
            }

            emitPollProgress(force: true)
            while !snapshots.contains(where: { $0.status.isTerminal }) {
                if cancellation?.isCancelled == true {
                    if cancellation?.reason == "steering" {
                        reason = "interrupted"
                        break
                    }
                    _ = deliveryConsumer.finishWatching(
                        taskIds: taskIds,
                        terminalTaskIds: []
                    )
                    watchFinished = true
                    throw CodingToolError.aborted
                }
                if Date() >= deadline {
                    reason = "timeout"
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                snapshots = await taskSnapshots(manager: manager, ids: taskIds)
                emitPollProgress()
            }

            // Render and acknowledge the same actor-isolated terminal snapshot.
            let finalLightweight = (try? await manager.snapshots(
                taskIds: taskIds,
                sessionId: sessionId,
                includeOutputTails: false
            )) ?? []
            let renderedSnapshots = taskOrderedSnapshots(
                await taskHydrateTerminalSnapshots(
                    manager: manager,
                    snapshots: finalLightweight
                ),
                ids: taskIds
            )
            if renderedSnapshots.contains(where: { $0.status.isTerminal }) {
                reason = "completed"
            }
            let terminalIds = Set(renderedSnapshots.filter(\.status.isTerminal).map(\.id))
            let lease = deliveryConsumer.finishWatching(
                taskIds: taskIds,
                terminalTaskIds: terminalIds
            )
            watchFinished = true
            var result = taskPollResult(
                snapshots: renderedSnapshots,
                reason: reason,
                alreadyDeliveredTaskIds: alreadyDelivered
            )
            result.retentionLease = lease
            return result
        }
    )
    tool = configureTaskTool(tool, manager: manager, deliveryConsumer: deliveryConsumer)
    tool.isBackgroundTaskPollTool = true
    return tool
}

private func configureTaskTool(
    _ tool: AgentTool,
    manager: BackgroundTaskManager,
    deliveryConsumer: BackgroundTaskDeliveryConsumer
) -> AgentTool {
    var tool = tool
    tool.codingToolCapabilities = .task
    tool.backgroundDeliveryConsumer = deliveryConsumer
    tool.backgroundTaskManager = manager
    return tool
}

private func taskPollProgressResult(
    snapshots: [BackgroundTaskSnapshot],
    elapsedMs: Int,
    timeoutSeconds: Int
) -> AgentToolResult {
    let queued = snapshots.count { $0.status == .queued }
    let running = snapshots.count { $0.status == .running }
    let terminal = snapshots.count { $0.status.isTerminal }
    let elapsed = Double(max(0, elapsedMs)) / 1_000
    let summary = String(
        format: "task_poll waiting · watched=%d · running=%d · queued=%d · terminal=%d · %.1fs/%ds",
        snapshots.count,
        running,
        queued,
        terminal,
        elapsed,
        timeoutSeconds
    )
    return AgentToolResult(
        content: [.text(TextContent(text: summary))],
        details: .object([
            "status": .string("polling"),
            "watched": .int(snapshots.count),
            "running": .int(running),
            "queued": .int(queued),
            "terminal": .int(terminal),
            "elapsed_ms": .int(max(0, elapsedMs)),
            "timeout_seconds": .int(timeoutSeconds),
        ]),
        uiDisplay: [summary]
    )
}

private func taskObject(
    _ value: JSONValue,
    toolName: String,
    allowedKeys: Set<String>
) throws -> [String: JSONValue] {
    guard case .object(let object) = value else {
        throw CodingToolError.invalidArgument("\(toolName): expected an object")
    }
    if let unknown = object.keys.filter({ !allowedKeys.contains($0) }).sorted().first {
        throw CodingToolError.invalidArgument("\(toolName): unknown argument `\(unknown)`")
    }
    return object
}

private func parsedTaskId(_ value: JSONValue?, toolName: String) throws -> String {
    guard case .string(let raw) = value ?? .null else {
        throw CodingToolError.invalidArgument("\(toolName): `task_id` is required")
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw CodingToolError.invalidArgument("\(toolName): `task_id` is required")
    }
    return trimmed
}

private func taskStringArray(
    _ value: JSONValue?,
    field: String,
    toolName: String
) throws -> [String] {
    guard let value else { return [] }
    if case .null = value { return [] }
    guard case .array(let values) = value else {
        throw CodingToolError.invalidArgument(
            "\(toolName): `\(field)` must be an array of task IDs"
        )
    }
    return try values.map { value in
        guard case .string(let raw) = value else {
            throw CodingToolError.invalidArgument(
                "\(toolName): `\(field)` must contain only task IDs"
            )
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw CodingToolError.invalidArgument(
                "\(toolName): `\(field)` must contain only task IDs"
            )
        }
        return id
    }
}

private func taskBool(
    _ value: JSONValue?,
    field: String,
    toolName: String
) throws -> Bool {
    guard let value else { return false }
    if case .null = value { return false }
    guard case .bool(let bool) = value else {
        throw CodingToolError.invalidArgument("\(toolName): `\(field)` must be a boolean")
    }
    return bool
}

private func taskBoundedInteger(
    _ value: JSONValue?,
    field: String,
    toolName: String,
    defaultValue: Int,
    range: ClosedRange<Int>
) throws -> Int {
    guard let value else { return defaultValue }
    if case .null = value { return defaultValue }
    let raw: Int
    switch value {
    case .int(let integer):
        raw = integer
    case .double(let double):
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(range.lowerBound),
              double <= Double(range.upperBound) else {
            throw CodingToolError.invalidArgument(
                "\(toolName): `\(field)` must be an integer from \(range.lowerBound) through \(range.upperBound)"
            )
        }
        raw = Int(double)
    default:
        throw CodingToolError.invalidArgument(
            "\(toolName): `\(field)` must be an integer from \(range.lowerBound) through \(range.upperBound)"
        )
    }
    guard range.contains(raw) else {
        throw CodingToolError.invalidArgument(
            "\(toolName): `\(field)` must be an integer from \(range.lowerBound) through \(range.upperBound)"
        )
    }
    return raw
}

private func taskTimeout(_ value: JSONValue?) throws -> Int {
    guard let value else { return 30 }
    if case .null = value { return 30 }
    let raw: Int
    switch value {
    case .int(let integer):
        raw = integer
    case .double(let double):
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= 1,
              double <= 300 else {
            throw CodingToolError.invalidArgument(
                "task_poll: `timeout_seconds` must be a finite integer from 1 through 300"
            )
        }
        raw = Int(double)
    default:
        throw CodingToolError.invalidArgument(
            "task_poll: `timeout_seconds` must be a finite integer from 1 through 300"
        )
    }
    guard (1...300).contains(raw) else {
        throw CodingToolError.invalidArgument(
            "task_poll: `timeout_seconds` must be a finite integer from 1 through 300"
        )
    }
    return raw
}

private func taskIsVisible(_ snapshot: BackgroundTaskSnapshot, sessionId: String?) -> Bool {
    sessionId == nil || snapshot.sessionId == sessionId
}

private func taskOrderedSnapshots(
    _ snapshots: [BackgroundTaskSnapshot],
    ids: [String]
) -> [BackgroundTaskSnapshot] {
    let byId = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
    return ids.compactMap { byId[$0] }
}

private func taskSnapshots(
    manager: BackgroundTaskManager,
    ids: [String]
) async -> [BackgroundTaskSnapshot] {
    var snapshots: [BackgroundTaskSnapshot] = []
    for id in ids {
        if let snapshot = await manager.get(id, includeOutputTail: false) {
            snapshots.append(snapshot)
        }
    }
    return snapshots
}

private func taskHydrateTerminalSnapshots(
    manager: BackgroundTaskManager,
    snapshots: [BackgroundTaskSnapshot]
) async -> [BackgroundTaskSnapshot] {
    var hydrated: [BackgroundTaskSnapshot] = []
    hydrated.reserveCapacity(snapshots.count)
    for snapshot in snapshots {
        if snapshot.status.isTerminal,
           let detailed = await manager.get(snapshot.id, includeOutputTail: true) {
            hydrated.append(detailed)
        } else {
            hydrated.append(snapshot)
        }
    }
    return hydrated
}

private func taskListResult(page: BackgroundTaskListPage) -> AgentToolResult {
    var lines: [String] = []
    if page.tasks.isEmpty {
        lines.append("No queued, running, or recent background tasks.")
    } else {
        for snapshot in page.tasks {
            var line = "\(snapshot.id): \(taskSemanticStatus(snapshot))"
            if snapshot.status == .queued {
                line += " · waiting_for_capacity"
            } else if snapshot.status == .running {
                line += " · runner_active"
            }
            if snapshot.outputSizeBytes > 0 {
                line += " · output_bytes=\(snapshot.outputSizeBytes)"
            }
            lines.append(line)
            var metadata = ["label: \(taskEscapeUntrustedOutput(snapshot.spec.label))"]
            if let description = snapshot.spec.description {
                metadata.append("description: \(taskEscapeUntrustedOutput(description))")
            }
            if let outcome = snapshot.outcome {
                metadata.append("summary: \(taskEscapeUntrustedOutput(outcome.summary))")
                if let error = outcome.errorMessage {
                    metadata.append("error: \(taskEscapeUntrustedOutput(error))")
                }
            }
            lines.append("  <untrusted-task-metadata>\n  \(metadata.joined(separator: "\n  "))\n  </untrusted-task-metadata>")
            if !snapshot.outputTail.isEmpty {
                lines.append("  output_tail:\n  <untrusted-output>\n\(taskEscapeUntrustedOutput(snapshot.outputTail.trimmingCharacters(in: .newlines)))\n  </untrusted-output>")
            }
            if snapshot.outputTailTruncated {
                lines.append("  output_truncated: true · use task_read for the complete artifact")
            }
        }
    }
    if let next = page.nextOffset {
        lines.append("More tasks available: call task_list({\"offset\":\(next)}).")
    }
    return AgentToolResult(
        content: [.text(TextContent(text: lines.joined(separator: "\n")))],
        details: .object([
            "count": .int(page.tasks.count),
            "total": .int(page.total),
            "offset": .int(page.offset),
            "next_offset": page.nextOffset.map(JSONValue.int) ?? .null,
            "tasks": .array(page.tasks.map(taskListSnapshotJSON)),
        ])
    )
}

private func taskOutputReadResult(_ chunk: BackgroundTaskOutputChunk) -> AgentToolResult {
    let escaped = taskEscapeUntrustedOutput(chunk.text)
    let encodingHint = chunk.encoding == .utf8
        ? "utf8"
        : "base64 (decode this page to recover invalid or unaligned bytes)"
    let body = """
    task \(chunk.taskId) output bytes \(chunk.offset)..<\(chunk.nextOffset) of \(chunk.totalBytes) (eof=\(chunk.eof))
    encoding: \(encodingHint)
    <untrusted-output>
    \(escaped)
    </untrusted-output>
    """
    return AgentToolResult(
        content: [.text(TextContent(text: body))],
        details: .object([
            "task_id": .string(chunk.taskId),
            "offset": .int(chunk.offset),
            "next_offset": .int(chunk.nextOffset),
            "total_bytes": .int(chunk.totalBytes),
            "eof": .bool(chunk.eof),
            "encoding": .string(chunk.encoding.rawValue),
            "bytes_base64": .string(chunk.bytesBase64),
            "output": .string(chunk.text),
        ])
    )
}

private func taskActionResult(
    snapshots: [BackgroundTaskSnapshot],
    cancelledIds: [String],
    requestedCancelIds: Set<String> = [],
    includeSnapshotDetails: Bool = false
) -> AgentToolResult {
    var lines: [String] = []
    if !cancelledIds.isEmpty {
        lines.append("Cancelled: \(cancelledIds.joined(separator: ", "))")
    }
    if !snapshots.isEmpty {
        lines.append(contentsOf: snapshots.map { snapshot in
            if includeSnapshotDetails || requestedCancelIds.contains(snapshot.id) {
                return taskSnapshotText(snapshot)
            }
                return "\(snapshot.id): \(snapshot.status.rawValue) — <untrusted-task-label>\(taskEscapeUntrustedOutput(snapshot.spec.label))</untrusted-task-label>"
        })
    } else if cancelledIds.isEmpty {
        lines.append("No background tasks.")
    }
    return AgentToolResult(
        content: [.text(TextContent(text: lines.joined(separator: "\n")))],
        details: .object([
            "cancelled": .array(cancelledIds.map(JSONValue.string)),
            "tasks": .array(snapshots.map(taskSnapshotJSON)),
        ])
    )
}

private func taskPollResult(
    snapshots: [BackgroundTaskSnapshot],
    reason: String,
    alreadyDeliveredTaskIds: Set<String> = []
) -> AgentToolResult {
    var body = "task_poll: \(reason)"
    for snapshot in snapshots {
        if alreadyDeliveredTaskIds.contains(snapshot.id), snapshot.status.isTerminal {
            body += "\n\ntask \(snapshot.id): completion was already delivered through runtime context"
            body += "\nstatus: \(taskSemanticStatus(snapshot))"
            if let outcome = snapshot.outcome {
                body += "\n<untrusted-task-metadata>"
                body += "\nsummary: \(taskEscapeUntrustedOutput(outcome.summary))"
                if let error = outcome.errorMessage {
                    body += "\nerror: \(taskEscapeUntrustedOutput(error))"
                }
                body += "\n</untrusted-task-metadata>"
            }
            if snapshot.outputSizeBytes > 0 {
                body += "\noutput_bytes: \(snapshot.outputSizeBytes)"
                body += "\nhint: use task_read with this task id to recover the complete output artifact"
            }
        } else {
            body += "\n\n\(taskSnapshotText(snapshot))"
        }
    }
    return AgentToolResult(
        content: [.text(TextContent(text: body))],
        details: .object([
            "reason": .string(reason),
            "completed_task_ids": .array(
                snapshots.filter { $0.status.isTerminal }.map { .string($0.id) }
            ),
            "tasks": .array(snapshots.map(taskSnapshotJSON)),
        ])
    )
}

private func taskSnapshotText(_ snapshot: BackgroundTaskSnapshot) -> String {
    var body = "task \(snapshot.id): \(taskSemanticStatus(snapshot))\n"
    body += "\nrunner_state: \(snapshot.status == .queued ? "waiting_for_capacity" : snapshot.status == .running ? "active" : "terminal")"
    if let file = snapshot.outputFile {
        body += "\noutput_file: \(taskEscapeUntrustedOutput(file))"
    }
    body += "\n<untrusted-task-metadata>"
    body += "\nkind: \(taskEscapeUntrustedOutput(snapshot.spec.kind))"
    body += "\nlabel: \(taskEscapeUntrustedOutput(snapshot.spec.label))"
    if let description = snapshot.spec.description {
        body += "\ndescription: \(taskEscapeUntrustedOutput(description))"
    }
    if let outcome = snapshot.outcome {
        body += "\nsummary: \(taskEscapeUntrustedOutput(outcome.summary))"
        if let error = outcome.errorMessage {
            body += "\nerror: \(taskEscapeUntrustedOutput(error))"
        }
        if let details = outcome.details,
           let data = try? JSONEncoder().encode(modelFacingJSON(details)),
           let json = String(data: data, encoding: .utf8) {
            body += "\noutcome_details: \(taskEscapeUntrustedOutput(json))"
        }
    }
    body += "\n</untrusted-task-metadata>"
    if !snapshot.outputTail.isEmpty {
        body += "\noutput_tail:\n"
        body += "<untrusted-output>\n"
        body += taskEscapeUntrustedOutput(
            snapshot.outputTail.trimmingCharacters(in: .newlines)
        )
        body += "\n</untrusted-output>"
    }
    if snapshot.outputTailTruncated {
        body += "\noutput_truncated: true (use task_read with byte offsets for the complete artifact)"
    }
    return body
}

private func taskEscapeUntrustedOutput(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func taskSnapshotJSON(_ snapshot: BackgroundTaskSnapshot) -> JSONValue {
    let semanticStatus = taskSemanticStatus(snapshot)
    var value: [String: JSONValue] = [
        "task_id": .string(snapshot.id),
        "status": .string(semanticStatus),
        "kind": .string(snapshot.spec.kind),
        "label": .string(snapshot.spec.label),
        "output_tail": .string(snapshot.outputTail),
        "output_bytes": .int(snapshot.outputSizeBytes),
        "output_truncated": .bool(snapshot.outputTailTruncated),
        "runner_state": .string(
            snapshot.status == .queued
                ? "waiting_for_capacity"
                : snapshot.status == .running ? "active" : "terminal"
        ),
    ]
    if semanticStatus != snapshot.status.rawValue {
        value["registry_status"] = .string(snapshot.status.rawValue)
    }
    if let file = snapshot.outputFile { value["output_file"] = .string(file) }
    if let outcome = snapshot.outcome {
        value["summary"] = .string(outcome.summary)
        if let details = outcome.details {
            value["outcome_details"] = modelFacingJSON(details)
        }
        if let error = outcome.errorMessage { value["error_message"] = .string(error) }
    }
    return .object(value)
}

private func taskListSnapshotJSON(_ snapshot: BackgroundTaskSnapshot) -> JSONValue {
    let semanticStatus = taskSemanticStatus(snapshot)
    var value: [String: JSONValue] = [
        "task_id": .string(snapshot.id),
        "status": .string(semanticStatus),
        "kind": .string(snapshot.spec.kind),
        "label": .string(snapshot.spec.label),
        "output_bytes": .int(snapshot.outputSizeBytes),
        "output_tail": .string(snapshot.outputTail),
        "output_truncated": .bool(snapshot.outputTailTruncated),
        "runner_state": .string(
            snapshot.status == .queued
                ? "waiting_for_capacity"
                : snapshot.status == .running ? "active" : "terminal"
        ),
    ]
    if semanticStatus != snapshot.status.rawValue {
        value["registry_status"] = .string(snapshot.status.rawValue)
    }
    if let description = snapshot.spec.description {
        value["description"] = .string(description)
    }
    if let runningAt = snapshot.runningAt {
        value["running_at"] = .string(ISO8601DateFormatter().string(from: runningAt))
    }
    if let outcome = snapshot.outcome {
        value["summary"] = .string(outcome.summary)
    }
    return .object(value)
}

private func taskSemanticStatus(_ snapshot: BackgroundTaskSnapshot) -> String {
    if snapshot.outcome?.summary == "incomplete" { return "incomplete" }
    return snapshot.status.rawValue
}
