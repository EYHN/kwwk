import Foundation
import Testing
@testable import KWTUI

@Suite("Input component")
struct InputComponentTests {
    @Test("insert advances cursor") func insert() {
        let input = InputComponent()
        input.handleInput("h")
        input.handleInput("i")
        #expect(input.value == "hi")
        #expect(input.cursor == 2)
    }

    @Test("backspace removes char before cursor") func backspace() {
        let input = InputComponent(initial: "hello")
        input.handleInput("\u{7F}")
        #expect(input.value == "hell")
    }

    @Test("home/end move cursor") func homeEnd() {
        let input = InputComponent(initial: "abc")
        input.handleInput("\u{1B}[H")  // home
        #expect(input.cursor == 0)
        input.handleInput("\u{1B}[F")  // end
        #expect(input.cursor == 3)
    }

    @Test("ctrl+a / ctrl+e jump to bounds") func ctrlJump() {
        let input = InputComponent(initial: "hello")
        input.handleInput("\u{01}")  // Ctrl-A
        #expect(input.cursor == 0)
        input.handleInput("\u{05}")  // Ctrl-E
        #expect(input.cursor == 5)
    }

    @Test("render keeps line at or under the requested width") func widthClamp() {
        let input = InputComponent(initial: String(repeating: "x", count: 200))
        let line = input.render(width: 40).first ?? ""
        // The focused cursor adds a zero-width marker; strip it for width checks.
        let stripped = line.replacingOccurrences(of: CURSOR_MARKER, with: "")
        #expect(stripped.count <= 40)
    }

    @Test("focused render embeds the cursor marker") func cursorMarker() {
        let input = InputComponent(initial: "ab")
        input.focused = true
        let line = input.render(width: 40).first ?? ""
        #expect(line.contains(CURSOR_MARKER))
    }
}

@Suite("Markdown component")
struct MarkdownComponentTests {
    @Test("strips bold / italic / code markers in output") func inlineStripping() {
        let md = MarkdownComponent("**hi** and *there* with `code`")
        let lines = md.render(width: 40)
        #expect(lines.first == "hi and there with code")
    }

    @Test("formats bullet lists with bullets and indentation") func bullets() {
        let md = MarkdownComponent("- first\n- second")
        let lines = md.render(width: 40)
        #expect(lines.contains("• first"))
        #expect(lines.contains("• second"))
    }

    @Test("renders headings") func headings() {
        let md = MarkdownComponent("# Big\n## Medium")
        let lines = md.render(width: 40)
        #expect(lines[0].hasPrefix("# "))
        #expect(lines[0].contains("BIG"))
        #expect(lines[1] == "## Medium")
    }

    @Test("keeps fenced code verbatim") func codeFence() {
        let md = MarkdownComponent("```\nlet x = 1\n```")
        let lines = md.render(width: 40)
        #expect(lines == ["let x = 1"])
    }
}
