import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

/// Small component whose lines can be mutated between renders.
final class TestLinesComponent: Component, @unchecked Sendable {
    var lines: [String]
    init(_ lines: [String] = []) { self.lines = lines }
    func render(width: Int) -> [String] { lines }
    func invalidate() {}
}

@Suite("TUI resize handling")
struct TUIResizeTests {
    @Test("triggers full re-render when height changes")
    func heightChange() async throws {
        let terminal = VirtualTerminal(width: 40, height: 10)
        let tui = TUI(terminal: terminal)
        let comp = TestLinesComponent(["Line 0", "Line 1", "Line 2"])
        tui.addChild(comp)
        tui.start()
        await terminal.waitForRender()

        let initial = tui.fullRedraws
        terminal.resize(width: 40, height: 15)
        await terminal.waitForRender()

        #expect(tui.fullRedraws > initial)
        let viewport = terminal.getViewport()
        #expect(viewport[0].contains("Line 0"))
        tui.stop()
    }

    @Test("triggers full re-render when width changes")
    func widthChange() async throws {
        let terminal = VirtualTerminal(width: 40, height: 10)
        let tui = TUI(terminal: terminal)
        tui.addChild(TestLinesComponent(["Hello"]))
        tui.start()
        await terminal.waitForRender()

        let initial = tui.fullRedraws
        terminal.resize(width: 60, height: 10)
        await terminal.waitForRender()

        #expect(tui.fullRedraws > initial)
        tui.stop()
    }
}

@Suite("TUI content shrinkage")
struct TUIShrinkageTests {
    @Test("clears empty rows when content shrinks")
    func shrinkClears() async throws {
        let terminal = VirtualTerminal(width: 40, height: 10)
        let tui = TUI(terminal: terminal)
        tui.setClearOnShrink(true)
        let comp = TestLinesComponent(["Line 0", "Line 1", "Line 2", "Line 3", "Line 4", "Line 5"])
        tui.addChild(comp)
        tui.start()
        await terminal.waitForRender()

        let initial = tui.fullRedraws
        comp.lines = ["Line 0", "Line 1"]
        tui.requestRender()
        await terminal.waitForRender()

        #expect(tui.fullRedraws > initial)
        let viewport = terminal.getViewport()
        #expect(viewport[0].contains("Line 0"))
        #expect(viewport[1].contains("Line 1"))
        #expect(viewport[2].trimmingCharacters(in: .whitespaces) == "")
        #expect(viewport[3].trimmingCharacters(in: .whitespaces) == "")
        tui.stop()
    }

    @Test("shrinking to a single line clears remaining rows")
    func shrinkSingleLine() async throws {
        let terminal = VirtualTerminal(width: 40, height: 10)
        let tui = TUI(terminal: terminal)
        tui.setClearOnShrink(true)
        let comp = TestLinesComponent(["Line 0", "Line 1", "Line 2", "Line 3"])
        tui.addChild(comp)
        tui.start()
        await terminal.waitForRender()

        comp.lines = ["Only line"]
        tui.requestRender()
        await terminal.waitForRender()

        let viewport = terminal.getViewport()
        #expect(viewport[0].contains("Only line"))
        #expect(viewport[1].trimmingCharacters(in: .whitespaces) == "")
        tui.stop()
    }
}

@Suite("Text component")
struct TextComponentTests {
    @Test("renders lines and truncates to viewport width")
    func truncatesToWidth() {
        let comp = TextComponent(["Hello, world!"])
        let rendered = comp.render(width: 5)
        #expect(rendered.count == 1)
        #expect(rendered[0].count <= 5)
    }

    @Test("caches output for the same input and width")
    func cachesRender() {
        let comp = TextComponent(["Hello"])
        let a = comp.render(width: 10)
        let b = comp.render(width: 10)
        // Cache implementation detail: second call returns the same strings.
        #expect(a == b)
    }

    @Test("invalidate clears the cache")
    func invalidateClearsCache() {
        let comp = TextComponent(["Hello"])
        _ = comp.render(width: 10)
        comp.invalidate()
        comp.lines = ["World"]
        let after = comp.render(width: 10)
        #expect(after == ["World"])
    }
}

@Suite("Container")
struct ContainerTests {
    @Test("stacks children vertically")
    func stacks() {
        let container = Container()
        container.addChild(TextComponent(["A", "B"]))
        container.addChild(TextComponent(["C"]))
        let rendered = container.render(width: 10)
        #expect(rendered == ["A", "B", "C"])
    }

