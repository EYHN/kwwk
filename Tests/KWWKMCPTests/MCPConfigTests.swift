import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKMCP

@Suite("MCP config")
struct MCPConfigTests {
    private func makeDirs(user: String?, project: String?) throws -> (home: String, cwd: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-mcpcfg-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".kwwk"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd.appendingPathComponent(".kwwk"), withIntermediateDirectories: true)
        if let user {
            try user.write(to: home.appendingPathComponent(".kwwk/mcp.json"), atomically: true, encoding: .utf8)
        }
        if let project {
            try project.write(to: cwd.appendingPathComponent(".kwwk/mcp.json"), atomically: true, encoding: .utf8)
        }
        return (home.path, cwd.path)
    }

    @Test("parses stdio and http entries with kwwk fields")
    func parsesEntries() throws {
        let dirs = try makeDirs(user: """
        {"mcpServers": {
          "fs": {"command": "npx", "args": ["-y", "server-fs", "${ROOT}"], "env": {"TOKEN": "${TOKEN}"}, "cwd": "sub",
                 "exposure": "direct", "toolExposure": {"delete_*": "hidden", "read": "deferred"},
                 "startupTimeout": 5, "timeout": 12.5, "description": "Files"},
          "docs": {"type": "streamable-http", "url": "https://${HOST}/mcp", "headers": {"Authorization": "Bearer ${TOKEN}"}},
          "plain": {"url": "http://localhost:3000/mcp", "enabled": false, "exposure": "codemode"}
        }}
        """, project: nil)
        let result = MCPConfigLoader.load(
            cwd: dirs.cwd, homeDirectory: dirs.home,
            environment: ["ROOT": "/r", "TOKEN": "secret", "HOST": "example.com"]
        )
        #expect(result.warnings.isEmpty)
        #expect(result.servers.map(\.name) == ["docs", "fs", "plain"])
        let fs = try #require(result.servers.first { $0.name == "fs" })
        #expect(fs.transport == .stdio(command: "npx", args: ["-y", "server-fs", "/r"], env: ["TOKEN": "secret"], cwd: "sub"))
        #expect(fs.exposure == .deferred)  // pi's "direct" is read as deferred
        #expect(fs.exposure(forTool: "delete_file") == .hidden)
        #expect(fs.exposure(forTool: "read") == .deferred)
        #expect(fs.exposure(forTool: "write") == .deferred)
        #expect(fs.startupTimeoutSeconds == 5)
        #expect(fs.toolTimeoutSeconds == 12.5)
        #expect(fs.description == "Files")
        let docs = try #require(result.servers.first { $0.name == "docs" })
        #expect(docs.transport == .http(url: URL(string: "https://example.com/mcp")!, headers: ["Authorization": "Bearer secret"]))
        #expect(docs.enabled)
        #expect(docs.exposure == .deferred)
        let plain = try #require(result.servers.first { $0.name == "plain" })
        #expect(!plain.enabled)
        #expect(plain.exposure == .deferred)
    }

    @Test("project entries replace or override user entries")
    func projectMerge() throws {
        let dirs = try makeDirs(user: """
        {"mcpServers": {
          "a": {"command": "a-server", "env": {"KEY": "user-secret"}},
          "b": {"command": "b-server"},
          "c": {"command": "c-server"}
        }}
        """, project: """
        {"mcpServers": {
          "a": {"enabled": false, "exposure": "direct", "toolExposure": {"x": "hidden"}},
          "b": {"url": "https://b.example/mcp"},
          "d": {"command": "d-server"},
          "e": {"enabled": false},
          "c": {"enabled": false, "env": {"KEY": "x"}}
        }}
        """)
        let result = MCPConfigLoader.load(cwd: dirs.cwd, homeDirectory: dirs.home, environment: [:])
        #expect(result.servers.map(\.name) == ["a", "b", "c", "d"])
        let a = try #require(result.servers.first { $0.name == "a" })
        #expect(!a.enabled)
        #expect(a.exposure == .deferred)
        #expect(a.toolExposure == ["x": .hidden])
        #expect(a.transport == .stdio(command: "a-server", args: [], env: ["KEY": "user-secret"], cwd: nil))
        let b = try #require(result.servers.first { $0.name == "b" })
        #expect(b.transport == .http(url: URL(string: "https://b.example/mcp")!, headers: [:]))
        let c = try #require(result.servers.first { $0.name == "c" })
        #expect(c.enabled, "an override with extra keys is rejected")
        #expect(result.warnings.contains { $0.contains("\"e\"") && $0.contains("override") })
        #expect(result.warnings.contains { $0.contains("\"c\"") && $0.contains("can only set") })
        #expect(result.files.count == 2)
    }

    @Test("invalid entries become warnings")
    func invalidEntries() throws {
        let dirs = try makeDirs(user: """
        {"mcpServers": {
          "sse": {"type": "sse", "url": "https://x/sse"},
          "bad name": {"command": "x"},
          "noTransport": {"enabled": true},
          "badArgs": {"command": "x", "args": "nope"},
          "badExposure": {"command": "x", "exposure": "sometimes"},
          "badUrl": {"url": "ftp://x"},
          "badTimeout": {"command": "x", "timeout": -1},
          "ok": {"command": "x", "env": {"A": "${MISSING}", "B": "${MISSING2:-fallback}"}}
        }}
        """, project: "{not json")
        let result = MCPConfigLoader.load(cwd: dirs.cwd, homeDirectory: dirs.home, environment: [:])
        #expect(result.servers.map(\.name) == ["ok"])
        let ok = try #require(result.servers.first)
        #expect(ok.transport == .stdio(command: "x", args: [], env: ["A": "", "B": "fallback"], cwd: nil))
        let warnings = result.warnings.joined(separator: "\n")
        #expect(warnings.contains("legacy SSE transport is not supported"))
        #expect(warnings.contains("invalid server name \"bad name\""))
        #expect(warnings.contains("server \"noTransport\" needs either"))
        #expect(warnings.contains("args must be an array of strings"))
        #expect(warnings.contains("exposure must be one of"))
        #expect(warnings.contains("url must be an http or https URL"))
        #expect(warnings.contains("timeout must be a positive number"))
        #expect(warnings.contains("unset environment variable MISSING"))
        #expect(!warnings.contains("MISSING2"))
        #expect(warnings.contains("invalid JSON"))
    }

    @Test("server names that sanitize alike conflict")
    func nameConflict() {
        let result = MCPConfigLoader.parse(
            ["mcpServers": ["my-srv": ["command": "a"], "my_srv": ["command": "b"]]],
            environment: [:]
        )
        #expect(result.servers.count == 1)
        #expect(result.warnings.contains { $0.contains("conflicts with") })
    }

    @Test("missing files yield an empty result")
    func missingFiles() throws {
        let dirs = try makeDirs(user: nil, project: nil)
        let result = MCPConfigLoader.load(cwd: dirs.cwd, homeDirectory: dirs.home)
        #expect(result.servers.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("env expansion")
    func envExpansion() {
        var missing: [String] = []
        let env = ["A": "1", "EMPTY": ""]
        #expect(EnvExpander.expand("x${A}y${B:-z}${EMPTY:-d}$A${", environment: env, missing: &missing) == "x1yzd$A${")
        #expect(missing.isEmpty)
        #expect(EnvExpander.expand("${NOPE}", environment: env, missing: &missing) == "")
        #expect(missing == ["NOPE"])
    }

    @Test("glob patterns")
    func glob() {
        #expect(MCPGlob.matches(pattern: "get_*", value: "get_issue"))
        #expect(MCPGlob.matches(pattern: "*_issue", value: "get_issue"))
        #expect(MCPGlob.matches(pattern: "*", value: ""))
        #expect(MCPGlob.matches(pattern: "a*b*c", value: "aXbYc"))
        #expect(!MCPGlob.matches(pattern: "a*b*c", value: "aXcYb"))
        #expect(!MCPGlob.matches(pattern: "ab*ab", value: "ab"))
        #expect(!MCPGlob.matches(pattern: "get_*", value: "list_issue"))
    }
}
