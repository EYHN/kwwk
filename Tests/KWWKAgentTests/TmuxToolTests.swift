import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// Tmux tests explicitly resolve `tmux` from PATH. When it isn't,
/// every test quietly returns — the bash + background path doesn't depend on
/// tmux so this shouldn't block CI on machines without it.
private func resolvedTmuxPath() -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":").map(String.init) {
        let candidate = "\(dir)/tmux"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

private func tmuxAvailable() async -> Bool {
    guard let tmuxPath = resolvedTmuxPath() else { return false }
    return await TmuxSessionManager(tmuxPath: tmuxPath).isAvailable
}

private func makeSessionManager() -> TmuxSessionManager {
    // Unique socket + session per test so parallel-running tests don't
    // collide with `duplicate session: kw`.
    let id = UUID().uuidString.prefix(8)
    return TmuxSessionManager(
        tmuxPath: resolvedTmuxPath()!,
        socketName: "kw-test-\(id)",
        sessionName: "t\(id)"
    )
}

@Suite("TmuxSessionManager", .serialized)
struct TmuxSessionManagerTests {

    @Test("availability probe reflects whether tmux is installed")
    func availability() async {
        let available = await tmuxAvailable()
        // Just asserts the probe doesn't crash. Actual availability depends
        // on the host — we can't #expect true/false either way on CI.
        _ = available
    }

    @Test("start a pane then capture its screen")
    func startAndCapture() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        let info = try await manager.startPane(command: "printf 'pane-hello\\n' ; sleep 5")
        #expect(info.paneId.hasPrefix("%"))
        // Give the shell a moment to print.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let captured = try await manager.capture(info.paneId, lines: 20)
        #expect(captured.contains("pane-hello"))
        try await manager.killPane(info.paneId)
    }

    @Test("send_keys literal types text into the pane")
    func sendKeysLiteral() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        // Run `cat` so whatever we type literally shows up in the pane.
        let info = try await manager.startPane(command: "cat")
        try? await Task.sleep(nanoseconds: 150_000_000)
        try await manager.sendKeys(info.paneId, keys: "KWTYPED", literal: true)
        try await manager.sendKeys(info.paneId, keys: "Enter")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let captured = try await manager.capture(info.paneId)
        #expect(captured.contains("KWTYPED"))
        try await manager.killPane(info.paneId)
    }

    @Test("kill removes the pane from list")
    func killRemoves() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        let info = try await manager.startPane(command: "sleep 10")
        let before = await manager.list().map(\.paneId)
        #expect(before.contains(info.paneId))
        try await manager.killPane(info.paneId)
        let after = await manager.list().map(\.paneId)
        #expect(!after.contains(info.paneId))
    }

    @Test("methods throw .unavailable when tmux is not on PATH")
    func unavailableRaises() async {
        let manager = TmuxSessionManager(tmuxPath: "/definitely-not-real/tmux-absent")
        await #expect(throws: TmuxError.self) {
            _ = try await manager.startPane(command: "echo hi")
        }
        await #expect(throws: TmuxError.self) {
            _ = try await manager.sendKeys("%1", keys: "Enter")
        }
        await #expect(throws: TmuxError.self) {
            _ = try await manager.capture("%1")
        }
        await #expect(throws: TmuxError.self) {
            _ = try await manager.killPane("%1")
        }
    }

    @Test("opening two panes in the same session does not fail")
    func twoPanesSequential() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        let first = try await manager.startPane(command: "sleep 10")
        let second = try await manager.startPane(command: "sleep 10")
        #expect(first.paneId.hasPrefix("%"))
        #expect(second.paneId.hasPrefix("%"))
        #expect(first.paneId != second.paneId)
        try await manager.killPane(first.paneId)
        try await manager.killPane(second.paneId)
    }

    @Test("killing the last pane then starting a new one recreates the session")
    func recreateSessionAfterLastKill() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        let first = try await manager.startPane(command: "echo first")
        try await manager.killPane(first.paneId)
        // Tmux auto-destroys the session when its last window is killed.
        // The next startPane should transparently recreate it.
        let second = try await manager.startPane(command: "echo second")
        #expect(second.paneId.hasPrefix("%"))
        try await manager.killPane(second.paneId)
    }
}

@Suite("Tmux tool", .serialized)
struct TmuxToolTests {

    @Test("createTmuxTool returns nil when tmux is unavailable")
    func gatedByAvailability() async {
        // Simulate by passing a manager with a bogus path.
        let bogus = TmuxSessionManager(tmuxPath: "/definitely-not-a-real-path/tmux-nope")
        let tool = await createTmuxTool(
            manager: bogus,
            cwd: FileManager.default.currentDirectoryPath
        )
        #expect(tool == nil)
    }

