import Foundation
import Testing
@testable import KWWKCli
@testable import KWWKMCP

@Suite("MCP config file")
struct MCPConfigFileTests {
    private struct Dirs {
        let root: URL
        var home: String { root.appendingPathComponent("home").path }
        var cwd: String { root.appendingPathComponent("project").path }

        init(user: String? = nil, project: String? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-mcpcfg-\(UUID().uuidString)")
            for (dir, content) in [("home", user), ("project", project)] {
                let kwwk = root.appendingPathComponent(dir).appendingPathComponent(".kwwk")
                try FileManager.default.createDirectory(at: kwwk, withIntermediateDirectories: true)
                try content?.write(to: kwwk.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
            }
        }

        func load(trustProject: Bool = false, environment: [String: String] = [:]) -> MCPConfigFile.Loaded {
            MCPConfigFile.load(cwd: cwd, homeDirectory: home, trustProject: trustProject, environment: environment)
        }
    }

    @Test("parses stdio and http entries with kwwk fields")
    func parsesEntries() throws {
        let dirs = try Dirs(user: """
        {"mcpServers": {
          "fs": {"command": "~/bin/fs", "args": ["${ROOT}", "~/data"], "env": {"TOKEN": "${TOKEN}"}, "cwd": "sub",
                 "exposure": "direct", "toolExposure": {"delete_*": "hidden"},
                 "startupTimeout": 5, "timeout": 12.5, "description": "Files"},
          "docs": {"type": "streamable-http", "url": "https://${HOST}/mcp", "headers": {"Authorization": "Bearer ${TOKEN}"}},
          "off": {"command": "x", "enabled": false}
        }}
        """)
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let loaded = dirs.load(environment: ["ROOT": "/r", "TOKEN": "t", "HOST": "example.com"])
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.entries.map(\.server.name) == ["docs", "fs"])

        let fs = try #require(loaded.entries.last)
        #expect(fs.server.transport == .stdio(
            command: dirs.home + "/bin/fs", args: ["/r", dirs.home + "/data"], env: ["TOKEN": "t"], cwd: dirs.cwd + "/sub"
        ))
        #expect(fs.server.exposure == .deferred)
        #expect(fs.server.exposure(forTool: "delete_all") == .hidden)
        #expect(fs.server.startupTimeoutSeconds == 5)
        #expect(fs.server.toolTimeoutSeconds == 12.5)
        #expect(fs.description == "Files")

        let docs = try #require(loaded.entries.first)
        #expect(docs.server.transport == .http(url: URL(string: "https://example.com/mcp")!, headers: ["Authorization": "Bearer t"]))
    }

    @Test("an untrusted project file is not read at all")
    func untrustedProject() throws {
        let dirs = try Dirs(
            user: #"{"mcpServers": {"gh": {"command": "gh-mcp", "enabled": false}}}"#,
            project: #"{"mcpServers": {"gh": {"enabled": true}, "evil": {"command": "rm"}}}"#
        )
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let untrusted = dirs.load()
        #expect(untrusted.entries.isEmpty)
        #expect(untrusted.warnings.contains { $0.contains(MCPRuntime.allowProjectServersVariable) })

        let trusted = dirs.load(trustProject: true)
        #expect(trusted.entries.map(\.server.name) == ["evil"])
    }

    @Test("a trusted project entry replaces the user entry of the same name")
    func projectReplaces() throws {
        let dirs = try Dirs(
            user: #"{"mcpServers": {"a": {"command": "user-a"}, "b": {"command": "user-b"}}}"#,
            project: #"{"mcpServers": {"a": {"command": "project-a"}}}"#
        )
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let loaded = dirs.load(trustProject: true)
        #expect(loaded.entries.map(\.server.transport) == [.stdio(command: "project-a"), .stdio(command: "user-b")])
    }

    @Test("a project directory that is the home directory reads the file once")
    func projectIsHome() throws {
        let dirs = try Dirs(user: #"{"mcpServers": {"a": {"command": "a"}}}"#)
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let loaded = MCPConfigFile.load(cwd: dirs.home, homeDirectory: dirs.home, trustProject: false, environment: [:])
        #expect(loaded.entries.map(\.server.name) == ["a"])
        #expect(loaded.warnings.isEmpty)
    }

    @Test("invalid entries become warnings, valid ones still load")
    func invalidEntries() throws {
        let dirs = try Dirs(user: """
        {"mcpServers": {
          "bad name": {"command": "x"},
          "sse": {"type": "sse", "url": "https://example.com/sse"},
          "nothing": {},
          "badexp": {"command": "x", "exposure": "sometimes"},
          "unset": {"command": "x", "env": {"K": "${MISSING}"}},
          "ok": {"command": "x"}
        }}
        """)
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let loaded = dirs.load()
        #expect(loaded.entries.map(\.server.name) == ["ok", "unset"])
        #expect(loaded.warnings.count == 5)
        #expect(loaded.warnings.contains { $0.contains("MISSING") })
    }

    @Test("env expansion")
    func expansion() {
        var expander = Expander(home: "/h", environment: ["A": "1", "EMPTY": ""])
        #expect(expander.expand("x${A}y${B:-dflt}z${EMPTY:-e}", field: "f") == "x1ydfltze")
        #expect(expander.expand("${NOPE}", field: "f") == "")
        #expect(expander.warnings.count == 1)
        #expect(expander.expandPath("~/x", field: "f") == "/h/x")
        #expect(expander.expandPath("a~/x", field: "f") == "a~/x")
    }
}
