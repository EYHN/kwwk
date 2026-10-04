import Foundation

/// How the tools of an MCP server reach the model.
///
/// MCP tools are never declared up front: a session never waits on a server
/// before its first request, and tools only cost context once used.
public enum MCPToolExposure: String, Sendable, Hashable, Codable, CaseIterable {
    /// Registered but not declared until a tool-search step loads them.
    case deferred
    /// Never exposed; `MCPManager.tools()` leaves them out.
    case hidden
}

/// How kwwk talks to an MCP server.
public enum MCPTransportConfig: Sendable, Hashable {
    /// Spawn `command` with `args` and speak newline-delimited JSON-RPC over
    /// its stdin/stdout. `env` is added to the inherited environment; a bare
    /// `command` is looked up on the resulting `PATH`. `cwd` nil inherits the
    /// process working directory.
    case stdio(command: String, args: [String] = [], env: [String: String] = [:], cwd: String? = nil)
    /// Streamable HTTP transport (MCP 2025-03-26+).
    case http(url: URL, headers: [String: String] = [:])
}

/// One MCP server. The SDK never reads configuration on its own; callers
/// build these values (the kwwk TUI parses `mcp.json` into them).
public struct MCPServerConfig: Sendable, Hashable {
    /// Server name: letters, digits, `_` and `-`.
    public var name: String
    public var transport: MCPTransportConfig
    /// Default exposure of the server's tools.
    public var exposure: MCPToolExposure
    /// Per-tool overrides of `exposure`. Keys are tool names as the server
    /// offers them, or patterns where `*` matches any run of characters. An
    /// exact name wins over patterns; among patterns the lexicographically
    /// first matching key wins.
    public var toolExposure: [String: MCPToolExposure]
    /// Bound on connecting (spawn + `initialize` + first `tools/list`).
    public var startupTimeoutSeconds: Double
    /// Per-request timeout of tool calls and other requests.
    public var toolTimeoutSeconds: Double

    public init(
        name: String,
        transport: MCPTransportConfig,
        exposure: MCPToolExposure = .deferred,
        toolExposure: [String: MCPToolExposure] = [:],
        startupTimeoutSeconds: Double = 30,
        toolTimeoutSeconds: Double = MCPClient.defaultRequestTimeoutSeconds
    ) {
        self.name = name
        self.transport = transport
        self.exposure = exposure
        self.toolExposure = toolExposure
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolTimeoutSeconds = toolTimeoutSeconds
    }

    /// Effective exposure of one tool: its exact `toolExposure` entry, else
    /// the first matching `*` pattern (in sorted key order), else `exposure`.
    public func exposure(forTool toolName: String) -> MCPToolExposure {
        if let exact = toolExposure[toolName] { return exact }
        for pattern in toolExposure.keys.sorted() where pattern.contains("*") {
            if MCPGlob.matches(pattern: pattern, value: toolName), let value = toolExposure[pattern] {
                return value
            }
        }
        return exposure
    }
}

/// Minimal `*`-only glob matching used for `toolExposure` patterns.
enum MCPGlob {
    static func matches(pattern: String, value: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == value }
        var rest = Substring(value)
        guard let first = parts.first, rest.hasPrefix(first) else { return false }
        rest = rest.dropFirst(first.count)
        let last = parts[parts.count - 1]
        for middle in parts.dropFirst().dropLast() where !middle.isEmpty {
            guard let range = rest.range(of: middle) else { return false }
            rest = rest[range.upperBound...]
        }
        return rest.count >= last.count && rest.hasSuffix(last)
    }
}
