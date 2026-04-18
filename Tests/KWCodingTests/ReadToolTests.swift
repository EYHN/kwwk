import Foundation
import Testing
@testable import KWAI
@testable import KWAgent
@testable import KWCoding

// Helpers

func makeTempDir(_ prefix: String = "kw-coding") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func write(_ contents: String, to url: URL) throws {
    try contents.data(using: .utf8)!.write(to: url)
}

func textOutput(_ result: AgentToolResult) -> String {
    result.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text } else { return nil }
    }.joined(separator: "\n")
}

@Suite("Read tool")
struct ReadToolTests {
    @Test("reads file contents that fit within limits")
    func readsSimple() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.txt")
        try write("Hello, world!\nLine 2\nLine 3", to: file)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute("call-1", ["path": .string(file.path)], nil, nil)
        #expect(textOutput(result) == "Hello, world!\nLine 2\nLine 3")
        #expect(result.details == nil)
    }

    @Test("throws for non-existent files")
    func missingFile() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.txt")

        let tool = createReadTool(cwd: dir.path)
        await #expect(throws: Error.self) {
            _ = try await tool.execute("call-2", ["path": .string(missing.path)], nil, nil)
        }
    }

    @Test("truncates files exceeding line limit")
    func truncatesByLines() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("large.txt")
        let lines = (1...2500).map { "Line \($0)" }.joined(separator: "\n")
        try write(lines, to: file)

        let tool = createReadTool(cwd: dir.path, options: ReadToolOptions(maxLines: 2000))
        let result = try await tool.execute("call-3", ["path": .string(file.path)], nil, nil)
        let output = textOutput(result)
        #expect(output.contains("Line 1"))
        #expect(output.contains("Line 2000"))
        #expect(!output.contains("Line 2001"))
        #expect(output.contains("Showing lines 1-2000 of 2500"))
        #expect(output.contains("offset=2001"))
    }

    @Test("honours offset and limit parameters")
    func offsetLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("offset.txt")
        let lines = (1...100).map { "Line \($0)" }.joined(separator: "\n")
        try write(lines, to: file)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute("call-4",
            ["path": .string(file.path), "offset": 41, "limit": 20],
            nil, nil
        )
        let output = textOutput(result)
        #expect(!output.contains("Line 40"))
        #expect(output.contains("Line 41"))
        #expect(output.contains("Line 60"))
        #expect(!output.contains("Line 61"))
        #expect(output.contains("[40 more lines in file. Use offset=61 to continue.]"))
    }

    @Test("throws when offset is beyond the file length")
    func offsetOutOfRange() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("short.txt")
        try write("Line 1\nLine 2\nLine 3", to: file)

        let tool = createReadTool(cwd: dir.path)
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-5",
                ["path": .string(file.path), "offset": 100],
                nil, nil
            )
        }
    }

    @Test("includes truncation details when output is truncated")
    func truncationDetails() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("large.txt")
        let lines = (1...2500).map { "Line \($0)" }.joined(separator: "\n")
        try write(lines, to: file)

        let tool = createReadTool(cwd: dir.path, options: ReadToolOptions(maxLines: 2000))
        let result = try await tool.execute("call-6", ["path": .string(file.path)], nil, nil)
        guard case .object(let details) = result.details ?? .null,
              case .object(let trunc) = details["truncation"] ?? .null else {
            Issue.record("expected truncation details")
            return
        }
        #expect(trunc["truncated"] == .bool(true))
        #expect(trunc["truncatedBy"] == .string("lines"))
        #expect(trunc["totalLines"] == .int(2500))
        #expect(trunc["outputLines"] == .int(2000))
    }

    @Test("detects PNG images by magic bytes and returns an image block")
    func pngDetection() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("image.txt")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!
        try png.write(to: file)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute("call-7", ["path": .string(file.path)], nil, nil)

        let hasImage = result.content.contains { block in
            if case .image(let img) = block { return img.mimeType == "image/png" } else { return false }
        }
        #expect(hasImage)
    }
}

@Suite("Write tool")
struct WriteToolTests {
    @Test("writes file contents")
    func writesFile() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.txt")

        let tool = createWriteTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            ["path": .string(file.path), "content": .string("Test content")],
            nil, nil
        )
        #expect(textOutput(result).contains("Successfully wrote"))
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written == "Test content")
    }

    @Test("creates parent directories when missing")
    func createsParents() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/dir/out.txt")

        let tool = createWriteTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-2",
            ["path": .string(file.path), "content": .string("hi")],
            nil, nil
        )
        #expect(textOutput(result).contains("Successfully wrote"))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite("Edit tool")
