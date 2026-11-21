import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

// Regression coverage for the file-tool / builder hardening pass.
// Shared helpers (`makeTempDir`, `write`, `textOutput`) live in ReadToolTests.

@Suite("Edit/Write preserve symlinks")
struct SymlinkWriteTests {
    @Test("edit writes through a symlink and leaves the link intact")
    func editWritesThroughSymlink() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.txt")
        try write("hello world", to: target)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("world"), "newText": .string("swift")])
        ])
        _ = try await tool.execute(
            "call-edit-symlink",
            .object(["path": .string(link.path), "edits": edits]),
            nil,
            nil
        )

        // The link is still a symlink pointing at the same target...
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(destination == target.path)
        // ...and the edit landed on the real target file, not a detached copy.
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello swift")
    }

    @Test("write writes through a symlink and leaves the link intact")
    func writeWritesThroughSymlink() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.txt")
        try write("original", to: target)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let tool = createWriteTool(cwd: dir.path)
        _ = try await tool.execute(
            "call-write-symlink",
            ["path": .string(link.path), "content": .string("replaced")],
            nil,
            nil
        )

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(destination == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replaced")
    }

    @Test("write preserves an existing file's inode")
    func writePreservesInode() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("keep-inode.txt")
        try write("before", to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int

        let tool = createWriteTool(cwd: dir.path)
        _ = try await tool.execute(
            "call-inode",
            ["path": .string(file.path), "content": .string("after")],
            nil,
            nil
        )

        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        #expect(before != nil)
        #expect(before == after)
        #expect(try String(contentsOf: file, encoding: .utf8) == "after")
    }
}

@Suite("Grep filtering and context")
struct GrepHardeningTests {
    @Test("glob filters candidate files and pruned dirs are skipped")
    func globAndPruning() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("needle here", to: dir.appendingPathComponent("a.swift"))
        try write("needle there", to: dir.appendingPathComponent("b.txt"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try write("needle nested", to: dir.appendingPathComponent("sub/c.swift"))
        // A match inside .git must be pruned even though it is a plain text file.
        let git = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try write("needle in git config", to: git.appendingPathComponent("config"))

        let tool = createGrepTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-grep-glob",
            ["pattern": .string("needle"), "path": .string(dir.path), "glob": .string("*.swift")],
            nil,
            nil
        )
        let output = textOutput(result)
        #expect(output.contains("a.swift"))
        #expect(output.contains("c.swift"))
        #expect(!output.contains("b.txt"))
        #expect(!output.contains("config"))
    }

    @Test("context parameter emits surrounding lines")
    func contextLines() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ctx.txt")
        try write("line before\nMATCH here\nline after", to: file)

        let tool = createGrepTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-grep-ctx",
            ["pattern": .string("MATCH"), "path": .string(file.path), "context": 1],
            nil,
            nil
        )
        let output = textOutput(result)
        #expect(output.contains("line before"))
        #expect(output.contains("MATCH here"))
        #expect(output.contains("line after"))
        // The match line uses `:`, context lines use `-`.
        #expect(output.contains("\(file.path):2:MATCH here"))
        #expect(output.contains("\(file.path)-1-line before"))
        #expect(output.contains("\(file.path)-3-line after"))
    }

    @Test("binary files are skipped")
    func skipsBinary() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("needle text", to: dir.appendingPathComponent("text.txt"))
        // A file containing a NUL byte next to the pattern bytes.
        var binary = Data("needle".utf8)
        binary.append(0)
        binary.append(Data("binary".utf8))
        try binary.write(to: dir.appendingPathComponent("blob.bin"))

        let tool = createGrepTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-grep-bin",
            ["pattern": .string("needle"), "path": .string(dir.path)],
            nil,
            nil
        )
        let output = textOutput(result)
        #expect(output.contains("text.txt"))
        #expect(!output.contains("blob.bin"))
    }
}

@Suite("Glob translation")
struct GlobHardeningTests {
    @Test("bracket characters are matched literally, not as a character class")
    func bracketsAreLiteral() {
        #expect(Glob.matches(path: "file[1].txt", pattern: "file[1].txt"))
        #expect(!Glob.matches(path: "file1.txt", pattern: "file[1].txt"))
    }

    @Test("expand prunes VCS and dependency directories")
    func expandPrunes() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("x", to: dir.appendingPathComponent("keep.swift"))
        for pruned in [".git", "node_modules"] {
            let sub = dir.appendingPathComponent(pruned)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try write("x", to: sub.appendingPathComponent("ignored.swift"))
        }
        let matches = Glob.expand(root: dir.path, pattern: "**/*.swift")
        #expect(matches.contains { $0.hasSuffix("keep.swift") })
        #expect(!matches.contains { $0.contains("/.git/") })
        #expect(!matches.contains { $0.contains("/node_modules/") })
    }
}

