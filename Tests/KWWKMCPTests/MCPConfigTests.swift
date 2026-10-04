import Foundation
import Testing
@testable import KWWKMCP

@Suite("MCP config")
struct MCPConfigTests {
    @Test("tool exposure: exact name, then patterns, then the server default")
    func exposure() {
        let config = MCPServerConfig(
            name: "fs",
            transport: .stdio(command: "fs"),
            toolExposure: ["delete_*": .hidden, "delete_tmp": .deferred]
        )
        #expect(config.exposure(forTool: "delete_all") == .hidden)
        #expect(config.exposure(forTool: "delete_tmp") == .deferred)
        #expect(config.exposure(forTool: "read") == .deferred)
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