    @Test("clear removes all children")
    func clear() {
        let container = Container()
        container.addChild(TextComponent(["X"]))
        container.clear()
        #expect(container.children.isEmpty)
        #expect(container.render(width: 10).isEmpty)
    }
}

@Suite("Prompt row")
struct PromptRowTests {
    @Test("prompt row renders slash completion as a dimmed ghost suffix")
    func promptRowRendersSlashCompletionHint() {
        let input = InputComponent(initial: "/mod")
        let row = PromptRow(prompt: Style.prompt("❯ "), input: input)
        row.focused = true
        row.ghostHintProvider = { value in
            slashCompletion(for: value, commandNames: ["model", "queue"])?.suffix
        }

        let rendered = row.render(width: 40).joined(separator: "\n")
        #expect(rendered.contains("/mod"))
        #expect(rendered.contains("el"))
        #expect(rendered.contains(Style.dim))
        #expect(ANSI.visibleWidth(rendered) < 40)
    }

    @Test("prompt row never exceeds extremely narrow widths")
    func promptRowStaysWithinNarrowWidths() {
        let input = InputComponent(initial: "/model")
        let row = PromptRow(prompt: Style.prompt("❯ "), input: input)
        row.focused = true
        row.ghostHintProvider = { _ in " extra" }

        for width in 0...2 {
            let rendered = row.render(width: width)
            #expect(!rendered.isEmpty)
            #expect(rendered.allSatisfy { ANSI.visibleWidth($0) <= width })
        }
    }
}

@Suite("Coding live zone")
struct CodingFrameTests {
    @Test("renders the live tail + breadcrumb prompt box")
    func liveZone() {
        let frame = CodingFrame(viewportHeight: 12)
        frame.breadcrumb = Theme.accentText("gpt-5.4")
        frame.metaRight = Theme.faintText("reasoning medium")
        frame.stateLine = Theme.faintText("ready")
        frame.setLiveLines([
            "",
            Style.tool("● bash(cmd: \"ls\")"),
            Style.running("  ⎿  calling…"),
        ])

        let lines = frame.render(width: 40)

        // Breadcrumb on the prompt box top border, running tool in the tail.
        #expect(lines.contains(where: { $0.contains("gpt-5.4") }))
        #expect(lines.contains(where: { $0.contains("calling") }))
        // Rounded box borders are present.
        #expect(lines.contains(where: { $0.contains("╭") }))
        #expect(lines.contains(where: { $0.contains("╰") }))
        #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= 40 })
    }

    @Test("clips the live tail so the prompt box stays visible")
    func tailNeverHidesPrompt() {
        let frame = CodingFrame(viewportHeight: 6)
        frame.setLiveLines((0..<50).map { "line \($0)" })

        let lines = frame.render(width: 30)

        // Prompt box bottom border must survive even with an overlong tail.
        #expect(lines.contains(where: { $0.contains("╰") }))
        #expect(lines.count <= 6 + 2) // tail clipped to the viewport budget
    }

    @Test("queued prompts render as a dim list above the prompt box")
    func queuedPromptsAboveBox() {
        let frame = CodingFrame(viewportHeight: 12)
        frame.setLiveLines([Style.tool("● bash(cmd: \"sleep 5\")")])
        frame.queuedPrompts = ["fix the failing test", "then update the docs"]

        let lines = frame.render(width: 50)
        let plain = lines.map { ANSI.stripEscapes($0) }
        let joined = plain.joined(separator: "\n")

        #expect(joined.contains("fix the failing test"))
        #expect(joined.contains("then update the docs"))
        // Edit/drop hint is present.
        #expect(joined.contains("↑ edit"))
        // The queued list sits above the prompt box, not below it.
        let firstQueued = plain.firstIndex { $0.contains("fix the failing test") }!
        let boxBottom = plain.firstIndex { $0.contains("╰") }!
        #expect(firstQueued < boxBottom)
    }

    @Test("slash menu takes the footer slot and hides the queue list")
    func slashMenuHidesQueueList() {
        let frame = CodingFrame(viewportHeight: 14)
        frame.slashCommands = [
            SlashCommandInfo(name: "compact", description: "compact the context"),
            SlashCommandInfo(name: "model", description: "switch model"),
        ]
        frame.queuedPrompts = ["fix the failing test"]
        frame.input.value = "/comp"  // slash popup is open

        let joined = frame.render(width: 50).map { ANSI.stripEscapes($0) }.joined(separator: "\n")
        #expect(joined.contains("/compact"))          // slash menu showing
        #expect(!joined.contains("fix the failing test"))  // queue list suppressed
        #expect(!joined.contains("↑ edit"))
    }