/// Fakes serving a 5,000-entry tree without touching the disk.
private struct ManyFindOperations: FindOperations {
    let count: Int
    let nameLength: Int
    func find(pattern: String, cwd: String, limit: Int?) async throws -> [String] {
        let all = (1...count).lazy.map { index -> String in
            let name = "file\(index)"
            return "/tree/" + name + String(repeating: "x", count: max(0, nameLength - name.count))
        }
        return Array(all.prefix(limit ?? count))
    }
}

private struct ManyLSOperations: LSOperations {
    let count: Int
    func list(path: String) async throws -> [LSEntry] {
        (1...count).map { LSEntry(name: "entry\($0)", kind: .file, size: 1) }
    }
}

@Suite("find / ls output caps")
struct ListingCapTests {
    @Test("find without a limit stops at 1000 entries and says more exist")
    func findDefaultCap() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createFindTool(
            cwd: dir.path,
            options: FindToolOptions(operations: ManyFindOperations(count: 5_000, nameLength: 10))
        )
        let result = try await tool.execute("find-cap", ["pattern": "*"], nil, nil)
        let text = textOutput(result)
        #expect(text.contains("/tree/file1000xx\n"))
        #expect(!text.contains("/tree/file1001"))
        #expect(text.hasSuffix("[truncated: showing the first 1000 entries; more exist — pass limit or narrow the pattern or path]"))
        guard case .object(let details) = result.details ?? .null,
              case .array(let files) = details["files"] ?? .null else {
            Issue.record("expected files details")
            return
        }
        #expect(files.count == 1_000)
    }

    @Test("find with an explicit limit returns exactly that many, with a notice only when more exist")
    func findExplicitLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createFindTool(
            cwd: dir.path,
            options: FindToolOptions(operations: ManyFindOperations(count: 2_500, nameLength: 10))
        )
        let wide = textOutput(try await tool.execute("find-wide", ["pattern": "*", "limit": 2_500], nil, nil))
        #expect(wide.contains("/tree/file2500"))
        #expect(!wide.contains("[truncated"))
        let narrow = textOutput(try await tool.execute("find-narrow", ["pattern": "*", "limit": 2_000], nil, nil))
        #expect(narrow.contains("/tree/file2000"))
        #expect(!narrow.contains("/tree/file2001"))
        #expect(narrow.contains("more exist — pass a larger limit"))
    }

    @Test("find caps the listing at 50KB whatever the limit")
    func findByteCap() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createFindTool(
            cwd: dir.path,
            options: FindToolOptions(operations: ManyFindOperations(count: 5_000, nameLength: 200))
        )
        let text = textOutput(try await tool.execute("find-bytes", ["pattern": "*", "limit": 5_000], nil, nil))
        #expect(text.utf8.count <= Truncate.listingMaxBytes + 256)
        #expect(text.contains("(50.0KB limit); narrow the pattern or path"))
    }

    @Test("ls without a limit stops at 500 entries and says more exist")
    func lsDefaultCap() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createLSTool(cwd: dir.path, options: LSToolOptions(operations: ManyLSOperations(count: 5_000)))
        let result = try await tool.execute("ls-cap", ["path": .string(dir.path)], nil, nil)
        let text = textOutput(result)
        #expect(text.hasPrefix("entry1\nentry2\n"))
        #expect(text.contains("\nentry500\n"))
        #expect(!text.contains("entry501"))
        #expect(text.hasSuffix("[truncated: showing the first 500 entries; more exist — pass limit or narrow the pattern or path]"))
        guard case .object(let details) = result.details ?? .null,
              case .array(let entries) = details["entries"] ?? .null else {
            Issue.record("expected entries details")
            return
        }
        #expect(entries.count == 500)

        let all = textOutput(try await tool.execute(
            "ls-all",
            ["path": .string(dir.path), "limit": 5_000],
            nil,
            nil
        ))
        #expect(all.contains("\nentry5000"))
        #expect(!all.contains("[truncated"))
    }

    @Test("a small directory lists without a notice")
    func lsSmall() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createLSTool(cwd: dir.path, options: LSToolOptions(operations: ManyLSOperations(count: 3)))
        let text = textOutput(try await tool.execute("ls-small", ["path": .string(dir.path)], nil, nil))
        #expect(text == "entry1\nentry2\nentry3")
    }
}
