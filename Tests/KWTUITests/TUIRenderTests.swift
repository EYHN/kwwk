import Foundation
import Testing
@testable import KWTUI

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
