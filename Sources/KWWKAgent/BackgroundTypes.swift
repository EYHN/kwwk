import Foundation
import KWWKAI

/// Lifecycle state of a background task tracked by `BackgroundTaskManager`.
public enum BackgroundTaskStatus: String, Sendable, Codable {
    /// Registered work waiting for runner capacity. Queued time does not count
    /// against the task's hard runtime timeout.
    case queued
    case running
    case completed
    case failed
    case killed

    public var isActive: Bool {
        self == .queued || self == .running
    }

    public var isTerminal: Bool { !isActive }
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
    /// Kind-specific identity metadata carried into manager-generated
    /// timeout/kill outcomes. It is never interpreted by the manager.
    public let metadata: JSONValue?
    /// Upper bound on runtime. The manager first requests cooperative
    /// cancellation, then forces a canonical failed registry state after its
    /// grace period if the runner does not report completion.
    public let hardTimeoutSeconds: Int

    public init(
        kind: String,
        label: String,
        description: String? = nil,
        metadata: JSONValue? = nil,
        hardTimeoutSeconds: Int = 1800
    ) {
        self.kind = kind
        self.label = label
        self.description = description
        self.metadata = metadata
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
///   - For non-agent jobs, the Manager may poll `outputFile` size for prompt
///     stall detection. It reads every job's tail on-demand for notifications.
///     No per-chunk callback is required.
public protocol BackgroundTaskRunner: Sendable {
    var spec: BackgroundTaskSpec { get }
    /// Called exactly once instead of `run` when a session-generation fence
    /// rejects a launch whose off-actor `spec` resolution completed after
    /// `closeSession`. Implementations may release reservations or mark their
    /// own registries terminal. The manager invokes this synchronous hook on a
    /// utility queue, never on its actor executor.
    func cancelBeforeLaunch(reason: String)
    func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    )
}

public extension BackgroundTaskRunner {
    func cancelBeforeLaunch(reason _: String) {}
}

/// Snapshot of task state returned from Manager query APIs.
public struct BackgroundTaskSnapshot: Sendable {
    public let id: String
    public let sessionId: String?
    public let spec: BackgroundTaskSpec
    public let status: BackgroundTaskStatus
    /// Registration time. For queued jobs this precedes `runningAt`.
    public let startedAt: Date
    /// Time the concrete runner acquired capacity. Nil while queued.
    public let runningAt: Date?
    public let completedAt: Date?
    public let outputFile: String?
    public let outputTail: String
    public let outputSizeBytes: Int
    public let outputTailTruncated: Bool
    public let outcome: BackgroundTaskOutcome?
}

/// A bounded, manager-authorized read from a task's output artifact. Offsets
/// and limits are bytes, not Swift character indices, so callers can page large
/// logs without requiring arbitrary filesystem access. A UTF-8 page may extend
/// the requested target by at most three bytes to finish one scalar.
public struct BackgroundTaskOutputChunk: Sendable {
    public enum Encoding: String, Sendable {
        /// `text` is a complete UTF-8 sequence. Successive chunks obtained from
        /// `nextOffset` can be concatenated without replacement characters.
        case utf8
        /// The requested bytes were not valid standalone UTF-8 (for example an
        /// explicitly unaligned offset or a binary log). `text` and
        /// `bytesBase64` contain the same bytes encoded as base64.
        case base64
    }

    public let taskId: String
    public let offset: Int
    public let nextOffset: Int
    public let totalBytes: Int
    public let text: String
    public let encoding: Encoding
    /// Lossless representation of the exact bytes in this page. This is useful
    /// for binary/invalid UTF-8 output and for SDK callers which need byte-exact
    /// reconstruction rather than display text.
    public let bytesBase64: String
    public let eof: Bool
}

/// Bounded page returned by manager-owned list queries.
public struct BackgroundTaskListPage: Sendable {
    public let tasks: [BackgroundTaskSnapshot]
    public let total: Int
    public let offset: Int
    public let nextOffset: Int?
}

/// Structured completion (or stall) notification. Delivered through the
/// Agent's internal runtime-aside channel via `messageText()`.
public struct BackgroundTaskNotification: Sendable {
    public let taskId: String
    public let sessionId: String?
    public let kind: String
    public let label: String
    public let description: String?
    public let status: BackgroundTaskStatus
    public let outcome: BackgroundTaskOutcome?   // nil while `stalled == true`
    public let outputTail: String
    /// True when the completion card contains only a bounded preview. Callers
    /// can retrieve the complete artifact through the `job` output reader.
    public var outputTruncated: Bool = false
    public let outputFile: String?
    public let durationMs: Int
    public let stalled: Bool

    /// Renders the notification as an XML block wrapped in a lead-in line.
    /// Callers wrap the returned string in a runtime-sourced `UserMessage` and
    /// inject it at a turn boundary or as a fresh internal prompt while idle.
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
                // Preserve only the legacy primitive tag consumed by the
                // compact CLI summary. Never derive sibling XML semantics from
                // arbitrary runner keys: even a syntactically safe key such as
                // `instruction` or `status` can spoof trusted structure. The
                // complete object is retained below as escaped JSON data.
                if case .object(let obj) = details {
                    if let value = obj["exitCode"],
                       let exitCode = value.asStringForTag() {
                        lines.append("  <exit-code>\(escape(exitCode))</exit-code>")
                    }
                }
                // Preserve nested and non-tag-safe details as escaped data.
                // Never derive XML syntax from an arbitrary runner key.
                if let data = try? JSONEncoder().encode(details),
                   let json = String(data: data, encoding: .utf8) {
                    lines.append("  <details-json>\(escape(json))</details-json>")
                }
            }
            if let errMessage = outcome.errorMessage {
                lines.append("  <error>\(escape(errMessage))</error>")
            }
        }
        lines.append("  <duration-ms>\(durationMs)</duration-ms>")
        if let outputFile {
            lines.append("  <output-file>\(escape(outputFile))</output-file>")
            lines.append("  <hint>Use job output reading to inspect the complete stdout/stderr artifact.</hint>")
        }
        if !outputTail.isEmpty {
            let trimmed = outputTail
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            lines.append("  <output-tail>")
            // Background output may contain repository-controlled text or even
            // XML-looking prompt injection. Keep it inside an explicit trust
            // boundary and escape it as data so it cannot close this element
            // or add sibling instructions to the runtime notification.
            lines.append("    <untrusted-output>")
            lines.append(escape(trimmed))
            lines.append("    </untrusted-output>")
            lines.append("  </output-tail>")
        }
        if outputTruncated {
            lines.append("  <output-truncated>true</output-truncated>")
        }
        if stalled {
            lines.append("  <suggestion>The command looks blocked on an interactive prompt. Cancel it with job(cancel:[task_id]) and retry with piped input (e.g. `echo y | command`) or a non-interactive flag.</suggestion>")
        }
        lines.append("</task-notification>")
        return lines.joined(separator: "\n")
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
