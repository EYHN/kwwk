import Foundation
import Testing
@testable import KWWKCli
@testable import KWWKAgent
@testable import KWWKAI

#if os(macOS) || os(Linux)
private let fakeServer = #"""
import json, sys

TOOLS = [
    {"name": "lookup", "description": "Look up documentation pages", "inputSchema": {"type": "object", "properties": {"topic": {"type": "string"}}}},
    {"name": "search_issues", "description": "Search the issue tracker for bugs", "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}}},
    {"name": "create_issue", "description": "File a new issue", "inputSchema": {"type": "object"}},
]

for line in sys.stdin:
    msg = json.loads(line)
    mid = msg.get("id")
    method = msg.get("method")
    if mid is None:
        continue
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        p = msg["params"]
        result = {"content": [{"type": "text", "text": p["name"] + ":" + json.dumps(p.get("arguments") or {}, sort_keys=True)}]}
    else:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}}) + "\n")
        sys.stdout.flush()
        continue
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
    sys.stdout.flush()
"""#

private struct Sandbox {
    let root: URL
    let home: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-mcp-runtime-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("project")
        for dir in [home.appendingPathComponent(".kwwk"), project.appendingPathComponent(".kwwk")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fakeServer.write(to: root.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    }

    var serverEntry: [String: Any] {
        ["command": "python3", "args": [root.appendingPathComponent("server.py").path]]
    }

    func writeUser(_ servers: [String: Any]) throws {
        try write(["mcpServers": servers], to: home.appendingPathComponent(".kwwk/mcp.json"))
    }

    func writeProject(_ servers: [String: Any]) throws {
        try write(["mcpServers": servers], to: project.appendingPathComponent(".kwwk/mcp.json"))
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}

@Suite("MCP runtime")
struct MCPRuntimeTests {
    @Test("project servers are ignored unless the project is trusted")
    func projectServersNeedOptIn() throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.writeProject(["repo": sandbox.serverEntry])

        let ignored = MCPRuntime(cwd: sandbox.project.path, homeDirectory: sandbox.home.path, environment: [:])
        #expect(ignored.manager == nil)
        #expect(ignored.warnings.contains { $0.contains("repo") && $0.contains(MCPRuntime.allowProjectServersVariable) })

        let trusted = MCPRuntime(
            cwd: sandbox.project.path,
            homeDirectory: sandbox.home.path,
            environment: [MCPRuntime.allowProjectServersVariable: "1"]
        )
        #expect(trusted.manager != nil)
        #expect(trusted.warnings.isEmpty)
    }

    @Test("direct tools join the agent, deferred tools load through tool_search")
    func endToEnd() async throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        var entry = sandbox.serverEntry
        entry["description"] = "Docs and issue tracker"
        entry["toolExposure"] = ["lookup": "direct"]
        try sandbox.writeUser(["tracker": entry])

        let runtime = MCPRuntime(cwd: sandbox.project.path, homeDirectory: sandbox.home.path, environment: [:])
        #expect(runtime.manager != nil)
        await runtime.start()
        defer { Task { await runtime.shutdown() } }

        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel(), tools: [makeEchoTool()]))
        runtime.attach(to: agent, messages: [])
        #expect(agent.state.systemPrompt.contains("<mcp_servers>"))
        #expect(agent.state.systemPrompt.contains("tracker: Docs and issue tracker"))

        #expect(await runtime.waitForStartup(timeout: 20))
        let names = agent.state.tools.map(\.name)
        #expect(names.contains("mcp__tracker__lookup"))
        #expect(names.contains(toolSearchToolName))
        #expect(!names.contains("mcp__tracker__search_issues"))

        let search = try #require(agent.state.tools.first { $0.name == toolSearchToolName })
        let result = try await search.execute("s1", ["query": "search bugs"], nil, nil)
        guard case .text(let text)? = result.content.first else {
            Issue.record("tool_search returned no text")
            return
        }
        #expect(text.text.contains("mcp__tracker__search_issues"))
        let loaded = try #require(agent.state.tools.first { $0.name == "mcp__tracker__search_issues" })
        let call = try await loaded.execute("c1", ["query": "crash"], nil, nil)
        guard case .text(let output)? = call.content.first else {
            Issue.record("MCP call returned no text")
            return
        }
        #expect(output.text == #"search_issues:{"query": "crash"}"#)
    }
}

private func makeEchoTool() -> AgentTool {
    AgentTool(name: "echo", label: "echo", description: "echo", parameters: ["type": "object"]) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "echo"))])
    }
}
#endif
