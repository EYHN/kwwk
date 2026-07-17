import Foundation

/// Retained-mode TUI runtime, inline render strategy (matches Claude Code's
/// behavior): anchor at the current cursor position, grow downward. Children
/// form the **live zone**, which is redrawn in place on every render. A
/// separate `commit(_:)` API writes lines ABOVE the live zone as append-only
/// output — those lines flow into the terminal's native scrollback exactly
/// like ordinary stdout, so users can scroll up to see history. Subsequent
/// renders move back up `liveHeight - 1` rows, rewrite the live zone, and
/// clear any trailing rows. Committed content is NOT repainted, which means
/// it can't be re-wrapped on resize — same constraint Ink has with its
/// `<Static>` component.
final class TUI: @unchecked Sendable {
    private let terminal: Terminal
    private let lock = NSLock()
    /// Live-zone children. Everything in here is redrawn in place on every
    /// render cycle. Static/committed content is written via `commit(_:)`
    /// and never tracked as a component — it scrolls into native scrollback
    /// and is owned by the terminal from that point on.
    private var children: [Component] = []
    private var lastFrameHeight: Int = 0
    private var lastRenderedLines: [String] = []
    /// Lines queued up to be written as append-only output above the live
    /// zone on the next render. Drained (→ []) every time we flush.
    private var pendingCommits: [String] = []
    /// Full retained transcript (every committed line, in order) so a resize
    /// can re-wrap the whole history to the new width instead of leaving the
    /// terminal to reflow already-drawn cells. Committed text is stored as
    /// *logical* lines (paragraphs, not pre-wrapped), so reprinting with
    /// autowrap on re-wraps it cleanly. Capped to bound memory.
    private var committedLines: [String] = []
    private static let maxCommittedLines = 20_000
    private var isStarted: Bool = false
    private var clearOnShrink: Bool = true
    private var resizeUnsubscribe: (() -> Void)?
    private var _fullRedraws: Int = 0
    /// Coalesces a burst of SIGWINCH events into a single authoritative
    /// repaint. A window drag fires many resize events per second; replaying
    /// the whole retained transcript (up to `maxCommittedLines`) on each step
    /// is wasteful, so we debounce and repaint once the drag settles, using the
    /// final terminal size. Cancelled + rescheduled on every resize event.
    private var pendingResizeWork: DispatchWorkItem?
    private var lastResizeRepaintAt = Date.distantPast
    private static let resizeDebounceMs: Int = 60
    /// Optional decorative header (the welcome card) rendered fresh at the
    /// current width. Emitted once into scrollback on the first frame, and
    /// re-rendered at the top on every resize full-repaint so its fixed-width
    /// box re-fits the new width instead of reflowing into broken borders.
    /// Not stored in `committedLines`.
    var headerProvider: (@Sendable (Int) -> [String])?
    private var headerEmitted = false
    /// Inline mode parks the hardware cursor on the focused component's row,
    /// which may not be the last live row (e.g. a prompt box with a bottom
    /// border below the input). We remember how many rows up that was so the
    /// next frame can drop back to the live-zone bottom before rewinding —
    /// otherwise the rewind math is off and old rows leak as duplicates.
    private var lastCursorUpBy: Int = 0
    /// Set by `clearFrame()` so `stop()` skips its trailing newline — the
    /// erased live zone left the cursor exactly where the next output should
    /// start. Reset whenever a render draws a fresh frame.
    private var frameCleared = false
    /// Estimated blank rows between the live zone's bottom edge and the
    /// bottom of the screen. Each render consumes them as committed + live
    /// output grows (once at 0 the zone is pinned to the screen bottom and
    /// further growth scrolls history up); a shrink while pinned means the
    /// inline redraw would strand the frame high on the screen — see
    /// `render()`. Initialized to 0 (assume pinned): the pessimistic guess
    /// only costs a redundant repaint, which redraws the same layout.
    private var rowsBelowLiveZone = 0

