import Foundation
import Testing
@testable import KWWKCli

@Suite("Stdin buffer")
struct StdinBufferTests {
    @Test("splits plain ASCII as individual keys") func ascii() {
        let buffer = StdinBuffer()
        #expect(buffer.feed("abc") == ["a", "b", "c"])
    }

    @Test("waits for CSI final byte across chunks") func csiAcrossChunks() {
        let buffer = StdinBuffer()
        #expect(buffer.feed("\u{1B}") == [])
        #expect(buffer.feed("[1;5") == [])
        #expect(buffer.feed("C") == ["\u{1B}[1;5C"])
    }

    @Test("emits bracketed paste as one synthetic key") func bracketedPaste() {
        let buffer = StdinBuffer()
        let paste = "\u{1B}[200~hello world\u{1B}[201~"
        #expect(buffer.feed(paste) == [paste])
    }

    @Test("splits multi-byte UTF-8 correctly") func utf8Handling() {
        let buffer = StdinBuffer()
        let emoji = "π"
        #expect(buffer.feed(emoji) == [emoji])
    }

    @Test("flushOnTimeout releases a pending ESC") func timeoutFlush() {
        let buffer = StdinBuffer()
        #expect(buffer.feed("\u{1B}") == [])
        #expect(buffer.flushOnTimeout() == ["\u{1B}"])
    }

    @Test("assembles a meta-prefixed Option+Arrow as one sequence") func metaArrow() {
        let buffer = StdinBuffer()
        // ESC ESC [ A delivered whole — Option+Up with "Option as Meta".
        #expect(buffer.feed("\u{1B}\u{1B}[A") == ["\u{1B}\u{1B}[A"])
    }

    @Test("waits for a meta-prefixed arrow split across chunks") func metaArrowChunks() {
        let buffer = StdinBuffer()
        #expect(buffer.feed("\u{1B}\u{1B}") == [])
        #expect(buffer.feed("[A") == ["\u{1B}\u{1B}[A"])
    }

    @Test("a genuine double-ESC flushes on timeout") func doubleEscTimeout() {
        let buffer = StdinBuffer()
        #expect(buffer.feed("\u{1B}\u{1B}") == [])
        #expect(buffer.flushOnTimeout() == ["\u{1B}"])
    }
}