    @Test("no queued list when the queue is empty")
    func noQueuedListWhenEmpty() {
        let frame = CodingFrame(viewportHeight: 12)
        frame.setLiveLines([Style.tool("● working")])

        let joined = frame.render(width: 50).map { ANSI.stripEscapes($0) }.joined(separator: "\n")
        #expect(!joined.contains("↑ edit"))
    }

    @Test("modal lines overlay the tail, prompt box still renders")
    func modalOverlay() {
        let frame = CodingFrame(viewportHeight: 12)
        frame.setLiveLines(["● running tool"])
        frame.setModalLines([Style.header("  Select a model")])

        let rendered = frame.render(width: 40).joined(separator: "\n")

        #expect(rendered.contains("Select a model"))
        #expect(!rendered.contains("running tool"))
        #expect(rendered.contains("╭"))
    }
}

@Suite("TUI inline resize reflow")
struct TUIInlineResizeReflowTests {
    @Test("live frame drawing leaves the last terminal column unused")
    func liveFrameLeavesLastColumnUnused() async {
        let terminal = VirtualTerminal(width: 5, height: 20)
        let tui = TUI(terminal: terminal)
        // A child wider than the terminal so the live-zone width-cap is
        // observable: the TUI renders children at width-1, leaving the last
        // column unused.
        tui.addChild(TextComponent([String(repeating: "─", count: 40)]))
        tui.start()
        await terminal.waitForRender()

        let writes = terminal.getWrites()
        let disable = "\u{1B}[?7l"
        let enable = "\u{1B}[?7h"
        let rule = "────"
        let disableIdx = writes.range(of: disable)?.lowerBound
        let ruleIdx = writes.range(of: rule)?.lowerBound
        let enableIdx = writes.range(of: enable, range: (ruleIdx ?? writes.startIndex)..<writes.endIndex)?.lowerBound

        #expect(disableIdx != nil && ruleIdx != nil && enableIdx != nil)
        if let disableIdx, let ruleIdx, let enableIdx {
            #expect(disableIdx < ruleIdx)
            #expect(ruleIdx < enableIdx)
        }
        #expect(!writes.contains("─────"))
        tui.stop()
    }

    @Test("inline live draw erases to end of screen so width-shrink reflow can't leak")
    func inlineLiveDrawErasesToEndOfScreen() async {
        let terminal = VirtualTerminal(width: 20, height: 20)
        let tui = TUI(terminal: terminal)
        tui.addChild(TextComponent([String(repeating: "─", count: 40)]))
        tui.start()
        await terminal.waitForRender()

        // The live draw must clear from the cursor to the end of the screen
        // (CSI 0 J) so that previously-drawn wider rows reflowed by a terminal
        // width-shrink don't leave wrapped remnants below the live zone.
        #expect(terminal.getWrites().contains("\u{1B}[0J"))
        tui.stop()
    }

    @Test("direct-terminal resize replays the whole retained transcript re-wrapped")
    func fullRepaintReplaysHistory() async {
        let terminal = VirtualTerminal(width: 40, height: 10)
        let tui = TUI(terminal: terminal)
        tui.addChild(TextComponent(["❯ "]))
        tui.start()
        await terminal.waitForRender()

        tui.commit(["first committed line", "second committed line"])
        tui.requestRender()
        await terminal.waitForRender()

        terminal.clearWrites()
        // The omp-style authoritative repaint: clear scrollback (ED3) and
        // replay every retained logical line so it re-wraps to the new width.
        tui.triggerFullRepaintForTesting()
        let writes = terminal.getWrites()
        #expect(writes.contains("\u{1B}[3J"))
        #expect(writes.contains("first committed line"))
        #expect(writes.contains("second committed line"))
        tui.stop()
    }

    @Test("full repaint does not duplicate pending commits")
    func fullRepaintDoesNotDuplicatePendingCommits() async {
        let terminal = VirtualTerminal(width: 40, height: 10)
        let tui = TUI(terminal: terminal)
        tui.addChild(TextComponent(["❯ "]))
        tui.start()
        await terminal.waitForRender()

        terminal.clearWrites()
        tui.commit(["pending once"])
        // Resize can force an authoritative repaint before the normal render
        // drains pending commits. The retained history should still contain
        // exactly one logical copy.
        tui.triggerFullRepaintForTesting()

        let writes = terminal.getWrites()
        let occurrences = writes.components(separatedBy: "pending once").count - 1
        #expect(occurrences == 1)
        tui.stop()
    }

