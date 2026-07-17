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
/// * `liveLines` — the mutable in-progress tail: the read-only fold group,
///   running tool headers + result previews, open-thinking labels, and the
///   unsettled trailing segment of assistant text (streamed token-by-token).
///   Stable text segments are committed append-only at hard-line boundaries
///   so the terminal's native autowrap handles long lines; only the trailing
///   partial stays live until it settles.
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

    /// The current in-progress tail: mutable tool slots, open-thinking
    /// labels, and the unsettled assistant-text tail streamed token-by-token.
    /// Stable text segments (up to a hard newline) are still committed
    /// append-only so the terminal owns native autowrap; only the trailing
    /// partial segment lives here until it settles.
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
    /// Content-block index of the text block the last `.textDelta` extended.
    /// While consecutive deltas grow the same block we append the delta
    /// directly (O(delta)); only a block transition falls back to re-deriving
    /// from the full snapshot. `nil` before the first text delta of a turn.
    private var lastAssistantTextIndex: Int?
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
        /// Set when this slot resolved as a foldable read-only call: the
        /// tool name + compact one-line summary that joins the current
        /// fold run instead of committing its own block.
        var foldEntry: FoldEntry?
    }

    private struct FoldEntry {
        let name: String
        let summary: String
    }

    /// Read-only tools whose successful results fold to a one-line summary
    /// instead of a content preview (omp keeps read/grep/glob visually
    /// light; edit/write/bash keep their full blocks). Errors never fold.
    private static let foldedTools: Set<String> = ["read", "grep", "find", "ls"]

    /// Consecutive resolved read-only calls (read/grep/find/ls), held back
    /// from scrollback so they commit as one group — a per-tool-count header
    /// (`read 2 files, grep 1 time`) over a dimmed tree, the same structure
    /// for one call or many. The run is sealed by any other content entering
    /// scrollback — assistant text, a non-folded tool block, a user message —
    /// so a burst of file/search calls reads
    /// as one calm block instead of N green-bulleted rows.
    private var foldRun: [FoldEntry] = []

    /// How to surface thinking blocks. Mirrored from `agent.state` via
    /// `setThinkingDisplay` so the UI can honor the user's `/thinking
    /// show|hide` choice without the renderer having to reach for the
    /// Agent.
    private var thinkingDisplay: ThinkingDisplay = .collapsed

    /// Minimum reasoning time before a **collapsed** thinking block is shown
    /// at all. Short thinks stay fully hidden — no live label, no committed
    /// row, no group seal — so a quick think between two tool calls doesn't
    /// chop the fold group into fragments. Expanded mode ignores this (the
    /// user opted into seeing every reasoning step). Stored so tests can
    /// lower it without waiting on the wall clock.
    var collapsedThinkingMinSeconds: Double = 3.0

    /// Start/end timestamps per thinking content-block index for the
    /// current streaming turn. `end == nil` while the block is still
    /// receiving deltas. Reset on every assistant `messageStart`.
    private var thinkingTimings: [Int: (start: DispatchTime, end: DispatchTime?)] = [:]

    /// Streaming thinking text per content-block index, accumulated from
    /// `.thinkingDelta` and shown live (expanded mode) while the block is
    /// open. Cleared when the block settles into the display layer.
    private var thinkingBuffers: [Int: String] = [:]

    /// Thinking blocks whose duration/body has already been consumed by the
    /// display layer. In expanded mode that means committed immediately; in
    /// collapsed mode it means staged into `collapsedThinkingNanoseconds`.
    /// Either way, this guards against double-counting when `messageEnd`
    /// sweeps up blocks that never saw an explicit `thinkingEnd`.
    private var settledThinkingBlocks: Set<Int> = []

    /// Sum of the active durations for the current run of adjacent collapsed
    /// thinking blocks. A `thinkingEnd` stages its duration here instead of
    /// committing a permanent row immediately. Assistant text, a tool call,
    /// user/runtime content, or the turn boundary flushes the run as one
    /// `[thought for …]` row. This is display-only; the underlying assistant
    /// content blocks remain untouched in the transcript and model context.
    private var collapsedThinkingNanoseconds: UInt64?

    /// Whether this stream attempt has irreversibly committed a thinking row
    /// to terminal scrollback. Unlike the live zone, scrollback cannot be
    /// erased on `.streamRewind`, so the retry path must annotate it as output
    /// from a discarded attempt just as it does committed assistant text.
    private var thinkingCommittedDuringAttempt = false

    /// Deterministic monotonic-clock seam for transcript tests. Production
    /// leaves this nil and reads `DispatchTime.now()`.
    var thinkingNowOverride: DispatchTime?

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
                flushCollapsedThinking()
                let text = userText(u)
                // Background-task completion notifications retain user role
                // for provider compatibility but carry `source == .runtime`
                // and a `<task-notification>`
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
                } else if u.source == .runtime,
                          let summary = BgNotificationSummary.parse(text) {
                    commit(summary.render())
                } else {
                    commit([""] + Theme.userBar(text, width: displayWidth))
                }
            case .assistant:
                // A previous turn normally flushed at `.turnEnd`; keep this
                // defensive boundary so an incomplete/custom event stream
                // cannot silently discard its last staged run.
                flushCollapsedThinking()
                streaming = true
                assistantIngestedCharacters = 0
                assistantSegmentBuffer = ""
                assistantCommittedDuringTurn = false
                thinkingCommittedDuringAttempt = false
                lastAssistantTextIndex = nil
                // New turn — drop any prior turn's thinking state.
                // Re-populated from `.thinkingStart` events below.
                thinkingTimings.removeAll()
                thinkingBuffers.removeAll()
                settledThinkingBlocks.removeAll()
                collapsedThinkingNanoseconds = nil
                recomputeLive()
            case .toolResult:
                break
            }

        case .messageUpdate(let assistant, let amEvent):
            // Thinking blocks remain mergeable only while they are adjacent.
            // Flush before ingesting/rendering either assistant text or a tool
            // call so the collapsed timing row stays in chronological order.
            switch amEvent {
            case .textStart, .textDelta, .textEnd,
                 .toolCallStart, .toolCallDelta, .toolCallEnd:
                flushCollapsedThinking()
            default:
                break
            }
            // Track thinking block lifecycle so collapsed rendering can
            // show elapsed time. Timestamps are monotonic (DispatchTime)
            // so the counter isn't affected by wall-clock jumps.
            switch amEvent {
            case .thinkingStart(let idx, _):
                // A text block that precedes this thinking block is now
                // structurally complete even if it had no trailing newline.
                // If the provider exposed that block only in this boundary's
                // accumulated snapshot, it is also a hard boundary for any
                // previously staged collapsed thought. Flush the thought
                // before ingesting the text so the two thinking runs cannot
                // merge across it or appear after it in scrollback.
                ingestThinkingBoundaryTextPrefix(assistant, beforeContentIndex: idx)
                if thinkingTimings[idx] == nil {
                    thinkingTimings[idx] = (start: thinkingNow(), end: nil)
                }
            case .thinkingDelta(let idx, let delta, _):
                thinkingBuffers[idx, default: ""] += delta
            case .thinkingEnd(let idx, let content, _):
                // Some providers expose preceding text only in the partial
                // snapshot attached to the thinking boundary. Commit that
                // prefix before the thought so expanded mode (which commits
                // immediately) and the final-snapshot fallback preserve the
                // original content-block order.
                ingestThinkingBoundaryTextPrefix(assistant, beforeContentIndex: idx)
                if var t = thinkingTimings[idx] {
                    t.end = thinkingNow()
                    thinkingTimings[idx] = t
                }
                settleThinkingBlock(idx, content: content)
            default:
                break
            }
            // Fast path: while consecutive text deltas grow the same content
            // block, append the delta straight into the segment buffer instead
            // of re-deriving (and re-diffing) the whole accumulated snapshot on
            // every event — the latter is O(n) per delta, O(n²) over a long
            // message. A block transition (a new text block after a tool call)
            // falls back to the snapshot path so the inter-block separator is
            // inserted correctly, then re-syncs the ingested count.
            if case .textDelta(let idx, let delta, _) = amEvent,
               lastAssistantTextIndex == nil || lastAssistantTextIndex == idx {
                lastAssistantTextIndex = idx
                assistantSegmentBuffer += delta
                assistantIngestedCharacters += delta.count
                drainAssistantSegmentBuffer(flushAll: false)
            } else {
                if case .textDelta(let idx, _, _) = amEvent { lastAssistantTextIndex = idx }
                ingestAssistantText(assistant, flushAll: false)
            }
            recomputeLive()

        case .messageEnd(let message):
            switch message {
            case .assistant(let a):
                // Seal any thinking blocks that didn't get an explicit
                // `thinkingEnd` (e.g. turn aborted mid-thought). This
                // freezes the elapsed counter at the abort moment.
                let end = thinkingNow()
                for (idx, t) in thinkingTimings where t.end == nil {
                    thinkingTimings[idx] = (start: t.start, end: end)
                }
                for idx in thinkingTimings.keys.sorted() where !settledThinkingBlocks.contains(idx) {
                    ingestThinkingBoundaryTextPrefix(a, beforeContentIndex: idx)
                    settleThinkingBlock(idx, content: thinkingBuffers[idx] ?? "")
                }
                // A provider may omit text stream events and expose text only
                // in its final snapshot. Treat that as the same hard boundary
                // as `.textStart` before committing the snapshot.
                if !assistantTextSnapshot(a).isEmpty {
                    flushCollapsedThinking()
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
                    flushCollapsedThinking()
                    commitAssistantLines(tail)
                }
                streaming = false
                assistantIngestedCharacters = 0
                assistantSegmentBuffer = ""
                assistantCommittedDuringTurn = false
                lastAssistantTextIndex = nil
                recomputeLive()
                flushQueuedVerbose()
            case .toolResult, .user:
                break
            }

        case .toolExecutionStart(let id, let name, let args):
            // Also enforce the tool boundary at execution time for providers
            // that don't stream a `.toolCallStart` event.
            flushCollapsedThinking()
            toolSlots.append(ToolSlot(id: id, name: name, args: args, partial: nil, resolution: nil))
            recomputeLive()

        case .toolExecutionUpdate(let id, _, _, let partialResult):
            guard let idx = toolSlots.firstIndex(where: { $0.id == id }) else { break }
            toolSlots[idx].partial = partialResult
            recomputeLive()

        case .toolExecutionEnd(let id, _, let result, let isError):
            guard let idx = toolSlots.firstIndex(where: { $0.id == id }) else { break }
            let slot = toolSlots[idx]
            if !isError, let summary = foldedSummary(name: slot.name, args: slot.args, result: result) {
                toolSlots[idx].foldEntry = FoldEntry(name: slot.name, summary: summary)
            } else {
                let header = toolHeader(name: slot.name, args: slot.args)
                // Leading blank, no trailing — uniform "every scrollback block
                // opens with a separator row, never closes with one" rule.
                var finalLines = ["", header]
                finalLines.append(contentsOf: formatToolResult(result, isError: isError))
                toolSlots[idx].resolution = finalLines
            }
            drainResolvedToolFront()
            recomputeLive()

        case .turnEnd:
            flushCollapsedThinking()

        case .agentEnd:
            flushCollapsedThinking()
            sealFoldRun()
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
            if assistantCommittedDuringTurn || thinkingCommittedDuringAttempt {
                commit([Style.dimmed("  ⋯ retry — prior partial above is discarded")])
            }
            assistantIngestedCharacters = 0
            assistantSegmentBuffer = ""
            assistantCommittedDuringTurn = false
            thinkingCommittedDuringAttempt = false
            lastAssistantTextIndex = nil
            queuedVerboseLines.removeAll()
            // The failed attempt's thinking is gone with the stream; the
            // retry's `messageStart` would clear these anyway, but the live
            // zone must not show a ghost `[thinking Ns…]` in between.
            thinkingTimings.removeAll()
            thinkingBuffers.removeAll()
            settledThinkingBlocks.removeAll()
            collapsedThinkingNanoseconds = nil
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

    /// Every scrollback write funnels through here, which makes it the
    /// single break point for the fold run: anything else entering
    /// scrollback seals the pending read-only group first, so the group
    /// always lands in chronological position.
    private func commit(_ lines: [String]) {
        sealFoldRun()
        rawCommit(lines)
    }

    private func rawCommit(_ lines: [String]) {
        for raw in lines {
            for sub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                pendingCommits.append(String(sub))
            }
        }
    }

    /// Flush the pending fold run into scrollback as a single count-headed
    /// tree block. Internal so `TranscriptSnapshot`'s replay can seal a
    /// trailing run without synthesizing a full `.agentEnd` payload.
    func sealFoldRun() {
        guard !foldRun.isEmpty else { return }
        let entries = foldRun
        foldRun.removeAll()
        rawCommit(foldRunLines(entries))
        recomputeLive()
    }

    /// One row of a read-only group: a resolved call carries its summary
    /// (`README.md · 200 lines`); a still-running call carries just its
    /// target (`README.md`) and fills in the count when it resolves.
    private struct GroupRow {
        let name: String
        let detail: String
    }

    private func foldRunLines(_ entries: [FoldEntry]) -> [String] {
        foldGroupLines(entries.map { GroupRow(name: $0.name, detail: $0.summary) })
    }

    /// Render a read-only group: a per-tool-count header (`read 2 files,
    /// ls 3 times`) over a dimmed tree — the same structure for one call or
    /// many. Used for both the committed group and the live (mid-flight)
    /// view, so a call joining or resolving only updates its row in place —
    /// no jump when the group settles into scrollback.
    private func foldGroupLines(_ rows: [GroupRow]) -> [String] {
        guard !rows.isEmpty else { return [] }
        // Always the same structure — count header over a dimmed tree — even
        // for a single call. A lone read/grep/ls never reshapes into a
        // standalone line and back as sibling calls arrive; the layout stays
        // stable regardless of how many land in the group.
        var out = ["", Style.tool("●") + " " + Style.dimmed(foldGroupHeader(rows))]
        for (i, r) in rows.enumerated() {
            let glyph = i == rows.count - 1 ? "└" : "├"
            let detail = r.detail.isEmpty ? "" : " \(r.detail)"
            out.append(Style.dimmed("  \(glyph) \(r.name)\(detail)"))
        }
        return out
    }

    /// Per-tool-type count summary for a group header, in first-appearance
    /// order: `read 2 files, ls 3 times, grep 1 time`. `read` counts files;
    /// the search/list tools count invocations.
    private func foldGroupHeader(_ rows: [GroupRow]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for r in rows {
            if counts[r.name] == nil { order.append(r.name) }
            counts[r.name, default: 0] += 1
        }
        return order.map { name -> String in
            let n = counts[name] ?? 0
            let unit: String
            switch name {
            case "read": unit = n == 1 ? "file" : "files"
            default: unit = n == 1 ? "time" : "times"
            }
            return "\(name) \(n) \(unit)"
        }.joined(separator: ", ")
    }

    /// The leading target of a still-running read-only call — the same
    /// prefix its resolved summary will start with, so the row doesn't jump
    /// when the count fills in. Empty when there's nothing meaningful yet.
    private func foldTarget(name: String, args: JSONValue) -> String {
        guard case .object(let obj) = args else { return "" }
        switch name {
        case "read", "ls":
            if case .string(let p) = obj["path"] ?? .null { return p }
            return name == "ls" ? "." : ""
        case "grep":
            guard case .string(let pat) = obj["pattern"] ?? .null else { return "" }
            var t = "\"\(truncate(pat, to: 60))\""
            if case .string(let p) = obj["path"] ?? .null { t += " in \(p)" }
            return t
        case "find":
            guard case .string(let pat) = obj["pattern"] ?? .null else { return "" }
            var t = "\"\(truncate(pat, to: 60))\""
            // Match the `in <path>` the resolved summary adds, so the row
            // doesn't shift when the count fills in.
            if case .string(let p) = obj["path"] ?? .null { t += " in \(p)" }
            return t
        default:
            return ""
        }
    }

    /// Pop resolved tool slots from the front of the queue until we hit
    /// one that's still running. This preserves start-order in the
    /// committed output even when tools finish out of order. Resolved
    /// read-only calls join the fold run instead of committing; any other
    /// resolved slot commits (sealing the run first).
    private func drainResolvedToolFront() {
        while let front = toolSlots.first {
            if let entry = front.foldEntry {
                foldRun.append(entry)
                toolSlots.removeFirst()
            } else if let resolved = front.resolution {
                commit(resolved)
                toolSlots.removeFirst()
            } else {
                break
            }
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
        // Read-only group, live: the resolved-pending fold entries plus any
        // foldable calls still in flight at the front of the queue, rendered
        // as one growing tree. An in-flight `read`/`grep`/`ls` sits inside
        // the group from the moment it starts — no separate `● read(…)`
        // block that later jumps into the group when it finishes.
        var groupRows: [GroupRow] = foldRun.map {
            GroupRow(name: $0.name, detail: $0.summary)
        }
        var consumed = 0
        for slot in toolSlots {
            guard Self.foldedTools.contains(slot.name) else { break }
            if let entry = slot.foldEntry {
                groupRows.append(GroupRow(name: entry.name, detail: entry.summary))
            } else if slot.resolution == nil {
                groupRows.append(GroupRow(
                    name: slot.name,
                    detail: foldTarget(name: slot.name, args: slot.args)
                ))
            } else {
                // A foldable call that errored keeps its own full block.
                break
            }
            consumed += 1
        }
        if !groupRows.isEmpty {
            out.append(contentsOf: foldGroupLines(groupRows))
        }
        // Token-streaming tail: the assistant text that hasn't reached a
        // hard-newline boundary yet. Rendered exactly where it will settle
        // (foldRun seals first, this message's tools start only later), with
        // the same leading-blank rule as `commitAssistantLines` so the
        // commit moment doesn't visually jump.
        if streaming && !assistantSegmentBuffer.isEmpty {
            if !assistantCommittedDuringTurn {
                out.append("")
            }
            out.append(assistantSegmentBuffer)
        }
        // Open thinking: collapsed mode renders one ticking row whose elapsed
        // value is the sum of the staged adjacent blocks plus the currently
        // active block(s). Expanded mode keeps its per-block body rendering.
        // Rendered *after* the text tail so an interleaved text→thinking
        // sequence keeps chronological order.
        let openThinking = thinkingTimings.sorted(by: { $0.key < $1.key }).filter {
            $0.value.end == nil && !settledThinkingBlocks.contains($0.key)
        }
        switch thinkingDisplay {
        case .collapsed:
            if collapsedThinkingNanoseconds != nil || !openThinking.isEmpty {
                let now = thinkingNow()
                var nanoseconds = collapsedThinkingNanoseconds ?? 0
                for (_, timing) in openThinking {
                    nanoseconds = addingClamped(
                        nanoseconds,
                        durationNanoseconds(from: timing.start, to: now)
                    )
                }
                let seconds = Double(nanoseconds) / 1_000_000_000
                if thinkingVisible(seconds: seconds, hasContent: false) {
                    out.append("")
                    out.append(Style.dimmed("[thinking \(formatElapsed(nanoseconds: nanoseconds))…]"))
                }
            }
        case .expanded:
            let now = thinkingNow()
            for (idx, timing) in openThinking {
                let buf = thinkingBuffers[idx] ?? ""
                let seconds = elapsedSeconds(from: timing.start, to: now)
                guard thinkingVisible(seconds: seconds, hasContent: !buf.isEmpty) else { continue }
                out.append("")
                out.append(Style.dimmed("[thinking \(formatElapsed(from: timing.start, to: now))…]"))
                if !buf.isEmpty {
                    out.append(contentsOf: buf.components(separatedBy: "\n").map { Style.dimmed("  " + $0) })
                }
            }
        }
        // Remaining slots — those past the leading foldable run consumed
        // into the group above (non-folded tools, or foldable calls blocked
        // behind a running non-folded tool).
        for slot in toolSlots.dropFirst(consumed) {
            // A resolved read-only call blocked behind an earlier running
            // non-folded slot renders as its own one-row group — byte-for-byte
            // the form it will settle into once it unblocks, so there's no
            // reflow on commit.
            if let entry = slot.foldEntry {
                out.append(contentsOf: foldGroupLines([GroupRow(name: entry.name, detail: entry.summary)]))
                continue
            }
            // Each tool execution is its own block — leading blank
            // separator keeps parallel tools from stacking against the
            // streaming body or each other. Matches the committed-
            // scrollback convention so live view and scrollback look
            // identical as blocks roll out.
            out.append("")
            out.append(toolHeader(name: slot.name, args: slot.args))
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
        assistantTextSnapshot(a, beforeContentIndex: nil)
    }

    /// Build the same flattened text snapshot as `assistantTextSnapshot(_:)`,
    /// optionally stopping before one content-block index. The prefix form is
    /// used to settle provider snapshots in block order at a thinking boundary.
    private func assistantTextSnapshot(
        _ a: AssistantMessage,
        beforeContentIndex: Int?
    ) -> String {
        var out = ""
        var renderedAny = false
        for (idx, block) in a.content.enumerated() {
            if let beforeContentIndex, idx >= beforeContentIndex { break }
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

    /// Ingest only text blocks that precede `contentIndex`. Unlike the full
    /// snapshot path, an already-consumed longer snapshot is left untouched;
    /// a prefix must never rewind the global text cursor.
    private func ingestAssistantTextPrefix(
        _ assistant: AssistantMessage,
        beforeContentIndex contentIndex: Int,
        flushAll: Bool
    ) {
        let snapshot = assistantTextSnapshot(
            assistant,
            beforeContentIndex: contentIndex
        )
        guard assistantIngestedCharacters <= snapshot.count else { return }
        if assistantIngestedCharacters < snapshot.count {
            let start = snapshot.index(
                snapshot.startIndex,
                offsetBy: assistantIngestedCharacters
            )
            assistantSegmentBuffer += snapshot[start...]
            assistantIngestedCharacters = snapshot.count
        }
        drainAssistantSegmentBuffer(flushAll: flushAll)
    }

    /// Settle text discovered only at a thinking lifecycle boundary. New text
    /// splits collapsed thinking runs, but an adjacent thinking block with no
    /// intervening text remains mergeable.
    private func ingestThinkingBoundaryTextPrefix(
        _ assistant: AssistantMessage,
        beforeContentIndex contentIndex: Int
    ) {
        let prefixLength = assistantTextSnapshot(
            assistant,
            beforeContentIndex: contentIndex
        ).count
        if assistantIngestedCharacters < prefixLength {
            flushCollapsedThinking()
        }
        ingestAssistantTextPrefix(
            assistant,
            beforeContentIndex: contentIndex,
            flushAll: true
        )
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

    /// Whether a thinking block that has run for `seconds` is worth
    /// surfacing. Collapsed mode hides anything under the threshold so quick
    /// reasoning between tool calls leaves no trace and doesn't fragment the
    /// fold group; expanded mode shows a block as soon as it has any body
    /// (the user asked to see reasoning), and still surfaces a long
    /// content-less think.
    private func thinkingVisible(seconds: Double, hasContent: Bool) -> Bool {
        switch thinkingDisplay {
        case .collapsed:
            return seconds >= collapsedThinkingMinSeconds
        case .expanded:
            return hasContent || seconds >= collapsedThinkingMinSeconds
        }
    }

    /// Consume one settled thinking block in the active display mode.
    /// Expanded mode commits it immediately with its body. Collapsed mode
    /// stages only its active duration so adjacent blocks can later flush as
    /// a single row without altering the underlying assistant message.
    private func settleThinkingBlock(_ idx: Int, content: String) {
        guard !settledThinkingBlocks.contains(idx) else { return }
        guard thinkingDisplay == .collapsed else {
            commitThinkingBlock(idx, content: content)
            return
        }

        settledThinkingBlocks.insert(idx)
        thinkingBuffers[idx] = nil
        let nanoseconds = thinkingTimings[idx].map {
            durationNanoseconds(from: $0.start, to: $0.end ?? thinkingNow())
        } ?? 0
        collapsedThinkingNanoseconds = addingClamped(
            collapsedThinkingNanoseconds ?? 0,
            nanoseconds
        )
    }

    /// Flush the current adjacent collapsed run at a visible-content boundary.
    /// The threshold applies to the *sum*, so several individually-short
    /// blocks can correctly surface as one meaningful reasoning interval.
    private func flushCollapsedThinking() {
        guard let nanoseconds = collapsedThinkingNanoseconds else { return }
        collapsedThinkingNanoseconds = nil
        let seconds = Double(nanoseconds) / 1_000_000_000
        guard seconds >= collapsedThinkingMinSeconds else {
            recomputeLive()
            return
        }
        thinkingCommittedDuringAttempt = true
        commit(["", Style.dimmed("[thought for \(formatElapsed(nanoseconds: nanoseconds))]")])
        recomputeLive()
    }

    /// Commit one expanded thinking block's settled form into scrollback: a
    /// dimmed timing label plus its full body. Like any other shown block it
    /// seals the pending fold run via `commit`.
    private func commitThinkingBlock(_ idx: Int, content: String) {
        guard !settledThinkingBlocks.contains(idx) else { return }
        settledThinkingBlocks.insert(idx)
        thinkingBuffers[idx] = nil
        let timing = thinkingTimings[idx]
        let end = timing?.end ?? thinkingNow()
        let seconds = timing.map { elapsedSeconds(from: $0.start, to: end) } ?? 0
        guard thinkingVisible(seconds: seconds, hasContent: !content.isEmpty) else { return }
        let elapsed = timing.map { formatElapsed(from: $0.start, to: end) } ?? "0.0s"
        var lines = ["", Style.dimmed("[thought for \(elapsed)]")]
        if thinkingDisplay == .expanded, !content.isEmpty {
            lines.append(contentsOf: content.components(separatedBy: "\n").map { Style.dimmed("  " + $0) })
        }
        thinkingCommittedDuringAttempt = true
        commit(lines)
    }

    /// Re-derive `liveLines` outside an agent event. The CodingTUI spinner
    /// tick calls this while `hasActiveThinking`, so the `[thinking Ns…]`
    /// elapsed counter advances even when the provider sends no deltas.
    func tickLive() {
        recomputeLive()
    }

    private func thinkingNow() -> DispatchTime {
        thinkingNowOverride ?? DispatchTime.now()
    }

    private func durationNanoseconds(from start: DispatchTime, to end: DispatchTime) -> UInt64 {
        end.uptimeNanoseconds >= start.uptimeNanoseconds
            ? end.uptimeNanoseconds - start.uptimeNanoseconds
            : 0
    }

    private func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private func elapsedSeconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(durationNanoseconds(from: start, to: end)) / 1_000_000_000
    }

    /// Format a DispatchTime delta as a human-readable duration. 0.1s
    /// granularity under 10 seconds so the counter visibly ticks; full
    /// seconds above that; `Nm Ss` once we cross a minute.
    private func formatElapsed(from start: DispatchTime, to end: DispatchTime) -> String {
        formatElapsed(nanoseconds: durationNanoseconds(from: start, to: end))
    }

    private func formatElapsed(nanoseconds: UInt64) -> String {
        let seconds = Double(nanoseconds) / 1_000_000_000
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

    /// `● name(args…)` header line for a tool block. `ask` gets its first
    /// question inline — the generic form would render the questions array as
    /// an opaque `questions: [2 items]`.
    private func toolHeader(name: String, args: JSONValue) -> String {
        if name == "ask", let summary = askHeaderSummary(args) {
            return Style.tool("● ask(\(summary))")
        }
        return Style.tool("● \(name)(\(formatArgs(args)))")
    }

    private func askHeaderSummary(_ args: JSONValue) -> String? {
        guard case .object(let obj) = args,
              case .array(let questions) = obj["questions"] ?? .null,
              case .object(let first) = questions.first ?? .null,
              case .string(let text) = first["question"] ?? .null else { return nil }
        var summary = "\"\(truncate(text, to: 60))\""
        if questions.count > 1 { summary += " +\(questions.count - 1) more" }
        return summary
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

    // MARK: - Read-only tool folding

    /// One-line summary for a successful read-only tool call, or nil for
    /// tools that keep their full block. The tool name is prepended by the
    /// caller (`● name summary` inline, or `name summary` as a tree row),
    /// so the summary here is name-free.
    private func foldedSummary(name: String, args: JSONValue, result: AgentToolResult) -> String? {
        guard Self.foldedTools.contains(name) else { return nil }
        guard case .object(let obj) = args else { return nil }
        switch name {
        case "read":
            guard case .string(let path) = obj["path"] ?? .null else { return nil }
            if result.content.contains(where: { if case .image = $0 { return true } else { return false } }) {
                return "\(path) · image"
            }
            let lines = resultLineCount(result)
            var label = path
            let offset = intArg(obj["offset"])
            if offset != nil || intArg(obj["limit"]) != nil {
                let start = offset ?? 1
                label += ":\(start)-\(start + max(lines, 1) - 1)"
            }
            return "\(label) · \(lines) \(lines == 1 ? "line" : "lines")"
        case "grep":
            guard case .string(let pattern) = obj["pattern"] ?? .null else { return nil }
            let matches = detailsArray(result, key: "matches")
            var label = "\"\(truncate(pattern, to: 60))\""
            if case .string(let path) = obj["path"] ?? .null {
                label += " in \(path)"
            }
            if matches.isEmpty {
                return "\(label) · no matches"
            }
            var files = Set<String>()
            for m in matches {
                if case .object(let mo) = m, case .string(let f) = mo["file"] ?? .null {
                    files.insert(f)
                }
            }
            label += " · \(matches.count) \(matches.count == 1 ? "match" : "matches")"
            if files.count > 1 {
                label += " · \(files.count) files"
            }
            return label
        case "find":
            guard case .string(let pattern) = obj["pattern"] ?? .null else { return nil }
            var label = "\"\(truncate(pattern, to: 60))\""
            // Surface the search root: `find "*.swift"` scoped to a subdir
            // that has no top-level match reads as a mysterious "no files"
            // otherwise (the glob's `*` doesn't cross `/`).
            if case .string(let path) = obj["path"] ?? .null {
                label += " in \(path)"
            }
            let files = detailsArray(result, key: "files")
            let count = files.isEmpty ? "no files" : "\(files.count) \(files.count == 1 ? "file" : "files")"
            return "\(label) · \(count)"
        case "ls":
            let path: String = {
                if case .string(let p) = obj["path"] ?? .null { return p }
                return "."
            }()
            let entries = detailsArray(result, key: "entries")
            return "\(path) · \(entries.count) \(entries.count == 1 ? "entry" : "entries")"
        default:
            return nil
        }
    }

    private func intArg(_ v: JSONValue?) -> Int? {
        switch v ?? .null {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    private func detailsArray(_ result: AgentToolResult, key: String) -> [JSONValue] {
        guard case .object(let details) = result.details ?? .null,
              case .array(let arr) = details[key] ?? .null else { return [] }
        return arr
    }

    /// Count the content lines of a tool result, excluding the trailing
    /// `[Showing lines X-Y of Z…]`-style bracket note the read tool appends
    /// after a blank line.
    private func resultLineCount(_ result: AgentToolResult) -> Int {
        let text = result.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined(separator: "\n")
        var lines = text.components(separatedBy: "\n")
        if lines.count >= 3,
           let last = lines.last, last.hasPrefix("["), last.hasSuffix("]"),
           lines[lines.count - 2].isEmpty {
            lines.removeLast(2)
        }
        return lines.count
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
