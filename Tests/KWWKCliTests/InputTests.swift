import Foundation
import Testing
@testable import KWWKCli

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

    @Test("soft-wraps content that exceeds the render width") func softWrap() {
        let input = InputComponent(initial: "abcdefghij")
        let rows = input.render(width: 3)
        // 10 chars / 3 cols = 4 visual rows (last is 1 char).
        #expect(rows.count == 4)
        #expect(rows[0] == "abc")
        #expect(rows[1] == "def")
        #expect(rows[2] == "ghi")
        #expect(rows[3] == "j")
    }

    @Test("literal \\n in buffer forces a hard break") func hardNewline() {
        let input = InputComponent(initial: "hi\nthere")
        let rows = input.render(width: 40)
        #expect(rows == ["hi", "there"])
    }

    @Test("Ctrl+J inserts a newline into the buffer") func ctrlJInsertsNewline() {
        let input = InputComponent(initial: "ab")
        // 0x0A is Ctrl+J (raw LF). Fires without any keyboard-protocol
        // support — works in every terminal.
        input.handleInput("\u{0A}")
        #expect(input.value == "ab\n")
        #expect(input.cursor == 3)
    }

    @Test("Alt+Enter does not insert a newline") func altEnterDoesNotInsertNewline() {
        let input = InputComponent(initial: "ab")
        // ESC + CR == alt+enter in the parser, but newline insertion is
        // bound to Shift+Enter now.
        input.handleInput("\u{1B}\r")
        #expect(input.value == "ab")
    }

    @Test("Shift+Enter inserts a newline") func shiftEnterInsertsNewline() {
        let input = InputComponent(initial: "ab")
        // Kitty keyboard protocol: CSI 13 ; 2 u == shift+enter.
        input.handleInput("\u{1B}[13;2u")
        #expect(input.value == "ab\n")
    }

    @Test("cursor column is correct after a standalone zero-width grapheme") func zeroWidthGraphemeCursor() {
        // A lone combining mark (U+0301) is a zero-width grapheme on its own —
        // reachable when a bracketed paste is inserted verbatim. With the
        // cursor sitting *between* the mark and the 'a', the cursor's visual
        // column is 0 (the mark contributes no width). The layout pass and the
        // marker-insertion pass must agree, or the marker lands past the 'a'.
        let input = InputComponent(initial: "\u{0301}a")
        input.focused = true
        input.moveHome()
        input.moveCursor(1)   // cursor index 1: between the combining mark and 'a'
        #expect(input.cursor == 1)
        let row = input.render(width: 40).first ?? ""
        let parts = row.components(separatedBy: CURSOR_MARKER)
        #expect(parts.count == 2)
        // Visible width before the marker == the cursor's visual column.
        let prefixWidth = parts[0].unicodeScalars.reduce(0) { $0 + ANSI.columnWidth(of: $1.value) }
        #expect(prefixWidth == 0)
    }

    @Test("cursor placed on the correct visual row after a hard break") func cursorMultiRow() {
        let input = InputComponent(initial: "hi\nx")
        input.focused = true
        // cursor is at end (index 4 == after "hi\nx")
        let rows = input.render(width: 40)
        #expect(rows.count == 2)
        #expect(!rows[0].contains(CURSOR_MARKER), "cursor should be on row 1 (the 'x' row), not row 0")
        #expect(rows[1].contains(CURSOR_MARKER))
    }
}

@Suite("Editor history recall")
struct InputHistoryTests {
    @Test("Up from empty browses newest-first; Down walks back out") func recall() {
        let input = InputComponent()
        input.addToHistory("first")
        input.addToHistory("second")
        // Up from an empty buffer begins browsing at the most recent entry,
        // anchoring the cursor at the *start* so the next Up keeps scrubbing.
        input.cursorUp()
        #expect(input.value == "second")
        #expect(input.cursor == 0)
        input.cursorUp()
        #expect(input.value == "first")
        #expect(input.cursor == 0)
        // No older entry — hard stop, buffer kept.
        input.cursorUp()
        #expect(input.value == "first")
        // Down → newer, cursor anchored at the end.
        input.cursorDown()
        #expect(input.value == "second")
        #expect(input.cursor == 6)
        // Down past the newest clears the editor (no draft slot in omp).
        input.cursorDown()
        #expect(input.value == "")
    }