    private static let disableAutowrap = "\u{1B}[?7l"
    private static let enableAutowrap = "\u{1B}[?7h"

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    // MARK: - Tree manipulation

    func addChild(_ component: Component) {
        lock.withLock { children.append(component) }
    }

    // MARK: - Lifecycle

    func start() {
        let alreadyStarted: Bool = lock.withLock {
            if isStarted { return true }
            isStarted = true
            return false
        }
        if alreadyStarted { return }

        resizeUnsubscribe = terminal.onResize { [weak self] _, _ in
            self?.handleResize()
        }
        requestRender()
    }

    func stop() {
        let wasStarted: Bool = lock.withLock {
            let prev = isStarted
            isStarted = false
            return prev
        }
        resizeUnsubscribe?()
        resizeUnsubscribe = nil
        // Drop any debounced resize repaint so it can't fire into a
        // torn-down / suspended terminal.
        lock.withLock {
            pendingResizeWork?.cancel()
            pendingResizeWork = nil
        }
        if wasStarted {
            let (cursorUpBy, cleared) = lock.withLock { (lastCursorUpBy, frameCleared) }
            var epilogue = TUI.enableAutowrap
            // The hardware cursor may be parked above the live-zone bottom
            // (inside a prompt box). Drop to the bottom before moving to a
            // fresh line so the shell prompt appears below the final frame,
            // not inside it. A `clearFrame()`-ed TUI has no final frame — the
            // cursor already sits where the next output should start.
            if cursorUpBy > 0 { epilogue += "\u{1B}[\(cursorUpBy)B" }
            if !cleared { epilogue += "\r\n" }
            if !epilogue.isEmpty { terminal.write(epilogue) }
        }
    }

    // MARK: - Rendering

    func requestRender() {
        render()
    }

    /// Queue `lines` to be written as append-only output above the live
    /// zone on the next render. Lines are written raw; if a committed line is
    /// wider than the terminal, the terminal's native autowrap owns the visual
    /// continuation rows. This is safe for committed output because it is never
    /// redrawn as part of the retained live frame.
    func commit(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.withLock {
            pendingCommits.append(contentsOf: lines)
            // Retain for resize re-wrapping.
            committedLines.append(contentsOf: lines)
            if committedLines.count > TUI.maxCommittedLines {
                committedLines.removeFirst(committedLines.count - TUI.maxCommittedLines)
            }
        }
    }

    /// Replace the entire retained transcript with `lines` and repaint from
    /// scratch — omp's branch/rewind treatment (`chatContainer.clear()` +
    /// `renderInitialMessages({clearTerminalHistory: true})`). On a direct
    /// terminal this clears the screen AND native scrollback (ED3) and
    /// replays `lines`, so scrolling up shows only the new transcript. Inside
    /// a multiplexer ED3 is hostile, so the visible pane is snapped instead
    /// and the pre-replacement history stays in the pane's own scrollback —
    /// the same constraint omp accepts (it skips clearScrollback there too).
    func replaceCommitted(_ lines: [String]) {
        lock.withLock {
            pendingCommits.removeAll()
            committedLines = lines
            if committedLines.count > TUI.maxCommittedLines {
                committedLines.removeFirst(committedLines.count - TUI.maxCommittedLines)
            }
        }
        repaintForResize()
    }

    func setClearOnShrink(_ value: Bool) {
        lock.withLock { clearOnShrink = value }
    }

    var fullRedraws: Int {
        lock.withLock { _fullRedraws }
    }

    /// Test hook: synchronously run the authoritative resize repaint
    /// (normally fired on a debounce after a SIGWINCH burst on direct
    /// terminals). Bypasses the timer + multiplexer gate so tests are
    /// deterministic.
    func triggerFullRepaintForTesting() {
        fullRepaint()
    }

