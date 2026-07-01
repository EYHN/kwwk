import Foundation
import KWWKAI
import KWWKAgent

/// Claude-Code-style transcript with a committed / live split.
///
/// The renderer maintains two buckets:
///
/// * `pendingCommits` — lines that have **settled** and are ready to be
///   written above the live zone as append-only output (they flow into the
///   terminal's native scrollback and stay there forever). CodingTUI
///   drains this on every agent event and passes it to `tui.commit(_:)`.
///
/// * `liveLines` — the mutable in-progress tail: running tool headers
///   + their result previews. Assistant text is not retained here; it is
///   committed append-only at stable segment boundaries so the terminal's
///   native autowrap handles long lines.
///
/// Settlement points:
///   - `messageStart(.user)` → commit the user prompt row + a blank
///     (user input never streams).
///   - `messageUpdate(.assistant)` → commit assistant text that has
///     reached a stable hard-line boundary. Keep the trailing partial
///     segment buffered.
///   - `messageEnd(.assistant)` → commit the remaining buffered segment
///     plus any aborted/error line. Clear assistant segment state.
///   - `toolExecutionEnd` → commit the tool header + result lines +
///     a blank, but **only after every earlier-started tool has also
///     settled** — preserves visual ordering when tools finish out of
///     order.
///
/// Once a chunk is committed it's in terminal scrollback — the renderer
/// can't reflow it on resize. Same constraint Ink's `<Static>` has.
@MainActor
final class TranscriptRenderer {
    /// Lines waiting to be flushed to the terminal as append-only output.
    /// Drained by CodingTUI via `drainCommits()` on every agent event.
    private var pendingCommits: [String] = []

    /// The current in-progress tail. Assistant text is deliberately not
    /// retained here: stable text segments are committed append-only so the
    /// terminal can handle native autowrap. The live tail is for mutable tool
    /// slots and transient status only.
    private(set) var liveLines: [String] = []

    /// True while an assistant message is mid-stream.
    private var streaming: Bool = false
    /// Number of characters from the latest full assistant text snapshot that
    /// have been ingested into `assistantSegmentBuffer` or committed. Provider
    /// deltas arrive with the accumulated partial message, so this prevents
    /// duplicate commits without relying on terminal width.
    private var assistantIngestedCharacters: Int = 0
    /// Tail of the assistant text that has not reached a stable segment
    /// boundary yet. It is flushed on newline boundaries while streaming and
    /// fully flushed on `messageEnd`.
    private var assistantSegmentBuffer: String = ""
    /// Whether this assistant turn has already emitted any text/error marker
    /// into scrollback. Used to prepend the block's leading separator exactly
    /// once.
    private var assistantCommittedDuringTurn: Bool = false

    /// Verbose diagnostics that arrived while the assistant body was live.
    /// They are committed after `messageEnd` so provider logs don't interleave
    /// with token streaming in the live zone.
    private var queuedVerboseLines: [String] = []

    /// In-flight tool calls, kept in **start order** so we can drain the
    /// front-of-queue when settlements land (out-of-order completions
    /// wait for preceding ones). Each slot carries either a `.running`
    /// marker or a `.resolved(lines)` payload ready to commit.
    private var toolSlots: [ToolSlot] = []

    private struct ToolSlot {
        let id: String
        let name: String
        let args: JSONValue
        var partial: AgentToolResult?
        var resolution: [String]?   // nil = running
    }

    /// How to surface thinking blocks. Mirrored from `agent.state` via
    /// `setThinkingDisplay` so the UI can honor the user's `/thinking
    /// show|hide` choice without the renderer having to reach for the
    /// Agent.
    private var thinkingDisplay: ThinkingDisplay = .collapsed

    /// Start/end timestamps per thinking content-block index for the
    /// current streaming turn. `end == nil` while the block is still
    /// receiving deltas. Reset on every `messageStart`.
    private var thinkingTimings: [Int: (start: DispatchTime, end: DispatchTime?)] = [:]

    /// Terminal width used to render full-width blocks (the user-message bar).
    /// Updated by CodingTUI on init + resize. Committed lines are otherwise
    /// width-agnostic (the terminal owns autowrap).
    var displayWidth: Int = 80

    init() {}

    func setThinkingDisplay(_ display: ThinkingDisplay) {
        thinkingDisplay = display
    }

