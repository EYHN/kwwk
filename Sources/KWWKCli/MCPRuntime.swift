import Foundation
import KWWKAI
import KWWKAgent
import KWWKMCP

/// The TUI's MCP integration: loads `mcp.json` (see ``MCPConfigFile``),
/// connects the servers in the background and exposes their tools through a
/// ``ToolCatalog`` and `tool_search`.
///
/// Nothing waits for a server before a request. `tool_search` waits for
/// servers that are still connecting, and a tool restored from a resumed
/// transcript waits for its server when called.
final class MCPRuntime: Sendable {
    /// Opts into servers defined by the project's own `.kwwk/mcp.json`. Off
    /// by default: opening a repository must not run its commands.
    static let allowProjectServersVariable = "KWWK_ALLOW_PROJECT_MCP"
    /// Prefix of every MCP tool name (`mcp__<server>__<tool>`).
    static let toolPrefix = "mcp__"

    let manager: MCPManager?
    let catalog: ToolCatalog
    let warnings: [String]
    /// Names the servers and what they offer. Built from config only, so it
    /// never changes while servers connect.
    let systemPromptSection: String?

    init(
        cwd: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let loaded = MCPConfigFile.load(
            cwd: cwd,
            homeDirectory: homeDirectory,
            trustProject: ["1", "true", "yes"].contains(environment[Self.allowProjectServersVariable]?.lowercased() ?? ""),
            environment: environment
        )
        // A server whose every tool is hidden contributes nothing: don't run it.
        let entries = loaded.entries.filter { entry in
            entry.server.exposure == .deferred || entry.server.toolExposure.values.contains(.deferred)
        }
        let manager = entries.isEmpty ? nil : MCPManager(configs: entries.map(\.server))
        let startupTimeout = entries.map(\.server.startupTimeoutSeconds).max() ?? 0
        self.manager = manager
        self.catalog = ToolCatalog { cancellation in
            await manager?.waitForStartup(timeout: startupTimeout, cancellation: cancellation)
        }
        self.warnings = loaded.warnings
        self.systemPromptSection = Self.renderSection(entries)
    }

    /// Connect servers in the background and mirror their tools into the
    /// catalog. Call once per process.
    func start() async {
        guard let manager else { return }
        let catalog = catalog
        await manager.onToolsChanged { tools in catalog.setTools(tools.map(\.tool)) }
        await manager.start()
    }

    /// Wire the session's first agent: the servers section joins its system
    /// prompt (later agents copy it with the rest of the prompt).
    func attach(to agent: Agent, messages: [Message]) {
        guard manager != nil else { return }
        if let section = systemPromptSection {
            agent.state.systemPrompt += "\n\n" + section
        }
        rebind(to: agent, messages: messages)
    }

    /// Point the catalog at `agent` (also a replacement agent after `/new` or
    /// `/resume`) and load the MCP tools its transcript had loaded.
    func rebind(to agent: Agent, messages: [Message]) {
        guard manager != nil else { return }
        if !agent.state.tools.contains(where: { $0.name == toolSearchToolName }) {
            agent.state.tools.append(makeToolSearchTool(catalog: catalog))
        }
        catalog.restore(loaded: TranscriptTools.currentTools(in: messages).filter { $0.name.hasPrefix(Self.toolPrefix) })
        catalog.bind(to: agent)
    }

    func shutdown() async {
        await manager?.shutdown()
    }

    private static func renderSection(_ entries: [MCPConfigEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let lines = entries.map { entry -> String in
            let name = entry.server.name
            guard let description = entry.description?.split(whereSeparator: \.isNewline).first else {
                return "- \(name)"
            }
            return "- \(name): \(description.prefix(250))"
        }
        return """
        <mcp_servers>
        These MCP servers provide tools named mcp__<server>__<tool> that are not loaded upfront. \
        Use \(toolSearchToolName) to find and load them before calling them.
        \(lines.joined(separator: "\n"))
        </mcp_servers>
        """
    }
}

// MARK: - /mcp

/// `/mcp`: list MCP servers with their connection state.
@MainActor
func registerMCPSlashCommand(_ registry: SlashCommandRegistry, runtime: MCPRuntime) {
    registry.register(SlashCommand(
        name: "mcp",
        description: "Show MCP server status",
        handler: { ctx, _ in
            guard let manager = runtime.manager else {
                ctx.notify(Style.dimmed("  /mcp: no MCP servers configured (~/.kwwk/mcp.json)"))
                return
            }
            let statuses = await manager.statuses()
            let servers = Dictionary(
                await manager.tools().map { ($0.tool.name, $0.server) },
                uniquingKeysWith: { first, _ in first }
            )
            let loaded = runtime.catalog.tools.compactMap { servers[$0.name] }
            var lines = [Style.dimmed("  /mcp: \(statuses.count) server\(statuses.count == 1 ? "" : "s")")]
            for status in statuses {
                let state: String
                switch status.state {
                case .connecting: state = "connecting"
                case .connected: state = "connected"
                case .disconnected(let reason): state = "disconnected: \(reason)"
                case .failed(let reason): state = "failed: \(reason)"
                case .closed: state = "closed"
                }
                let active = loaded.filter { $0 == status.name }.count
                lines.append(Style.dimmed("    \(status.name) · \(state) · \(status.toolCount) tools, \(active) loaded"))
            }
            lines += runtime.warnings.map { Style.dimmed("    warning: \($0)") }
            ctx.notifyBlock(lines)
        }
    ))
}
