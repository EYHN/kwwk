import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

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

    @Test("allows explicit paths outside cwd")
    func allowsOutsideCwd() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outside = outsideDir.appendingPathComponent("secret.txt")
        try write("secret", to: outside)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute("call-outside", ["path": .string(outside.path)], nil, nil)
        #expect(textOutput(result) == "secret")
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

    @Test("allows explicit writes outside cwd")
    func allowsOutsideCwd() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outside = outsideDir.appendingPathComponent("out.txt")

        let tool = createWriteTool(cwd: dir.path)
        _ = try await tool.execute(
            "call-outside",
            ["path": .string(outside.path), "content": .string("outside")],
            nil, nil
        )
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
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
        let updates = EditUpdateCapture()
        let edits: JSONValue = .array([
            .object(["oldText": .string("world"), "newText": .string("testing")])
        ])
        let result = try await tool.execute(
            "call-1",
            .object(["path": .string(file.path), "edits": edits]),
            nil,
            { updates.record($0) }
        )

        #expect(textOutput(result).contains("Successfully replaced"))
        if case .object(let details) = result.details ?? .null,
           case .string(let diff) = details["diff"] ?? .null,
           case .string(let patch) = details["patch"] ?? .null,
           case .int(let firstChangedLine) = details["firstChangedLine"] ?? .null {
            #expect(diff.contains("testing"))
            #expect(patch.contains("--- \(file.path)"))
            #expect(patch.contains("+++ \(file.path)"))
            #expect(firstChangedLine == 1)
        } else {
            Issue.record("expected diff, patch, and firstChangedLine in details")
        }
        let previewDisplays = updates.uiDisplays()
        #expect(previewDisplays.contains(where: { $0.contains("Previewing 1 replacement") }))
        #expect(previewDisplays.contains(where: { $0.contains("testing") }))
        #expect(result.uiDisplay?.contains(where: { $0.contains("Successfully replaced") }) == true)
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

    @Test("missing target error includes POSIX code")
    func missingTargetIncludesPOSIXCode() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.txt")

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("hello"), "newText": .string("world")])
        ])
        do {
            _ = try await tool.execute(
                "call-missing-target",
                .object(["path": .string(missing.path), "edits": edits]),
                nil, nil
            )
            Issue.record("expected missing target to throw")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            #expect(message.contains("Could not edit file: \(missing.path). Error code: ENOENT."))
        }
    }

    @Test("directory target error includes POSIX code")
    func directoryTargetIncludesPOSIXCode() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("hello"), "newText": .string("world")])
        ])
        do {
            _ = try await tool.execute(
                "call-directory-target",
                .object(["path": .string(dir.path), "edits": edits]),
                nil, nil
            )
            Issue.record("expected directory target to throw")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            #expect(message.contains("Could not edit file: \(dir.path). Error code: EISDIR."))
        }
    }

    @Test("permission target error includes POSIX code")
    func permissionTargetIncludesPOSIXCode() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("no-access.txt")
        try write("hello", to: file)

        let tool = createEditTool(
            cwd: dir.path,
            options: EditToolOptions(operations: AccessDeniedEditOperations())
        )
        let edits: JSONValue = .array([
            .object(["oldText": .string("hello"), "newText": .string("world")])
        ])
        do {
            _ = try await tool.execute(
                "call-permission-target",
                .object(["path": .string(file.path), "edits": edits]),
                nil, nil
            )
            Issue.record("expected permission target to throw")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            #expect(message.contains("Could not edit file: \(file.path). Error code: EACCES."))
        }
    }

    @Test("allows explicit edits outside cwd")
    func allowsOutsideCwd() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outside = outsideDir.appendingPathComponent("edit.txt")
        try write("secret", to: outside)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("secret"), "newText": .string("changed")])
        ])
        _ = try await tool.execute(
            "call-outside",
            .object(["path": .string(outside.path), "edits": edits]),
            nil, nil
        )
        #expect(try String(contentsOf: outside, encoding: .utf8) == "changed")
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

    @Test("collapses large unchanged gaps in displayed diff")
    func collapsedLargeGapDiff() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("large-gap.txt")
        let lines = (1...600).map { "line \(String(format: "%03d", $0))" }
        try write(lines.joined(separator: "\n") + "\n", to: file)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("line 100\n"), "newText": .string("LINE 100\n")]),
            .object(["oldText": .string("line 300\n"), "newText": .string("LINE 300\n")]),
            .object(["oldText": .string("line 500\n"), "newText": .string("LINE 500\n")]),
        ])
        let result = try await tool.execute(
            "call-large-gap",
            .object(["path": .string(file.path), "edits": edits]),
            nil, nil
        )

        guard case .object(let details) = result.details ?? .null,
              case .string(let diff) = details["diff"] ?? .null else {
            Issue.record("expected diff in details")
            return
        }
        #expect(diff.contains("LINE 100"))
        #expect(diff.contains("LINE 300"))
        #expect(diff.contains("LINE 500"))
        #expect(diff.contains("..."))
        #expect(!diff.contains("line 250"))
        #expect(diff.components(separatedBy: "\n").count < 60)
    }
}

