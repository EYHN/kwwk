import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kw-bashbg-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private var isCIRunner: Bool {
    ProcessInfo.processInfo.environment["CI"] == "true"
        || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
}

/// True when `pid` is no longer a live, running process: gone (`ESRCH`) or — on
/// Linux — a zombie. When a SIGKILL'd orphan is reparented to an init that
/// doesn't reap promptly (common in CI containers), `kill(pid, 0)` still
/// succeeds even though the process is dead; a zombie counts as terminated.
func processTerminated(_ pid: pid_t) -> Bool {
    if kill(pid, 0) != 0 { return true }
    #if os(Linux)
    guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
          let close = stat.lastIndex(of: ")") else { return true }
    let afterParen = stat[stat.index(after: close)...].drop(while: { $0 == " " })
    return afterParen.first == "Z"
    #else
    return false
    #endif
}

func awaitUntil(
    _ budgetMs: Int,
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    let budgetMs = isCIRunner ? max(budgetMs * 10, budgetMs + 5000) : budgetMs
    let start = Date()
    while Date().timeIntervalSince(start) * 1000 < Double(budgetMs) {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@Suite("BashBackgroundRunner", .serialized)
struct BashBackgroundRunnerTests {

    @Test("runs a command, writes stdout to the output file and reports exit 0")
    func runsAndWrites() async {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(
            command: "echo hello-bg-runner",
            workDir: nil,
            description: "echo test",
            environment: testBashEnvironment
        )
        let (taskId, file) = await manager.spawn(runner: runner, sessionId: "s1")
        let done = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for bash background runner")
            return
        }
        let snap = await manager.get(taskId)
        #expect(snap?.status == .completed)
        if let outcome = snap?.outcome {
            #expect(outcome.success == true)
            #expect(outcome.summary == "exit 0")
        }
        let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(contents.contains("hello-bg-runner"))
    }

    @Test("non-zero exit code is reported as failure")
    func failure() async {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(command: "exit 3", environment: testBashEnvironment)
        let (taskId, _) = await manager.spawn(runner: runner)
        let done = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for failing bash background runner")
            return
        }
        let snap = await manager.get(taskId)
        #expect(snap?.status == .failed)
        #expect(snap?.outcome?.summary == "exit 3")
    }

    @Test("cancellation kills the running process and emits killed outcome")
    func cancel() async {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(command: "sleep 30", environment: testBashEnvironment)
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")
        // Allow process to start.
        try? await Task.sleep(nanoseconds: 50_000_000)
        try? await manager.kill(taskId)
        let done = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for cancelled bash background runner")
            return
        }
        let snap = await manager.get(taskId)
        #expect(snap?.status == .killed)
    }

    @Test("cancellation kills grandchildren, not just the shell (no orphans)")
    func cancelKillsGrandchild() async {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let pidFile = outputDir.appendingPathComponent("grandchild.pid")
        let manager = BackgroundTaskManager(outputDir: outputDir)
        // The shell backgrounds a grandchild `sleep`, records its pid, then
        // blocks. Killing the task must reap the whole process group.
        let runner = BashBackgroundRunner(
            command: "sleep 30 & echo $! > \(pidFile.path); sleep 30",
            environment: testBashEnvironment
        )
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")

        // Wait for the grandchild pid to be recorded and confirm it's alive.
        let started = await awaitUntil(3000) {
            guard let s = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return kill(pid, 0) == 0
        }
        #expect(started)
        let grandchildPid = pid_t(
            (try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ) ?? -1
        #expect(grandchildPid > 0)

        try? await manager.kill(taskId)

        // The grandchild must die (SIGTERM to the group, SIGKILL escalation).
        // Accept a zombie as dead: CI containers may not reap the orphan.
        let reaped = await awaitUntil(5000) {
            processTerminated(grandchildPid)
        }
        #expect(reaped)
    }

    @Test("extraEnv is propagated to the child process")
    func extraEnv() async {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(
            command: "echo $KW_BGTEST_VAR",
            environment: testBashEnvironment,
            extraEnv: ["KW_BGTEST_VAR": "extraenv-works"]
        )
        let (taskId, file) = await manager.spawn(runner: runner, sessionId: "s1")
        let done = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for bash environment propagation")
            return
        }
        let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(contents.contains("extraenv-works"))
    }
}

