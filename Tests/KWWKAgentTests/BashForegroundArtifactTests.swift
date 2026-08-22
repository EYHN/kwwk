import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// A foreground command whose inline output was truncated used to have its raw
/// output file deleted on completion, permanently losing the middle of the log
/// — exactly where a build's first compile error lands. These tests pin the
/// replacement contract: truncated output keeps a manager-tracked artifact and
/// the truncation notice points at it, untruncated output leaves nothing
/// behind, and retained artifacts are garbage-collected oldest first.
@Suite("Bash foreground output artifacts", .serialized)
struct BashForegroundArtifactTests {
    private func makeTool(manager: BackgroundTaskManager, cwd: URL) -> AgentTool {
        createBashTool(cwd: cwd.path, options: BashToolOptions(
            environment: testBashEnvironment,
            manager: manager,
            sessionId: "fg-artifacts"
        ))
    }

    @Test("truncated foreground output keeps the raw artifact and points at it")
    func truncatedOutputKeepsArtifact() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = makeTool(manager: manager, cwd: cwdDir)

        let result = try await tool.execute(
            "truncated-fg",
            ["command": .string("seq 1 100000")],
            nil, nil
        )
        let text = textOutput(result)
        #expect(text.hasPrefix("[output truncated:"))
        #expect(text.contains("full output kept at "))
        #expect(text.hasSuffix("100000"))

        guard case .object(let details) = result.details ?? .null,
              case .string(let path) = details["outputFile"] ?? .null else {
            Issue.record("expected details.outputFile for truncated output")
            return
        }
        #expect(text.contains(path))
        // The middle of the log — unreachable inline — is on disk in full.
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.hasPrefix("1\n2\n"))
        #expect(contents.contains("\n50000\n"))
    }

    @Test("untruncated foreground output deletes the artifact as before")
    func untruncatedOutputDeletesArtifact() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = makeTool(manager: manager, cwd: cwdDir)

        let result = try await tool.execute(
            "small-fg",
            ["command": .string("echo small-output")],
            nil, nil
        )
        let text = textOutput(result)
        #expect(text.contains("small-output"))
        #expect(!text.contains("[output truncated:"))
        if case .object(let details) = result.details ?? .null {
            #expect(details["outputFile"] == nil)
        }
        let leftovers = (try? FileManager.default
            .contentsOfDirectory(atPath: outputDir.path)) ?? []
        #expect(!leftovers.contains { $0.hasPrefix("fg_") })
    }

    @Test("failing truncated command keeps the artifact and the error points at it")
    func failingTruncatedCommandKeepsArtifact() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = makeTool(manager: manager, cwd: cwdDir)

        do {
            _ = try await tool.execute(
                "failing-fg",
                ["command": .string("seq 1 100000; exit 3")],
                nil, nil
            )
            Issue.record("expected commandFailed for exit 3")
        } catch CodingToolError.commandFailed(let stderr, let exitCode) {
            #expect(exitCode == 3)
            #expect(stderr.contains("full output kept at "))
            let leftovers = (try? FileManager.default
                .contentsOfDirectory(atPath: outputDir.path)) ?? []
            #expect(leftovers.contains { $0.hasPrefix("fg_") })
        }
    }

    @Test("retained artifacts are garbage-collected oldest first")
    func retainedArtifactsPruneOldestFirst() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        await manager.setRetainedForegroundOutputLimits(
            count: 2,
            bytes: 64 * 1024 * 1024
        )
        let tool = makeTool(manager: manager, cwd: cwdDir)

        var paths: [String] = []
        for call in 0..<3 {
            let result = try await tool.execute(
                "gc-fg-\(call)",
                ["command": .string("seq 1 100000")],
                nil, nil
            )
            guard case .object(let details) = result.details ?? .null,
                  case .string(let path) = details["outputFile"] ?? .null else {
                Issue.record("expected details.outputFile for truncated output")
                return
            }
            paths.append(path)
        }
        #expect(!FileManager.default.fileExists(atPath: paths[0]))
        #expect(FileManager.default.fileExists(atPath: paths[1]))
        #expect(FileManager.default.fileExists(atPath: paths[2]))
    }
}

/// Expose the retention bounds so the GC test can squeeze them.
extension BackgroundTaskManager {
    func setRetainedForegroundOutputLimits(count: Int, bytes: Int) {
        retainedForegroundOutputLimit = count
        retainedForegroundOutputByteLimit = bytes
    }
}
