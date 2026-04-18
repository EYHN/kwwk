import Foundation

/// Retained-mode TUI runtime. Two render strategies:
///
/// - `.inline` (default, matches Claude Code's behavior): anchor at the
///   current cursor position, grow downward. On first render we simply write
///   our frame at the cursor — if there isn't enough room, the terminal
///   scrolls the shell's previous output up into scrollback, exactly like a
///   normal program's output. Subsequent renders move back up N-1 rows,
///   rewrite lines in place, and clear any trailing rows from the previous
///   frame.
///
/// - `.alternate`: enter the alternate screen buffer on start and restore the
///   original screen on stop. For full-screen apps that don't care about
///   preserving scrollback.
public final class TUI: @unchecked Sendable {
    public enum RenderMode: Sendable { case inline, alternate }

    private let terminal: Terminal
    private let lock = NSLock()
    private var children: [Component] = []
    private var lastFrameHeight: Int = 0
    private var lastRenderedLines: [String] = []
    private var isStarted: Bool = false
    private var clearOnShrink: Bool = true
    private var resizeUnsubscribe: (() -> Void)?
    private var _fullRedraws: Int = 0
    private var renderMode: RenderMode = .inline
    private var hideCursor: Bool = false

    public init(terminal: Terminal) {
        self.terminal = terminal
    }

    public func setRenderMode(_ mode: RenderMode) {
        lock.withLock { renderMode = mode }
    }

    /// Legacy helper for backwards compatibility with earlier API.
    public func setUseAlternateScreen(_ value: Bool) {
        setRenderMode(value ? .alternate : .inline)
    }

    public func setHideCursor(_ value: Bool) {
        lock.withLock { hideCursor = value }
    }

    // MARK: - Tree manipulation

    public func addChild(_ component: Component) {
        lock.withLock { children.append(component) }
    }

    public func removeChild(_ component: Component) {
        lock.withLock { children.removeAll { $0 === component } }
    }

    // MARK: - Lifecycle

    public func start() {
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

    public func stop() {
        let wasStarted: Bool = lock.withLock {
            let prev = isStarted
            isStarted = false
            return prev
        }
        resizeUnsubscribe?()
        resizeUnsubscribe = nil
        if wasStarted {
            let (mode, hide) = lock.withLock { (renderMode, hideCursor) }
            var epilogue = ""
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

    public func requestRender() {
        render(forceFullRedraw: false)
    }

    public func setClearOnShrink(_ value: Bool) {
        lock.withLock { clearOnShrink = value }
    }

    public var fullRedraws: Int {
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
        let oldLines: [String]
        let oldHeight: Int
        let mode: RenderMode
        let clearOnShrinkEnabled: Bool

        lock.lock()
        snapshotChildren = children
        width = terminal.width
        termHeight = terminal.height
        oldLines = lastRenderedLines
        oldHeight = lastFrameHeight
        mode = renderMode
        clearOnShrinkEnabled = clearOnShrink
        lock.unlock()

        // Collect rendered lines from children, cap to terminal height.
        var rendered: [String] = []
        for child in snapshotChildren {
            rendered.append(contentsOf: child.render(width: width))
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
        var out = "\u{1B}[H"
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
        return out
    }

    // MARK: - Inline rendering
    //
    // Anchors at the cursor position of the first render. Subsequent renders
    // move up (oldHeight - 1) rows, rewrite, and clear any trailing rows.
    // Cursor never steps above the anchor — shell scrollback above is safe.

    private func renderInline(
        rendered: [String],
        oldHeight: Int,
        forceFullRedraw: Bool
    ) -> String {
        var out = ""

        // If we've rendered before, wind the cursor back to the frame top and
        // clear the existing frame. That way we don't have to reason about
        // diffing old and new line by line — simpler than pi-tui's approach,
        // but correct, and fast enough at interactive rates.
        if oldHeight > 0 {
            out += "\r"
            if oldHeight > 1 {
                out += "\u{1B}[\(oldHeight - 1)A"
            }
            for i in 0..<oldHeight {
                out += "\u{1B}[2K"
                if i < oldHeight - 1 { out += "\r\n" }
            }
            // Cursor is now at column 0 of the last cleared row. Move back up
            // to the top row of the region so we can redraw there.
            out += "\r"
            if oldHeight > 1 {
                out += "\u{1B}[\(oldHeight - 1)A"
            }
        }

        // Draw new frame. `\r\n` between rows; no trailing `\r\n` so the
        // cursor lands at the end of the last line.
        var cursorTarget: (rowFromTop: Int, col: Int)?
        for (i, rawLine) in rendered.enumerated() {
            let (cleanLine, col) = TUI.extractCursor(rawLine)
            if let col, cursorTarget == nil { cursorTarget = (i, col) }
            out += cleanLine
            if i < rendered.count - 1 { out += "\r\n" }
        }

        // Reposition the hardware cursor to wherever the focused component
        // asked. Cursor is currently at (bottom_row, visibleWidth(lastLine)).
        if let target = cursorTarget {
            let upBy = (rendered.count - 1) - target.rowFromTop
            if upBy > 0 { out += "\u{1B}[\(upBy)A" }
            out += "\r"
            if target.col > 0 { out += "\u{1B}[\(target.col)C" }
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