@Suite("Bash tool + background manager", .serialized)
struct BashToolBackgroundTests {

    @Test("run_in_background=true returns immediately with a task id")
    func explicitBackground() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createBashTool(cwd: cwdDir.path, options: BashToolOptions(
            environment: testBashEnvironment,
            manager: manager,
            sessionId: "s1"
        ))
        let result = try await tool.execute(
            "call-1",
            .object([
                "command": .string("echo hi > out.txt && sleep 0.05 && cat out.txt"),
                "run_in_background": .bool(true),
                "description": .string("echo then cat"),
            ]),
            nil, nil
        )
        guard case .object(let obj) = result.details ?? .null else {
            Issue.record("expected details.object, got \(String(describing: result.details))")
            return
        }
        guard case .string(let status) = obj["status"] ?? .null else {
            Issue.record("expected status string")
            return
        }
        #expect(status == "background_started")
        guard case .string(let taskId) = obj["taskId"] ?? .null else {
            Issue.record("expected taskId string")
            return
        }
        #expect(taskId.hasPrefix("bg_"))

        let done = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for explicit background command")
            return
        }
        let snap = await manager.get(taskId)
        #expect(snap?.status == .completed)
    }

    @Test("foreground command within timeout returns normally (no flip)")
    func foregroundNoFlip() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createBashTool(cwd: cwdDir.path, options: BashToolOptions(
            environment: testBashEnvironment,
            defaultTimeoutSeconds: 30,
            manager: manager,
            sessionId: "s1",
            autoBackgroundOnTimeout: true
        ))
        let result = try await tool.execute(
            "call-1",
            .object(["command": .string("echo fg-works")]),
            nil, nil
        )
        if case .text(let t) = result.content.first {
            #expect(t.text.contains("fg-works"))
        }
        guard case .object(let obj) = result.details ?? .null else {
            Issue.record("expected details.object")
            return
        }
        if case .int(let code) = obj["exitCode"] ?? .null {
            #expect(code == 0)
        } else {
            Issue.record("expected exitCode")
        }
    }

    @Test("missing command argument throws")
    func missingCommand() async {
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let manager = BackgroundTaskManager(outputDir: makeTempDir())
        let tool = createBashTool(cwd: cwdDir.path, options: BashToolOptions(
            environment: testBashEnvironment,
            manager: manager
        ))
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-1",
                .object(["run_in_background": .bool(true)]),
                nil, nil
            )
        }
    }

    @Test("user-supplied timeout is capped at maxTimeoutSeconds")
    func timeoutCap() async throws {
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        // Soft default 2s, cap 3s. A request for 9999s should be clamped to 3s.
        let tool = createBashTool(cwd: cwdDir.path, options: BashToolOptions(
            environment: testBashEnvironment,
            defaultTimeoutSeconds: 2,
            maxTimeoutSeconds: 3,
            manager: manager,
            sessionId: "s1",
            autoBackgroundOnTimeout: true
        ))
        let start = Date()
        let result = try await tool.execute(
            "call-1",
            .object([
                "command": .string("sleep 10"),
                "timeout": .int(9999),
            ]),
            nil, nil
        )
        let elapsed = Date().timeIntervalSince(start)
        // We expect the soft timeout (cap=3s) to fire and the command to flip.
        #expect(elapsed < 5)
        if case .object(let obj) = result.details ?? .null,
           case .string(let status) = obj["status"] ?? .null {
            #expect(status == "auto_backgrounded")
        }
    }

    @Test("soft timeout flips foreground command to background")
    func autoBackgroundOnTimeout() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createBashTool(cwd: cwdDir.path, options: BashToolOptions(
            environment: testBashEnvironment,
            defaultTimeoutSeconds: 1,      // soft timeout = 1s
            manager: manager,
            sessionId: "sF",
            autoBackgroundOnTimeout: true,
            hardTimeoutSeconds: 30
        ))
        let result = try await tool.execute(
            "call-1",
            .object([
                "command": .string("sleep 3; echo done-after-sleep"),
                "description": .string("slow echo"),
            ]),
            nil, nil
        )
        guard case .object(let obj) = result.details ?? .null else {
            Issue.record("expected details.object")
            return
        }
        if case .string(let status) = obj["status"] ?? .null {
            #expect(status == "auto_backgrounded")
        } else {
            Issue.record("expected status=auto_backgrounded")
        }
        guard case .string(let taskId) = obj["taskId"] ?? .null else {
            Issue.record("expected taskId")
            return
        }

        // Wait for the background task to complete.
        let done = await awaitUntil(8000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for auto-backgrounded command")
            return
        }
        let snap = await manager.get(taskId)
        #expect(snap?.status == .completed)
        if let file = snap?.outputFile {
            let contents = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            #expect(contents.contains("done-after-sleep"))
        }
    }
}