    @Test("addToHistory trims, drops empties and consecutive dupes") func dedupe() {
        let input = InputComponent()
        input.addToHistory("  hi  ")
        input.addToHistory("hi")     // consecutive dupe (after trim) — ignored
        input.addToHistory("   ")    // empty — ignored
        #expect(input.navigateHistory(-1) == true)
        #expect(input.value == "hi")
        // Only one entry recorded.
        #expect(input.navigateHistory(-1) == false)
    }

    @Test("navigateHistory is a no-op with empty history") func emptyHistory() {
        let input = InputComponent(initial: "draft")
        #expect(input.navigateHistory(-1) == false)
        #expect(input.value == "draft")
    }

    @Test("typing at the Up-anchor appends at the end and exits browsing") func typingExits() {
        let input = InputComponent()
        input.addToHistory("recalled")
        input.cursorUp()
        #expect(input.value == "recalled")
        #expect(input.cursor == 0)
        // omp #exitHistoryForEditing: the cursor sits at the start purely for
        // scrubbing — typing jumps it to the end first, then inserts.
        input.handleInput("!")
        #expect(input.value == "recalled!")
        // Browse mode exited: Up on the first visual row is now "go to line
        // start", never a destructive recall.
        input.cursorUp()
        #expect(input.value == "recalled!")
        #expect(input.cursor == 0)
    }

    @Test("Up never replaces a non-empty draft with history") func draftNeverReplaced() {
        let input = InputComponent()
        input.addToHistory("prev")
        input.value = "my unsent draft"
        input.moveEnd()
        // First Up on the (single) first visual row → start of line.
        input.cursorUp()
        #expect(input.value == "my unsent draft")
        #expect(input.cursor == 0)
        // Further Ups stay put — history is only enterable from empty.
        input.cursorUp()
        #expect(input.value == "my unsent draft")
        #expect(input.cursor == 0)
    }

    @Test("Up/Down in a multi-line draft move the cursor, boundaries snap to line start/end") func multilineDraft() {
        let input = InputComponent(initial: "line1\nline2")
        input.addToHistory("prev")
        input.moveEnd()
        // Up from row 1 col 5 → row 0 col 5.
        input.cursorUp()
        #expect(input.cursor == 5)
        #expect(input.value == "line1\nline2")
        // Up on the first visual row → column 0, not history.
        input.cursorUp()
        #expect(input.cursor == 0)
        input.cursorUp()
        #expect(input.cursor == 0)
        // Down from row 0 col 0 → row 1 col 0.
        input.cursorDown()
        #expect(input.cursor == 6)
        // Down on the last visual row → end of line; further Downs no-op.
        input.cursorDown()
        #expect(input.cursor == 11)
        input.cursorDown()
        #expect(input.cursor == 11)
        #expect(input.value == "line1\nline2")
    }

    @Test("browsing a multi-line entry: Down walks rows before advancing") func multilineEntryScrub() {
        let input = InputComponent()
        input.addToHistory("a\nb")
        input.cursorUp()
        #expect(input.value == "a\nb")
        #expect(input.cursor == 0)   // Up-anchor: first visual row
        // Still browsing, but not on the last visual row → cursor moves down.
        input.cursorDown()
        #expect(input.value == "a\nb")
        #expect(input.cursor == 2)
        // Now on the last visual row → navigate newer, which clears.
        input.cursorDown()
        #expect(input.value == "")
    }
}

@Suite("Editor vertical movement")
struct InputVerticalMovementTests {
    @Test("Up/Down move by visual (soft-wrapped) row, not logical line") func softWrapRows() {
        let input = InputComponent(initial: "abcdefghij")
        input.addToHistory("prev")
        _ = input.render(width: 3)   // rows: abc / def / ghi / j
        input.moveEnd()
        input.cursorUp()
        #expect(input.cursor == 7)   // row "ghi", col 1
        input.cursorUp()
        #expect(input.cursor == 4)
        input.cursorUp()
        #expect(input.cursor == 1)
        // First visual row → start of line; the non-empty buffer never
        // recalls history even though the cursor is on the first row.
        input.cursorUp()
        #expect(input.cursor == 0)
        #expect(input.value == "abcdefghij")
    }

    @Test("goal column survives a short row and is restored once it fits") func stickyColumn() {
        let input = InputComponent(initial: "abcde\nxy\nabcde")
        input.moveEnd()              // row 2, col 5
        input.cursorUp()
        #expect(input.cursor == 8)   // clamped to end of "xy" (col 2), goal 5 remembered
        input.cursorUp()
        #expect(input.cursor == 5)   // row 0 fits col 5 → goal restored + consumed
        input.cursorDown()
        #expect(input.cursor == 8)   // short row again → clamp, goal 5 remembered
        input.cursorDown()
        #expect(input.cursor == 14)  // restored on the bottom row
    }

