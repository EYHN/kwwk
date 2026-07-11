import Foundation
import KWWKAI

/// Unified background-task control. Polling accepts many ids in one tool call
/// and returns as soon as any watched task reaches a terminal state. Background
/// results auto-deliver through runtime asides, so polling is only for moments
/// when the agent is genuinely blocked on a result.
public func createTaskTool(
    manager: BackgroundTaskManager,
    sessionId: String? = nil,
    deliveryConsumer explicitConsumer: BackgroundTaskDeliveryConsumer? = nil
) -> AgentTool {
    let deliveryConsumer = explicitConsumer ?? BackgroundTaskDeliveryConsumer(sessionId: sessionId)
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "poll": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "Task ids to watch. Returns when any one finishes. Omit all actions to watch every running task."
                ),
            ]),
            "cancel": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Task ids to cancel."),
            ]),
            "list": .object([
                "type": .string("boolean"),
                "description": .string(
                    "List queued/running and recent terminal tasks without waiting. Output is paginated and includes at most 512 bytes of trust-bounded log preview per task; use read for complete output."
                ),
            ]),
            "include_all": .object([
                "type": .string("boolean"),
                "description": .string("With list=true, include older terminal history too."),
            ]),
            "list_offset": .object([
                "type": .string("integer"),
                "minimum": .int(0),
                "description": .string("Zero-based list page offset. Defaults to 0."),
            ]),
            "list_limit": .object([
                "type": .string("integer"),
                "minimum": .int(1),
                "maximum": .int(50),
                "description": .string("List page size. Defaults to 20, maximum 50."),
            ]),
            "read": .object([
                "type": .string("object"),
                "properties": .object([
                    "task_id": .object(["type": .string("string")]),
                    "offset": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "description": .string("Byte offset. Defaults to 0."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(32_768),
                        "description": .string("Target bytes. Defaults to 8192; a valid UTF-8 scalar may extend a page by at most 3 bytes so next_offset remains text-safe."),
                    ]),
                ]),
                "required": .array([.string("task_id")]),
                "additionalProperties": .bool(false),
                "description": .string("Read a bounded range of a manager-owned output artifact by task id."),
            ]),
            "timeout_seconds": .object([
                "type": .string("integer"),
                "minimum": .int(1),
                "maximum": .int(300),
                "description": .string("Maximum poll duration. Defaults to 30 seconds."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    var tool = AgentTool(
        name: "task",
        label: "task",
        description: """
        Manage background tasks. Results are delivered automatically when tasks finish; do not poll merely to retrieve output. When completely blocked, make one call with poll containing every relevant task id. Poll is wait-any across queued and running tasks: it returns on the first terminal result, timeout, or queued user message. Queue time does not consume a task's hard runtime timeout. Never emit multiple task poll calls in one assistant turn. Use list=true for a bounded status page, read={task_id,offset,limit} for manager-authorized log paging, and cancel=[...] to stop queued or running tasks.
        """,
        parameters: parameters,
        interruptible: true,
        execute: { _, args, cancellation, onUpdate in
            try cancellation?.throwIfCancelled()
            guard case .object(let object) = args else {
                throw CodingToolError.invalidArgument("task: expected an object")
            }

            let allowedKeys: Set<String> = [
                "poll", "cancel", "list", "include_all", "list_offset",
                "list_limit", "read", "timeout_seconds",
            ]
            if let unknown = object.keys.filter({ !allowedKeys.contains($0) }).sorted().first {
                throw CodingToolError.invalidArgument("task: unknown argument `\(unknown)`")
            }

            var seenCancelIds: Set<String> = []
            let cancelIds = try taskStringArray(object["cancel"], field: "cancel")
                .filter { seenCancelIds.insert($0).inserted }
            let requestedPollIds = try taskStringArray(object["poll"], field: "poll")
            let shouldList = try taskBool(object["list"], field: "list")
            let includeAll = try taskBool(object["include_all"], field: "include_all")
            let listOffset = try taskBoundedInteger(
                object["list_offset"],
                field: "list_offset",
                defaultValue: 0,
                range: 0...1_000_000_000
            )
            let listLimit = try taskBoundedInteger(
                object["list_limit"],
                field: "list_limit",
                defaultValue: 20,
                range: 1...50
            )
            let readRequest = try taskReadRequest(object["read"])
            let timeoutSeconds = try taskTimeout(object["timeout_seconds"])

            if readRequest != nil,
               shouldList || !cancelIds.isEmpty || !requestedPollIds.isEmpty {
                throw CodingToolError.invalidArgument(
                    "task: `read` cannot be combined with poll, cancel, or list"
                )
            }
            if shouldList, !requestedPollIds.isEmpty {
                throw CodingToolError.invalidArgument(
                    "task: `list` cannot be combined with a non-empty poll"
                )
            }
            if !shouldList,
               object["include_all"] != nil || object["list_offset"] != nil
                    || object["list_limit"] != nil {
                throw CodingToolError.invalidArgument(
                    "task: include_all/list_offset/list_limit require list=true"
                )
            }

            if let readRequest {
                try cancellation?.throwIfCancelled()
                let chunk: BackgroundTaskOutputChunk
                do {
                    chunk = try await manager.readOutput(
                        taskId: readRequest.taskId,
                        sessionId: sessionId,
                        offset: readRequest.offset,
                        limit: readRequest.limit
                    )
                } catch let error as BackgroundTaskError {
                    throw CodingToolError.invalidArgument(error.localizedDescription)
                }
                return taskOutputReadResult(chunk)
            }

            // Resolve and validate every target before the first mutation. A
            // mixed valid/invalid cancel list must never partially kill work.
            for id in cancelIds {
                guard let snapshot = await manager.get(id),
                      taskIsVisible(snapshot, sessionId: sessionId) else {
                    throw CodingToolError.invalidArgument("task not found in this session: \(id)")
                }
            }

            // Empty action arrays are no-ops. An entirely action-less request
            // still means poll-all, while `list: true` plus empty arrays must
            // remain an immediate list operation.
            let shouldPoll = !requestedPollIds.isEmpty
                || (!shouldList && cancelIds.isEmpty && readRequest == nil)
            let pollIds: [String]
            if shouldPoll {
                if requestedPollIds.isEmpty {
                    pollIds = await manager.activeTaskIds(sessionId: sessionId)
                } else {
                    var seen: Set<String> = []
                    pollIds = requestedPollIds.filter { seen.insert($0).inserted }
                    _ = try await manager.snapshots(
                        taskIds: pollIds,
                        sessionId: sessionId,
                        includeOutputTails: false
                    )
                }
            } else {
                pollIds = []
            }

            var seenWatched: Set<String> = []
            let watchedIds = (cancelIds + pollIds).filter { seenWatched.insert($0).inserted }
            let alreadyDelivered = deliveryConsumer.beginWatching(taskIds: watchedIds)
            var watchFinished = false
            defer {
                if !watchFinished {
                    deliveryConsumer.finishWatching(
                        taskIds: watchedIds,
                        terminalTaskIds: []
                    )?.rollback()
                }
            }

            try cancellation?.throwIfCancelled()
            let cancellationBatch = try await manager.killAtomically(
                cancelIds,
                sessionId: sessionId
            )
            let cancelledIds = cancellationBatch.cancelledIds

            if !shouldPoll {
                if shouldList {
                    let page = await manager.listPage(
                        sessionId: sessionId,
                        includeAllTerminal: includeAll,
                        offset: listOffset,
                        limit: listLimit
                    )
                    let terminalIds = Set(cancellationBatch.snapshots.filter {
                        $0.status.isTerminal
                    }.map(\.id))
                    let lease = deliveryConsumer.finishWatching(
                        taskIds: watchedIds,
                        terminalTaskIds: terminalIds
                    )
                    watchFinished = true
                    var result = taskListResult(page: page, cancelledIds: cancelledIds)
                    result.retentionLease = lease
                    return result
                }
                let snapshots = taskOrderedSnapshots(cancellationBatch.snapshots, ids: cancelIds)
                let watchedIdSet = Set(watchedIds)
                let terminalIds = Set(snapshots.filter {
                    watchedIdSet.contains($0.id) && $0.status.isTerminal
                }.map(\.id))
                let lease = deliveryConsumer.finishWatching(
                    taskIds: watchedIds,
                    terminalTaskIds: terminalIds
                )
                watchFinished = true
                var result = taskActionResult(
                    snapshots: snapshots,
                    cancelledIds: cancelledIds,
                    requestedCancelIds: Set(cancelIds)
                )
                result.retentionLease = lease
                return result
            }

            guard !pollIds.isEmpty else {
                _ = deliveryConsumer.finishWatching(taskIds: watchedIds, terminalTaskIds: [])
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
                    taskIds: pollIds,
                    sessionId: sessionId,
                    includeOutputTails: false
                )
            } catch let error as BackgroundTaskError {
                throw CodingToolError.invalidArgument(error.localizedDescription)
            }

            var snapshots = taskOrderedSnapshots(watched, ids: pollIds)
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
                    _ = deliveryConsumer.finishWatching(taskIds: watchedIds, terminalTaskIds: [])
                    watchFinished = true
                    throw CodingToolError.aborted
                }
                if Date() >= deadline {
                    reason = "timeout"
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                snapshots = await taskSnapshots(manager: manager, ids: pollIds)
                emitPollProgress()
            }

            // Take one final actor-isolated snapshot and use this exact value
            // for both rendered output and lease acknowledgement. If a task
            // completes after the snapshot, finishWatching sees it was not
            // represented and restores its automatic aside.
            let finalLightweight = (try? await manager.snapshots(
                taskIds: watchedIds,
                sessionId: sessionId,
                includeOutputTails: false
            )) ?? []
            let finalWatched = await taskHydrateTerminalSnapshots(
                manager: manager,
                snapshots: finalLightweight
            )
            let renderedPollSnapshots = taskOrderedSnapshots(finalWatched, ids: pollIds)
            if renderedPollSnapshots.contains(where: { $0.status.isTerminal }) {
                reason = "completed"
            }
            let pollIdSet = Set(pollIds)
            let renderedCancelSnapshots = taskOrderedSnapshots(
                finalWatched,
                ids: cancelIds.filter { !pollIdSet.contains($0) }
            )
            let renderedSnapshots = renderedCancelSnapshots + renderedPollSnapshots
            let terminalIds = Set(renderedSnapshots.filter { $0.status.isTerminal }.map(\.id))
            let lease = deliveryConsumer.finishWatching(
                taskIds: watchedIds,
                terminalTaskIds: terminalIds
            )
            watchFinished = true
            var result = taskPollResult(
                snapshots: renderedSnapshots,
                reason: reason,
                alreadyDeliveredTaskIds: alreadyDelivered,
                cancelledIds: cancelledIds
            )
            result.retentionLease = lease
            return result
        }
    )
    tool.isBackgroundTaskTool = true
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
        format: "task poll waiting · watched=%d · running=%d · queued=%d · terminal=%d · %.1fs/%ds",
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

/// Must be called only after schema validation and the before-tool hook rewrite.
/// It intentionally mirrors `createTaskTool`'s action semantics exactly.
func taskRequestWillPoll(_ args: JSONValue) -> Bool {
    guard case .object(let object) = args else { return false }
    let allowedKeys: Set<String> = [
        "poll", "cancel", "list", "include_all", "list_offset",
        "list_limit", "read", "timeout_seconds",
    ]
    guard object.keys.allSatisfy(allowedKeys.contains) else { return false }
    guard let pollIds = try? taskStringArray(object["poll"], field: "poll"),
          let cancelIds = try? taskStringArray(object["cancel"], field: "cancel") else {
        return false
    }
    let shouldList: Bool = {
        if case .bool(let value) = object["list"] ?? .null { return value }
        return false
    }()
    return !pollIds.isEmpty
        || (!shouldList && cancelIds.isEmpty && object["read"] == nil)
}

private struct TaskReadRequest {
    let taskId: String
    let offset: Int
    let limit: Int
}

private func taskReadRequest(_ value: JSONValue?) throws -> TaskReadRequest? {
    guard let value else { return nil }
    guard case .object(let object) = value else {
        throw CodingToolError.invalidArgument("task: `read` must be an object")
    }
    let allowed: Set<String> = ["task_id", "offset", "limit"]
    if let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first {
        throw CodingToolError.invalidArgument("task: unknown read argument `\(unknown)`")
    }
    guard case .string(let taskId) = object["task_id"] ?? .null,
          !taskId.isEmpty else {
        throw CodingToolError.invalidArgument("task: `read.task_id` is required")
    }
    return TaskReadRequest(
        taskId: taskId,
        offset: try taskBoundedInteger(
            object["offset"],
            field: "read.offset",
            defaultValue: 0,
            range: 0...1_000_000_000
        ),
        limit: try taskBoundedInteger(
            object["limit"],
            field: "read.limit",
            defaultValue: 8_192,
            range: 1...32_768
        )
    )
}

private func taskStringArray(_ value: JSONValue?, field: String) throws -> [String] {
    guard let value else { return [] }
    guard case .array(let values) = value else {
        throw CodingToolError.invalidArgument("task: `\(field)` must be an array of task ids")
    }
    return try values.map { value in
        guard case .string(let id) = value, !id.isEmpty else {
            throw CodingToolError.invalidArgument("task: `\(field)` must contain only task ids")
        }
        return id
    }
}

private func taskBool(_ value: JSONValue?, field: String) throws -> Bool {
    guard let value else { return false }
    guard case .bool(let bool) = value else {
        throw CodingToolError.invalidArgument("task: `\(field)` must be a boolean")
    }
    return bool
}

private func taskBoundedInteger(
    _ value: JSONValue?,
    field: String,
    defaultValue: Int,
    range: ClosedRange<Int>
) throws -> Int {
    guard let value else { return defaultValue }
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
                "task: `\(field)` must be an integer from \(range.lowerBound) through \(range.upperBound)"
            )
        }
        raw = Int(double)
    default:
        throw CodingToolError.invalidArgument(
            "task: `\(field)` must be an integer from \(range.lowerBound) through \(range.upperBound)"
        )
    }
    guard range.contains(raw) else {
        throw CodingToolError.invalidArgument(
            "task: `\(field)` must be an integer from \(range.lowerBound) through \(range.upperBound)"
        )
    }
    return raw
}