@Suite("task_status tool", .serialized)
struct TaskStatusToolTests {

    @Test("list returns running tasks")
    func listRunning() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-bgstatus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(command: "sleep 10", environment: testBashEnvironment)
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let tool = createTaskStatusTool(manager: manager, sessionId: "s1")
        let result = try await tool.execute(
            "call-1",
            .object(["action": .string("list")]),
            nil, nil
        )
        if case .text(let t) = result.content.first {
            #expect(t.text.contains(taskId))
        }
        try? await manager.kill(taskId)
    }

    @Test("status returns details for a task")
    func statusByTaskId() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-bgstatus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(command: "echo hi", environment: testBashEnvironment)
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")
        let done = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for task before status lookup")
            return
        }

        let tool = createTaskStatusTool(manager: manager, sessionId: "s1")
        let result = try await tool.execute(
            "call-1",
            .object(["action": .string("status"), "task_id": .string(taskId)]),
            nil, nil
        )
        if case .text(let t) = result.content.first {
            #expect(t.text.contains("completed"))
        }
    }

    @Test("kill terminates a running task")
    func killViaTool() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-bgstatus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(command: "sleep 30", environment: testBashEnvironment)
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let tool = createTaskStatusTool(manager: manager, sessionId: "s1")
        _ = try await tool.execute(
            "call-1",
            .object(["action": .string("kill"), "task_id": .string(taskId)]),
            nil, nil
        )
        let gone = await awaitUntil(2000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        #expect(gone)
        let snap = await manager.get(taskId)
        #expect(snap?.status == .killed)
    }

    @Test("unknown action throws")
    func unknownAction() async {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createTaskStatusTool(manager: manager, sessionId: "s1")
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "c1",
                .object(["action": .string("nope")]),
                nil, nil
            )
        }
    }

    @Test("status missing task_id throws")
    func statusMissingId() async {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createTaskStatusTool(manager: manager, sessionId: "s1")
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "c1",
                .object(["action": .string("status")]),
                nil, nil
            )
        }
    }

    @Test("kill on already-terminal task is graceful")
    func killAlreadyTerminal() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(command: "echo done", environment: testBashEnvironment)
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "s1")
        let done = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }
        guard done else {
            Issue.record("timed out waiting for terminal task before kill")
            return
        }
        let tool = createTaskStatusTool(manager: manager, sessionId: "s1")
        let result = try await tool.execute(
            "c1",
            .object(["action": .string("kill"), "task_id": .string(taskId)]),
            nil, nil
        )
        // Non-running tasks return a friendly result, not a throw.
        if case .object(let obj) = result.details ?? .null,
           case .bool(let killed) = obj["killed"] ?? .null {
            #expect(killed == false)
        }
    }

    @Test("list with no tasks returns empty")
    func listEmpty() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createTaskStatusTool(manager: manager, sessionId: "s1")
        let result = try await tool.execute(
            "c1",
            .object(["action": .string("list")]),
            nil, nil
        )
        if case .text(let t) = result.content.first {
            #expect(t.text.contains("No background tasks"))
        }
    }

    @Test("task_id scoped to another session is hidden")
    func crossSessionScoping() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-bgstatus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = BashBackgroundRunner(command: "echo hi", environment: testBashEnvironment)
        let (taskId, _) = await manager.spawn(runner: runner, sessionId: "sA")
        _ = await awaitUntil(3000) {
            let s = await manager.get(taskId)
            return s?.status != .running
        }

        let tool = createTaskStatusTool(manager: manager, sessionId: "sB")
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-1",
                .object(["action": .string("status"), "task_id": .string(taskId)]),
                nil, nil
            )
        }
    }
}
