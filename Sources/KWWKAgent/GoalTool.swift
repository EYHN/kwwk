import Foundation
import KWWKAI

/// Marker embedded in every hidden goal-continuation message. Declared here in
/// the agent layer (not KWWKCli) so the session recorder can recognize and skip
/// persisting these ephemeral steers — keeping goal continuations in-memory only,
/// matching the live transcript where they're already suppressed. `GoalMode`
/// (KWWKCli) reuses this same string for its render-time suppression.
public let goalContinuationMarker = "<!-- kwwk:goal-continuation -->"

/// True when `message` is a hidden goal continuation (role=user whose text
/// *begins* with the marker). We anchor on the prefix, not `contains`, so an
/// ordinary user prompt that merely quotes the marker mid-sentence is never
/// mistaken for a synthetic continuation.
public func isHiddenGoalContinuation(_ message: Message) -> Bool {
    // Match the EXACT shape `kickGoalContinuation` produces: a user message with
    // a single text block whose text begins with the marker. Requiring a lone
    // block (not "any block") means a real multi-block user message — e.g. a
    // marker-quoting text block plus an image — is never mistaken for a
    // synthetic continuation and clobbered on persistence.
    guard case .user(let u) = message,
          u.content.count == 1,
          case .text(let t) = u.content[0],
          t.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(goalContinuationMarker)
    else { return false }
    return true
}

/// On-disk stand-in for a hidden goal continuation. Keeps the marker (so it
/// stays display-suppressed even after `/resume`) and the `user` role (so the
/// persisted transcript preserves valid user→assistant alternation — providers
/// like Anthropic reject an assistant-first / user-less history), but drops the
/// objective body so no goal state is written to disk. Non-continuation
/// messages pass through unchanged.
public func redactedForPersistence(_ message: Message) -> Message {
    guard isHiddenGoalContinuation(message), case .user(let u) = message else { return message }
    return .user(UserMessage(
        content: [.text(TextContent(text: "\(goalContinuationMarker) (redacted goal continuation)"))],
        timestamp: u.timestamp
    ))
}

/// Lifecycle of a session-scoped goal. `active` drives the autonomous loop;
/// `paused` is the guardrail-cap stop (resumable); `complete` is the model's
/// verified done-claim; `dropped` is "no goal / user cleared it".
public enum GoalStatus: String, Sendable, Equatable {
    case active, paused, complete, dropped
}

public struct GoalSnapshot: Sendable, Equatable {
    public var objective: String
    public var status: GoalStatus
    /// Consecutive hidden auto-continuations performed since the last real
    /// user message. Compared against the guardrail cap.
    public var autoContinueCount: Int
}

/// Session-scoped, in-memory ONLY. Shared by reference between the `goal`
/// tool (async, off-main), the `/goal` slash command, the status line, and the
/// agent-end continuation loop. Evaporates on process exit — no persistence.
///
/// Lock-based (not an actor) so `snapshot()` reads are synchronous and callable
/// from the synchronous `@MainActor` status-line refresh. Mirrors `AgentState`.
public final class GoalStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _objective = ""
    private var _status: GoalStatus = .dropped
    private var _autoContinueCount = 0

    public init() {}

    public func start(_ objective: String) {
        lock.withLock { _objective = objective; _status = .active; _autoContinueCount = 0 }
    }
    /// User cleared the goal (`/goal off`). Fully resets.
    public func stop() {
        lock.withLock { _status = .dropped; _objective = ""; _autoContinueCount = 0 }
    }
    /// Model called `goal({op:"complete"})`. Compare-and-set from `.active` only,
    /// so a stale/in-flight turn (or any non-goal turn — the tool is always
    /// available) can't resurrect a completion after the user stopped, paused,
    /// or never set a goal. Returns whether it actually transitioned.
    @discardableResult
    public func complete() -> Bool {
        lock.withLock {
            guard _status == .active else { return false }
            _status = .complete; _autoContinueCount = 0
            return true
        }
    }
    /// Guardrail cap tripped — loop halted, goal resumable.
    public func pauseForCap() {
        lock.withLock { _status = .paused }
    }
    /// `/goal resume` — un-pause and clear the counter so the loop restarts.
    public func resume() {
        lock.withLock { if _status == .paused { _status = .active }; _autoContinueCount = 0 }
    }
    /// Reset on every real user message so the cap only counts *consecutive*
    /// autonomous continuations.
    public func resetAutoContinue() {
        lock.withLock { _autoContinueCount = 0 }
    }
    /// Called once per hidden continuation injection.
    public func recordAutoContinue() {
        lock.withLock { _autoContinueCount += 1 }
    }
    /// Roll back a count when the continuation lost a race and never actually
    /// started a turn (so the cap only reflects turns that really ran).
    public func undoAutoContinue() {
        lock.withLock { if _autoContinueCount > 0 { _autoContinueCount -= 1 } }
    }
    public func snapshot() -> GoalSnapshot {
        lock.withLock { GoalSnapshot(objective: _objective, status: _status, autoContinueCount: _autoContinueCount) }
    }
    public var isActive: Bool { lock.withLock { _status == .active } }
}

/// The model-facing `goal` tool. Exposes `get` (inspect) and `complete`
/// (verified done — flips the in-memory store and ends the autonomous loop).
/// `create`/`drop` are intentionally NOT exposed: the user starts/stops goals
/// via `/goal`. Narration suppression is a TUI render concern (there is no
/// `intent` field on `AgentTool`); the tool stays quiet by returning terse text.
public func createGoalTool(store: GoalStore) -> AgentTool {
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "op": .object([
                "type": .string("string"),
                "enum": .array([.string("get"), .string("complete")]),
                "description": .string("get = inspect the active goal; complete = mark it verified-done (only after a current-state audit); ends the autonomous loop."),
            ]),
        ]),
        "required": .array([.string("op")]),
    ])
    return AgentTool(
        name: "goal",
        label: "goal",
        description: "Inspect or complete the active goal. goal({op:\"get\"}) returns the current objective + status. goal({op:\"complete\"}) is ONLY for verified completion after auditing the current repo state against every deliverable; it ends the autonomous loop.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let op) = obj["op"] ?? .null else {
                throw CodingToolError.invalidArgument("goal: `op` is required (get | complete)")
            }
            switch op {
            case "get":
                let s = store.snapshot()
                let body = "objective: \(s.objective.isEmpty ? "(none)" : s.objective)\nstatus: \(s.status.rawValue)"
                return AgentToolResult(
                    content: [.text(TextContent(text: body))],
                    details: .object([
                        "objective": .string(s.objective),
                        "status": .string(s.status.rawValue),
                    ]),
                    uiDisplay: ["goal: \(s.status.rawValue)"]
                )
            case "complete":
                let didComplete = store.complete()
                guard didComplete else {
                    // No active goal to complete (already stopped/paused/none) —
                    // don't fabricate a completion event.
                    let s = store.snapshot()
                    return AgentToolResult(
                        content: [.text(TextContent(text: "No active goal to complete (current status: \(s.status.rawValue))."))],
                        details: .object(["status": .string(s.status.rawValue), "completed": .bool(false)]),
                        uiDisplay: ["goal: no active goal"]
                    )
                }
                return AgentToolResult(
                    content: [.text(TextContent(text: "Goal marked complete. The autonomous loop is now stopped."))],
                    details: .object(["status": .string("complete"), "completed": .bool(true)]),
                    uiDisplay: ["goal: complete"]
                )
            default:
                throw CodingToolError.invalidArgument("goal: unknown op \(op) (expected: get | complete)")
            }
        }
    )
}
