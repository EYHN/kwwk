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
    @Test("large stdout does not deadlock and is tail-bounded")
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
            nil, nil
        )
        let text = textOutput(result)
        // Completed (didn't hang), tail preserved, and bounded well under the
        // raw ~600KB the command emitted.
        #expect(text.hasSuffix("100000"))
        #expect(text.hasPrefix("[output truncated:"))
        #expect(text.utf8.count < 200_000)
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
            nil, nil
        )
        let text = textOutput(result)
        #expect(text.hasSuffix("100000"))
    }
}