    /// Test hook: synchronously run the multiplexer in-place repaint (normally
    /// fired on a SIGWINCH inside tmux/screen/zellij). Lets tests exercise the
    /// snap-and-repaint path without setting environment variables.
    func triggerMultiplexerRepaintForTesting() {
        multiplexerRepaint()
    }

    /// User-driven full repaint (bound to Ctrl+L). Clears the screen +
    /// scrollback and replays the retained transcript, header, and live zone
    /// at the current width — the conventional "redraw" escape hatch for when
    /// a background process or a flaky resize has corrupted the on-screen
    /// frame.
    func forceRepaint() {
        fullRepaint()
    }

    /// Drop retained live-zone geometry so the next render anchors fresh at the
    /// current cursor instead of rewinding over rows that no longer exist.
    /// Called by `TUIRunner.resume()` after a full-screen sub-flow (`/login`)
    /// printed its own output where the live zone used to be — without this,
    /// the first post-resume render would clear `lastFrameHeight` rows relative
    /// to the new cursor and erase the sub-flow's output.
    func resetFrameGeometryForResume() {
        lock.withLock {
            lastFrameHeight = 0
            lastCursorUpBy = 0
            lastRenderedLines = []
            // Unknown geometry after the sub-flow's output — assume pinned
            // (the conservative guess only risks a redundant repaint).
            rowsBelowLiveZone = 0
        }
    }

    /// Erase the live zone in place (rewind to its top, clear to end of
    /// screen) and drop retained geometry. `TUIRunner.suspend()` calls this
    /// before handing the terminal to a sub-flow (the `/login` OAuth
    /// handoff) so the frame vanishes instead of freezing into scrollback
    /// above the sub-flow's output. `stop()` sees `frameCleared` and skips
    /// its trailing newline.
    func clearFrame() {
        let out: String? = lock.withLock {
            guard isStarted, lastFrameHeight > 0 else { return nil }
            var s = TUI.disableAutowrap
            if lastCursorUpBy > 0 { s += "\u{1B}[\(lastCursorUpBy)B" }
            s += "\r"
            if lastFrameHeight > 1 { s += "\u{1B}[\(lastFrameHeight - 1)A" }
            // The live zone is the bottommost content, so clearing from the
            // cursor to end-of-screen wipes exactly the frame's rows.
            s += "\u{1B}[0J"
            s += TUI.enableAutowrap
            lastFrameHeight = 0
            lastCursorUpBy = 0
            lastRenderedLines = []
            rowsBelowLiveZone = 0
            frameCleared = true
            return s
        }
        if let out { terminal.write(out) }
    }

    private func handleResize() {
        let snapshotChildren: [Component] = lock.withLock { children }
        for child in snapshotChildren { child.invalidate() }
        // Leading edge + trailing coalesce: an isolated SIGWINCH repaints
        // immediately (snappy single resizes), while a drag's burst collapses
        // into one trailing repaint at the settled size instead of replaying
        // the whole transcript per step. The escape-flush timer already
        // establishes that the main queue is serviced, so a main-queue
        // `asyncAfter` fires reliably for the trailing edge.
        let immediate: Bool = lock.withLock {
            guard pendingResizeWork == nil,
                  Date().timeIntervalSince(lastResizeRepaintAt) >= Double(TUI.resizeDebounceMs) / 1000
            else { return false }
            lastResizeRepaintAt = Date()
            return true
        }
        if immediate {
            repaintForResize()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.performResizeRepaint() }
        lock.withLock {
            pendingResizeWork?.cancel()
            pendingResizeWork = work
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(TUI.resizeDebounceMs),
            execute: work
        )
    }

    private func performResizeRepaint() {
        let cancelled = lock.withLock { () -> Bool in
            if pendingResizeWork == nil { return true }
            pendingResizeWork = nil
            lastResizeRepaintAt = Date()
            return false
        }
        if cancelled { return }
        repaintForResize()
    }