private func taskTimeout(_ value: JSONValue?) throws -> Int {
    guard let value else { return 30 }
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
                "task: `timeout_seconds` must be a finite integer from 1 through 300"
            )
        }
        raw = Int(double)
    default:
        throw CodingToolError.invalidArgument(
            "task: `timeout_seconds` must be a finite integer from 1 through 300"
        )
    }
    guard (1...300).contains(raw) else {
        throw CodingToolError.invalidArgument(
            "task: `timeout_seconds` must be a finite integer from 1 through 300"
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

private func taskListResult(
    page: BackgroundTaskListPage,
    cancelledIds: [String]
) -> AgentToolResult {
    var lines: [String] = []
    if !cancelledIds.isEmpty {
        lines.append("Cancelled: \(cancelledIds.joined(separator: ", "))")
    }
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
                lines.append("  output_truncated: true · use task read for the complete artifact")
            }
        }
    }
    if let next = page.nextOffset {
        lines.append("More tasks available: call task(list:true, list_offset:\(next)).")
    }
    return AgentToolResult(
        content: [.text(TextContent(text: lines.joined(separator: "\n")))],
        details: .object([
            "cancelled": .array(cancelledIds.map(JSONValue.string)),
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
    alreadyDeliveredTaskIds: Set<String> = [],
    cancelledIds: [String] = []
) -> AgentToolResult {
    var body = "task poll: \(reason)"
    if !cancelledIds.isEmpty {
        body += "\n\ncancelled: \(cancelledIds.joined(separator: ", "))"
    }
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
                body += "\nhint: use task read with this task id to recover the complete output artifact"
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
            "cancelled": .array(cancelledIds.map(JSONValue.string)),
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
           let data = try? JSONEncoder().encode(details),
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
        body += "\noutput_truncated: true (use task read with byte offsets for the complete artifact)"
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
        if let details = outcome.details { value["outcome_details"] = details }
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
