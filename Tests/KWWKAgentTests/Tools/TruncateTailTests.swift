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

    @Test("boundBashOutput keeps the head and tail of one-line output")
    func boundSingleLine() {
        let big = "START " + String(repeating: "z", count: 120 * 1024) + " EXIT 1"
        let bounded = boundBashOutput(big)
        #expect(bounded.hasPrefix("START zzz"))
        #expect(bounded.contains("[… output truncated: "))
        #expect(!bounded.contains("line(s)"))
        #expect(bounded.hasSuffix("z EXIT 1"))
        #expect(bounded.utf8.count <= Truncate.bashHeadBytes + Truncate.bashTailBytes + 512)
    }

    @Test("boundBashOutput marks the middle only when truncated")
    func boundNotice() {
        #expect(boundBashOutput("hello") == "hello")
        let big = (1...5000).map { "row \($0)" }.joined(separator: "\n")
        let bounded = boundBashOutput(big, fullOutputPath: "/tmp/full output.log")
        #expect(bounded.hasPrefix("row 1\nrow 2\n"))
        #expect(bounded.hasSuffix("row 5000"))
        #expect(bounded.contains("full output: /tmp/full output.log"))
        #expect(bounded.contains("grep -n \"error:\" '/tmp/full output.log'"))
        #expect(bounded.utf8.count <= Truncate.bashHeadBytes + Truncate.bashTailBytes + 512)
    }
}

@Suite("Truncate.truncateHeadTail")
struct TruncateHeadTailTests {
    @Test("content within head + tail passes through untouched")
    func passthrough() {
        let text = String(repeating: "a", count: 16 * 1024)
        let r = Truncate.truncateHeadTail(text)
        #expect(!r.truncated)
        #expect(r.head == text)
        #expect(r.tail.isEmpty)
        // One byte over the budget is cut.
        #expect(Truncate.truncateHeadTail(text + "b").truncated)
    }

    @Test("cuts on line boundaries and counts the omitted lines")
    func lineBoundaries() {
        let content = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let r = Truncate.truncateHeadTail(content, headBytes: 30, tailBytes: 40)
        #expect(r.truncated)
        #expect(r.head == "line 1\nline 2\nline 3\nline 4")
        // "line 96\n" would overrun the 40 bytes by one.
        #expect(r.tail == "line 97\nline 98\nline 99\nline 100\n")
        #expect(r.omittedLines == 92)
        #expect(r.head.utf8.count + r.tail.utf8.count + r.omittedBytes == content.utf8.count)
    }

    @Test("CRLF line endings stay whole on both sides of the cut")
    func crlf() {
        let content = (1...100).map { "line \($0)\r\n" }.joined()
        let r = Truncate.truncateHeadTail(content, headBytes: 30, tailBytes: 40)
        #expect(r.head.utf8.last == 0x0D)
        #expect(r.head.hasPrefix("line 1\r\nline 2\r\n"))
        #expect(r.tail.utf8.first == UInt8(ascii: "l"))
        #expect(r.tail.hasSuffix("line 100\r\n"))
        #expect(content.utf8.starts(with: r.head.utf8))
        #expect(content.hasSuffix(r.tail))
    }

    @Test("a single over-budget line is cut on UTF-8 scalar boundaries")
    func multibyteBoundaries() {
        // Every cut position lands inside some multi-byte scalar.
        let content = String(repeating: "é😀中", count: 2_000)
        for (head, tail) in [(30, 41), (31, 42), (32, 43), (33, 44)] {
            let r = Truncate.truncateHeadTail(content, headBytes: head, tailBytes: tail)
            #expect(r.truncated)
            #expect(!r.head.contains("\u{FFFD}"))
            #expect(!r.tail.contains("\u{FFFD}"))
            #expect(r.head.utf8.count <= head && r.head.utf8.count > head - 4)
            #expect(r.tail.utf8.count <= tail && r.tail.utf8.count > tail - 4)
            #expect(content.hasPrefix(r.head))
            #expect(content.hasSuffix(r.tail))
        }
    }

    @Test("two windows over a larger content report bytes but not lines")
    func windows() {
        let prefix = Array("first\nsecond\nthird\n".utf8)
        let suffix = Array("x\ny\nlast line\n".utf8)
        let r = Truncate.truncateHeadTail(
            prefix: prefix,
            suffix: suffix,
            totalBytes: 10_000,
            headBytes: 14,
            tailBytes: 12
        )
        #expect(r.head == "first\nsecond")
        #expect(r.tail == "last line\n")
        #expect(r.omittedLines == nil)
        #expect(r.omittedBytes == 10_000 - r.head.utf8.count - r.tail.utf8.count)
    }
}
