import Testing
import Foundation
@testable import KWWKCli

/// Covers the TUI/perf review-fix cluster: grapheme-aware widths, Kitty CSI-u
/// punctuation decoding, and linear bracketed-paste accumulation.
@Suite("TUI cluster fixes")
struct TUIClusterFixTests {

    // MARK: - Width table (finding 5)

    @Test("ZWJ emoji sequence is one 2-column glyph")
    func zwjFamilyWidth() {
        // 👨‍👩‍👧 = man ZWJ woman ZWJ girl — a single rendered glyph.
        let family = "👨‍👩‍👧"
        #expect(ANSI.graphemeWidth(Character(family)) == 2)
        #expect(ANSI.visibleWidth(family) == 2)
    }

    @Test("skin-tone modifier composes onto its base (width 2, not 4)")
    func skinToneWidth() {
        let thumbs = "👍🏽"
        #expect(ANSI.graphemeWidth(Character(thumbs)) == 2)
        #expect(ANSI.visibleWidth(thumbs) == 2)
    }

    @Test("regional-indicator flag is one 2-column glyph")
    func flagWidth() {
        let us = "🇺🇸"
        #expect(ANSI.graphemeWidth(Character(us)) == 2)
        #expect(ANSI.visibleWidth(us) == 2)
        // Two flags side by side = 4 columns.
        #expect(ANSI.visibleWidth("🇺🇸🇬🇧") == 4)
    }

    @Test("modern Extended-A pictographs (U+1FA70–1FAFF) are width 2")
    func extendedAEmojiWidth() {
        #expect(ANSI.columnWidth(of: 0x1FA79) == 2) // adhesive bandage
        #expect(ANSI.columnWidth(of: 0x1FAB4) == 2) // potted plant
        #expect(ANSI.graphemeWidth("🩹") == 2)
    }

    @Test("plain ASCII and CJK widths are unchanged")
    func baselineWidths() {
        #expect(ANSI.visibleWidth("hello") == 5)
        #expect(ANSI.visibleWidth("你好") == 4)
        #expect(ANSI.graphemeWidth("a") == 1)
        #expect(ANSI.graphemeWidth("中") == 2)
    }

    // MARK: - Kitty CSI-u punctuation (finding 9)

    @Test("Ctrl+/ decodes to name \"/\" with ctrl on kitty terminals")
    func kittyCtrlSlash() {
        // CSI 47 ; 5 u  →  '/' (0x2F) with ctrl (mod 5 = 1 + ctrl).
        let ev = Keys.parse("\u{1B}[47;5u")
        #expect(ev?.name == "/")
        #expect(ev?.ctrl == true)
    }

    @Test("Ctrl+_ decodes to name \"_\" with ctrl on kitty terminals")
    func kittyCtrlUnderscore() {
        let ev = Keys.parse("\u{1B}[95;5u")
        #expect(ev?.name == "_")
        #expect(ev?.ctrl == true)
    }

    @Test("kitty letters still lower-case with modifiers preserved")
    func kittyLetterStillWorks() {
        // CSI 97 ; 5 u = Ctrl+a
        let ev = Keys.parse("\u{1B}[97;5u")
        #expect(ev?.name == "a")
        #expect(ev?.ctrl == true)
    }

    // MARK: - Bracketed paste accumulation (finding 2)

    @Test("bracketed paste split across chunks yields one sequence")
    func pasteAcrossChunks() {
        let buf = StdinBuffer()
        // Start marker + first half, no terminator yet.
        var out = buf.feed("\u{1B}[200~hello ")
        #expect(out.isEmpty)
        // Rest of the body + terminator arrives in a later chunk.
        out = buf.feed("world\u{1B}[201~")
        #expect(out.count == 1)
        #expect(out.first == "\u{1B}[200~hello world\u{1B}[201~")
    }

    @Test("large paste accumulates intact regardless of chunk boundaries")
    func largePasteReassembles() {
        let buf = StdinBuffer()
        let body = String(repeating: "x", count: 200_000)
        let full = "\u{1B}[200~" + body + "\u{1B}[201~"
        let bytes = Array(full.utf8)
        // Feed in many 4 KB chunks, mimicking stdin reads.
        var out: [String] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + 4096, bytes.count)
            out += buf.feed(Data(bytes[i..<end]))
            i = end
        }
        #expect(out.count == 1)
        #expect(out.first == full)
    }

    @Test("ordinary keystrokes still split correctly after the cursor rewrite")
    func plainKeysStillSplit() {
        let buf = StdinBuffer()
        let out = buf.feed("abc")
        #expect(out == ["a", "b", "c"])
        // A CSI arrow arrives whole.
        #expect(buf.feed("\u{1B}[A") == ["\u{1B}[A"])
    }

    @Test("terminator straddling a chunk boundary is still found")
    func terminatorStraddlesBoundary() {
        let buf = StdinBuffer()
        #expect(buf.feed("\u{1B}[200~data\u{1B}[20").isEmpty)
        let out = buf.feed("1~")
        #expect(out.count == 1)
        #expect(out.first == "\u{1B}[200~data\u{1B}[201~")
    }
}
