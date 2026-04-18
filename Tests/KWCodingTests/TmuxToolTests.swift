import Foundation
import Testing
@testable import KWCoding
@testable import KWAgent
@testable import KWAI

/// Tmux tests are gated on `tmux` being installed on PATH. When it isn't,
/// every test quietly returns — the bash + background path doesn't depend on
/// tmux so this shouldn't block CI on machines without it.
private func tmuxAvailable() async -> Bool {
    await TmuxSessionManager().isAvailable
}

private func makeSessionManager() -> TmuxSessionManager {
    TmuxSessionManager()
}

@Suite("TmuxSessionManager")
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
}

@Suite("Tmux tool")
struct TmuxToolTests {

    @Test("createTmuxTool returns nil when tmux is unavailable")
    func gatedByAvailability() async {
        // Simulate by passing a manager with a bogus path.
        let bogus = TmuxSessionManager(tmuxPath: "/definitely-not-a-real-path/tmux-nope")
        let tool = await createTmuxTool(manager: bogus)
        #expect(tool == nil)
    }

    @Test("start → capture → kill round trip via the tool interface")
    func roundTrip() async throws {
        guard await tmuxAvailable() else { return }
        let manager = makeSessionManager()
        defer { Task { await manager.teardown() } }
        guard let tool = await createTmuxTool(manager: manager) else {
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
}
