import Foundation
import KWAI
import KWAgent
import KWTUI

/// Claude-Code-style transcript. Owns a single line buffer — assistant
/// streaming rewrites the tail of the buffer until the turn settles, tool
/// events append stable lines. The render function returns the full line
/// list; the viewport decides which tail to show.
@MainActor
public final class TranscriptRenderer {
    public let lines: TranscriptBuffer

    /// When non-nil, the indices mark the range in `lines.all` that a
    /// still-streaming assistant turn occupies. Cleared on messageEnd.
    private var streamingRange: Range<Int>?
    private var pendingTools: [String: ToolState] = [:]

    struct ToolState {
        var name: String
        var args: JSONValue
        var headerIndex: Int
    }

    public init() {
        self.lines = TranscriptBuffer()
    }

    public func apply(_ event: AgentEvent) {
        switch event {
        case .messageStart(let message):
            switch message {
            case .user(let u):
                append(Style.user("❯ " + userText(u)))
                append("")
            case .assistant:
                // Start of a streaming turn: reserve a cursor for overwriting.
                let start = lines.count
                streamingRange = start..<start
            case .toolResult:
                break
            }

        case .messageUpdate(let assistant, _):
            replaceStreaming(with: renderAssistantLines(assistant))

        case .messageEnd(let message):
            switch message {
            case .assistant(let a):
                replaceStreaming(with: renderAssistantLines(a))
                streamingRange = nil
                if a.stopReason == .aborted {
                    append(Style.dimmed("⋯ aborted"))
                }
                if let err = a.errorMessage, a.stopReason == .error {
                    append(Style.error("✗ \(err)"))
                }
                append("")
            case .toolResult:
                // Handled when tool_execution_end fires.
                break
            case .user:
                break
            }

        case .toolExecutionStart(let id, let name, let args):
            let header = Style.tool("● \(name)(\(formatArgs(args)))")
            let idx = lines.count
            append(header)
            append(Style.dimmed("  ⎿  running…"))
            pendingTools[id] = ToolState(name: name, args: args, headerIndex: idx)

        case .toolExecutionEnd(let id, _, let result, let isError):
            guard let state = pendingTools.removeValue(forKey: id) else { break }
            // Replace the "running…" placeholder (at headerIndex+1), plus
            // append a trailing blank so the next block reads cleanly.
            var resultLines = formatToolResult(result, isError: isError)
            resultLines.append("")
            lines.replace(from: state.headerIndex + 1, with: resultLines)

        case .agentEnd:
            break
        default: break
        }
    }

    // MARK: - Append primitives (split multi-line inputs)

    private func append(_ line: String) {
        for sub in line.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(String(sub))
        }
    }

    private func replaceStreaming(with newLines: [String]) {
        let range = streamingRange ?? (lines.count..<lines.count)
        lines.replace(range: range, with: newLines)
        streamingRange = range.lowerBound..<(range.lowerBound + newLines.count)
    }

    // MARK: - Formatting

    private func userText(_ u: UserMessage) -> String {
        u.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined(separator: " ")
    }

    private func renderAssistantLines(_ a: AssistantMessage) -> [String] {
        var out: [String] = []
        for block in a.content {
            switch block {
            case .text(let t):
                if t.text.isEmpty { continue }
                out.append(contentsOf: t.text.components(separatedBy: "\n"))
            case .thinking(let th):
                if th.thinking.isEmpty { continue }
                out.append(Style.dimmed("[thinking]"))
                for line in th.thinking.components(separatedBy: "\n") {
                    out.append(Style.dimmed("  " + line))
                }
            case .toolCall:
                // Tool calls render via toolExecutionStart so the `⎿` result
                // lines attach to the same `●` header. Skip here to avoid a
                // duplicate line during streaming.
                continue
            }
        }
        return out
    }

    private func formatArgs(_ args: JSONValue) -> String {
        guard case .object(let obj) = args else { return "" }
        return obj.keys.sorted().compactMap { key -> String? in
            guard let v = obj[key] else { return nil }
            return "\(key): \(formatValue(v))"
        }.joined(separator: ", ")
    }

    private func formatValue(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return "\(b)"
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return "\"\(truncate(s, to: 60))\""
        case .array(let arr): return "[\(arr.count) items]"
        case .object: return "{…}"
        }
    }

    private func formatToolResult(_ result: AgentToolResult, isError: Bool) -> [String] {
        let text = result.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined(separator: "\n")
        let lines = text.components(separatedBy: "\n")
        let preview = Array(lines.prefix(4))
        let hidden = max(0, lines.count - preview.count)
        let arm = "  ⎿ "
        var out: [String] = preview.map { line in
            let body = arm + truncate(line, to: 200)
            return isError ? Style.error(body) : Style.dimmed(body)
        }
        if hidden > 0 {
            let note = "  ⎿ … \(hidden) more lines"
            out.append(isError ? Style.error(note) : Style.dimmed(note))
        }
        return out
    }

    private func truncate(_ s: String, to max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}

/// Thread-local line buffer with cheap tail replacement semantics. Not
/// actually thread-safe — callers are expected to mutate it from the main
/// actor only. Backed by a plain array.
@MainActor
public final class TranscriptBuffer {
    public private(set) var all: [String] = []

    public init() {}

    public var count: Int { all.count }

    public func append(_ line: String) { all.append(line) }

    /// Replace `range` with `newLines`. Clamps to buffer bounds.
    public func replace(range: Range<Int>, with newLines: [String]) {
        let safeRange = clampedRange(range)
        all.replaceSubrange(safeRange, with: newLines)
    }

    /// Replace from `start` to the end with `newLines`.
    public func replace(from start: Int, with newLines: [String]) {
        let clamped = max(0, min(start, all.count))
        all.replaceSubrange(clamped..<all.count, with: newLines)
    }

    /// Return the tail of the buffer, at most `n` lines.
    public func tail(_ n: Int) -> [String] {
        guard n >= 0 else { return [] }
        if all.count <= n { return all }
        return Array(all.suffix(n))
    }

    private func clampedRange(_ range: Range<Int>) -> Range<Int> {
        let lower = max(0, min(range.lowerBound, all.count))
        let upper = max(lower, min(range.upperBound, all.count))
        return lower..<upper
    }
}
