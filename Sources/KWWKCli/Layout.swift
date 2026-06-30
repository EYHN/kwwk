import Foundation

/// Claude-Code-style layout for the live zone — everything below the
/// committed scrollback. The header is printed once at startup (see
/// `CodingTUI`) and scrolls away like any other output, so it isn't part
/// of this component tree.
///
/// Components in render order:
///
///   liveTail   — streaming assistant text + running tool placeholders +
///                transient notifications. Height is bounded (rendered
///                content only, no viewport padding).
///   status     — compact metadata line + state line. This also acts as
///                the visual separator above the prompt area.
///   queue      — persistent list of queued steering messages. Zero rows
///                when empty so the layout collapses cleanly.
///   prompt     — the `❯ …` input row.
final class CodingLayout: @unchecked Sendable {
    let liveTail: TextComponent
    let status: TextComponent
    let queue: TextComponent
    let input: InputComponent
    let promptRow: PromptRow

    /// How many rows the status block occupies. Defaults to 2: metadata
    /// line + state line.
    let statusRows: Int

    init(statusRows: Int = 2) {
        self.liveTail = TextComponent([])
        self.status = TextComponent([])
        self.queue = TextComponent([])
        self.input = InputComponent()
        self.promptRow = PromptRow(prompt: Style.prompt("❯ "), input: input)

        self.statusRows = statusRows
    }

    /// Install layout components into `tui` in display order. Call once at
    /// setup time.
    ///
    /// The status row is the separator between transcript output and input.
    /// A full-width divider is intentionally avoided in inline mode because
    /// exact-width rows interact badly with terminal resize/reflow.
    func install(into tui: TUI) {
        tui.addChild(liveTail)
        tui.addChild(status)
        tui.addChild(queue)
        tui.addChild(promptRow)
    }

    /// Last terminal height seen. Tracked so callers can clip the live
    /// tail to a sensible size when the tail grows large (e.g. a wall
    /// of streaming assistant text mid-turn) — without it the live zone
    /// could push the prompt below the visible area.
    private(set) var lastTerminalHeight: Int = 20
    /// Last terminal width seen. Needed because `promptRow` can now
    /// wrap across several rows, and its visual height depends on the
    /// terminal's column count.
    private(set) var lastTerminalWidth: Int = 80

    /// Current tail lines (unclipped).
    private var tailLines: [String] = []

    /// Rows consumed by the non-tail parts of the live zone at the
    /// last-observed terminal size: status(statusRows) +
    /// queue.lines.count + promptRow.height.
    ///
    /// The prompt row is multi-line once the user soft-wraps the input
    /// or hits Ctrl+Enter, so its height varies per render.
    var nonTailRows: Int {
        statusRows + queue.lines.count + promptHeight
    }

    /// Visual height of the prompt row at the current terminal width.
    /// Reads the rendered line count — the component is cached so
    /// repeated calls are cheap.
    private var promptHeight: Int {
        max(1, promptRow.render(width: lastTerminalWidth).count)
    }

    /// Current budget for the live tail — how many rows the tail can
    /// occupy before it overruns the fixed live-zone elements. Callers
    /// that want to spill overflow into scrollback use this to decide
    /// when to commit.
    var liveTailBudget: Int {
        max(0, lastTerminalHeight - nonTailRows)
    }

    /// Recompute the tail's height budget based on the terminal size and
    /// reapply the current tail content. Called on resize + whenever the
    /// queue area grows/shrinks. Pass the terminal's current width so
    /// the prompt-row height (which can wrap) stays in sync.
    func fitViewport(height: Int, width: Int? = nil) {
        lastTerminalHeight = height
        if let width { lastTerminalWidth = width }
        applyTail()
    }

    /// Replace the live tail's contents (streaming text, running tool
    /// markers, transient notifications). Clipped to whatever fits above
    /// the fixed rows; if the tail is shorter than the budget we just
    /// show all of it — no top-padding (committed scrollback sits above).
    func setLiveTail(_ lines: [String]) {
        tailLines = lines
        applyTail()
    }

    /// Replace the queue panel's contents. Automatically re-fits so the
    /// tail budget updates.
    func setQueueLines(_ lines: [String]) {
        queue.lines = lines
        queue.invalidate()
        applyTail()
    }

    private func applyTail() {
        let budget = max(0, lastTerminalHeight - nonTailRows)
        let clipped: [String]
        if tailLines.count > budget {
            // Keep the tail of the tail — most recent content.
            clipped = Array(tailLines.suffix(budget))
        } else {
            clipped = tailLines
        }
        liveTail.lines = clipped
        liveTail.invalidate()
    }
}

/// Composes `prompt + input` as a (possibly multi-row) block. The first
/// visual row carries the `❯ ` prefix; continuation rows (from soft-
/// wrapping or explicit `\n`s) are indented by the prompt's visible
/// width so the body reads as one aligned paragraph.
///
///   ❯ this line is long enough that it wraps
///     onto a second continuation row
///     with a literal newline in between
///     and keeps going
final class PromptRow: Component, Focusable, @unchecked Sendable {
    let prompt: String
    let input: InputComponent
    var wantsKeyRelease: Bool { input.wantsKeyRelease }
    var ghostHintProvider: ((String) -> String?)?

    init(prompt: String, input: InputComponent) {
        self.prompt = prompt
        self.input = input
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        let promptWidth = ANSI.visibleWidth(prompt)
        if width <= promptWidth {
            return [ANSI.truncate(prompt, to: width)]
        }
        let innerWidth = max(1, width - promptWidth)
        let inner = renderInputRows(width: innerWidth)
        guard !inner.isEmpty else { return [prompt] }
        let indent = String(repeating: " ", count: promptWidth)
        var out: [String] = []
        for (i, row) in inner.enumerated() {
            out.append(i == 0 ? prompt + row : indent + row)
        }
        return out
    }

    func handleInput(_ data: String) { input.handleInput(data) }
    func invalidate() { input.invalidate() }

    var focused: Bool {
        get { input.focused }
        set { input.focused = newValue }
    }

    private func renderInputRows(width: Int) -> [String] {
        var rows = input.render(width: width)
        guard focused,
              input.cursor == input.value.count,
              let hint = ghostHintProvider?(input.value),
              !hint.isEmpty,
              var last = rows.popLast()
        else { return rows }

        let available = max(0, width - ANSI.visibleWidth(last))
        guard available > 0 else {
            rows.append(last)
            return rows
        }
        let visibleHint = ANSI.truncate(hint, to: available)
        guard !visibleHint.isEmpty else {
            rows.append(last)
            return rows
        }
        last += Style.dimmed(visibleHint)
        rows.append(last)
        return rows
    }
}
