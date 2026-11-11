import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

/// Swift reads "\r\n" as one Character, so a Character split on "\n" finds
/// no line break in a CRLF file. The read tool counted lines on bytes and
/// sliced on Characters, and trapped (SIGILL, exit 132) on the first
/// offset/limit read of a CRLF file: sparql-university's
/// `/app/university_graph.ttl` in the FrontierHarness eval, 4 of 4 trials.
@Suite("CRLF line handling")
struct CRLFLineTests {
    /// 305 CRLF-terminated Turtle lines with non-ASCII names, the shape of
    /// `university_graph.ttl` (`wc -l` 305).
    private func turtle() -> String {
        (1...305).map { n in
            n % 7 == 0 ? "uni:U\(n) uni:hasName \"Universidad Politécnica \(n)\" ;" : "# line \(n)"
        }.map { $0 + "\r\n" }.joined()
    }

    @Test("read with offset/limit on a CRLF file returns the window (eval repro)")
    func offsetLimitOnCRLF() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("university_graph.ttl")
        try write(turtle(), to: file)

        let tool = createReadTool(cwd: dir.path)
        // The exact arguments of the trajectory's second tool call.
        let result = try await tool.execute(
            "call-crlf",
            ["path": .string(file.path), "offset": .int(100), "limit": .int(210)],
            nil,
            nil
        )
        let output = textOutput(result)
        #expect(output.hasPrefix("# line 100\r\n"))
        #expect(output.contains("uni:U105 uni:hasName \"Universidad Politécnica 105\" ;\r\n"))
        #expect(output.contains("# line 305\r\n"))
        #expect(!output.contains("# line 99\r\n"))
        // 306 lines by "\n" count: the empty piece after the final CRLF.
        #expect(!output.contains("more lines in file"))
    }

    @Test("read reports the remaining CRLF lines and the next offset")
    func remainingLinesOnCRLF() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.ttl")
        try write(turtle(), to: file)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-crlf-2",
            ["path": .string(file.path), "offset": .int(8), "limit": .int(5)],
            nil,
            nil
        )
        #expect(textOutput(result) == "# line 8\r\n# line 9\r\n# line 10\r\n# line 11\r\n# line 12\r\n\n[294 more lines in file. Use offset=13 to continue.]")
    }

    @Test("read with only an offset on a CRLF file reads to EOF")
    func offsetOnlyOnCRLF() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("b.txt")
        try write("one\r\ntwo\r\nthree\r\nfour", to: file)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute("call-crlf-3", ["path": .string(file.path), "offset": .int(3)], nil, nil)
        #expect(textOutput(result) == "three\r\nfour")
        let none = try await tool.execute(
            "call-crlf-4",
            ["path": .string(file.path), "offset": .int(2), "limit": .int(0)],
            nil,
            nil
        )
        #expect(textOutput(none).hasPrefix("\n\n[3 more lines in file. Use offset=2 to continue.]"))
    }

    @Test("a CRLF file over the line budget truncates by lines, not as one huge line")
    func truncatesCRLFByLines() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.txt")
        try write((1...2500).map { "Line \($0)\r\n" }.joined(), to: file)

        let tool = createReadTool(cwd: dir.path, options: ReadToolOptions(maxLines: 2000))
        let output = textOutput(try await tool.execute("call-crlf-5", ["path": .string(file.path)], nil, nil))
        // Compared as whole graphemes: the kept "\r" and the notice's "\n" make one "\r\n".
        #expect(output.hasPrefix("Line 1\r\nLine 2\r\n"))
        #expect(output.contains("Line 1999\r\nLine 2000\r\n\n[Showing lines 1-2000 of 2501. Use offset=2001 to continue.]"))
        #expect(!output.contains("Line 2001"))
    }

    @Test("readLineWindow cuts on the newline byte")
    func lineWindow() {
        let text = "a\r\nb\r\nc"
        #expect(readLineWindow(text, startLine: 1, limit: 1) == ("b\r", 1))
        #expect(readLineWindow(text, startLine: 1, limit: 9) == ("b\r\nc", 2))
        #expect(readLineWindow(text, startLine: 2, limit: nil).content == "c")
        #expect(readLineWindow(text, startLine: 0, limit: 0) == ("", 0))
    }

    @Test("truncateHead and truncateTail count CRLF lines")
    func truncateCRLF() {
        let content = (1...10).map { "l\($0)" }.joined(separator: "\r\n") + "\r\n"
        let head = Truncate.truncateHead(content, maxLines: 3, maxBytes: 1_000)
        #expect(head.truncated)
        #expect(head.content == "l1\r\nl2\r\nl3\r")
        let tail = Truncate.truncateTail(content, maxLines: 2, maxBytes: 1_000)
        #expect(tail.totalLines == 10)
        #expect(tail.content == "l9\r\nl10\r")
    }

    @Test("edit keeps CRLF line endings")
    func editKeepsCRLF() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("c.ttl")
        try write("alpha\r\nbeta\r\ngamma\r\n", to: file)

        let tool = createEditTool(cwd: dir.path)
        _ = try await tool.execute(
            "call-crlf-6",
            ["path": .string(file.path), "edits": .array([.object(["oldText": .string("beta\ngamma"), "newText": .string("BETA\ngamma")])])],
            nil,
            nil
        )
        #expect(try String(contentsOf: file, encoding: .utf8) == "alpha\r\nBETA\r\ngamma\r\n")
        #expect(EditDiff.detectLineEnding("x\r\ny\r\n") == .crlf)
    }
}