    @Test("unknown action throws")
    func unknownAction() async {
        // Use a fake-path manager so the tool factory returns nil on this
        // host; we reach directly into a tool with a real manager only if
        // tmux is available.
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        guard let tool = await createTmuxTool(
            manager: manager,
            cwd: FileManager.default.currentDirectoryPath
        ) else { return }
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-1",
                .object(["action": .string("nope")]),
                nil, nil
            )
        }
    }

    @Test("start without command throws")
    func startMissingCommand() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        guard let tool = await createTmuxTool(
            manager: manager,
            cwd: FileManager.default.currentDirectoryPath
        ) else { return }
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-1",
                .object(["action": .string("start")]),
                nil, nil
            )
        }
    }

    @Test("list action works when there are no panes")
    func listEmpty() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        guard let tool = await createTmuxTool(
            manager: manager,
            cwd: FileManager.default.currentDirectoryPath
        ) else { return }
        let result = try await tool.execute(
            "call-1",
            .object(["action": .string("list")]),
            nil, nil
        )
        if case .text(let t) = result.content.first {
            #expect(t.text.contains("No tmux panes"))
        }
    }

    @Test("start → capture → kill round trip via the tool interface")
    func roundTrip() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        guard let tool = await createTmuxTool(
            manager: manager,
            cwd: FileManager.default.currentDirectoryPath
        ) else {
            Issue.record("tmux available but tool factory returned nil")
            return
        }
        let startResult = try await tool.execute(
            "call-1",
            .object([
                "action": .string("start"),
                "command": .string("printf 'from-tool\\n' ; sleep 5"),
            ]),
            nil, nil
        )
        guard case .object(let startObj) = startResult.details ?? .null,
              case .string(let paneId) = startObj["pane_id"] ?? .null
        else {
            Issue.record("no pane_id in start result")
            return
        }
        #expect(paneId.hasPrefix("%"))
        try? await Task.sleep(nanoseconds: 250_000_000)

        let captureResult = try await tool.execute(
            "call-2",
            .object([
                "action": .string("capture"),
                "pane_id": .string(paneId),
            ]),
            nil, nil
        )
        if case .text(let t) = captureResult.content.first {
            #expect(t.text.contains("from-tool"))
        }

        _ = try await tool.execute(
            "call-3",
            .object([
                "action": .string("kill"),
                "pane_id": .string(paneId),
            ]),
            nil, nil
        )
    }

    @Test("start with bgManager returns a task_id")
    func startReturnsTaskId() async throws {
        guard await tmuxAvailable() else { return }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let tmuxMgr = makeSessionManager()
        defer { Task { await tmuxMgr.teardown() } }
        let bgManager = BackgroundTaskManager(outputDir: outputDir)
        guard let tool = await createTmuxTool(
            manager: tmuxMgr,
            cwd: outputDir.path,
            bgManager: bgManager,
            sessionId: "s1"
        ) else {
            Issue.record("tmux available but tool factory returned nil")
            return
        }
        let result = try await tool.execute(
            "call-1",
            .object([
                "action": .string("start"),
                "command": .string("echo hello-tmux-bg"),
            ]),
            nil, nil
        )
        guard case .object(let obj) = result.details ?? .null else {
            Issue.record("expected details object")
            return
        }
        #expect(obj["pane_id"] != nil)
        #expect(obj["task_id"] != nil, "task_id should be present when bgManager is wired")
    }

    @Test("tmux pane shows up in task_status list")
    func paneInTaskStatus() async throws {
        guard await tmuxAvailable() else { return }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let tmuxMgr = makeSessionManager()
        defer { Task { await tmuxMgr.teardown() } }
        let bgManager = BackgroundTaskManager(outputDir: outputDir)
        guard let tool = await createTmuxTool(
            manager: tmuxMgr,
            cwd: outputDir.path,
            bgManager: bgManager,
            sessionId: "s1"
        ) else { return }

        let startResult = try await tool.execute(
            "call-1",
            .object([
                "action": .string("start"),
                "command": .string("sleep 5"),
            ]),
            nil, nil
        )
        guard case .object(let obj) = startResult.details ?? .null,
              case .string(let taskId) = obj["task_id"] ?? .null else {
            Issue.record("expected task_id")
            return
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let statusTool = createTaskStatusTool(manager: bgManager, sessionId: "s1")
        let listResult = try await statusTool.execute(
            "call-2",
            .object(["action": .string("list")]),
            nil, nil
        )
        if case .text(let t) = listResult.content.first {
            #expect(t.text.contains(taskId), "task_status list should contain tmux task")
        }

        // Clean up
        if case .string(let paneId) = obj["pane_id"] ?? .null {
            _ = try? await tool.execute(
                "call-3",
                .object(["action": .string("kill"), "pane_id": .string(paneId)]),
                nil, nil
            )
        }
    }

    @Test("wait_task on a tmux pane blocks until killed")
    func waitTaskOnPane() async throws {
        guard await tmuxAvailable() else { return }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let tmuxMgr = makeSessionManager()
        defer { Task { await tmuxMgr.teardown() } }
        let bgManager = BackgroundTaskManager(outputDir: outputDir)
        guard let tmuxTool = await createTmuxTool(
            manager: tmuxMgr,
            cwd: outputDir.path,
            bgManager: bgManager,
            sessionId: "s1"
        ) else { return }

        let startResult = try await tmuxTool.execute(
            "call-1",
            .object([
                "action": .string("start"),
                "command": .string("echo pane-output && sleep 30"),
            ]),
            nil, nil
        )
        guard case .object(let obj) = startResult.details ?? .null,
              case .string(let taskId) = obj["task_id"] ?? .null,
              case .string(let paneId) = obj["pane_id"] ?? .null else {
            Issue.record("expected task_id and pane_id")
            return
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Kill the pane via tmux tool — the bg task should pick this up.
        let waitTool = createWaitTaskTool(manager: bgManager, sessionId: "s1")
        let waitTask = Task {
            try await waitTool.execute(
                "call-2",
                .object(["task_id": .string(taskId), "timeout_seconds": .int(10)]),
                nil, nil
            )
        }

        // Give wait_task a moment to enter its poll loop, then kill the pane.
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = try? await tmuxTool.execute(
            "call-3",
            .object(["action": .string("kill"), "pane_id": .string(paneId)]),
            nil, nil
        )

        let result = try await waitTask.value
        if case .object(let waitObj) = result.details ?? .null {
            if case .bool(let waited) = waitObj["waited"] ?? .null {
                #expect(waited == true, "should have waited for pane to die")
            }
            if case .string(let status) = waitObj["status"] ?? .null {
                #expect(status == "killed" || status == "completed" || status == "failed",
                       "unexpected status: \(status)")
            }
        }
    }
}
