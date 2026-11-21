import Foundation
import Testing
@testable import KWWKAgent

@Suite("Truncate.truncateTail")
struct TruncateTailTests {
    @Test("short content passes through untouched")
    func passthrough() {
        let r = Truncate.truncateTail("a\nb\nc")
        #expect(!r.truncated)
        #expect(r.content == "a\nb\nc")
        #expect(r.outputLines == 3)
    }

    @Test("keeps the last lines when the line budget is exceeded")
    func lineBudget() {
        let content = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let r = Truncate.truncateTail(content, maxLines: 10, maxBytes: 1_000_000)
        #expect(r.truncated)
        #expect(r.truncatedBy == "lines")
        #expect(r.outputLines == 10)
        // Tail is kept: last line survives, earliest lines are dropped.
        #expect(r.content.hasSuffix("line 100"))
        #expect(!r.content.contains("line 1\n"))
        #expect(r.content.hasPrefix("line 91"))
    }

    @Test("keeps the last bytes when the byte budget is exceeded")
    func byteBudget() {
        let content = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let r = Truncate.truncateTail(content, maxLines: 10_000, maxBytes: 20)
        #expect(r.truncated)
        #expect(r.truncatedBy == "bytes")
        #expect(r.outputBytes <= 20)
        #expect(r.content.hasSuffix("line 100"))
    }

    @Test("keeps the tail of a single line larger than the byte budget")
    func singleLongLine() {
        let content = String(repeating: "x", count: 100) + "é final error"
        let r = Truncate.truncateTail(content, maxLines: 10_000, maxBytes: 20)
        #expect(r.truncated)
        #expect(r.truncatedBy == "bytes")
        #expect(r.lastLinePartial)
        #expect(r.outputLines == 1)
        #expect(r.outputBytes <= 20)
        #expect(r.content.hasSuffix("final error"))
        #expect(content.hasSuffix(r.content))
    }

    @Test("keeps the partial tail of a long last line after earlier lines")
    func longLastLineAfterShortLines() {
        let content = "first\nsecond\n" + String(repeating: "y", count: 100) + "done"
        let r = Truncate.truncateTail(content, maxLines: 10_000, maxBytes: 20)
        #expect(r.lastLinePartial)
        #expect(r.outputLines == 1)
        #expect(r.totalLines == 3)
        #expect(r.content.hasSuffix("done"))
        #expect(!r.content.contains("\n"))
    }

    @Test("boundBashOutput keeps the tail of one-line output")
    func boundSingleLine() {
        let big = String(repeating: "z", count: 120 * 1024) + " EXIT 1"
        let bounded = boundBashOutput(big)
        #expect(bounded.contains("[… output truncated: "))
        #expect(bounded.hasSuffix("z EXIT 1"))
    }

    @Test("boundBashOutput keeps the head and tail of CRLF / multi-byte output within 16KB")
    func boundHeadTail() {
        #expect(boundBashOutput("hello") == "hello")
        let big = (1...5000).map { "row \($0) é😀\r\n" }.joined()
        let bounded = boundBashOutputDetailed(big, fullOutputPath: "/tmp/out.log").text
        #expect(bounded.hasPrefix("row 1 é😀\r\nrow 2 é😀\r\n"))
        #expect(bounded.hasSuffix("row 5000 é😀\r"))
        #expect(bounded.contains("full output: /tmp/out.log"))
        #expect(!bounded.contains("\u{FFFD}"))
        #expect(bounded.utf8.count <= Truncate.bashHeadBytes + Truncate.bashTailBytes + 256)
    }
}
