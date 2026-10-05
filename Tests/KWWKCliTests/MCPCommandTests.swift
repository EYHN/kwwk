import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli
@testable import KWWKMCP

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var outLines: [String] = []
    private var errLines: [String] = []
    var out: String { lock.withLock { outLines.joined(separator: "\n") } }
    var err: String { lock.withLock { errLines.joined(separator: "\n") } }
    var io: MCPCommandIO {
        MCPCommandIO(
            out: { [self] line in lock.withLock { outLines.append(line) } },
            err: { [self] line in lock.withLock { errLines.append(line) } }
        )
    }
}

@Suite("kwwk mcp command")
struct MCPCommandTests {
    private struct Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-mcpcmd-\(UUID().uuidString)")
        var home: String { root.appendingPathComponent("home").path }
        var cwd: String { root.appendingPathComponent("project").path }

        init() throws {
            try FileManager.default.createDirectory(atPath: root.appendingPathComponent("home").path, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: root.appendingPathComponent("project").path, withIntermediateDirectories: true)
        }

        func run(_ arguments: [String], environment: [String: String] = [:]) async -> (Int32, Output) {
            let output = Output()
            let code = await MCPCommand.run(arguments, cwd: cwd, homeDirectory: home, environment: environment, io: output.io)
            return (code, output)
        }

        func config(_ scope: MCPConfigScope) throws -> JSONValue {
            let url = MCPConfigFile.path(scope: scope, cwd: cwd, homeDirectory: home)
            return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        }
    }

    @Test("add writes HTTP and stdio entries the loader accepts")
    func add() async throws {
        let box = try Sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        var (code, output) = await box.run([
            "add", "linear", "https://mcp.linear.app/mcp", "--description", "Linear issues",
            "--client-name", "Codex", "--callback-port", "4567",
        ])
        #expect(code == 0)
        #expect(output.out.contains("Added HTTP MCP server linear to user config (~/.kwwk/mcp.json)."))
        #expect(output.out.contains("kwwk mcp login linear"))

        (code, output) = await box.run([
            "add", "-e", "TOKEN=${GH_TOKEN}", "--description=GitHub", "github", "--", "npx", "-y", "server-github", "--model", "x",
        ])
        #expect(code == 0, "\(output.err)")

        (code, _) = await box.run(["add", "api", "https://api.example.com/mcp", "-H", "Authorization: Bearer t"])
        #expect(code == 0)

        let servers = try box.config(.user)["mcpServers"]
        #expect(servers?["linear"] == [
            "type": "http", "url": "https://mcp.linear.app/mcp", "description": "Linear issues",
            "oauth": ["clientName": "Codex", "callbackPort": 4567],
        ])
        #expect(servers?["github"] == [
            "command": "npx", "args": ["-y", "server-github", "--model", "x"],
            "env": ["TOKEN": "${GH_TOKEN}"], "description": "GitHub",
        ])
        let attributes = try FileManager.default.attributesOfItem(
            atPath: MCPConfigFile.path(scope: .user, cwd: box.cwd, homeDirectory: box.home).path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let loaded = MCPConfigFile.load(cwd: box.cwd, homeDirectory: box.home, trustProject: false, environment: ["GH_TOKEN": "g"])
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.entries.map(\.server.name) == ["api", "github", "linear"])
        #expect(loaded.entries.first { $0.server.name == "linear" }?.oauth?.clientName == "Codex")
        #expect(loaded.entries.first { $0.server.name == "api" }?.oauth == nil)
    }

    @Test("add refuses duplicates, bad input and SSE")
    func addErrors() async throws {
        let box = try Sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = await box.run(["add", "a", "https://a.example/mcp"])
        var (code, output) = await box.run(["add", "a", "https://b.example/mcp"])
        #expect(code == 2)
        #expect(output.err.contains("already exists"))
        (code, output) = await box.run(["add", "bad name", "https://a.example/mcp"])
        #expect(code == 1)
        #expect(output.err.contains("invalid name"))
        (code, _) = await box.run(["add", "-t", "sse", "s", "https://a.example/sse"])
        #expect(code == 2)
        (code, _) = await box.run(["add", "x", "https://a.example/mcp", "-e", "A=b"])
        #expect(code == 2)
        (code, _) = await box.run(["add", "--bogus", "x", "https://a.example/mcp"])
        #expect(code == 2)
        (code, _) = await box.run(["add", "x"])
        #expect(code == 2)
    }

    @Test("project scope, add-json, get, remove")
    func scopesAndRemove() async throws {
        let box = try Sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        var (code, output) = await box.run([
            "add-json", "--scope", "project", "docs", #"{"type":"http","url":"https://docs.example/mcp","headers":{"X-Api-Key":"secret"}}"#,
        ])
        #expect(code == 0)
        #expect(output.out.contains("KWWK_ALLOW_PROJECT_MCP=1"))
        #expect(try box.config(.project)["mcpServers"]?["docs"]?["url"] == "https://docs.example/mcp")
        (code, output) = await box.run(["add-json", "broken", "{nope"])
        #expect(code == 2)

        (code, output) = await box.run(["get", "docs"])
        #expect(code == 0)
        #expect(output.out.contains("Scope: project"))
        #expect(output.out.contains("Header: X-Api-Key: ***"))
        #expect(!output.out.contains("secret"))
        #expect(output.out.contains("OAuth: on, not signed in"))

        _ = await box.run(["add", "docs", "https://user.example/mcp"])
        (code, output) = await box.run(["remove", "docs"])
        #expect(code == 0)
        #expect(output.out.contains("from user config"))
        #expect(output.out.contains("from project config"))
        (code, _) = await box.run(["remove", "docs"])
        #expect(code == 2)
    }

    @Test("list checks each server; logout forgets the sign-in")
    func listAndLogout() async throws {
        let box = try Sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        var (code, output) = await box.run(["list"])
        #expect(code == 0)
        #expect(output.out.contains("No MCP servers configured"))
        _ = await box.run(["add", "--no-oauth", "down", "http://127.0.0.1:9/mcp"])
        (code, output) = await box.run(["list"])
        #expect(code == 0)
        #expect(output.out.contains("down (user): http://127.0.0.1:9/mcp (HTTP) - ✘ Failed to connect"))

        _ = await box.run(["add", "linear", "https://mcp.linear.app/mcp"])
        let store = MCPOAuthFileStore(url: MCPOAuthFileStore.defaultURL(homeDirectory: box.home))
        try await store.update(server: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!) {
            $0.tokens = MCPOAuthTokens(accessToken: "t")
        }
        (code, output) = await box.run(["get", "linear"])
        #expect(output.out.contains("signed in"))
        #expect(!output.out.contains("not signed in"))
        (code, output) = await box.run(["logout", "linear"])
        #expect(code == 0)
        #expect(await store.record(server: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!).tokens == nil)
        (code, _) = await box.run(["logout", "down"])
        #expect(code == 2)
    }
}
