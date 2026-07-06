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
            nil, nil
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
            nil, nil
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
            nil, nil
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
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("needle nested", to: dir.appendingPathComponent("sub/c.swift"))
        // A match inside .git must be pruned even though it is a plain text file.
        let git = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try write("needle in git config", to: git.appendingPathComponent("config"))

        let tool = createGrepTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-grep-glob",
            ["pattern": .string("needle"), "path": .string(dir.path), "glob": .string("*.swift")],
            nil, nil
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
            nil, nil
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
            nil, nil
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

@Suite("Coding agent tmux configuration")
struct TmuxConfigValidationTests {
    private func model() -> Model {
        Model(id: "m", name: "m", api: "a", provider: "p")
    }

    @Test("tmux on the agent's tools without a manager throws at build time")
    func agentToolsTmuxThrows() async throws {
        await #expect(throws: CodingAgentConfigError.self) {
            _ = try await makeCodingAgent(CodingAgentConfig(
                model: model(),
                cwd: "/tmp",
                tools: .allIncludingTmux,
                bashEnvironment: [:]
            ))
        }
    }

    @Test("tmux on a subagent's tools without a manager throws at build time")
    func subagentTmuxThrows() async throws {
        let sub = SubagentDefinition(
            name: "pty",
            description: "d",
            prompt: "p",
            tools: [.read, .tmux]
        )
        await #expect(throws: CodingAgentConfigError.self) {
            _ = try await makeCodingAgent(CodingAgentConfig(
                model: model(),
                cwd: "/tmp",
                tools: .readOnly,
                subagents: [sub],
                bashEnvironment: [:]
            ))
        }
    }
}
