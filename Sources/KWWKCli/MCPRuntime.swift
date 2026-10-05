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
/// transcript waits for its server when called. HTTP servers use OAuth
/// (credentials in `~/.kwwk/mcp-oauth.json`) unless their config sends its
/// own `Authorization` header or sets `"oauth": false`; one that needs a
/// sign-in waits for `/mcp login <server>`.
final class MCPRuntime: Sendable {
    /// Opts into servers defined by the project's own `.kwwk/mcp.json`. Off
    /// by default: opening a repository must not run its commands.
    static let allowProjectServersVariable = "KWWK_ALLOW_PROJECT_MCP"
    /// Prefix of every MCP tool name (`mcp__<server>__<tool>`).
    static let toolPrefix = MCPManager.toolPrefix

    let manager: MCPManager?
    let catalog: ToolCatalog
    let warnings: [String]
    /// OAuth clients by server name.
    let oauthProviders: [String: CLIMCPOAuthProvider]
    let oauthStore: MCPOAuthFileStore

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
        let storeURL = MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory)
        let store = MCPOAuthFileStore(url: storeURL)
        let records = MCPOAuthFileStore.readRecords(url: storeURL)
        var providers: [String: CLIMCPOAuthProvider] = [:]
        var auth: [String: MCPTransportAuth] = [:]
        for entry in entries {
            guard let settings = entry.oauth, case .http(let url, _) = entry.server.transport else { continue }
            let port = MCPOAuthCLI.callbackPort(server: entry.server.name, serverURL: url, settings: settings, records: records)
            let provider = CLIMCPOAuthProvider(
                server: entry.server.name,
                serverURL: url,
                settings: settings,
                store: store,
                callbackPort: port
            )
            providers[entry.server.name] = provider
            // Background runs only refresh; `/mcp login` signs in.
            auth[entry.server.name] = .oauth(provider, interactive: false)
        }
        let spill = MCPDirectoryResultSpill(
            directory: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".kwwk/mcp-results")
        )
        let manager = entries.isEmpty ? nil : MCPManager(
            configs: entries.map(\.server),
            auth: auth,
            resultLimits: MCPResultLimits(spill: spill)
        )
        let searchWait = entries.map(\.server.startupTimeoutSeconds).max() ?? 0
        self.manager = manager
        self.catalog = ToolCatalog(
            instructions: MCPManager.renderPromptSection(entries.map(\.server)),
            owns: { $0.hasPrefix(MCPManager.toolPrefix) },
            prepare: { cancellation in
                await manager?.prepareForSearch(timeout: searchWait, cancellation: cancellation)
            },
            unavailableSources: { await manager?.unavailableServers() ?? [] }
        )
        self.warnings = loaded.warnings
        self.oauthProviders = providers
        self.oauthStore = store
        for (name, provider) in providers {
            let port = provider.callbackPort
            Task { await store.remember(port: port, server: name) }
        }
    }

    /// Connect servers in the background and mirror their tools into the
    /// catalog. Call once per process.
    func start() async {
        guard let manager else { return }
        let catalog = catalog
        await manager.onToolsChanged { tools in catalog.setTools(tools.map(\.tool)) }
        await manager.start()
    }

    /// Wire the session's first agent.
    func attach(to agent: Agent, messages: [Message]) {
        rebind(to: agent, messages: messages)
    }

    /// Point the catalog at `agent` (also a replacement agent after `/new` or
    /// `/resume`) and load the MCP tools its transcript had loaded. The
    /// catalog adds `tool_search` and the server list itself.
    func rebind(to agent: Agent, messages: [Message]) {
        guard manager != nil else { return }
        catalog.restore(from: messages)
        catalog.bind(to: agent)
    }

    /// Sign in to `server` with the browser, then reconnect it.
    func login(server: String) async throws {
        guard let manager else { throw MCPManagerError.unknownServer(server) }
        guard let provider = oauthProviders[server] else {
            throw MCPAuthError.providerMisconfigured("MCP server \"\(server)\" does not use OAuth")
        }
        try await provider.login()
        try await manager.reconnect(server)
    }

    /// Forget `server`'s OAuth credentials and reconnect it (it will need
    /// `/mcp login`).
    func logout(server: String) async throws {
        guard let manager else { throw MCPManagerError.unknownServer(server) }
        guard oauthProviders[server] != nil else {
            throw MCPAuthError.providerMisconfigured("MCP server \"\(server)\" does not use OAuth")
        }
        try await oauthStore.remove(server: server)
        try await manager.reconnect(server)
    }

    func shutdown() async {
        await manager?.shutdown()
    }
}

// MARK: - /mcp

/// `/mcp`: list MCP servers with their connection state; `/mcp login
/// <server>` and `/mcp logout <server>` manage OAuth sign-in.
@MainActor
func registerMCPSlashCommand(_ registry: SlashCommandRegistry, runtime: MCPRuntime) {
    registry.register(SlashCommand(
        name: "mcp",
        description: "Show MCP server status; /mcp login|logout <server>",
        handler: { ctx, args in
            guard let manager = runtime.manager else {
                ctx.notify(Style.dimmed("  /mcp: no MCP servers configured (~/.kwwk/mcp.json)"))
                return
            }
            let words = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let action = words.first, action == "login" || action == "logout" {
                guard words.count == 2 else {
                    ctx.notify(Style.dimmed("  usage: /mcp \(action) <server>"))
                    return
                }
                let server = words[1]
                do {
                    if action == "login" {
                        ctx.notify(Style.dimmed("  /mcp: signing in to \(server) in your browser…"))
                        try await runtime.login(server: server)
                        ctx.notify(Style.dimmed("  /mcp: signed in to \(server)"))
                    } else {
                        try await runtime.logout(server: server)
                        ctx.notify(Style.dimmed("  /mcp: signed out of \(server)"))
                    }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    ctx.notify(Style.dimmed("  /mcp \(action) \(server): \(message)"))
                }
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
                case .authorizationRequired:
                    state = runtime.oauthProviders[status.name] != nil
                        ? "needs sign-in: /mcp login \(status.name)"
                        : "needs authorization"
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
