import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// The default (no-manager) bash path used to read its pipes only after
/// `waitUntilExit`, deadlocking on any command whose output exceeded the
/// ~64KB pipe buffer. These tests drive far more than that through both
/// stdout and stderr; a regression would hang (child blocked in write(2),
/// parent in wait) instead of completing.
@Suite("Bash output draining + bounding")
struct BashOutputBoundingTests {
    @Test("large stdout does not deadlock and is head/tail-bounded with a saved copy")
    func largeStdout() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(
            cwd: dir.path,
            options: BashToolOptions(environment: testBashEnvironment)
        )
        let result = try await tool.execute(
            "call-1",
            ["command": .string("seq 1 100000")],
            nil,
            nil
        )
        let text = textOutput(result)
        // Completed (didn't hang), head and tail preserved, and bounded to
        // ~16KB of the raw ~600KB the command emitted.
        #expect(text.hasSuffix("100000"))
        #expect(text.hasPrefix("1\n2\n"))
        #expect(text.contains("[… output truncated: "))
        #expect(text.utf8.count <= Truncate.bashHeadBytes + Truncate.bashTailBytes + 1_024)
        // The pipe path has no output file of its own: one is saved and named.
        guard case .object(let details) = result.details ?? .null,
              case .string(let path) = details["outputFile"] ?? .null else {
            Issue.record("expected details.outputFile for truncated output")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(text.contains("full output: \(path)"))
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("\n50000\n"))
        #expect(contents.hasSuffix("100000\n"))
    }

    @Test("large stderr does not deadlock")
    func largeStderr() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(
            cwd: dir.path,
            options: BashToolOptions(environment: testBashEnvironment)
        )
        // Exit 0 with everything on stderr; the body is the stderr stream.
        let result = try await tool.execute(
            "call-2",
            ["command": .string("seq 1 100000 1>&2")],
            nil,
            nil
        )
        let text = textOutput(result)
        #expect(text.hasSuffix("100000"))
    }

    @Test("a failing command's output is bounded too")
    func failingLegacyOutputIsBounded() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = createBashTool(
            cwd: dir.path,
            options: BashToolOptions(environment: testBashEnvironment)
        )
        do {
            _ = try await tool.execute(
                "call-3",
                ["command": .string("seq 1 100000 1>&2; exit 4")],
                nil,
                nil
            )
            Issue.record("expected commandFailed for exit 4")
        } catch CodingToolError.commandFailed(let stderr, let exitCode) {
            #expect(exitCode == 4)
            #expect(stderr.hasPrefix("1\n2\n"))
            #expect(stderr.hasSuffix("\n100000"))
            #expect(stderr.contains("full output: "))
            #expect(stderr.utf8.count <= Truncate.bashHeadBytes + Truncate.bashTailBytes + 1_024)
        }
    }
}
