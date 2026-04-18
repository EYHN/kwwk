import Foundation
import KWAI

/// Lifecycle state of a background task tracked by `BackgroundTaskManager`.
public enum BackgroundTaskStatus: String, Sendable, Codable {
    case running
    case completed
    case failed
    case killed
}

/// Generic description of a background task. Runner-specific parameters
/// (bash command, HTTP url, …) live on the concrete `BackgroundTaskRunner`,
/// not here — the Manager only needs enough metadata to track / notify.
public struct BackgroundTaskSpec: Sendable, Codable {
    /// Tag used in notification formatting (e.g. "bash", "http").
    public let kind: String
    /// One-line human-readable label (e.g. "npm install").
    public let label: String
    /// Optional longer description ("install dependencies").
    public let description: String?
    /// Upper bound on runtime. Manager enforces this by cancelling the
    /// task's cancellation handle after the deadline elapses.
    public let hardTimeoutSeconds: Int

    public init(
        kind: String,
        label: String,
        description: String? = nil,
        hardTimeoutSeconds: Int = 1800
    ) {
        self.kind = kind
        self.label = label
        self.description = description
        self.hardTimeoutSeconds = hardTimeoutSeconds
    }
}

/// Final outcome reported by a `BackgroundTaskRunner` via `onDone`.
public struct BackgroundTaskOutcome: Sendable {
    public let success: Bool
    /// Short human-readable summary (e.g. "exit 0", "200 OK", "deadline exceeded").
    public let summary: String
    /// Kind-specific structured extras (bash: exitCode; http: statusCode; …).
    public let details: JSONValue?
    /// Set when the runner failed to even start or complete normally.
    public let errorMessage: String?

    public init(success: Bool, summary: String, details: JSONValue? = nil, errorMessage: String? = nil) {
        self.success = success
        self.summary = summary
        self.details = details
        self.errorMessage = errorMessage
    }
}

/// Pluggable executor. KWAgent ships no concrete runners — KWCoding (or user
/// code) supplies one per task kind (`BashBackgroundRunner`, …). The Manager
/// owns lifecycle; the Runner owns the work.
///
/// Contract:
///   - `run` must return promptly (do the work in a detached Task).
///   - The Manager pre-allocates `outputFile` (creates parent dir and empty
///     file). The Runner writes stdout/stderr/body/… into that file however
///     it likes — for bash this is an fd redirect at spawn time so bytes
///     never enter Swift memory. For HTTP runners the body can be flushed
///     once at the end. Leaving the file empty is also fine.
///   - Must call `onDone` exactly once with the final outcome. Calling it
///     transitions the task out of `.running`.
///   - If `cancellation.isCancelled` becomes true, the runner should stop
///     ASAP and still call `onDone` (with `success: false`,
///     `summary: "aborted"`).
///   - The Manager polls `outputFile` size for stall detection and reads its
///     tail on-demand for notifications. No per-chunk callback is required.
public protocol BackgroundTaskRunner: Sendable {
    var spec: BackgroundTaskSpec { get }
    func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    )
}

/// Snapshot of task state returned from Manager query APIs.
public struct BackgroundTaskSnapshot: Sendable {
    public let id: String
    public let sessionId: String?
    public let spec: BackgroundTaskSpec
    public let status: BackgroundTaskStatus
    public let startedAt: Date
    public let completedAt: Date?
    public let outputFile: String?
    public let outputTail: String
    public let outcome: BackgroundTaskOutcome?
}

/// Structured completion (or stall) notification. Delivered to the Agent as a
/// user message via `messageText()`.
public struct BackgroundTaskNotification: Sendable {
    public let taskId: String
    public let sessionId: String?
    public let kind: String
    public let label: String
    public let description: String?
    public let status: BackgroundTaskStatus
    public let outcome: BackgroundTaskOutcome?   // nil while `stalled == true`
    public let outputTail: String
    public let outputFile: String?
    public let durationMs: Int
    public let stalled: Bool

    /// Renders the notification as an XML block wrapped in a lead-in line.
    /// Callers wrap the returned string in a `UserMessage` and inject it into
    /// the Agent — at a turn boundary (steering) or as a fresh prompt (idle).
    public func messageText() -> String {
        let lead = stalled
            ? "A background task appears stuck and may need attention:"
            : "A background task completed:"
        return lead + "\n" + formatXML()
    }

    private func formatXML() -> String {
        var lines: [String] = []
        lines.append("<task-notification>")
        lines.append("  <task-id>\(escape(taskId))</task-id>")
        lines.append("  <kind>\(escape(kind))</kind>")
        lines.append("  <label>\(escape(label))</label>")
        if let description {
            lines.append("  <description>\(escape(description))</description>")
        }
        if stalled {
            lines.append("  <status>stalled</status>")
        } else {
            lines.append("  <status>\(status.rawValue)</status>")
        }
        if let outcome {
            lines.append("  <summary>\(escape(outcome.summary))</summary>")
            if let details = outcome.details {
                // Collapse primitive detail keys (`exitCode`, `statusCode`, …)
                // into their own tags so the model can parse cheaply.
                if case .object(let obj) = details {
                    for key in obj.keys.sorted() {
                        let value = obj[key]!
                        if let s = value.asStringForTag() {
                            let tag = kebab(key)
                            lines.append("  <\(tag)>\(escape(s))</\(tag)>")
                        }
                    }
                }
            }
            if let errMessage = outcome.errorMessage {
                lines.append("  <error>\(escape(errMessage))</error>")
            }
        }
        lines.append("  <duration-ms>\(durationMs)</duration-ms>")
        if let outputFile {
            lines.append("  <output-file>\(escape(outputFile))</output-file>")
            lines.append("  <hint>Use the Read tool on the output file to inspect full stdout/stderr.</hint>")
        }
        if !outputTail.isEmpty {
            let trimmed = outputTail
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            lines.append("  <output-tail>")
            lines.append(trimmed)
            lines.append("  </output-tail>")
        }
        if stalled {
            lines.append("  <suggestion>The command looks blocked on an interactive prompt. Kill it with bg_status and retry with piped input (e.g. `echo y | command`) or a non-interactive flag.</suggestion>")
        }
        lines.append("</task-notification>")
        return lines.joined(separator: "\n")
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func kebab(_ camel: String) -> String {
        var out = ""
        for (i, ch) in camel.enumerated() {
            if ch.isUppercase && i != 0 {
                out.append("-")
                out.append(ch.lowercased())
            } else {
                out.append(ch.lowercased())
            }
        }
        return out
    }
}

extension JSONValue {
    fileprivate func asStringForTag() -> String? {
        switch self {
        case .string(let s): return s
        case .int(let n): return String(n)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        case .array, .object: return nil
        }
    }
}
