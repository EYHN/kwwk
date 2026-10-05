import Foundation
import KWWKAgent
import KWWKAI

extension MCPManager {
    /// Prefix of every MCP tool name (`mcp__<server>__<tool>`).
    public nonisolated static let toolPrefix = "mcp__"

    /// A `ToolCatalog` fed by this manager, ready to `bind(to:)` an agent:
    ///
    /// - every connected server's tools are searchable through `tool_search`,
    ///   and leave the catalog (and any agent that loaded them) when their
    ///   server is removed or needs authorization;
    /// - its instructions are `promptSection()` as of now. Call
    ///   `catalog.setInstructions(await manager.promptSection())` after
    ///   adding or removing servers, when changing the system prompt is fine;
    /// - `tool_search` first retries servers whose reconnection gave up and
    ///   waits up to `searchWaitSeconds` for servers still connecting;
    /// - `tool_search` names the servers that cannot provide tools when it
    ///   finds fewer than asked for.
    ///
    /// Starts the manager.
    public func makeToolCatalog(searchWaitSeconds: TimeInterval = 30) async -> ToolCatalog {
        let catalog = ToolCatalog(
            instructions: promptSection(),
            owns: { $0.hasPrefix(MCPManager.toolPrefix) },
            prepare: { [weak self] cancellation in
                await self?.prepareForSearch(timeout: searchWaitSeconds, cancellation: cancellation)
            },
            unavailableSources: { [weak self] in
                await self?.unavailableServers() ?? []
            }
        )
        catalog.setTools(tools().map(\.tool))
        onToolsChanged { tools in catalog.setTools(tools.map(\.tool)) }
        start()
        return catalog
    }
}
