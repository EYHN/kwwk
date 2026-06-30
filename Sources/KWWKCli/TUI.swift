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
    private var hideCursor: Bool = false
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

    private static let disableAutowrap = "\u{1B}[?7l"
    private static let enableAutowrap = "\u{1B}[?7h"

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func setHideCursor(_ value: Bool) {
        lock.withLock { hideCursor = value }
    }

    // MARK: - Tree manipulation

    func addChild(_ component: Component) {
        lock.withLock { children.append(component) }
    }

    func removeChild(_ component: Component) {
        lock.withLock { children.removeAll { $0 === component } }
    }

    // MARK: - Lifecycle

    func start() {
        let alreadyStarted: Bool = lock.withLock {
            if isStarted { return true }
            isStarted = true
            return false
        }
        if alreadyStarted { return }

        var prologue = ""
        let hide = lock.withLock { hideCursor }
        if hide { prologue += "\u{1B}[?25l" }
        if !prologue.isEmpty { terminal.write(prologue) }

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
        if wasStarted {
            let (hide, cursorUpBy) = lock.withLock { (hideCursor, lastCursorUpBy) }
            var epilogue = TUI.enableAutowrap
            if hide { epilogue += "\u{1B}[?25h" }
            // The hardware cursor may be parked above the live-zone bottom
            // (inside a prompt box). Drop to the bottom before moving to a
            // fresh line so the shell prompt appears below the final frame,
            // not inside it.
            if cursorUpBy > 0 { epilogue += "\u{1B}[\(cursorUpBy)B" }
            epilogue += "\r\n"
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

    private func handleResize() {
        let snapshotChildren: [Component] = lock.withLock { children }
        for child in snapshotChildren { child.invalidate() }
        let inlineDirect = !TUI.resizeRepaintsInPlace()
        if inlineDirect {
            // Direct terminal: authoritative repaint that clears scrollback and
            // replays the whole transcript so every line re-wraps to the new
            // width — synchronously on every SIGWINCH, no throttle, so resize
            // tracks the drag with zero latency. Synchronized output keeps it
            // flicker-free even at drag rates.
            fullRepaint()
        } else {
            // Multiplexer (tmux/screen/zellij): ED3 is hostile and the pane
            // reflows its own visible window, so snap + repaint it in place.
            multiplexerRepaint()
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

        lock.withLock {
            lastRenderedLines = rendered
            lastFrameHeight = rendered.count
            lastCursorUpBy = upBy
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
        var committed: [String]

        lock.lock()
        snapshotChildren = children
        width = terminal.width
        termHeight = terminal.height
        oldHeight = lastFrameHeight
        prevCursorUpBy = lastCursorUpBy
        clearOnShrinkEnabled = clearOnShrink
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
            if shrinking { _fullRedraws += 1 }
        }

        terminal.write(frame)
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
