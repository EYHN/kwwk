import Foundation
import KWWKAI
import KWWKAgent
import KWWKMCP

/// The TUI's MCP integration: loads `~/.kwwk/mcp.json` (and, when allowed,
/// `<cwd>/.kwwk/mcp.json`), connects servers in the background, and keeps
/// their tools in a ``ToolCatalog`` bound to the live agent.
///
/// MCP tools are always deferred: nothing waits for a server before a
/// request. `tool_search` waits for servers still connecting, then loads the
/// matching tools; the agent loop records the change in the transcript, so
/// prompt caching and session resume keep working.
final class MCPRuntime: @unchecked Sendable {
    /// Environment variable that opts into servers defined by the project's
    /// own `.kwwk/mcp.json`. Off by default: a cloned repository must not be
    /// able to launch arbitrary commands just by being opened.
    static let allowProjectServersVariable = "KWWK_ALLOW_PROJECT_MCP"
    static let catalogSource = "mcp"

    let manager: MCPManager?
    let catalog = ToolCatalog()
    let warnings: [String]
    private let configs: [MCPServerConfig]

    /// Static system-prompt section naming the servers whose tools must be
    /// searched for. Built from config only so it never changes while
    /// servers connect.
    let systemPromptSection: String?

    init(
        cwd: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let loaded = MCPConfigLoader.load(cwd: cwd, homeDirectory: homeDirectory, environment: environment)
        var warnings = loaded.warnings
        let projectFile = URL(fileURLWithPath: cwd).appendingPathComponent(".kwwk/mcp.json").standardizedFileURL.path
        let allowProject = ["1", "true", "yes"].contains(environment[Self.allowProjectServersVariable]?.lowercased() ?? "")
        var configs: [MCPServerConfig] = []
        var ignored: [String] = []
        for config in loaded.servers {
            let fromProject = config.source.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path == projectFile
            } ?? false
            if fromProject && !allowProject && config.enabled {
                ignored.append(config.name)
                continue
            }
            configs.append(config)
        }
        if !ignored.isEmpty {
            warnings.append(
                "ignored MCP servers from \(projectFile): \(ignored.joined(separator: ", ")). "
                    + "Set \(Self.allowProjectServersVariable)=1 to trust this project's servers."
            )
        }
        self.configs = configs
        self.warnings = warnings
        let enabled = configs.filter(\.enabled)
        self.manager = enabled.isEmpty ? nil : MCPManager(configs: configs, workingDirectory: cwd)
        self.systemPromptSection = Self.renderSection(enabled)
    }

    /// Whether any enabled server can expose a tool, which makes
    /// `tool_search` necessary.
    var hasSearchableServers: Bool {
        configs.contains(where: Self.isSearchable)
    }

    private static func isSearchable(_ config: MCPServerConfig) -> Bool {
        config.enabled && (config.exposure == .deferred || config.toolExposure.values.contains(.deferred))
    }

    /// Connect servers in the background and mirror their tools into the
    /// catalog. Call once per process.
    func start() async {
        guard let manager else { return }
        let catalog = catalog
        await manager.onToolsChanged { tools in
            Self.publish(tools, to: catalog)
        }
        catalog.setSearchPreparation {
            await Self.waitAndPublish(manager: manager, catalog: catalog, timeout: MCPManager.defaultStartupTimeoutSeconds)
        }
        await manager.start()
    }

    /// Wait for in-flight connections, then publish the settled tool list.
    /// Change notifications are delivered asynchronously, so a waiter must
    /// not rely on them having arrived when the wait returns.
    @discardableResult
    func waitForStartup(timeout: TimeInterval) async -> Bool {
        guard let manager else { return true }
        return await Self.waitAndPublish(manager: manager, catalog: catalog, timeout: timeout)
    }

    @discardableResult
    private static func waitAndPublish(manager: MCPManager, catalog: ToolCatalog, timeout: TimeInterval) async -> Bool {
        let settled = await manager.waitForStartup(timeout: timeout)
        publish(await manager.tools(), to: catalog)
        return settled
    }

    private static func publish(_ tools: [MCPAgentTool], to catalog: ToolCatalog) {
        catalog.setTools(tools.map(\.tool), source: catalogSource)
    }

    /// Wire an agent to the catalog. `messages` is the transcript the agent
    /// starts from; deferred tools it had loaded are loaded again.
    func attach(to agent: Agent, messages: [Message]) {
        guard manager != nil else { return }
        if let section = systemPromptSection, !agent.state.systemPrompt.contains(section) {
            agent.state.systemPrompt = agent.state.systemPrompt + "\n\n" + section
        }
        rebind(to: agent, messages: messages)
    }

    /// Move the catalog to a replacement agent (`/new`, `/resume`) whose
    /// system prompt and hooks were copied from the previous one.
    func rebind(to agent: Agent, messages: [Message]) {
        guard manager != nil else { return }
        if hasSearchableServers, !agent.state.tools.contains(where: { $0.name == toolSearchToolName }) {
            agent.state.tools = agent.state.tools + [makeToolSearchTool(catalog: catalog)]
        }
        catalog.restoreLoadedTools(from: messages)
        catalog.bind(to: agent)
    }

    func shutdown() async {
        await manager?.shutdown()
    }

    private static func renderSection(_ configs: [MCPServerConfig]) -> String? {
        let listed = configs.filter(isSearchable)
        guard !listed.isEmpty else { return nil }
        var lines = [
            "<mcp_servers>",
            "These MCP servers provide tools named mcp__<server>__<tool> that are not loaded upfront. "
                + "Use \(toolSearchToolName) to find and load them before calling them.",
        ]
        for config in listed {
            var line = "- \(config.name)"
            if let description = config.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                let clipped = description.count > 250 ? String(description.prefix(249)) + "…" : description
                line += ": \(clipped.replacingOccurrences(of: "\n", with: " "))"
            }
            lines.append(line)
        }
        lines.append("</mcp_servers>")
        return lines.joined(separator: "\n")
    }
}

// MARK: - /mcp

/// `/mcp`: list configured MCP servers with their connection state.
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
            let mcpTools = await manager.tools()
            let loaded = Set(ctx.agent.state.tools.map(\.name))
            var lines = [Style.dimmed("  /mcp: \(statuses.count) server\(statuses.count == 1 ? "" : "s")")]
            for status in statuses {
                let state: String
                switch status.state {
                case .disabled: state = "disabled"
                case .connecting: state = "connecting"
                case .connected: state = "connected"
                case .disconnected(let reason): state = "disconnected: \(reason)"
                case .failed(let reason): state = "failed: \(reason)"
                case .closed: state = "closed"
                }
                let active = mcpTools.filter { $0.server == status.name && loaded.contains($0.tool.name) }.count
                lines.append(Style.dimmed(
                    "    \(status.name) · \(state) · \(status.toolCount) tools, \(active) loaded"
                ))
            }
            for warning in runtime.warnings {
                lines.append(Style.dimmed("    warning: \(warning)"))
            }
            ctx.notifyBlock(lines)
        }
    ))
}
