import Foundation
import KWTUI

/// Claude-Code-style layout: header, transcript body (viewport-clipped),
/// divider, status line, input row with an `❯` prompt. CodingLayout holds the
/// components and knows how to fit them to a terminal height; the caller is
/// responsible for owning the `TUI` instance and adding the components in
/// order.
public final class CodingLayout: @unchecked Sendable {
    public let header: TextComponent
    public let transcript: TextComponent
    public let divider: HorizontalRule
    public let status: TextComponent
    public let input: InputComponent
    public let promptRow: PromptRow

    /// Rows used by everything except the transcript body. The body's
    /// `maxLines` is set to `terminalHeight - reservedRows` each render cycle.
    public let reservedRows: Int

    public init() {
        self.header = TextComponent([])
        self.transcript = TextComponent([])
        self.divider = HorizontalRule("─")
        self.status = TextComponent([])
        self.input = InputComponent()
        self.promptRow = PromptRow(prompt: Style.prompt("❯ "), input: input)

        //   header:     3
        //   blank:      1
        //   divider:    1
        //   status:     1
        //   blank:      1
        //   prompt:     1
        self.reservedRows = 3 + 1 + 1 + 1 + 1 + 1
    }

    /// Install layout components into `tui` in display order. Call once at
    /// setup time.
    public func install(into tui: TUI) {
        tui.addChild(header)
        tui.addChild(TextComponent([""]))
        tui.addChild(transcript)
        tui.addChild(divider)
        tui.addChild(status)
        tui.addChild(TextComponent([""]))
        tui.addChild(promptRow)
    }

    /// Current transcript height budget; updated on every fitViewport call.
    private var transcriptBudget: Int = 20

    /// Last set of transcript lines (unpadded). Stored so `fitViewport` can
    /// repad the transcript when the terminal resizes.
    private var currentLines: [String] = []

    /// Recompute `transcript.maxLines` based on the terminal's current height
    /// and re-pad the content so the tail stays glued to the bottom of the
    /// transcript region.
    public func fitViewport(height: Int) {
        transcriptBudget = max(1, height - reservedRows)
        transcript.maxLines = transcriptBudget
        applyPaddedLines()
    }

    /// Replace the whole transcript line list. Pads with empty rows at the
    /// top so the most recent content sits at the bottom of the viewport
    /// (classic chat layout).
    public func setTranscript(_ lines: [String]) {
        currentLines = lines
        applyPaddedLines()
    }

    private func applyPaddedLines() {
        let tail = currentLines.suffix(transcriptBudget)
        let pad = max(0, transcriptBudget - tail.count)
        transcript.lines = Array(repeating: "", count: pad) + Array(tail)
        transcript.invalidate()
    }
}

/// Composes `prompt + input` on a single rendered row so we don't burn an
/// extra row on a standalone prompt character.
public final class PromptRow: Component, Focusable, @unchecked Sendable {
    public let prompt: String
    public let input: InputComponent
    public var wantsKeyRelease: Bool { input.wantsKeyRelease }

    public init(prompt: String, input: InputComponent) {
        self.prompt = prompt
        self.input = input
    }

    public func render(width: Int) -> [String] {
        let promptWidth = ANSI.visibleWidth(prompt)
        let inner = input.render(width: max(1, width - promptWidth))
        let body = inner.first ?? ""
        return [prompt + body]
    }

    public func handleInput(_ data: String) { input.handleInput(data) }
    public func invalidate() { input.invalidate() }

    public var focused: Bool {
        get { input.focused }
        set { input.focused = newValue }
    }
}