    @Test("a horizontal move clears the goal column") func horizontalMoveClearsGoal() {
        let input = InputComponent(initial: "abcde\nxy\nabcde")
        input.moveEnd()
        input.cursorUp()             // on "xy" end, goal 5 pending
        input.handleInput("\u{1B}[D")   // Left → col 1, goal cleared
        #expect(input.cursor == 7)
        input.cursorUp()
        #expect(input.cursor == 1)   // straight up at col 1, no goal restore
    }
}

@Suite("Editor viewport")
struct InputViewportTests {
    private func stripped(_ rows: [String]) -> [String] {
        rows.map { $0.replacingOccurrences(of: CURSOR_MARKER, with: "") }
    }

    @Test("render is capped at maxVisibleRows with the cursor row visible") func heightCap() {
        let input = InputComponent(initial: (0..<10).map { "l\($0)" }.joined(separator: "\n"))
        input.maxVisibleRows = 4
        input.focused = true
        input.moveEnd()
        let rows = input.render(width: 40)
        #expect(stripped(rows) == ["l6", "l7", "l8", "l9"])
        #expect(rows[3].contains(CURSOR_MARKER))
    }

    @Test("cursor above the viewport pins it to the top row") func scrollUp() {
        let input = InputComponent(initial: (0..<10).map { "l\($0)" }.joined(separator: "\n"))
        input.maxVisibleRows = 4
        input.focused = true
        input.moveEnd()
        _ = input.render(width: 40)  // scrolled to the bottom
        input.moveHome()
        let rows = input.render(width: 40)
        #expect(stripped(rows) == ["l0", "l1", "l2", "l3"])
        #expect(rows[0].contains(CURSOR_MARKER))
    }

    @Test("viewport does not chase the cursor while it stays inside") func minimalScroll() {
        let input = InputComponent(initial: (0..<10).map { "l\($0)" }.joined(separator: "\n"))
        input.maxVisibleRows = 4
        input.focused = true
        input.moveHome()
        _ = input.render(width: 40)  // offset 0
        for _ in 0..<3 { input.cursorDown() }
        var rows = input.render(width: 40)
        #expect(stripped(rows) == ["l0", "l1", "l2", "l3"])
        #expect(rows[3].contains(CURSOR_MARKER))
        // One more row down crosses the bottom edge → scroll by one.
        input.cursorDown()
        rows = input.render(width: 40)
        #expect(stripped(rows) == ["l1", "l2", "l3", "l4"])
        #expect(rows[3].contains(CURSOR_MARKER))
    }

    @Test("soft-wrapped rows count 1:1 against the cap") func wrappedRowsCounted() {
        let input = InputComponent(initial: "abcdefghijkl")
        input.maxVisibleRows = 2
        input.moveEnd()
        let rows = input.render(width: 3)   // 4 visual rows, viewport shows 2
        #expect(rows == ["ghi", "jkl"])
    }

    @Test("shrinking content pulls the viewport back to the top") func shrinkClamps() {
        let input = InputComponent(initial: (0..<10).map { "l\($0)" }.joined(separator: "\n"))
        input.maxVisibleRows = 4
        input.moveEnd()
        _ = input.render(width: 40)  // scrolled to the bottom
        input.handleInput("\u{15}")  // Ctrl+U → kill to start, buffer empty
        let rows = input.render(width: 40)
        #expect(rows == [""])
    }

    @Test("CodingFrame derives the cap from the terminal height (omp formula)") func frameCap() {
        // rows 20: clamp(20−12, 6, 18) = 8, min(8, 20−4) = 8 → 6 content rows.
        #expect(CodingFrame(viewportHeight: 20).input.maxVisibleRows == 6)
        // rows 40: clamp(28, 6, 18) = 18 → 16 content rows.
        #expect(CodingFrame(viewportHeight: 40).input.maxVisibleRows == 16)
        // rows 8: clamp(−4, 6, 18) = 6, min(6, 4) = 4, floor 3... = 4 → 2 rows.
        #expect(CodingFrame(viewportHeight: 8).input.maxVisibleRows == 2)
        // rows 5: comfortable 6, rows−4 = 1, floor 3 → 3 → 1 content row.
        #expect(CodingFrame(viewportHeight: 5).input.maxVisibleRows == 1)
    }
}

