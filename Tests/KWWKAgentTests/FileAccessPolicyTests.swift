import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

private func expectPathAccessDenied(
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("expected path access to be denied")
    } catch let error as CodingToolError {
        #expect(error.errorDescription?.contains("Access denied") == true)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Suite("Workspace file access policy")
struct FileAccessPolicyTests {
    @Test("read containment handles normalization, absolute paths, prefixes, home, and symlinks")
    func readContainment() async throws {
        let fixture = makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let inside = fixture.workspace.appendingPathComponent("inside.txt")
        let outside = fixture.prefixCollision.appendingPathComponent("secret.txt")
        try write("inside", to: inside)
        try write("secret", to: outside)

        let insideTarget = fixture.workspace.appendingPathComponent("target.txt")
        try write("target", to: insideTarget)
        let insideLink = fixture.workspace.appendingPathComponent("inside-link.txt")
        try FileManager.default.createSymbolicLink(at: insideLink, withDestinationURL: insideTarget)
        let outsideLink = fixture.workspace.appendingPathComponent("outside-link.txt")
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: outside)

        let tool = createReadTool(cwd: fixture.workspace.path, fileAccessPolicy: .workspaceOnly)

        let normalized = try await tool.execute(
            "read-normalized",
            ["path": .string("sub/../inside.txt")],
            nil,
            nil
        )
        #expect(textOutput(normalized) == "inside")

        let absoluteInside = try await tool.execute(
            "read-absolute-inside",
            ["path": .string(inside.path)],
            nil,
            nil
        )
        #expect(textOutput(absoluteInside) == "inside")

        let linkedInside = try await tool.execute(
            "read-linked-inside",
            ["path": .string(insideLink.path)],
            nil,
            nil
        )
        #expect(textOutput(linkedInside) == "target")

        await expectPathAccessDenied {
            _ = try await tool.execute(
                "read-dotdot",
                ["path": .string("../\(fixture.prefixCollision.lastPathComponent)/secret.txt")],
                nil,
                nil
            )
        }
        await expectPathAccessDenied {
            _ = try await tool.execute(
                "read-prefix-collision",
                ["path": .string(outside.path)],
                nil,
                nil
            )
        }
        await expectPathAccessDenied {
            _ = try await tool.execute(
                "read-symlink-escape",
                ["path": .string(outsideLink.path)],
                nil,
                nil
            )
        }
        await expectPathAccessDenied {
            _ = try PathUtils.resolveForAccess(
                "~",
                cwd: fixture.workspace.path,
                policy: .workspaceOnly,
                intent: .read
            )
        }
    }

    @Test("unrestricted remains the default and explicit extra roots are access-specific")
    func compatibilityAndAdditionalRoots() async throws {
        let fixture = makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let outside = fixture.prefixCollision.appendingPathComponent("outside.txt")
        try write("outside", to: outside)

        let legacy = createReadTool(cwd: fixture.workspace.path)
        let legacyResult = try await legacy.execute(
            "read-unrestricted",
            ["path": .string(outside.path)],
            nil,
            nil
        )
        #expect(textOutput(legacyResult) == "outside")

        let readPolicy = FileAccessPolicy.workspaceOnly(
            additionalReadRoots: [fixture.prefixCollision.path]
        )
        let allowedRead = createReadTool(
            cwd: fixture.workspace.path,
            fileAccessPolicy: readPolicy
        )
        let readResult = try await allowedRead.execute(
            "read-allowlist",
            ["path": .string(outside.path)],
            nil,
            nil
        )
        #expect(textOutput(readResult) == "outside")

        let created = fixture.prefixCollision.appendingPathComponent("new/deep/file.txt")
        let writePolicy = FileAccessPolicy.workspaceOnly(
            additionalWriteRoots: [fixture.prefixCollision.path]
        )
        let allowedWrite = createWriteTool(
            cwd: fixture.workspace.path,
            fileAccessPolicy: writePolicy
        )
        _ = try await allowedWrite.execute(
            "write-allowlist",
            ["path": .string(created.path), "content": .string("created")],
            nil,
            nil
        )
        #expect(try String(contentsOf: created, encoding: .utf8) == "created")
    }

    @Test("write allows a missing in-workspace target but rejects a missing target through an escaping symlink")
    func missingWriteTargetAndSymlinkAncestor() async throws {
        let fixture = makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let tool = createWriteTool(cwd: fixture.workspace.path, fileAccessPolicy: .workspaceOnly)

        let inside = fixture.workspace.appendingPathComponent("new/deep/file.txt")
        _ = try await tool.execute(
            "write-inside",
            ["path": .string(inside.path), "content": .string("ok")],
            nil,
            nil
        )
        #expect(try String(contentsOf: inside, encoding: .utf8) == "ok")

        let outsideDirectoryLink = fixture.workspace.appendingPathComponent("external-dir")
        try FileManager.default.createSymbolicLink(
            at: outsideDirectoryLink,
            withDestinationURL: fixture.prefixCollision
        )
        let escaped = outsideDirectoryLink.appendingPathComponent("not-created/file.txt")
        await expectPathAccessDenied {
            _ = try await tool.execute(
                "write-symlink-ancestor",
                ["path": .string(escaped.path), "content": .string("no")],
                nil,
                nil
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.prefixCollision.appendingPathComponent("not-created/file.txt").path
        ))
    }

    @Test("edit rejects an existing symlink whose target is outside the workspace")
    func editSymlinkEscape() async throws {
        let fixture = makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let outside = fixture.prefixCollision.appendingPathComponent("editable.txt")
        try write("before", to: outside)
        let link = fixture.workspace.appendingPathComponent("editable.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let tool = createEditTool(cwd: fixture.workspace.path, fileAccessPolicy: .workspaceOnly)

        await expectPathAccessDenied {
            _ = try await tool.execute(
                "edit-symlink-escape",
                [
                    "path": .string(link.path),
                    "edits": .array([
                        .object(["oldText": .string("before"), "newText": .string("after")])
                    ]),
                ],
                nil,
                nil
            )
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "before")
    }

    @Test("grep, find, and ls reject a traversal root symlinked outside the workspace")
    func recursiveToolRoots() async throws {
        let fixture = makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write("needle", to: fixture.prefixCollision.appendingPathComponent("secret.txt"))
        let link = fixture.workspace.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.prefixCollision)

        let grep = createGrepTool(cwd: fixture.workspace.path, fileAccessPolicy: .workspaceOnly)
        await expectPathAccessDenied {
            _ = try await grep.execute(
                "grep-outside",
                ["pattern": .string("needle"), "path": .string(link.path)],
                nil,
                nil
            )
        }

        let find = createFindTool(cwd: fixture.workspace.path, fileAccessPolicy: .workspaceOnly)
        await expectPathAccessDenied {
            _ = try await find.execute(
                "find-outside",
                ["pattern": .string("*.txt"), "path": .string(link.path)],
                nil,
                nil
            )
        }

        let ls = createLSTool(cwd: fixture.workspace.path, fileAccessPolicy: .workspaceOnly)
        await expectPathAccessDenied {
            _ = try await ls.execute(
                "ls-outside",
                ["path": .string(link.path)],
                nil,
                nil
            )
        }
    }

    @Test("buildCodingToolList forwards the path policy")
    func builderForwardsPolicy() async throws {
        let fixture = makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let outside = fixture.prefixCollision.appendingPathComponent("secret.txt")
        try write("secret", to: outside)
        let tools = buildCodingToolList(
            cwd: fixture.workspace.path,
            selected: .read,
            backgroundManager: nil,
            sessionId: nil,
            fileAccessPolicy: .workspaceOnly,
            bashEnvironment: [:]
        )
        let read = try #require(tools.first { $0.name == "read" })

        await expectPathAccessDenied {
            _ = try await read.execute(
                "builder-read-outside",
                ["path": .string(outside.path)],
                nil,
                nil
            )
        }
    }
}

private struct PolicyFixture {
    var container: URL
    var workspace: URL
    var prefixCollision: URL
}

private func makePolicyFixture() -> PolicyFixture {
    let container = makeTempDir("kw-file-policy")
    let workspace = container.appendingPathComponent("repo")
    let prefixCollision = container.appendingPathComponent("repo-private")
    try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: prefixCollision, withIntermediateDirectories: true)
    return PolicyFixture(
        container: container,
        workspace: workspace,
        prefixCollision: prefixCollision
    )
}
