import Foundation

/// Retained-mode TUI runtime. Two render strategies:
///
/// - `.inline` (default, matches Claude Code's behavior): anchor at the
///   current cursor position, grow downward. Children form the **live zone**,
///   which is redrawn in place on every render. A separate `commit(_:)`
///   API writes lines ABOVE the live zone as append-only output — those
///   lines flow into the terminal's native scrollback exactly like
///   ordinary stdout, so users can scroll up to see history. Subsequent
///   renders move back up `liveHeight - 1` rows, rewrite the live zone,
///   and clear any trailing rows. Committed content is NOT repainted,
///   which means it can't be re-wrapped on resize — same constraint Ink
///   has with its `<Static>` component.
///
/// - `.alternate`: enter the alternate screen buffer on start and restore the
///   original screen on stop. For full-screen apps that don't care about
///   preserving scrollback. `commit(_:)` is a no-op in this mode (there's no
///   scrollback to write into).
final class TUI: @unchecked Sendable {
    enum RenderMode: Sendable { case inline, alternate }

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
    private var isStarted: Bool = false
    private var clearOnShrink: Bool = true
    private var resizeUnsubscribe: (() -> Void)?
    private var _fullRedraws: Int = 0
    private var renderMode: RenderMode = .inline
    private var hideCursor: Bool = false

    private static let disableAutowrap = "\u{1B}[?7l"
    private static let enableAutowrap = "\u{1B}[?7h"

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func setRenderMode(_ mode: RenderMode) {
        lock.withLock { renderMode = mode }
    }