    private func repaintForResize() {
        if TUI.resizeRepaintsInPlace() {
            // Multiplexer (tmux/screen/zellij): ED3 is hostile and the pane
            // reflows its own visible window, so snap + repaint it in place.
            multiplexerRepaint()
        } else {
            // Direct terminal: authoritative repaint that clears scrollback and
            // replays the whole transcript so every line re-wraps to the new
            // width. Synchronized output keeps it flicker-free.
            fullRepaint()
        }
    }

    /// True inside a terminal multiplexer, where clearing scrollback (ED3) is
    /// hostile and the pane reflows its own visible window on resize.
    private static func resizeRepaintsInPlace() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["TMUX"] != nil || env["STY"] != nil || env["ZELLIJ"] != nil { return true }
        let term = (env["TERM"] ?? "").lowercased()
        return term.hasPrefix("tmux") || term.hasPrefix("screen")
    }

    /// Clear the screen + native scrollback and replay the entire retained
    /// transcript, then the live zone. Because committed text is stored as
    /// logical lines, reprinting with autowrap on re-wraps every line to the
    /// current width — the omp "erase and replay the whole transcript on
    /// resize" behavior. Direct terminals only (callers gate on multiplexer).
    private func fullRepaint() {
        let snapshotChildren: [Component]
        let width: Int
        let termHeight: Int
        let history: [String]
        let header: [String]
        lock.lock()
        snapshotChildren = children
        width = terminal.width
        termHeight = terminal.height
        // `commit(_:)` already retained pending lines in `committedLines`.
        // A resize can arrive before the next normal render drains
        // `pendingCommits`; clear that queue so the authoritative repaint owns
        // the write without replaying the same logical lines twice.
        pendingCommits.removeAll()
        history = committedLines
        // Capture the decorative header under lock (mirrors multiplexerRepaint).
        // `headerEmitted`/`headerProvider` are shared render-state, and this
        // repaint can run off the main thread via the resize/escape-flush path.
        header = (headerEmitted ? headerProvider?(width) : nil) ?? []
        lock.unlock()

        let liveWidth = max(0, width - 1)
        var rendered: [String] = []
        for child in snapshotChildren {
            rendered.append(contentsOf: child.render(width: liveWidth))
        }
        rendered = rendered.map { ANSI.truncate($0, to: liveWidth) }
        if rendered.count > termHeight {
            rendered = Array(rendered.suffix(termHeight))
        }

        // Wrap the whole repaint in synchronized output (DEC 2026) so the
        // terminal presents it atomically — no clear-then-redraw flash even
        // when we repaint many times a second during a drag. Terminals that
        // don't support it ignore the private-mode toggles.
        var out = "\u{1B}[?2026h"
        // Home, clear screen, clear scrollback.
        out += "\u{1B}[H\u{1B}[2J\u{1B}[3J"
        out += TUI.enableAutowrap
        // Re-render the decorative header fresh at the new width so its
        // fixed-width box re-fits instead of reflowing into broken borders.
        for line in header {
            out += "\u{1B}[2K" + line + "\r\n"
        }
        // Replay history with autowrap on so the terminal re-wraps each
        // logical line to the new width. Overflow scrolls into native
        // scrollback exactly as during normal operation.
        for line in history {
            out += "\u{1B}[2K" + line + "\r\n"
        }
        // Draw the live zone (autowrap-off, cursor parked).
        let (live, upBy) = emitLiveZone(rendered)
        out += live
        out += "\u{1B}[?2026l"   // end synchronized output

        // Rows the replayed header + history occupy once the terminal wraps
        // them to the current width — the live zone's bottom edge lands that
        // far down (or at the last row once the replay overflows the screen).
        var historyPhysical = 0
        for line in header + history {
            historyPhysical += line.isEmpty ? 1 : ANSI.wrap(line, width: max(1, width)).count
        }

        lock.withLock {
            lastRenderedLines = rendered
            lastFrameHeight = rendered.count
            lastCursorUpBy = upBy
            frameCleared = false
            rowsBelowLiveZone = max(0, termHeight - historyPhysical - rendered.count)
            _fullRedraws += 1
        }
        terminal.write(out)
    }

    /// Resize repaint for a terminal multiplexer (tmux/screen/zellij). ED3
    /// (scrollback clear) is hostile in a multiplexer, and replaying the whole
    /// transcript would re-scroll it into the pane's native scrollback on every
    /// resize step (duplicating history). So instead we SNAP the viewport,
    /// exactly like omp's non-clearScrollback full paint (pi-tui emitFullPaint:
    /// `ESC[2J ESC[H` then committed-prefix + window): clear only the visible
    /// pane and reprint its bottom `height` rows — the most recent committed
    /// tail (re-wrapped to the new width) plus the live zone, with the
    /// decorative header re-rendered fresh when it still falls inside that
    /// window. Older history stays in the pane's scrollback, reflowed by the
    /// multiplexer (the same constraint omp accepts — we never ED3 here).
    private func multiplexerRepaint() {
        let snapshotChildren: [Component]
        let width: Int
        let termHeight: Int
        let history: [String]
        let header: [String]
        lock.lock()
        snapshotChildren = children
        width = terminal.width
        termHeight = terminal.height
        // A resize can arrive before the next normal render drains
        // `pendingCommits`; this repaint owns the write, so clear the queue to
        // avoid replaying the same logical lines twice.
        pendingCommits.removeAll()
        history = committedLines
        header = (headerEmitted ? headerProvider?(width) : nil) ?? []
        lock.unlock()

        let liveWidth = max(0, width - 1)
        var rendered: [String] = []
        for child in snapshotChildren {
            rendered.append(contentsOf: child.render(width: liveWidth))
        }
        rendered = rendered.map { ANSI.truncate($0, to: liveWidth) }
        if rendered.count > termHeight {
            rendered = Array(rendered.suffix(termHeight))
        }

        // Physical rows available above the live zone in the visible window.
        // Re-wrap header + committed history to the new width and keep only the
        // tail that fits, so the live zone lands at the window bottom and
        // nothing is pushed (duplicated) into the multiplexer's scrollback.
        let available = max(0, termHeight - rendered.count)
        var historyPhysical: [String] = []
        for line in header + history {
            if line.isEmpty { historyPhysical.append("") }
            else { historyPhysical.append(contentsOf: ANSI.wrap(line, width: width)) }
        }
        let onScreen = available > 0 ? Array(historyPhysical.suffix(available)) : []

        var out = "\u{1B}[?2026h"          // begin synchronized output
        out += "\u{1B}[H\u{1B}[2J"         // home + clear viewport (NOT scrollback)
        out += TUI.disableAutowrap         // rows are pre-wrapped to width
        for line in onScreen {
            out += "\u{1B}[2K" + line + "\r\n"
        }
        let (live, upBy) = emitLiveZone(rendered)
        out += live
        out += "\u{1B}[?2026l"             // end synchronized output

        lock.withLock {
            lastRenderedLines = rendered
            lastFrameHeight = rendered.count
            lastCursorUpBy = upBy
            frameCleared = false
            // The snapped window bottom-fills with history; whatever the tail
            // didn't cover stays blank below the live zone.
            rowsBelowLiveZone = max(0, available - onScreen.count)
            _fullRedraws += 1
        }
        terminal.write(out)
    }

    private func render() {
        let snapshotChildren: [Component]
        let width: Int
        let termHeight: Int
        let oldHeight: Int
        let prevCursorUpBy: Int
        let clearOnShrinkEnabled: Bool
        let oldRendered: [String]
        var committed: [String]

        // Suppress all frame output while stopped/suspended (e.g. during a
        // `/login` sub-flow that hands the terminal to another runner). A
        // background spinner tick or agent event could otherwise fire a
        // render straight into the sub-flow's screen. Pending commits stay
        // buffered and flush on the first render after `start()` resumes.
        guard lock.withLock({ isStarted }) else { return }

        lock.lock()
        snapshotChildren = children
        width = terminal.width
        termHeight = terminal.height
        oldHeight = lastFrameHeight
        prevCursorUpBy = lastCursorUpBy
        clearOnShrinkEnabled = clearOnShrink
        oldRendered = lastRenderedLines
        committed = pendingCommits
        pendingCommits.removeAll()
        let emitHeaderNow = !headerEmitted && headerProvider != nil
        if emitHeaderNow { headerEmitted = true }
        lock.unlock()

        // First frame: emit the decorative header (welcome card) into
        // scrollback above everything else.
        if emitHeaderNow, let header = headerProvider {
            committed = header(width) + committed
        }

        // Collect rendered lines from children (the live zone). Leave the
        // terminal's last column unused. Several terminals keep a
        // deferred-wrap flag after printing into the final column; a
        // following resize can then reflow the retained frame into extra
        // physical rows that our logical-height clear pass cannot see.
        let liveWidth = max(0, width - 1)

        // Collect rendered lines from children (the live zone). Cap to
        // terminal height; there's no point trying to show more live rows
        // than the terminal has.
        var rendered: [String] = []
        for child in snapshotChildren {
            rendered.append(contentsOf: child.render(width: liveWidth))
        }
        rendered = rendered.map { ANSI.truncate($0, to: liveWidth) }
        if rendered.count > termHeight {
            rendered = Array(rendered.suffix(termHeight))
        }

        // No-op suppression: the live zone is byte-for-byte what is already on
        // screen and there is nothing new to commit. The stored previous frame
        // is the source of truth, and the hardware cursor is already parked
        // correctly, so skip the write (and the terminal's repaint) entirely.
        if committed.isEmpty, !emitHeaderNow, rendered == oldRendered {
            return
        }

        // Same-height fast path: no committed lines and the live zone still has
        // the same number of rows. Rewrite only the rows that actually changed
        // instead of clearing and redrawing the whole zone — the spinner tick /
        // single-token cases touch one line but used to repaint all of them.
        if committed.isEmpty, !emitHeaderNow, oldHeight > 0, rendered.count == oldHeight {
            let (frame, newCursorUpBy) = renderInlineDiff(
                rendered: rendered,
                oldRendered: oldRendered,
                prevCursorUpBy: prevCursorUpBy
            )
            lock.withLock {
                lastRenderedLines = rendered
                lastFrameHeight = rendered.count
                lastCursorUpBy = newCursorUpBy
                frameCleared = false
            }
            terminal.write(frame)
            return
        }

        // Update the estimate of how many blank rows remain between the live
        // zone's bottom and the screen bottom: the inline redraw below reuses
        // the old zone's rows and pushes the bottom edge down by however much
        // (committed + new live) output exceeds the old height — clamped at 0,
        // where the terminal starts scrolling instead. Committed lines are
        // written raw at full terminal width (autowrap on), so measure their
        // physical rows with the same wrap the terminal will apply.
        let prevSlack = lock.withLock { rowsBelowLiveZone }
        var committedPhysical = 0
        for line in committed {
            committedPhysical += line.isEmpty ? 1 : ANSI.wrap(line, width: max(1, width)).count
        }
        let newSlack = max(0, prevSlack + oldHeight - committedPhysical - rendered.count)

        // A live zone pinned to the screen bottom (a grown frame — e.g. the
        // /model selector — scrolled history up until its bottom hit the last
        // row) that now shrinks by more rows than the committed lines refill:
        // the inline redraw below would strand the new (smaller) frame where
        // the old zone's TOP was — after a tall modal closes that's (near)
        // the very top of the screen, with nothing but blank rows underneath,
        // and every subsequent keystroke would keep redrawing it up there.
        // Fall back to the authoritative repaint instead, which re-lays the
        // committed tail and parks the live zone back against the viewport
        // bottom. The drained commits are already retained in
        // `committedLines`, so the repaint replays them without loss.
        if oldHeight > 0, prevSlack == 0, newSlack > 0 {
            repaintForResize()
            return
        }

        let shrinking = rendered.count < oldHeight && clearOnShrinkEnabled

        let (frame, newCursorUpBy) = renderInline(
            rendered: rendered,
            oldHeight: oldHeight,
            committed: committed,
            prevCursorUpBy: prevCursorUpBy
        )

        lock.withLock {
            lastRenderedLines = rendered
            lastFrameHeight = rendered.count
            lastCursorUpBy = newCursorUpBy
            frameCleared = false
            rowsBelowLiveZone = newSlack
            if shrinking { _fullRedraws += 1 }
        }

        // Wrap the live-zone update in synchronized output (DEC 2026) so the
        // rewind-clear-redraw is presented atomically — no partial-frame flicker
        // even under rapid streaming ticks. Terminals lacking support ignore the
        // private-mode toggles. (The resize repaints wrap themselves.)
        terminal.write("\u{1B}[?2026h" + frame + "\u{1B}[?2026l")
    }

    /// Same-height incremental repaint: rewind to the top of the live zone and
    /// rewrite only the rows whose text differs from `oldRendered`, then re-park
    /// the cursor. Wrapped in synchronized output. Requires
    /// `rendered.count == oldRendered.count > 0`.
    private func renderInlineDiff(
        rendered: [String],
        oldRendered: [String],
        prevCursorUpBy: Int
    ) -> (String, cursorUpBy: Int) {
        let height = rendered.count
        var out = "\u{1B}[?2026h" + TUI.disableAutowrap
        // Drop to the live-zone bottom (the cursor may be parked above it),
        // then rewind to the top-left.
        if prevCursorUpBy > 0 { out += "\u{1B}[\(prevCursorUpBy)B" }
        out += "\r"
        if height > 1 { out += "\u{1B}[\(height - 1)A" }

        var cursorTarget: (rowFromTop: Int, col: Int)?
        for i in 0..<height {
            let (cleanLine, col) = TUI.extractCursor(rendered[i])
            if let col, cursorTarget == nil { cursorTarget = (i, col) }
            let (oldClean, _) = TUI.extractCursor(oldRendered[i])
            if cleanLine != oldClean {
                // Cursor is at column 0 of row i; clear + rewrite it.
                out += "\r\u{1B}[2K" + cleanLine
            }
            // Advance to column 0 of the next row (CR handles a row we just
            // wrote mid-line; the LF steps down).
            if i < height - 1 { out += "\r\n" }
        }

        // Re-park the hardware cursor onto the focused row/column.
        var upBy = 0
        if let target = cursorTarget {
            upBy = max(0, (height - 1) - target.rowFromTop)
            if upBy > 0 { out += "\u{1B}[\(upBy)A" }
            out += "\r"
            if target.col > 0 { out += "\u{1B}[\(target.col)C" }
        } else {
            out += "\r"
        }
        out += TUI.enableAutowrap + "\u{1B}[?2026l"
        return (out, upBy)
    }

    // MARK: - Inline rendering
    //
    // Anchors at the cursor position of the first render. Subsequent renders
    // move up (oldHeight - 1) rows, rewrite, and clear any trailing rows.
    // Cursor never steps above the anchor — shell scrollback above is safe.
    //
    // Committed lines (the append-only output above the live zone) are
    // emitted between "clear old live" and "draw new live": they occupy the
    // rows that used to hold the top of the live zone, and the live zone
    // gets pushed down below them. If the combined output overflows the
    // terminal's bottom row, the terminal naturally scrolls the oldest row
    // into scrollback — which is exactly what we want for committed output
    // to persist as viewable history.

    /// Pure with respect to shared render-state: it reads the previous
    /// cursor-up offset via `prevCursorUpBy` and returns the new offset rather
    /// than touching the `lastCursorUpBy` stored property. Because `render()`
    /// can run off the main thread (the escape-flush path schedules a flush on
    /// a global queue), all shared-state access stays under the caller's lock —
    /// this function mutates nothing observable.
    private func renderInline(
        rendered: [String],
        oldHeight: Int,
        committed: [String],
        prevCursorUpBy: Int
    ) -> (String, cursorUpBy: Int) {
        var out = ""

        // Step 1: rewind to the top of the previous live zone.
        if oldHeight > 0 {
            out += TUI.disableAutowrap
            // The previous frame may have parked the cursor above the live
            // zone bottom (focused row isn't the last row). Drop back down to
            // the bottom first so the rewind below lands on the right row.
            if prevCursorUpBy > 0 {
                out += "\u{1B}[\(prevCursorUpBy)B"
            }
            out += "\r"
            if oldHeight > 1 {
                out += "\u{1B}[\(oldHeight - 1)A"
            }
            // Clear oldHeight rows in place so leftover content doesn't
            // bleed through when the new frame is shorter than the old.
            for i in 0..<oldHeight {
                out += "\u{1B}[2K"
                if i < oldHeight - 1 { out += "\u{1B}[B" }
            }
            // Back to the top of the cleared area.
            out += "\r"
            if oldHeight > 1 {
                out += "\u{1B}[\(oldHeight - 1)A"
            }
            out += TUI.enableAutowrap
        }

        // Step 2: emit committed lines as permanent output. Lines are written
        // raw so the terminal can autowrap long output exactly like stdout.
        // Each line ends in \r\n so the cursor advances to a fresh row
        // afterwards.
        // If the total committed + live output is taller than what fits
        // below the current cursor, the terminal's built-in scroll
        // behavior kicks in — rows at the top slide up into scrollback,
        // which is the whole point of this path.
        for line in committed {
            out += "\u{1B}[2K"   // clear any stale cell content on this row
            out += line
            out += "\r\n"
        }

        // Step 3+4: draw the live frame and park the cursor.
        let (live, upBy) = emitLiveZone(rendered)
        out += live

        return (out, upBy)
    }

    /// Emit the live-zone rows at the current cursor (assumed to be at the
    /// top-left of the zone). Returns the escape string plus the number of
    /// rows the cursor was parked above the zone bottom (so the next frame
    /// can drop back down before rewinding). Autowrap is disabled while
    /// drawing; a trailing `CSI 0 J` wipes any reflow remnants below.
    private func emitLiveZone(_ rendered: [String]) -> (String, cursorUpBy: Int) {
        guard !rendered.isEmpty else { return ("", 0) }
        var out = TUI.disableAutowrap
        var cursorTarget: (rowFromTop: Int, col: Int)?
        for (i, rawLine) in rendered.enumerated() {
            let (cleanLine, col) = TUI.extractCursor(rawLine)
            if let col, cursorTarget == nil { cursorTarget = (i, col) }
            out += "\u{1B}[2K"
            out += cleanLine
            if i < rendered.count - 1 { out += "\r\n" }
        }
        // Erase cursor→end-of-screen: the live zone is the bottommost content,
        // so this safely wipes wrapped remnants a width-shrink reflowed below.
        out += "\u{1B}[0J"
        var upBy = 0
        if let target = cursorTarget {
            upBy = max(0, (rendered.count - 1) - target.rowFromTop)
            if upBy > 0 { out += "\u{1B}[\(upBy)A" }
            out += "\r"
            if target.col > 0 { out += "\u{1B}[\(target.col)C" }
        }
        out += TUI.enableAutowrap
        return (out, upBy)
    }

    /// Strip a CURSOR_MARKER from the line, returning the cleaned text and
    /// the visible column (ANSI-agnostic) the marker sat at.
    static func extractCursor(_ line: String) -> (String, Int?) {
        guard let range = line.range(of: CURSOR_MARKER) else { return (line, nil) }
        let before = String(line[..<range.lowerBound])
        let after = String(line[range.upperBound...])
        return (before + after, ANSI.visibleWidth(before))
    }
}