@Suite("Editor word editing + kill ring")
struct InputWordEditTests {
    @Test("Ctrl+W deletes the word before the cursor") func ctrlW() {
        let input = InputComponent(initial: "hello world")
        input.handleInput("\u{17}")  // Ctrl+W
        #expect(input.value == "hello ")
        #expect(input.cursor == 6)
    }

    @Test("Alt+Backspace deletes word backward") func altBackspace() {
        let input = InputComponent(initial: "foo bar")
        input.handleInput("\u{1B}\u{7F}")  // ESC + DEL = Alt+Backspace
        #expect(input.value == "foo ")
    }

    @Test("Alt+D deletes the word after the cursor") func altD() {
        let input = InputComponent(initial: "hello world")
        input.moveHome()
        input.handleInput("\u{1B}d")  // Alt+D
        #expect(input.value == " world")
        #expect(input.cursor == 0)
    }

    @Test("Alt+B / Alt+F move by word") func altWordMove() {
        let input = InputComponent(initial: "alpha beta gamma")
        input.handleInput("\u{1B}b")  // Alt+B → start of "gamma"
        #expect(input.cursor == 11)
        input.handleInput("\u{1B}b")  // → start of "beta"
        #expect(input.cursor == 6)
        input.handleInput("\u{1B}f")  // → end of "beta"
        #expect(input.cursor == 10)
    }

    @Test("word boundaries keep apostrophe joiners inside a word") func joiner() {
        let input = InputComponent(initial: "don't stop")
        #expect(input.wordBoundaryLeft(from: 5) == 0)   // back over "don't"
    }

    @Test("CJK runs are their own boundary") func cjk() {
        let input = InputComponent(initial: "你好 world")
        // Right from start consumes the CJK run, stopping at the space.
        #expect(input.wordBoundaryRight(from: 0) == 2)
    }

    @Test("Ctrl+Y yanks the last kill back") func yank() {
        let input = InputComponent(initial: "hello world")
        input.handleInput("\u{17}")   // Ctrl+W → kill "world"
        #expect(input.value == "hello ")
        input.handleInput("\u{19}")   // Ctrl+Y → yank it back
        #expect(input.value == "hello world")
    }

    @Test("consecutive Ctrl+W accumulate into one yank") func accumulate() {
        let input = InputComponent(initial: "one two three")
        input.handleInput("\u{17}")   // kill "three"
        input.handleInput("\u{17}")   // kill "two " (prepended)
        #expect(input.value == "one ")
        input.handleInput("\u{19}")   // yank both at once
        #expect(input.value == "one two three")
    }

    @Test("Ctrl+U routes through the kill ring") func ctrlUYankable() {
        let input = InputComponent(initial: "discard keep")
        // Move to just before "keep" so Ctrl+U kills "discard ".
        input.moveHome()
        for _ in 0..<8 { input.moveCursor(1) }
        input.handleInput("\u{15}")   // Ctrl+U
        #expect(input.value == "keep")
        input.handleInput("\u{19}")   // Ctrl+Y restores it
        #expect(input.value == "discard keep")
    }
}

@Suite("Editor yank-pop")
struct InputYankPopTests {
    /// Seed the kill ring with three *distinct* (non-accumulating) entries —
    /// oldest "one", newest "three". The `value` setter resets `lastAction`,
    /// so each Ctrl+U pushes a fresh ring entry instead of accumulating.
    private func ringOfThree() -> InputComponent {
        let input = InputComponent()
        for word in ["one", "two", "three"] {
            input.value = word
            input.moveEnd()
            input.handleInput("\u{15}")   // Ctrl+U → kill the whole buffer
        }
        return input
    }

    @Test("Alt+Y after Ctrl+Y cycles through the kills and wraps") func cycleAndWrap() {
        let input = ringOfThree()
        input.handleInput("\u{19}")    // Ctrl+Y → yank newest
        #expect(input.value == "three")
        input.handleInput("\u{1B}y")   // Alt+Y → next older
        #expect(input.value == "two")
        input.handleInput("\u{1B}y")
        #expect(input.value == "one")
        input.handleInput("\u{1B}y")   // wraps back to the newest
        #expect(input.value == "three")
    }

    @Test("Alt+Y is a no-op when the last action was not a yank") func noPopWithoutYank() {
        let input = ringOfThree()       // ring has >1 entry, but no yank yet
        input.value = "kept"            // value setter clears lastAction
        input.moveEnd()
        input.handleInput("\u{1B}y")    // Alt+Y → guard: lastAction != .yank
        #expect(input.value == "kept")
    }