    /// Legacy helper for backwards compatibility with earlier API.
    func setUseAlternateScreen(_ value: Bool) {
        setRenderMode(value ? .alternate : .inline)
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
        let (mode, hide) = lock.withLock { (renderMode, hideCursor) }
        if mode == .alternate { prologue += "\u{1B}[?1049h\u{1B}[H" }
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
            let (mode, hide) = lock.withLock { (renderMode, hideCursor) }
            var epilogue = TUI.enableAutowrap
            if hide { epilogue += "\u{1B}[?25h" }
            if mode == .alternate {
                epilogue += "\u{1B}[?1049l"
            } else {
                // Inline mode: leave the final frame on screen and move cursor
                // to a fresh line so the shell prompt appears below us.
                epilogue += "\r\n"
            }
            if !epilogue.isEmpty { terminal.write(epilogue) }
        }
    }

    // MARK: - Rendering

    func requestRender() {
        render(forceFullRedraw: false)
    }

    /// Queue `lines` to be written as append-only output above the live
    /// zone on the next render. Lines are written raw; if a committed line is
    /// wider than the terminal, the terminal's native autowrap owns the visual
    /// continuation rows. This is safe for committed output because it is never
    /// redrawn as part of the retained live frame.
    ///
    /// In `.alternate` mode there's no scrollback to target, so this is
    /// a no-op. Callers that want to display the same content in both
    /// modes should also put it somewhere in the live child tree.
    func commit(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.withLock {
            pendingCommits.append(contentsOf: lines)
        }
    }

    func setClearOnShrink(_ value: Bool) {
        lock.withLock { clearOnShrink = value }
    }

    var fullRedraws: Int {
        lock.withLock { _fullRedraws }
    }

    private func handleResize() {
        let snapshotChildren: [Component] = lock.withLock { children }
        for child in snapshotChildren { child.invalidate() }
        render(forceFullRedraw: true)
    }

    private func render(forceFullRedraw: Bool) {
        let snapshotChildren: [Component]
        let width: Int
        let termHeight: Int
        let oldHeight: Int
        let mode: RenderMode
        let clearOnShrinkEnabled: Bool
        let committed: [String]

        lock.lock()
        snapshotChildren = children
        width = terminal.width
        termHeight = terminal.height
        oldHeight = lastFrameHeight
        mode = renderMode
        clearOnShrinkEnabled = clearOnShrink
        committed = pendingCommits
        pendingCommits.removeAll()
        lock.unlock()

        // Collect rendered lines from children (the live zone). In inline
        // mode leave the terminal's last column unused. Several terminals
        // keep a deferred-wrap flag after printing into the final column;
        // a following resize can then reflow the retained frame into extra
        // physical rows that our logical-height clear pass cannot see.
        let liveWidth = mode == .inline ? max(0, width - 1) : width

        // Collect rendered lines from children (the live zone). Cap to
        // terminal height; there's no point trying to show more live rows
        // than the terminal has.
        var rendered: [String] = []
        for child in snapshotChildren {
            rendered.append(contentsOf: child.render(width: liveWidth))
        }
        if mode == .inline {
            rendered = rendered.map { ANSI.truncate($0, to: liveWidth) }
        }
        if rendered.count > termHeight {
            rendered = Array(rendered.suffix(termHeight))
        }

        let shrinking = rendered.count < oldHeight && clearOnShrinkEnabled
        let doFullRedraw = forceFullRedraw || shrinking

        lock.withLock {
            lastRenderedLines = rendered
            lastFrameHeight = rendered.count
            if doFullRedraw { _fullRedraws += 1 }
        }

        switch mode {
        case .alternate:
            // Alternate screen has no scrollback — committed output has
            // nowhere to go. Drop it; callers that want content in both
            // modes should keep it in the live tree too.
            terminal.write(renderAlternate(
                rendered: rendered,
                oldHeight: oldHeight,
                forceFullRedraw: forceFullRedraw,
                shrinking: shrinking
            ))
        case .inline:
            terminal.write(renderInline(
                rendered: rendered,
                oldHeight: oldHeight,
                committed: committed,
                forceFullRedraw: forceFullRedraw
            ))
        }
    }

    // MARK: - Alternate screen rendering

    private func renderAlternate(
        rendered: [String],
        oldHeight: Int,
        forceFullRedraw: Bool,
        shrinking: Bool
    ) -> String {
        var out = TUI.disableAutowrap + "\u{1B}[H"
        if forceFullRedraw {
            out += "\u{1B}[2J\u{1B}[H"
        }
        var cursorTarget: (row: Int, col: Int)?
        for (i, rawLine) in rendered.enumerated() {
            let (cleanLine, col) = TUI.extractCursor(rawLine)
            if let col, cursorTarget == nil { cursorTarget = (i + 1, col + 1) } // 1-based
            out += cleanLine + "\u{1B}[K"
            if i < rendered.count - 1 { out += "\r\n" }
        }
        if shrinking {
            for _ in 0..<(oldHeight - rendered.count) {
                out += "\r\n\u{1B}[K"
            }
        }
        if let target = cursorTarget {
            out += "\u{1B}[\(target.row);\(target.col)H"
        }
        out += TUI.enableAutowrap
        return out
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

    private func renderInline(
        rendered: [String],
        oldHeight: Int,
        committed: [String],
        forceFullRedraw: Bool
    ) -> String {
        var out = ""

        // Step 1: rewind to the top of the previous live zone.
        if oldHeight > 0 {
            out += TUI.disableAutowrap
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

        // Step 3: draw the live frame. `\r\n` between rows; no trailing
        // `\r\n` so the cursor lands at the end of the last line, where
        // we may further position it for the focused component.
        var cursorTarget: (rowFromTop: Int, col: Int)?
        if !rendered.isEmpty {
            // The retained live frame owns its rows and repaints them by
            // logical height. Temporarily disable terminal autowrap so
            // exact-width live rows do not become soft-wrapped scrollback
            // lines during terminal resize.
            out += TUI.disableAutowrap
            for (i, rawLine) in rendered.enumerated() {
                let (cleanLine, col) = TUI.extractCursor(rawLine)
                if let col, cursorTarget == nil { cursorTarget = (i, col) }
                out += "\u{1B}[2K"
                out += cleanLine
                if i < rendered.count - 1 { out += "\r\n" }
            }

            // Step 4: reposition the hardware cursor to wherever the focused
            // component asked. Cursor is currently at (bottom_row,
            // visibleWidth(lastLine)) of the live zone.
            if let target = cursorTarget {
                let upBy = (rendered.count - 1) - target.rowFromTop
                if upBy > 0 { out += "\u{1B}[\(upBy)A" }
                out += "\r"
                if target.col > 0 { out += "\u{1B}[\(target.col)C" }
            }
            out += TUI.enableAutowrap
        }

        _ = forceFullRedraw
        return out
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
