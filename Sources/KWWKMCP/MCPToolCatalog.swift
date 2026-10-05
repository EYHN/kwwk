import Foundation
import KWWKAgent
import KWWKAI

extension MCPManager {
    /// Prefix of every MCP tool name (`mcp__<server>__<tool>`).
    public nonisolated static let toolPrefix = "mcp__"

    /// A `ToolCatalog` fed by this manager, ready to `bind(to:)` an agent:
    ///
    /// - every connected server's tools are searchable through
    ///   `tool_search`, and leave the catalog (and any agent that loaded
    ///   them) when their server is removed, replaced, needs authorization or
    ///   the manager shuts down;
    /// - its instructions are `promptSection()` as of now. Call
    ///   `catalog.setInstructions(await manager.promptSection())` after
    ///   adding or removing servers, when changing the system prompt is fine;
    /// - `tool_search` first retries servers whose reconnection gave up, and
    ///   servers that need authorization whose auth provider has a new
    ///   token, and waits up to `searchWaitSeconds` for servers still
    ///   connecting;
    /// - `tool_search` names the servers that cannot provide tools when it
    ///   finds fewer than asked for.
    ///
    /// The manager holds the catalog weakly; after the catalog is released,
    /// its observer unregisters itself at the next tool change. Starts the
    /// manager.
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
        let registration = ObserverRegistration()
        registration.id = onToolsChanged { [weak self, weak catalog] tools in
            guard let catalog else {
                if let id = registration.id { await self?.removeObserver(id) }
                return
            }
            catalog.setTools(tools.map(\.tool))
        }
        start()
        return catalog
    }
}

/// The id of an observer, readable from inside the observer itself.
private final class ObserverRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    var id: UUID? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