    /// True when the current turn has at least one thinking block that
    /// has started but not yet closed. The CodingTUI poll uses this to
    /// trigger a re-render each tick so collapsed-mode elapsed seconds
    /// keep advancing even without provider deltas.
    var hasActiveThinking: Bool {
        thinkingTimings.values.contains { $0.end == nil }
    }

    /// Drain the commit buffer. Caller is expected to forward the
    /// returned lines to `TUI.commit(_:)` so they become permanent
    /// scrollback above the live zone.
    func drainCommits() -> [String] {
        let out = pendingCommits
        pendingCommits.removeAll()
        return out
    }

    func apply(_ event: AgentEvent) {
        switch event {
        case .messageStart(let message):
            switch message {
            case .user(let u):
                let text = userText(u)
                // Background-task completion notifications arrive as
                // synthetic user messages carrying a `<task-notification>`
                // XML block. Rendering them raw dumps 15+ lines of tags
                // into the UI; detect them by the fixed lead-in the bridge
                // emits (see `BackgroundTaskNotification.messageText()`)
                // and fold them into a tool-result-style summary instead.
                if isHiddenGoalContinuation(message) {
                    // Hidden goal-continuation steer: role=user, suppressed from
                    // the visible transcript. It still reaches the model and
                    // agent.state.messages — only the render is skipped. Uses the
                    // same single-text-block predicate as persistence so a real
                    // multi-block message that merely starts with the marker is
                    // still shown, not hidden.
                } else if let summary = BgNotificationSummary.parse(text) {
                    commit(summary.render())
                } else {
                    commit([""] + Theme.userBar(text, width: displayWidth))
                }
            case .assistant:
                streaming = true
                assistantIngestedCharacters = 0
                assistantSegmentBuffer = ""
                assistantCommittedDuringTurn = false
                // New turn — drop any prior turn's thinking timings.
                // Re-populated from `.thinkingStart` events below.
                thinkingTimings.removeAll()
                recomputeLive()
            case .toolResult:
                break
            }

        case .messageUpdate(let assistant, let amEvent):
            // Track thinking block lifecycle so collapsed rendering can
            // show elapsed time. Timestamps are monotonic (DispatchTime)
            // so the counter isn't affected by wall-clock jumps.
            switch amEvent {
            case .thinkingStart(let idx, _):
                if thinkingTimings[idx] == nil {
                    thinkingTimings[idx] = (start: DispatchTime.now(), end: nil)
                }
            case .thinkingEnd(let idx, _, _):
                if var t = thinkingTimings[idx] {
                    t.end = DispatchTime.now()
                    thinkingTimings[idx] = t
                }
            default:
                break
            }
            ingestAssistantText(assistant, flushAll: false)
            recomputeLive()

        case .messageEnd(let message):
            switch message {
            case .assistant(let a):
                // Seal any thinking blocks that didn't get an explicit
                // `thinkingEnd` (e.g. turn aborted mid-thought). This
                // freezes the elapsed counter at the abort moment.
                for (idx, t) in thinkingTimings where t.end == nil {
                    thinkingTimings[idx] = (start: t.start, end: DispatchTime.now())
                }
                ingestAssistantText(a, flushAll: true)
                var tail: [String] = []
                if a.stopReason == .aborted {
                    tail.append(Style.dimmed("⋯ aborted"))
                }
                if let err = a.errorMessage, a.stopReason == .error {
                    tail.append(Style.error("✗ \(err)"))
                }
                if !tail.isEmpty {
                    commitAssistantLines(tail)
                }
                streaming = false
                assistantIngestedCharacters = 0
                assistantSegmentBuffer = ""
                assistantCommittedDuringTurn = false
                recomputeLive()
                flushQueuedVerbose()
            case .toolResult, .user:
                break
            }

        case .toolExecutionStart(let id, let name, let args):
            toolSlots.append(ToolSlot(id: id, name: name, args: args, partial: nil, resolution: nil))
            recomputeLive()

        case .toolExecutionUpdate(let id, _, _, let partialResult):
            guard let idx = toolSlots.firstIndex(where: { $0.id == id }) else { break }
            toolSlots[idx].partial = partialResult
            recomputeLive()

        case .toolExecutionEnd(let id, _, let result, let isError):
            guard let idx = toolSlots.firstIndex(where: { $0.id == id }) else { break }
            let slot = toolSlots[idx]
            let header = Style.tool("● \(slot.name)(\(formatArgs(slot.args)))")
            // Leading blank, no trailing — uniform "every scrollback block
            // opens with a separator row, never closes with one" rule.
            var finalLines = ["", header]
            finalLines.append(contentsOf: formatToolResult(result, isError: isError))
            toolSlots[idx].resolution = finalLines
            drainResolvedToolFront()
            recomputeLive()

        case .agentEnd:
            flushQueuedVerbose()

        case .streamRetry(_, let delayMs, _):
            let delayLabel = delayMs >= 1000
                ? "\(Int((Double(delayMs) / 1000.0).rounded(.up)))s"
                : "\(delayMs)ms"
            // Intentionally omit the reason here — the user sees just the
            // retry countdown during transient failures. If every retry is
            // exhausted the final error surfaces via messageEnd's `✗` line.
            commit([Style.dimmed("  ⟳ retrying in \(delayLabel)")])

        case .streamRewind:
            // A retryable error killed the stream mid-flight. Clear the
            // segment buffer so the retry's `messageStart` paints a clean
            // slate. If we already committed completed segments into
            // scrollback, those lines are irrevocable — terminals can't
            // un-scroll. Drop a visible marker so the user knows the earlier
            // output was from a failed attempt; the retry's body will follow
            // after the next messageStart.
            if assistantCommittedDuringTurn {
                commit([Style.dimmed("  ⋯ retry — prior partial above is discarded")])
            }
            assistantIngestedCharacters = 0
            assistantSegmentBuffer = ""
            assistantCommittedDuringTurn = false
            queuedVerboseLines.removeAll()
            recomputeLive()

        case .verbose(let event):
            let lines = renderVerbose(event)
            if streaming {
                queuedVerboseLines.append(contentsOf: lines)
            } else {
                commit(lines)
            }

        default: break
        }
    }

