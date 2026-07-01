import Foundation
import Testing
@testable import KWWKCli

@Suite("ANSI truncate")
struct ANSITruncateTests {

    @Test("cutting inside an open pen appends a single reset")
    func closesOpenPen() {
        // A colored, unclosed span cut mid-text must not leak the color.
        let s = "\u{1B}[31mhello world"
        let out = ANSI.truncate(s, to: 5)
        #expect(ANSI.visibleWidth(out) == 5)
        #expect(out.hasSuffix("\u{1B}[0m"))
    }

    @Test("[open][reset][open]text cut ends reset with no leaked color")
    func openResetOpenLatchRegression() {
        // The old sticky hadStyle/hadClose booleans latched hadClose on the
        // first reset, so a later open never re-armed the trailing reset —
        // leaking the second pen's color. Track a single current-pen instead.
        let s = "\u{1B}[31m\u{1B}[0m\u{1B}[32mtext"
        let out = ANSI.truncate(s, to: 2)
        #expect(ANSI.visibleWidth(out) == 2)
        #expect(out.hasSuffix("\u{1B}[0m"))
        // The trailing reset must be the last escape (no color after it).
        #expect(out.hasSuffix("te\u{1B}[0m"))
    }

    @Test("a trailing reset in the source is not double-closed")
    func alreadyClosedPenIsLeftAlone() {
        let s = "\u{1B}[31mhi\u{1B}[0m"
        let out = ANSI.truncate(s, to: 5)
        // Pen closed by the source reset — no extra reset appended.
        #expect(out == "\u{1B}[31mhi\u{1B}[0m")
    }
}

@Suite("Box borders")
struct BoxBorderTests {

    @Test("top clamps an over-long label to width and keeps the corner")
    func topClampsLongLabel() {
        let width = 20
        let label = String(repeating: "breadcrumb", count: 6) // 60 cols, far over inner
        let line = Box.top(width: width, label: label)
        #expect(ANSI.visibleWidth(line) == width)
        #expect(ANSI.stripEscapes(line).hasSuffix(Box.tr))
    }

    @Test("bottom clamps an over-long right label to width and keeps the corner")
    func bottomClampsLongLabel() {
        let width = 18
        let label = String(repeating: "status", count: 8)
        let line = Box.bottom(width: width, rightLabel: label)
        #expect(ANSI.visibleWidth(line) == width)
        #expect(ANSI.stripEscapes(line).hasSuffix(Box.br))
    }

    @Test("top with a normal label spans exactly width and keeps the corner")
    func topNormalLabel() {
        let line = Box.top(width: 30, label: "main.swift")
        #expect(ANSI.visibleWidth(line) == 30)
        #expect(ANSI.stripEscapes(line).hasSuffix(Box.tr))
    }
}