    @Test("Alt+Y is a no-op when the ring holds a single kill") func noPopSingleKill() {
        let input = InputComponent(initial: "hello world")
        input.moveEnd()
        input.handleInput("\u{17}")     // Ctrl+W → kill "world" (ring count == 1)
        input.handleInput("\u{19}")     // Ctrl+Y → "hello world", lastAction .yank
        input.handleInput("\u{1B}y")    // Alt+Y → guard: count not > 1
        #expect(input.value == "hello world")
    }

    @Test("Alt+Y is a no-op once the cursor leaves the yanked text") func noPopAfterCursorMove() {
        let input = ringOfThree()       // ring count > 1
        input.handleInput("\u{19}")     // Ctrl+Y → "three"
        #expect(input.value == "three")
        input.handleInput("\u{1B}[D")   // Left → cursor no longer abuts the yank
        input.handleInput("\u{1B}y")    // Alt+Y → pre-cursor text no longer == last yank
        #expect(input.value == "three")
    }
}

@Suite("Editor undo")
struct InputUndoTests {
    @Test("Ctrl+Z restores text removed by a kill") func undoKill() {
        let input = InputComponent(initial: "hello world")
        input.handleInput("\u{17}")   // Ctrl+W → "hello "
        #expect(input.value == "hello ")
        input.handleInput("\u{1A}")   // Ctrl+Z → undo
        #expect(input.value == "hello world")
    }

    @Test("Ctrl+_ also undoes") func underscoreUndo() {
        let input = InputComponent(initial: "abc")
        input.handleInput("\u{15}")   // Ctrl+U → ""
        #expect(input.value == "")
        input.handleInput("\u{1F}")   // Ctrl+_ → undo
        #expect(input.value == "abc")
    }

    @Test("a run of typed characters undoes as one step") func coalesceTyping() {
        let input = InputComponent()
        input.handleInput("a")
        input.handleInput("b")
        input.handleInput("c")
        #expect(input.value == "abc")
        input.undo()
        #expect(input.value == "")
    }

    @Test("undo with nothing on the stack is a no-op") func emptyUndo() {
        let input = InputComponent(initial: "x")
        input.undo()
        #expect(input.value == "x")
    }

    @Test("undo stack is capped at maxUndoStack") func undoCap() {
        let input = InputComponent()
        // Each multi-char insert is its own undo step (no typed-run coalescing),
        // so 60 inserts record 60 snapshots — only the last 50 survive the cap.
        for i in 0..<60 { input.insert("\(i),") }
        let full = (0..<60).map { "\($0)," }.joined()
        #expect(input.value == full)
        // Undoing 50 times unwinds to the snapshot taken before the 11th insert
        // (i.e. with inserts 0–9 applied); the older 10 snapshots were dropped.
        for _ in 0..<50 { input.undo() }
        let kept = (0..<10).map { "\($0)," }.joined()
        #expect(input.value == kept)
        // Stack exhausted — a further undo is a no-op (it can't go back further).
        input.undo()
        #expect(input.value == kept)
    }

    @Test("undo after yank-pop restores cleanly") func undoAfterYankPop() {
        let input = InputComponent()
        for word in ["one", "two"] {       // ring: oldest "one", newest "two"
            input.value = word
            input.moveEnd()
            input.handleInput("\u{15}")    // Ctrl+U
        }
        input.value = "tail"
        input.moveEnd()
        input.handleInput("\u{19}")        // Ctrl+Y → "tailtwo"
        #expect(input.value == "tailtwo")
        input.handleInput("\u{1B}y")       // Alt+Y → "tailone"
        #expect(input.value == "tailone")
        input.handleInput("\u{1A}")        // Ctrl+Z → undo the pop → "tailtwo"
        #expect(input.value == "tailtwo")
        input.handleInput("\u{1A}")        // Ctrl+Z → undo the yank → "tail"
        #expect(input.value == "tail")
    }
}

@Suite("Keybinding matching")
struct KeybindingTests {
    @Test("plain Enter binding does not match Shift+Enter") func enterBindingRejectsShift() {
        let binding = KeyBinding("enter", shift: false)
        let plainEnter = KeyEvent(name: "enter")
        let shiftEnter = KeyEvent(name: "enter", shift: true)
        #expect(binding.matches(plainEnter) == true)
        #expect(binding.matches(shiftEnter) == false)
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
