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

    @Test("boundBashOutput prepends a notice only when truncated")
    func boundNotice() {
        #expect(boundBashOutput("hello") == "hello")
        let big = (1...5000).map { "row \($0)" }.joined(separator: "\n")
        let bounded = boundBashOutput(big)
        #expect(bounded.hasPrefix("[output truncated:"))
        #expect(bounded.hasSuffix("row 5000"))
    }
}