struct EditToolTests {
    @Test("replaces text in a file")
    func replacesText() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("edit.txt")
        try write("Hello, world!", to: file)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("world"), "newText": .string("testing")])
        ])
        let result = try await tool.execute(
            "call-1",
            .object(["path": .string(file.path), "edits": edits]),
            nil, nil
        )

        #expect(textOutput(result).contains("Successfully replaced"))
        if case .object(let details) = result.details ?? .null,
           case .string(let diff) = details["diff"] ?? .null {
            #expect(diff.contains("testing"))
        } else {
            Issue.record("expected diff in details")
        }
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == "Hello, testing!")
    }

    @Test("fails when oldText is not present")
    func missingOldText() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("edit.txt")
        try write("Hello, world!", to: file)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("nonexistent"), "newText": .string("x")])
        ])
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-2",
                .object(["path": .string(file.path), "edits": edits]),
                nil, nil
            )
        }
    }

    @Test("fails when oldText matches multiple locations")
    func ambiguousOldText() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("edit.txt")
        try write("foo foo foo", to: file)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("foo"), "newText": .string("bar")])
        ])
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-3",
                .object(["path": .string(file.path), "edits": edits]),
                nil, nil
            )
        }
    }

    @Test("applies multiple disjoint edits in one call")
    func multipleEdits() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("multi.txt")
        try write("alpha\nbeta\ngamma\ndelta\n", to: file)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("alpha\n"), "newText": .string("ALPHA\n")]),
            .object(["oldText": .string("gamma\n"), "newText": .string("GAMMA\n")]),
        ])
        let result = try await tool.execute(
            "call-4",
            .object(["path": .string(file.path), "edits": edits]),
            nil, nil
        )
        #expect(textOutput(result).contains("Successfully replaced 2 block(s)"))
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == "ALPHA\nbeta\nGAMMA\ndelta\n")
    }
}

@Suite("Bash tool")
struct BashToolTests {
    @Test("runs a simple command and returns stdout")
    func simpleCommand() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            ["command": .string("echo hello-kw")],
            nil, nil
        )
        #expect(textOutput(result).contains("hello-kw"))
    }

    @Test("surfaces non-zero exit code as an error")
    func exitCodeFailure() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(cwd: dir.path)
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-2",
                ["command": .string("exit 42")],
                nil, nil
            )
        }
    }

    @Test("respects cancellation")
    func cancels() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(cwd: dir.path)
        let cancel = CancellationHandle()
        Task { @Sendable in
            try? await Task.sleep(nanoseconds: 20_000_000)
            cancel.cancel()
        }
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-3",
                ["command": .string("sleep 5")],
                cancel, nil
            )
        }
    }
}

@Suite("Grep tool")
struct GrepToolTests {
    @Test("returns matches across files")
    func basicGrep() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("needle one\nhaystack\nneedle two", to: dir.appendingPathComponent("a.txt"))
        try write("something else", to: dir.appendingPathComponent("b.txt"))

        let tool = createGrepTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            ["pattern": .string("needle"), "path": .string(dir.path)],
            nil, nil
        )
        let output = textOutput(result)
        #expect(output.contains("needle one"))
        #expect(output.contains("needle two"))
        #expect(!output.contains("something else"))
    }
}

@Suite("Find tool")
struct FindToolTests {
    @Test("finds files matching a glob")
    func findsGlob() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("x", to: dir.appendingPathComponent("one.swift"))
        try write("x", to: dir.appendingPathComponent("sub/two.swift"))
        try write("x", to: dir.appendingPathComponent("three.txt"))

        let tool = createFindTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            ["pattern": .string("**/*.swift"), "path": .string(dir.path)],
            nil, nil
        )
        let output = textOutput(result)
        #expect(output.contains("one.swift"))
        #expect(output.contains("two.swift"))
        #expect(!output.contains("three.txt"))
    }
}

@Suite("LS tool")
struct LSToolTests {
    @Test("lists a directory's contents")
    func listsDirectory() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("x", to: dir.appendingPathComponent("a.txt"))
        try write("x", to: dir.appendingPathComponent("b.txt"))

        let tool = createLSTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            ["path": .string(dir.path)],
            nil, nil
        )
        let output = textOutput(result)
        #expect(output.contains("a.txt"))
        #expect(output.contains("b.txt"))
    }
}
