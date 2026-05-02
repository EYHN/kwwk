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
/// * `liveLines` — the in-progress tail: streaming assistant text plus
///   any running tool headers + their result previews. This is what
///   `CodingLayout.liveTail` shows, redrawn in place each frame.
///
/// Settlement points:
///   - `messageStart(.user)` → commit the user prompt row + a blank
///     (user input never streams).
///   - `messageEnd(.assistant)` → commit the assistant turn's body
///     (plus any aborted/error line) + a blank. Clear streaming tail.
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

    /// The current in-progress tail. Recomputed from `streamingBody` +
    /// `toolSlots` on every change.
    private(set) var liveLines: [String] = []

    /// True while an assistant message is mid-stream.
    private var streaming: Bool = false
    /// Current rendered lines of the streaming assistant turn, **minus**
    /// any head that was already spilled to the commit buffer. The
    /// spilled prefix count is tracked in `streamingCommittedPrefix`; on
    /// every `messageUpdate` we recompute the full body and then drop
    /// the first `streamingCommittedPrefix` lines so we never re-emit
    /// them.
    private var streamingBody: [String] = []
    /// Lines of the current turn's body that have already been flushed
    /// to the commit buffer (i.e. are in terminal scrollback, not in
    /// the live zone). Reset to 0 on every `messageStart(.assistant)`.
    private var streamingCommittedPrefix: Int = 0

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

    /// Spill the streaming assistant body's head into the commit buffer
    /// when it would otherwise exceed `budget` rows after accounting for
    /// `reserved` caller-owned rows (typically notifications) and the
    /// space running tool slots will consume.
    ///
    /// Committed lines are removed from `streamingBody` so future
    /// `messageUpdate`s don't re-emit them. Tool slots stay live even
    /// under pressure — they can still mutate (running → result) and
    /// committing them early would dump a `running…` placeholder into
    /// scrollback.
    ///
    /// Call this from the UI layer every time the live tail is about to
    /// be recomputed; it's idempotent once the body fits.
    func applyLiveBudget(_ budget: Int, reserved: Int = 0) {
        let toolLines = toolSlotsRenderedLineCount()
        let streamingBudget = max(0, budget - reserved - toolLines)
        guard streamingBody.count > streamingBudget else { return }
        let overflow = streamingBody.count - streamingBudget
        commit(Array(streamingBody.prefix(overflow)))
        streamingBody = Array(streamingBody.suffix(streamingBudget))
        // Remember how much of this turn's rendered body is now in
        // scrollback so the next `messageUpdate` knows to skip it
        // (otherwise we'd re-commit the same prefix every token).
        streamingCommittedPrefix += overflow
        recomputeLive()
    }

    /// How many rows running tool slots contribute to the live zone.
    /// Mirrors `recomputeLive`'s tool rendering so the budget math in
    /// `applyLiveBudget` matches what the user actually sees.
    private func toolSlotsRenderedLineCount() -> Int {
        var n = 0
        for slot in toolSlots {
            n += 1  // leading blank separator (one block per tool)
            n += 1  // header
            if let resolved = slot.resolution {
                n += max(0, resolved.count - 2)  // body (skip leading blank + header)
            } else if let partial = slot.partial {
                n += formatToolResult(partial, isError: false).count
            } else {
                n += 1  // "running…"
            }
        }
        return n
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
                if let summary = BgNotificationSummary.parse(text) {
                    commit(summary.render())
                } else {
                    commit(["", Style.user("❯ " + text)])
                }
            case .assistant:
                streaming = true
                streamingBody = []
                streamingCommittedPrefix = 0
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
            let full = renderAssistantLines(assistant)
            // Drop the already-spilled head so we don't round-trip
            // those lines on every token. `streamingCommittedPrefix`
            // grows monotonically per turn; assistant output is
            // append-only under our agent so this is safe.
            streamingBody = Array(full.dropFirst(streamingCommittedPrefix))
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
                let full = renderAssistantLines(a)
                var tail = Array(full.dropFirst(streamingCommittedPrefix))
                if a.stopReason == .aborted {
                    tail.append(Style.dimmed("⋯ aborted"))
                }
                if let err = a.errorMessage, a.stopReason == .error {
                    tail.append(Style.error("✗ \(err)"))
                }
                commit(tail)
                streaming = false
                streamingBody = []
                streamingCommittedPrefix = 0
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
            // live-zone partial so the retry's `messageStart` paints a
            // clean slate. If we already spilled head-of-body into
            // committed scrollback (`applyLiveBudget` does that on long
            // turns), those lines are irrevocable — terminals can't
            // un-scroll. Drop a visible marker so the user knows the
            // earlier output was from a failed attempt; the retry's
            // body will follow after the next messageStart.
            if streamingCommittedPrefix > 0 {
                commit([Style.dimmed("  ⋯ retry — prior partial above is discarded")])
            }
            streamingBody = []
            streamingCommittedPrefix = 0
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

    /// Rebuild `liveLines` from the current streaming body + any
    /// still-live tool slots. Slots that have resolved but are blocked
    /// behind an earlier running slot still render here as their final
    /// result — so the user sees the complete output as soon as it's
    /// known, even before the commit happens.
    private func recomputeLive() {
        var out: [String] = []
        if !streamingBody.isEmpty {
            for raw in streamingBody {
                for sub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                    out.append(String(sub))
                }
            }
        }
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
                out.append(Style.dimmed("  ⎿  running…"))
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

    private func renderAssistantLines(_ a: AssistantMessage) -> [String] {
        // Every scrollback block opens with a leading blank row and never
        // closes with one — so the next block brings its own separator.
        var out: [String] = [""]
        var renderedAny = false
        var thinkingIndex = 0
        for block in a.content {
            switch block {
            case .text(let t):
                if t.text.isEmpty { continue }
                if renderedAny { out.append("") }
                out.append(contentsOf: t.text.components(separatedBy: "\n"))
                renderedAny = true
            case .thinking(let th):
                defer { thinkingIndex += 1 }
                if th.thinking.isEmpty { continue }
                if renderedAny { out.append("") }
                switch thinkingDisplay {
                case .collapsed:
                    out.append(Style.dimmed(collapsedThinkingLabel(blockIndex: thinkingIndex)))
                case .expanded:
                    out.append(Style.dimmed(expandedThinkingHeader(blockIndex: thinkingIndex)))
                    for line in th.thinking.components(separatedBy: "\n") {
                        out.append(Style.dimmed("  " + line))
                    }
                }
                renderedAny = true
            case .toolCall:
                // Tool calls render via toolExecutionStart so the `⎿` result
                // lines attach to the same `●` header. Skip here to avoid a
                // duplicate line during streaming.
                continue
            }
        }
        return out
    }

    /// One-liner for a thinking block in collapsed mode.
    ///   running  → "[thinking 2.3s…]"
    ///   settled  → "[thought for 3.4s]"
    private func collapsedThinkingLabel(blockIndex: Int) -> String {
        let timing = thinkingTimings[blockIndex]
        if let timing {
            if let end = timing.end {
                return "[thought for \(formatElapsed(from: timing.start, to: end))]"
            } else {
                return "[thinking \(formatElapsed(from: timing.start, to: DispatchTime.now()))…]"
            }
        }
        // No timing recorded — message restored from history or fed in
        // pre-formed (no events observed). Fall back to a neutral marker.
        return "[thought]"
    }

    /// Header used in expanded mode. Mirrors the collapsed label format
    /// so the user can eyeball duration without switching modes.
    private func expandedThinkingHeader(blockIndex: Int) -> String {
        let timing = thinkingTimings[blockIndex]
        if let timing {
            if let end = timing.end {
                return "[thinking — \(formatElapsed(from: timing.start, to: end))]"
            } else {
                return "[thinking — \(formatElapsed(from: timing.start, to: DispatchTime.now()))…]"
            }
        }
        return "[thinking]"
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