    @Test("stop exits below live zone when cursor is parked above bottom")
    func stopDropsCursorToLiveZoneBottom() async {
        let terminal = VirtualTerminal(width: 40, height: 10)
        let tui = TUI(terminal: terminal)
        tui.addChild(TestLinesComponent([CURSOR_MARKER + "input", "border", "state"]))
        tui.start()
        await terminal.waitForRender()

        terminal.clearWrites()
        tui.stop()

        #expect(terminal.getWrites().contains("\u{1B}[2B\r\n"))
    }

    @Test("inline renderer clamps overflowing child rows before writing")
    func inlineRendererClampsOverflowingChildRows() async {
        let terminal = VirtualTerminal(width: 5, height: 20)
        let tui = TUI(terminal: terminal)
        tui.addChild(TestLinesComponent(["ABCDE"]))
        tui.start()
        await terminal.waitForRender()

        let writes = terminal.getWrites()
        #expect(writes.contains("ABCD"))
        #expect(!writes.contains("ABCDE"))
        tui.stop()
    }

    @Test("shrinking width does not expand clear range to terminal reflow height")
    func shrinkKeepsLogicalClearHeight() async {
        let terminal = VirtualTerminal(width: 12, height: 20)
        let tui = TUI(terminal: terminal)
        tui.addChild(TestLinesComponent([String(repeating: "─", count: 11)]))
        tui.start()
        await terminal.waitForRender()

        terminal.clearWrites()
        terminal.resize(width: 4, height: 20)
        await terminal.waitForRender()

        let writes = terminal.getWrites()
        #expect(!writes.contains("\u{1B}[2A"))
        #expect(!writes.contains("\r\n\u{1B}[2K"))
        tui.stop()
    }
}

@Suite("Virtual terminal ANSI processing")
struct VirtualTerminalTests {
    @Test("writes printable characters into the grid")
    func writesPrintable() {
        let t = VirtualTerminal(width: 10, height: 3)
        t.write("Hi")
        let viewport = t.getViewport()
        #expect(viewport[0].hasPrefix("Hi"))
    }

    @Test("newline advances to next row")
    func newline() {
        let t = VirtualTerminal(width: 10, height: 3)
        t.write("A\nB")
        let viewport = t.getViewport()
        #expect(viewport[0].hasPrefix("A"))
        #expect(viewport[1].hasPrefix("B"))
    }

    @Test("clears a line with CSI K")
    func csiK() {
        let t = VirtualTerminal(width: 10, height: 2)
        t.write("ABCDE")
        t.write("\u{1b}[3G") // move cursor to column 3
        t.write("\u{1b}[K") // clear from cursor to end
        let viewport = t.getViewport()
        #expect(viewport[0].hasPrefix("AB"))
        #expect(viewport[0].trimmingCharacters(in: .whitespaces) == "AB")
    }

    @Test("ignores APC cursor marker sequences")
    func apcCursor() {
        let t = VirtualTerminal(width: 10, height: 2)
        t.write("A\u{1b}_pi:c\u{7}B")
        let viewport = t.getViewport()
        #expect(viewport[0].hasPrefix("AB"))
    }

    @Test("resize preserves existing content where possible")
    func resizeKeepsContent() {
        let t = VirtualTerminal(width: 10, height: 3)
        t.write("Hello")
        t.resize(width: 20, height: 5)
        let viewport = t.getViewport()
        #expect(viewport.count == 5)
        #expect(viewport[0].hasPrefix("Hello"))
    }

    @Test("emits resize events to subscribers")
    func resizeNotifiesListeners() {
        let t = VirtualTerminal(width: 10, height: 3)
        let recorded = RecordedSize()
        let un = t.onResize { w, h in recorded.set(w: w, h: h) }
        defer { un() }
        t.resize(width: 30, height: 7)
        #expect(recorded.w == 30)
        #expect(recorded.h == 7)
    }
}

final class RecordedSize: @unchecked Sendable {
    private let lock = NSLock()
    var w: Int = 0
    var h: Int = 0
    func set(w: Int, h: Int) {
        lock.lock(); defer { lock.unlock() }
        self.w = w
        self.h = h
    }
}