@Suite("Path utilities")
struct PathUtilsTests {
    @Test("resolveToCwd strips at-prefix and normalizes unicode spaces")
    func stripsAtPrefixAndNormalizesSpaces() {
        let resolved = PathUtils.resolveToCwd("@nested\u{00A0}dir/file.txt", cwd: "/tmp/root")
        #expect(resolved == "/tmp/root/nested dir/file.txt")
    }

    @Test("resolveToCwd expands tilde only for tilde paths")
    func expandsTildePaths() {
        #expect(PathUtils.resolveToCwd("~/file.txt", cwd: "/tmp").hasPrefix(NSHomeDirectory()))
        #expect(PathUtils.resolveToCwd("~not-home/file.txt", cwd: "/tmp") == "/tmp/~not-home/file.txt")
    }
}

private final class EditUpdateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [AgentToolResult] = []

    func record(_ update: AgentToolResult) {
        lock.withLock { updates.append(update) }
    }

    func uiDisplays() -> [String] {
        lock.withLock { updates.flatMap { $0.uiDisplay ?? [] } }
    }
}

private struct AccessDeniedEditOperations: EditOperations {
    func readFile(_ absolutePath: String) async throws -> Data {
        Issue.record("readFile should not be called after access fails")
        return Data()
    }

    func writeFile(_ absolutePath: String, content: Data) async throws {
        Issue.record("writeFile should not be called after access fails")
    }

    func access(_ absolutePath: String) async throws {
        throw POSIXError(.EACCES)
    }
}

@Suite("Bash tool")
struct BashToolTests {
    @Test("runs a simple command and returns stdout")
    func simpleCommand() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(
            cwd: dir.path,
            options: BashToolOptions(environment: testBashEnvironment)
        )
        let result = try await tool.execute(
            "call-1",
            ["command": .string("echo hello-kw")],
            nil, nil
        )
        #expect(textOutput(result).contains("hello-kw"))
    }

    @Test("uses only the explicit environment")
    func explicitEnvironmentOnly() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(
            cwd: dir.path,
            options: BashToolOptions(environment: testBashEnvironment)
        )
        let result = try await tool.execute(
            "call-env",
            ["command": .string("printf '<%s>' \"$HOME\"")],
            nil, nil
        )
        #expect(textOutput(result) == "<>")
    }

    @Test("surfaces non-zero exit code as an error")
    func exitCodeFailure() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(
            cwd: dir.path,
            options: BashToolOptions(environment: testBashEnvironment)
        )
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
        let tool = createBashTool(
            cwd: dir.path,
            options: BashToolOptions(environment: testBashEnvironment)
        )
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

    @Test("a glob with a slash matches relative to the search root")
    func slashGlobMatchesRelativeToRoot() async throws {
        // makeTempDir lives under /var on macOS — a firmlink the enumerator
        // resolves to /private/var. The relative-path slice must use the same
        // canonical base or the glob prefix is cut at the wrong offset and
        // nothing matches (the bug Glob.canonicalDirectoryPath fixes).
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/nested"), withIntermediateDirectories: true)
        try write("needle direct", to: dir.appendingPathComponent("src/direct.swift"))
        try write("needle buried", to: dir.appendingPathComponent("src/nested/buried.swift"))
        try write("needle outside", to: dir.appendingPathComponent("top.swift"))

        let tool = createGrepTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            [
                "pattern": .string("needle"),
                "path": .string(dir.path),
                "glob": .string("src/*.swift"),
            ],
            nil, nil
        )
        let output = textOutput(result)
        #expect(output.contains("needle direct"))
        // `src/*.swift` does not cross into src/nested and never leaves src.
        #expect(!output.contains("needle buried"))
        #expect(!output.contains("needle outside"))
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

    @Test("a slashless pattern matches by name at any depth (recursive)")
    func slashlessPatternRecurses() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try write("x", to: dir.appendingPathComponent("top.swift"))
        try write("x", to: dir.appendingPathComponent("sub/mid.swift"))
        try write("x", to: dir.appendingPathComponent("sub/deep/low.swift"))
        try write("x", to: dir.appendingPathComponent("sub/note.txt"))

        let tool = createFindTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            ["pattern": .string("*.swift"), "path": .string(dir.path)],
            nil, nil
        )
        let output = textOutput(result)
        // Every .swift, regardless of depth — not just the top-level one.
        #expect(output.contains("top.swift"))
        #expect(output.contains("mid.swift"))
        #expect(output.contains("low.swift"))
        #expect(!output.contains("note.txt"))
    }

    @Test("a pattern with a slash scopes to that directory, not deeper")
    func slashPatternScopesToDirectory() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/nested"), withIntermediateDirectories: true)
        try write("x", to: dir.appendingPathComponent("src/direct.swift"))
        try write("x", to: dir.appendingPathComponent("src/nested/buried.swift"))

        let tool = createFindTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            ["pattern": .string("src/*.swift"), "path": .string(dir.path)],
            nil, nil
        )
        let output = textOutput(result)
        #expect(output.contains("direct.swift"))
        // `src/*.swift` does not cross into src/nested — that needs src/**/*.swift.
        #expect(!output.contains("buried.swift"))
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
