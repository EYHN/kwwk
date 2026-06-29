import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("wait_task tool", .serialized)
struct WaitTaskToolTests {

    @Test("returns immediately when the task is already terminal")
    func fastPathTerminal() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(command: "echo quick", environment: testBashEnvironment)
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")
        let done = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for task before fast-path wait")
            return
        }

        let tool = createWaitTaskTool(manager: manager, sessionId: "s1")
        let start = Date()
        let result = try await tool.execute(
            "c1",
            .object(["task_id": .string(taskId)]),
            nil,
            nil
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.1, "fast path should skip the poll loop when terminal")
        if case .object(let obj) = result.details ?? .null {
            if case .bool(let waited) = obj["waited"] ?? .null { #expect(waited == true) }
            if case .bool(let to) = obj["timed_out"] ?? .null { #expect(to == false) }
            if case .string(let s) = obj["status"] ?? .null { #expect(s == "completed") }
        }
    }

    @Test("blocks until a running task finishes")
    func blocksUntilComplete() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(
            command: "sleep 0.3 && echo slow-done",
            environment: testBashEnvironment
        )
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")

        let tool = createWaitTaskTool(manager: manager, sessionId: "s1")
        let result = try await tool.execute(
            "c1",
            .object(["task_id": .string(taskId), "timeout_seconds": .int(5)]),
            nil,
            nil
        )
        if case .object(let obj) = result.details ?? .null {
            if case .bool(let to) = obj["timed_out"] ?? .null { #expect(to == false) }
            if case .string(let s) = obj["status"] ?? .null {
                #expect(s == "completed", "status was \(s)")
            }
        }
        if case .text(let t) = result.content.first {
            #expect(t.text.contains("slow-done"))
        }
    }

    @Test("surfaces timed_out=true when the task is still running at the deadline")
    func timesOutCleanly() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = NeverCompletingRunner(label: "wait-timeout")
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")
        defer { Task { try? await manager.kill(taskId) } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let tool = createWaitTaskTool(manager: manager, sessionId: "s1")
        let start = Date()
        let result = try await tool.execute(
            "c1",
            .object(["task_id": .string(taskId), "timeout_seconds": .int(1)]),
            nil,
            nil
        )
        let elapsed = Date().timeIntervalSince(start)
        // The real checks are the returned timeout status below and that the
        // tool did not skip its polling loop by returning immediately.
        #expect(elapsed >= 0.9, "wait_task returned too quickly: \(elapsed)s")
        if case .object(let obj) = result.details ?? .null {
            if case .bool(let to) = obj["timed_out"] ?? .null { #expect(to == true) }
            if case .bool(let w) = obj["waited"] ?? .null { #expect(w == false) }
            if case .string(let s) = obj["status"] ?? .null { #expect(s == "running") }
        }
    }

    @Test("rejects task_ids that belong to a different session")
    func rejectsCrossSession() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let (taskId, _) = await manager.spawn(
            runner: BashBackgroundRunner(command: "sleep 30", environment: testBashEnvironment),
            sessionId: "sA"
        )
        defer { Task { try? await manager.kill(taskId) } }

        let tool = createWaitTaskTool(manager: manager, sessionId: "sB")
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "c1",
                .object(["task_id": .string(taskId)]),
                nil,
                nil
            )
        }
    }

    @Test("aborts the wait when the tool's cancellation handle fires")
    func honorsCancellation() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let (taskId, _) = await manager.spawn(
            runner: NeverCompletingRunner(label: "wait-cancel"),
            sessionId: "s1"
        )
        defer { Task { try? await manager.kill(taskId) } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let cancel = CancellationHandle()
        let tool = createWaitTaskTool(manager: manager, sessionId: "s1")
        cancel.cancel(reason: "test")

        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "c1",
                .object(["task_id": .string(taskId), "timeout_seconds": .int(10)]),
                cancel,
                nil
            )
        }
    }

    @Test("invalid timeout values are clamped instead of rejected")
    func clampsTimeout() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let (taskId, _) = await manager.spawn(
            runner: NeverCompletingRunner(label: "wait-clamp"),
            sessionId: "s1"
        )
        defer { Task { try? await manager.kill(taskId) } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let tool = createWaitTaskTool(manager: manager, sessionId: "s1")
        // timeout_seconds = 0 → clamped to 1 → hits deadline almost
        // immediately and returns timed_out=true. Nothing throws.
        let result = try await tool.execute(
            "c1",
            .object(["task_id": .string(taskId), "timeout_seconds": .int(0)]),
            nil,
            nil
        )
        if case .object(let obj) = result.details ?? .null,
           case .bool(let to) = obj["timed_out"] ?? .null {
            #expect(to == true)
        }
    }
}

// MARK: - Helpers

private struct NeverCompletingRunner: BackgroundTaskRunner {
    let spec: BackgroundTaskSpec

    init(label: String) {
        self.spec = BackgroundTaskSpec(
            kind: "never",
            label: label,
            description: nil,
            hardTimeoutSeconds: 3600
        )
    }

    func run(
        taskId _: String,
        outputFile _: URL,
        cancellation _: CancellationHandle,
        onDone _: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    ) {
    }
}