    // MARK: - Commit / live helpers

    private func commit(_ lines: [String]) {
        for raw in lines {
            for sub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                pendingCommits.append(String(sub))
            }
        }
    }

    /// Pop resolved tool slots from the front of the queue until we hit
    /// one that's still running. This preserves start-order in the
    /// committed output even when tools finish out of order.
    private func drainResolvedToolFront() {
        while let front = toolSlots.first, let resolved = front.resolution {
            commit(resolved)
            toolSlots.removeFirst()
        }
    }

    private func flushQueuedVerbose() {
        guard !queuedVerboseLines.isEmpty else { return }
        commit(queuedVerboseLines)
        queuedVerboseLines.removeAll()
    }

    /// Rebuild `liveLines` from any still-live tool slots. Slots that have
    /// resolved but are blocked
    /// behind an earlier running slot still render here as their final
    /// result — so the user sees the complete output as soon as it's
    /// known, even before the commit happens.
    private func recomputeLive() {
        var out: [String] = []
        for slot in toolSlots {
            // Each tool execution is its own block — leading blank
            // separator keeps parallel tools from stacking against the
            // streaming body or each other. Matches the committed-
            // scrollback convention so live view and scrollback look
            // identical as blocks roll out.
            out.append("")
            let header = Style.tool("● \(slot.name)(\(formatArgs(slot.args)))")
            out.append(header)
            if let resolved = slot.resolution {
                // Committed form is `["", header, body...]`; we've
                // already emitted our own blank + header, so strip those
                // two from the resolved payload and keep only the body.
                let body = resolved.dropFirst(2)
                out.append(contentsOf: body)
            } else if let partial = slot.partial {
                out.append(contentsOf: formatToolResult(partial, isError: false))
            } else {
                out.append(Style.running("  ⎿  calling…"))
            }
        }
        liveLines = out
    }

    // MARK: - Formatting

    /// Extract the visible text for a user message, stripping the
    /// machine-readable `<attachments>…</attachments>` block that
    /// `buildPromptWithAttachments` appends. The LLM still sees the
    /// full block — this is purely what we show in the transcript.
    private func userText(_ u: UserMessage) -> String {
        stripAttachmentsBlock(rawUserText(u))
    }

    /// Regex-free strip: remove everything from the first literal
    /// `<attachments>` marker through the matching `</attachments>`.
    /// Only the first block (there should be at most one) is stripped.
    private func stripAttachmentsBlock(_ text: String) -> String {
        guard let openRange = text.range(of: "<attachments>") else { return text }
        guard let closeRange = text.range(of: "</attachments>", range: openRange.upperBound..<text.endIndex)
        else { return text }
        var out = String(text[..<openRange.lowerBound])
        out += text[closeRange.upperBound..<text.endIndex]
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rawUserText(_ u: UserMessage) -> String {
        u.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined(separator: " ")
    }

    private func assistantTextSnapshot(_ a: AssistantMessage) -> String {
        var out = ""
        var renderedAny = false
        for block in a.content {
            switch block {
            case .text(let t):
                if t.text.isEmpty { continue }
                if renderedAny {
                    if out.hasSuffix("\n\n") {
                        // Already separated by a blank line.
                    } else if out.hasSuffix("\n") {
                        out += "\n"
                    } else {
                        out += "\n\n"
                    }
                }
                out += t.text
                renderedAny = true
            case .thinking, .toolCall:
                // Tool calls render via toolExecutionStart so the `⎿` result
                // lines attach to the same `●` header. Skip here to avoid a
                // duplicate line during streaming.
                continue
            }
        }
        return out
    }

    private func ingestAssistantText(_ assistant: AssistantMessage, flushAll: Bool) {
        let snapshot = assistantTextSnapshot(assistant)
        if assistantIngestedCharacters > snapshot.count {
            assistantIngestedCharacters = 0
            assistantSegmentBuffer = ""
        }
        if assistantIngestedCharacters < snapshot.count {
            let start = snapshot.index(snapshot.startIndex, offsetBy: assistantIngestedCharacters)
            assistantSegmentBuffer += snapshot[start...]
            assistantIngestedCharacters = snapshot.count
        }
        drainAssistantSegmentBuffer(flushAll: flushAll)
    }

    private func drainAssistantSegmentBuffer(flushAll: Bool) {
        let segment: String
        if flushAll {
            guard !assistantSegmentBuffer.isEmpty else { return }
            segment = assistantSegmentBuffer
            assistantSegmentBuffer = ""
        } else {
            guard let boundary = assistantSegmentBuffer.lastIndex(of: "\n") else { return }
            segment = String(assistantSegmentBuffer[..<boundary])
            assistantSegmentBuffer = String(assistantSegmentBuffer[assistantSegmentBuffer.index(after: boundary)...])
        }
        if segment.isEmpty {
            if assistantCommittedDuringTurn {
                commit([""])
            }
            return
        }
        commitAssistantLines(segment.components(separatedBy: "\n"))
    }

    private func commitAssistantLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        if assistantCommittedDuringTurn {
            commit(lines)
        } else {
            commit([""] + lines)
            assistantCommittedDuringTurn = true
        }
    }

    /// Format a DispatchTime delta as a human-readable duration. 0.1s
    /// granularity under 10 seconds so the counter visibly ticks; full
    /// seconds above that; `Nm Ss` once we cross a minute.
    private func formatElapsed(from start: DispatchTime, to end: DispatchTime) -> String {
        let ns = end.uptimeNanoseconds >= start.uptimeNanoseconds
            ? end.uptimeNanoseconds - start.uptimeNanoseconds
            : 0
        let seconds = Double(ns) / 1_000_000_000
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return "\(Int(seconds))s"
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
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
        let arm = "  ⎿ "
        func styler(_ s: String) -> String { isError ? Style.error(s) : Style.dimmed(s) }

        // Tool-defined UI display wins over the default preview: tools that
        // know their output is noisy (e.g. "ls -R" or "grep") can supply a
        // pre-formatted summary here and it's shown as-is.
        if let display = result.uiDisplay, !display.isEmpty {
            return display.map { styler(arm + truncate($0, to: 200)) }
        }

        let text = result.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined(separator: "\n")
        let allLines = text.components(separatedBy: "\n")
        let preview = Array(allLines.prefix(4))
        let hidden = max(0, allLines.count - preview.count)
        var out: [String] = preview.map { styler(arm + truncate($0, to: 200)) }
        if hidden > 0 {
            out.append(styler("  ⎿ … \(hidden) more lines"))
        }
        return out
    }

    private func renderVerbose(_ event: VerboseEvent) -> [String] {
        var line = "  verbose"
        if !event.source.isEmpty {
            line += " [\(event.source)]"
        }
        line += ": \(event.message)"
        let metadata = formatVerboseMetadata(event.metadata)
        if !metadata.isEmpty {
            line += " · \(metadata)"
        }
        return ["", Style.dimmed(line)]
    }

    private func formatVerboseMetadata(_ metadata: [String: JSONValue]) -> String {
        metadata.keys.sorted().compactMap { key in
            guard let value = metadata[key] else { return nil }
            return "\(key)=\(formatValue(value))"
        }.joined(separator: " ")
    }

    private func truncate(_ s: String, to max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}
