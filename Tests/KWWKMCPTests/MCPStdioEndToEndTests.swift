#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI
@testable import KWWKMCP

/// Collects values from `@Sendable` callbacks.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var values: [T] { lock.withLock { items } }
}

func waitUntil(timeout: Double = 10, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

@Suite("MCP stdio end-to-end", .serialized)
struct MCPStdioEndToEndTests {
    private func makeTransport(env: [String: String] = [:]) throws -> (MCPStdioTransport, URL) {
        guard let python = FakeMCPServer.python else { throw SkipError() }
        let installed = try FakeMCPServer.install()
        let transport = MCPStdioTransport(
            command: python,
            args: ["-u", installed.script],
            env: env,
            cwd: installed.directory.path
        )
        return (transport, installed.directory)
    }

    struct SkipError: Error {}

    private func stateJSON(_ client: MCPClient) async throws -> JSONValue {
        let result = try await client.callTool(name: "state", arguments: [:])
        guard case .text(let text)? = result.content.first else { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test("client handshake, pagination, calls, server requests")
    func clientRoundTrip() async throws {
        let (transport, directory) = try makeTransport(env: ["MCP_TEST_VAR": "hello"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MCPClient(transport: transport)
        let changed = Collector<Int>()
        await client.setToolsListChangedHandler { changed.append(1) }
        try await client.connect(timeoutSeconds: 10)
        #expect(await client.isConnected)
        #expect(await client.serverInfo == MCPServerInfo(name: "fake", version: "1.2.3"))
        #expect(await client.instructions == "Fake server for tests.\nSecond line.")
        #expect(await client.negotiatedProtocolVersion == "2025-06-18")

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo", "add", "fail", "slow", "image", "state", "change", "env", "exit"])
        #expect(tools.first?.description == "Echo the text back")
        #expect(tools[1].title == "Add numbers")

        let echo = try await client.callTool(name: "echo", arguments: ["text": "hi"])
        #expect(echo.content == [.text("hi")])
        let add = try await client.callTool(name: "add", arguments: ["a": 2, "b": 3])
        #expect(add.structuredContent == ["sum": 5])
        let fail = try await client.callTool(name: "fail", arguments: .null)
        #expect(fail.isError)
        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(name: "missing", arguments: [:])
        }

        let env = try await client.callTool(name: "env", arguments: [:])
        guard case .text(let envText)? = env.content.first else {
            Issue.record("no env text")
            return
        }
        let envJSON = try JSONDecoder().decode(JSONValue.self, from: Data(envText.utf8))
        #expect(envJSON["var"] == "hello")
        let cwd = envJSON["cwd"]?.mcpString ?? ""
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
            == directory.resolvingSymlinksInPath().path)

        // The server pinged us and sent an unknown request after initialized.
        let replies = try await stateJSON(client)["replies"]
        #expect(replies?["s1"]?["result"] == .object([:]))
        #expect(replies?["s2"]?["error"]?["code"] == .int(-32601))

        try await client.ping()

        // list_changed reaches the handler and the new tool appears.
        _ = try await client.callTool(name: "change", arguments: [:])
        #expect(await waitUntil { changed.values.count == 1 })
        #expect(try await client.listTools().contains { $0.name == "late" })

        await client.close()
        #expect(await !client.isConnected)
        await #expect(throws: MCPError.self) { try await client.ping() }
    }

    @Test("cancellation sends notifications/cancelled; progress is reported; timeouts")
    func cancellationAndProgress() async throws {
        let (transport, directory) = try makeTransport()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MCPClient(transport: transport)
        try await client.connect(timeoutSeconds: 10)
        defer { Task { await client.close() } }

        let handle = CancellationHandle()
        let progress = Collector<MCPProgress>()
        let call = Task {
            try await client.callTool(name: "slow", arguments: [:], cancellation: handle, onProgress: { progress.append($0) })
        }
        #expect(await waitUntil { !progress.values.isEmpty })
        #expect(progress.values.first == MCPProgress(progress: 1, total: 2, message: "halfway"))
        handle.cancel(reason: "user")
        await #expect(throws: CancellationError.self) { _ = try await call.value }

        #expect(await waitUntil {
            guard let state = try? await self.stateJSON(client), case .array(let ids)? = state["cancelled"] else { return false }
            return !ids.isEmpty
        })

        await #expect(throws: MCPError.timeout(method: "tools/call", seconds: 0.3)) {
            _ = try await client.callTool(name: "slow", arguments: [:], timeoutSeconds: 0.3)
        }
        // Task cancellation also works.
        let taskCall = Task { try await client.callTool(name: "slow", arguments: [:]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        taskCall.cancel()
        await #expect(throws: CancellationError.self) { _ = try await taskCall.value }
    }

    @Test("server exit fails pending requests with the stderr tail")
    func serverExit() async throws {
        let (transport, directory) = try makeTransport()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MCPClient(transport: transport)
        let closed = Collector<String>()
        await client.setCloseHandler { error in closed.append(error?.localizedDescription ?? "") }
        try await client.connect(timeoutSeconds: 10)
        do {
            _ = try await client.callTool(name: "exit", arguments: [:])
            Issue.record("expected an error")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("connection closed"))
            #expect(message.contains("fake server exiting on request"))
        }
        #expect(await waitUntil { closed.values.count == 1 })
        #expect(closed.values.first?.contains("status 3") == true)
        #expect(await !client.isConnected)
    }

    @Test("spawn failures are reported")
    func spawnFailure() async throws {
        let transport = MCPStdioTransport(command: "definitely-not-a-command-kwwk", cwd: "/tmp")
        let client = MCPClient(transport: transport)
        await #expect(throws: MCPError.spawnFailed("command not found: definitely-not-a-command-kwwk")) {
            try await client.connect()
        }
        // A server that exits immediately reports its stderr.
        let crash = MCPStdioTransport(command: "/bin/sh", args: ["-c", "echo boom >&2; exit 2"], cwd: "/tmp")
        let crashClient = MCPClient(transport: crash)
        do {
            try await crashClient.connect(timeoutSeconds: 5)
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription.contains("boom"))
        }
    }

    @Test("manager connects, exposes tools, follows list_changed, shuts down")
    func manager() async throws {
        guard let python = FakeMCPServer.python else { return }
        let installed = try FakeMCPServer.install()
        defer { try? FileManager.default.removeItem(at: installed.directory) }
        let configs = [
            MCPServerConfig(
                name: "fake-srv",
                transport: .stdio(command: python, args: ["-u", installed.script], cwd: installed.directory.path),
                toolExposure: ["s*": .hidden, "state": .deferred]
            ),
            MCPServerConfig(name: "broken", transport: .stdio(command: "definitely-not-a-command-kwwk")),
        ]
        let manager = MCPManager(configs: configs)
        let updates = Collector<[String]>()
        await manager.onToolsChanged { tools in updates.append(tools.map(\.tool.name)) }
        await manager.start()
        #expect(await manager.waitForStartup(timeout: 15))
        // Startup includes delivering the tools to observers.
        #expect(updates.values.last?.contains("mcp__fake_srv__echo") == true)

        let tools = await manager.tools()
        func tool(_ name: String) throws -> AgentTool {
            try #require(tools.first { $0.tool.name == "mcp__fake_srv__\(name)" }).tool
        }
        let names = tools.map(\.tool.name)
        #expect(names.contains("mcp__fake_srv__state"))
        #expect(!names.contains("mcp__fake_srv__slow"), "hidden by pattern")
        #expect(tools.allSatisfy { $0.server == "fake-srv" })

        @Sendable func state(_ server: String) async -> MCPServerState? {
            await manager.statuses().first { $0.name == server }?.state
        }
        #expect(await state("fake-srv") == .connected)
        if case .failed(let message)? = await state("broken") {
            #expect(message.contains("command not found"))
        } else {
            Issue.record("expected broken server to fail")
        }

        // Execute through the AgentTool.
        let echo = try tool("echo")
        let result = try await echo.execute("call-1", ["text": "via agent"], nil, nil)
        #expect(result.content == [.text(TextContent(text: "via agent"))])
        let fail = try tool("fail")
        await #expect(throws: MCPToolCallError.self) {
            _ = try await fail.execute("call-2", [:], nil, nil)
        }

        // list_changed adds the new tool and notifies observers.
        _ = try await tool("change").execute("call-3", [:], nil, nil)
        #expect(await waitUntil { await manager.tools().contains { $0.tool.name == "mcp__fake_srv__late" } })
        #expect(await waitUntil { updates.values.last?.contains("mcp__fake_srv__late") == true })

        // A dropped connection reconnects on the next call.
        _ = try? await tool("exit").execute("call-4", [:], nil, nil)
        #expect(await waitUntil {
            if case .disconnected? = await state("fake-srv") { return true }
            return false
        })
        let again = try await echo.execute("call-5", ["text": "back"], nil, nil)
        #expect(again.content == [.text(TextContent(text: "back"))])
        #expect(await state("fake-srv") == .connected)

        await manager.shutdown()
        #expect(await manager.tools().isEmpty)
        #expect(updates.values.last == [])
        #expect(await state("fake-srv") == .closed)
        await #expect(throws: MCPManagerError.shutDown) {
            _ = try await echo.execute("call-6", ["text": "x"], nil, nil)
        }
    }

    @Test("tool calls wait for a server that is still connecting")
    func waitsForConnecting() async throws {
        guard let python = FakeMCPServer.python else { return }
        let installed = try FakeMCPServer.install()
        defer { try? FileManager.default.removeItem(at: installed.directory) }
        let manager = MCPManager(
            configs: [MCPServerConfig(
                name: "fake",
                transport: .stdio(command: python, args: ["-u", installed.script], cwd: installed.directory.path)
            )]
        )
        await manager.start()
        // Call before startup finished.
        let result = try await manager.callTool(server: "fake", tool: "echo", arguments: ["text": "early"])
        #expect(result.content == [.text("early")])
        await manager.shutdown()
    }
}
#endif
