import Foundation
import KWWKAgent
import KWWKAI

/// An MCP tool adapted for the agent.
public struct MCPAgentTool: Sendable {
    /// The agent tool (`mcp__<server>__<tool>`).
    public var tool: AgentTool
    /// Name of the server that offers it.
    public var server: String
}

/// Connection state of one server.
public enum MCPServerState: Sendable, Hashable {
    case connecting
    case connected
    /// The connection dropped after it was established. Its tools stay; the
    /// manager reconnects in the background, and a tool call reconnects too.
    case disconnected(String)
    /// Connecting failed. The manager retries in the background a few times,
    /// then once more on the next tool search or call.
    case failed(String)
    /// The server needs authorization the auth provider could not supply.
    /// Tools it already offered stay; there is no background reconnection,
    /// but every tool search and every call on it asks the provider again.
    case authorizationRequired(String?)
    /// The manager was shut down.
    case closed
}

/// Status of one server, for UI.
public struct MCPServerStatus: Sendable, Hashable {
    public var name: String
    public var state: MCPServerState
    /// Tools the server offers (including hidden ones).
    public var toolCount: Int
    public var serverInfo: MCPServerInfo?
}

/// Background reconnection after a dropped or failed connection.
public struct MCPReconnectPolicy: Sendable, Hashable {
    /// Background attempts after a drop or failure before giving up until
    /// the next tool search or call.
    public var maxAttempts: Int
    public var initialDelaySeconds: Double
    public var maxDelaySeconds: Double

    public init(maxAttempts: Int = 5, initialDelaySeconds: Double = 1, maxDelaySeconds: Double = 30) {
        self.maxAttempts = maxAttempts
        self.initialDelaySeconds = initialDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
    }

    public static let `default` = MCPReconnectPolicy()
    /// No background reconnection.
    public static let none = MCPReconnectPolicy(maxAttempts: 0)

    func delay(afterFailures failures: Int) -> Double {
        let exponent = Double(max(0, failures - 1))
        return min(maxDelaySeconds, initialDelaySeconds * pow(2, exponent))
    }
}

/// Owns the connections to a set of MCP servers and the agent tools they
/// contribute.
///
/// `start()` connects every server concurrently in the background. Tools
/// appear once their server connected; observers registered with
/// `onToolsChanged` hear about every change (servers connecting or going
/// away, `tools/list_changed`, authorization being required, shutdown).
///
/// - A dropped connection keeps its tools and reconnects in the background
///   (`MCPReconnectPolicy`); a call on it reconnects first.
/// - A server that needs authorization (`MCPAuthError`) keeps the tools it
///   offered but is not reconnected in the background; each tool search and
///   each call on it connects again, asking the auth provider for fresh
///   credentials (the provider decides what to cache).
/// - Servers can be added, replaced and removed while running.
/// - A tool call is never sent twice: a call that failed because the
///   connection dropped fails, and the next call reconnects.
public actor MCPManager {
    public nonisolated let clientName: String
    public nonisolated let clientVersion: String
    public nonisolated let reconnectPolicy: MCPReconnectPolicy
    public nonisolated let resultLimits: MCPResultLimits
    private let transportFactory: MCPTransportFactory

    private struct Server {
        var config: MCPServerConfig
        var auth: MCPTransportAuth?
        var state: MCPServerState = .connecting
        var client: MCPClient?
        var tools: [MCPTool] = []
        var serverInfo: MCPServerInfo?
        var connectTask: Task<MCPClient, Error>?
        var reconnectTask: Task<Void, Never>?
        /// Consecutive failed connection attempts.
        var failures = 0
        var generation = 0
        /// Orders concurrent `tools/list` refreshes; only the newest applies.
        var toolsRevision = 0
    }

    private var servers: [String: Server] = [:]
    private var order: [String] = []
    private var agentTools: [MCPAgentTool] = []
    private var toolsSignature: [String] = []
    private var toolObservers: [(id: UUID, handler: @Sendable ([MCPAgentTool]) async -> Void)] = []
    private var deliveryChain: Task<Void, Never>?
    private var started = false
    private var isShutDown = false
    /// Source of `Server.generation` values, unique across the manager so a
    /// server removed and added again never matches an old connect.
    private var generationCounter = 0

    private func nextGeneration() -> Int {
        generationCounter += 1
        return generationCounter
    }

    /// - Parameters:
    ///   - configs: Servers to manage. Later duplicates of a name are ignored.
    ///   - auth: Authentication per server name (HTTP servers).
    ///   - resultLimits: How much of a tool result reaches the model.
    ///   - transportFactory: Builds transports; defaults to stdio / streamable
    ///     HTTP from the config.
    public init(
        configs: [MCPServerConfig],
        auth: [String: MCPTransportAuth] = [:],
        clientName: String = "kwwk",
        clientVersion: String = "1.0.0",
        reconnectPolicy: MCPReconnectPolicy = .default,
        resultLimits: MCPResultLimits = .default,
        transportFactory: @escaping MCPTransportFactory = { try MCPTransports.make(for: $0, auth: $1) }
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.reconnectPolicy = reconnectPolicy
        self.resultLimits = resultLimits
        self.transportFactory = transportFactory
        for config in configs where servers[config.name] == nil {
            order.append(config.name)
            servers[config.name] = Server(config: config, auth: auth[config.name])
        }
    }

    // MARK: - Lifecycle

    /// Begin connecting every server in the background. Idempotent.
    public func start() {
        guard !started, !isShutDown else { return }
        started = true
        for name in order {
            _ = ensureConnecting(name)
        }
    }

    /// Wait until every connection attempt in flight settled (connected or
    /// failed) and observers heard about the resulting tools, or `timeout`
    /// seconds passed, or `cancellation` fired. Starts the manager if needed.
    /// Returns true when everything settled in time.
    @discardableResult
    public func waitForStartup(timeout: TimeInterval, cancellation: CancellationHandle? = nil) async -> Bool {
        start()
        return await waitForConnections(timeout: timeout, cancellation: cancellation)
    }

    /// Before a tool search: retry once each server whose background
    /// reconnection gave up or that needs authorization, then wait like
    /// `waitForStartup`.
    @discardableResult
    public func prepareForSearch(timeout: TimeInterval, cancellation: CancellationHandle? = nil) async -> Bool {
        start()
        for name in order {
            guard let server = servers[name], server.connectTask == nil, server.reconnectTask == nil else { continue }
            switch server.state {
            case .failed, .disconnected, .authorizationRequired:
                _ = ensureConnecting(name)
            default:
                break
            }
        }
        return await waitForConnections(timeout: timeout, cancellation: cancellation)
    }

    private func waitForConnections(timeout: TimeInterval, cancellation: CancellationHandle?) async -> Bool {
        let tasks = order.compactMap { servers[$0]?.connectTask }
        let all = Task<Void, Error> { [weak self] in
            for task in tasks { _ = try? await task.value }
            await self?.deliveredChanges()
        }
        do {
            try await MCPWait.value(of: all, timeoutSeconds: timeout, cancellation: cancellation, what: "MCP startup")
            return true
        } catch {
            return false
        }
    }

    /// Returns once every tool change so far reached the observers.
    private func deliveredChanges() async {
        await deliveryChain?.value
    }

    /// Close every connection. Tools are withdrawn (observers receive `[]`).
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        var clients: [MCPClient] = []
        for name in order {
            guard var server = servers[name] else { continue }
            server.connectTask?.cancel()
            server.connectTask = nil
            server.reconnectTask?.cancel()
            server.reconnectTask = nil
            server.generation = nextGeneration()
            if let client = server.client { clients.append(client) }
            server.client = nil
            server.state = .closed
            servers[name] = server
        }
        await closeAll(clients)
        rebuildTools()
        await deliveryChain?.value
    }

    private func closeAll(_ clients: [MCPClient]) async {
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.close() }
            }
        }
    }

    // MARK: - Changing servers

    /// Add a server and start connecting it (once the manager started).
    /// Fails when a server of that name exists.
    public func addServer(_ config: MCPServerConfig, auth: MCPTransportAuth? = nil) throws {
        guard !isShutDown else { throw MCPManagerError.shutDown }
        guard servers[config.name] == nil else { throw MCPManagerError.duplicateServer(config.name) }
        order.append(config.name)
        servers[config.name] = Server(config: config, auth: auth)
        if started { _ = ensureConnecting(config.name) }
    }

    /// Remove a server: close its connection and withdraw its tools.
    public func removeServer(_ name: String) async {
        guard var server = servers.removeValue(forKey: name) else { return }
        order.removeAll { $0 == name }
        server.connectTask?.cancel()
        server.reconnectTask?.cancel()
        let client = server.client
        server.client = nil
        rebuildTools()
        await client?.close()
    }

    /// Replace a server's configuration and auth: the old connection closes
    /// and its tools leave until the new one connects.
    public func updateServer(_ config: MCPServerConfig, auth: MCPTransportAuth? = nil) async throws {
        guard !isShutDown else { throw MCPManagerError.shutDown }
        guard let existing = servers[config.name] else {
            try addServer(config, auth: auth)
            return
        }
        existing.connectTask?.cancel()
        existing.reconnectTask?.cancel()
        let client = existing.client
        var server = Server(config: config, auth: auth)
        server.generation = nextGeneration()
        servers[config.name] = server
        rebuildTools()
        await client?.close()
        if started { _ = ensureConnecting(config.name) }
    }

    /// Drop the current connection (if any) and connect again now, e.g.
    /// when the host knows new credentials are in place.
    public func reconnect(_ name: String) async throws {
        guard !isShutDown else { throw MCPManagerError.shutDown }
        guard var server = servers[name] else { throw MCPManagerError.unknownServer(name) }
        server.connectTask?.cancel()
        server.connectTask = nil
        server.reconnectTask?.cancel()
        server.reconnectTask = nil
        server.failures = 0
        server.generation = nextGeneration()
        let client = server.client
        server.client = nil
        servers[name] = server
        await client?.close()
        started = true
        _ = ensureConnecting(name)
    }

    // MARK: - Queries

    /// Agent tools of the available servers, hidden tools excluded, in
    /// config order then server order.
    public func tools() -> [MCPAgentTool] {
        agentTools
    }

    /// Status of every server, in config order.
    public func statuses() -> [MCPServerStatus] {
        order.compactMap { name in
            guard let server = servers[name] else { return nil }
            return MCPServerStatus(
                name: name,
                state: server.state,
                toolCount: server.tools.count,
                serverInfo: server.serverInfo
            )
        }
    }

    /// Servers that cannot provide tools right now, with a short reason, for
    /// `tool_search` to name. Servers still connecting, and servers whose
    /// tools stay available while they reconnect, are not listed.
    public func unavailableServers() -> [ToolSourceStatus] {
        order.compactMap { name in
            guard let server = servers[name] else { return nil }
            switch server.state {
            case .authorizationRequired:
                return ToolSourceStatus(name: name, reason: "requires authorization")
            case .failed where server.tools.isEmpty:
                return ToolSourceStatus(name: name, reason: "failed to connect")
            case .disconnected where server.tools.isEmpty:
                return ToolSourceStatus(name: name, reason: "disconnected")
            default:
                return nil
            }
        }
    }

    /// The system-prompt section listing the servers: one line each, name
    /// and description, no state. Built from configuration only.
    public func promptSection() -> String? {
        let configs = order.compactMap { servers[$0]?.config }
            .filter { $0.exposure == .deferred || $0.toolExposure.values.contains(.deferred) }
        return Self.renderPromptSection(configs)
    }

    /// The prompt section for `configs`.
    public static func renderPromptSection(_ configs: [MCPServerConfig]) -> String? {
        guard !configs.isEmpty else { return nil }
        let lines = configs.map { config -> String in
            guard let description = config.description?.split(whereSeparator: \.isNewline).first else {
                return "- \(config.name)"
            }
            return "- \(config.name): \(description.prefix(250))"
        }
        return """
        <mcp_servers>
        These MCP servers provide tools named mcp__<server>__<tool> that are not loaded upfront. \
        Use \(toolSearchToolName) to find and load them before calling them.
        \(lines.joined(separator: "\n"))
        </mcp_servers>
        """
    }

    /// Register a handler called with the full tool list whenever it changes.
    /// Calls are delivered in order. Returns a token for `removeObserver(_:)`.
    @discardableResult
    public func onToolsChanged(_ handler: @escaping @Sendable ([MCPAgentTool]) async -> Void) -> UUID {
        let id = UUID()
        toolObservers.append((id, handler))
        return id
    }

    public func removeObserver(_ id: UUID) {
        toolObservers.removeAll { $0.id == id }
    }

    /// Registered tool observers (tests).
    var observerCount: Int { toolObservers.count }

    // MARK: - Tool calls

    /// Call a tool by its server-side name, waiting for (or re-establishing)
    /// the connection first. Used by the agent tools' `execute`. A server
    /// that needs authorization is connected again first; when the provider
    /// still has no usable credentials the call fails with
    /// `MCPManagerError.authorizationRequired`.
    public func callTool(
        server name: String,
        tool: String,
        arguments: JSONValue,
        cancellation: CancellationHandle? = nil,
        onProgress: (@Sendable (MCPProgress) -> Void)? = nil
    ) async throws -> MCPCallToolResult {
        let client = try await client(for: name, cancellation: cancellation)
        let config = servers[name]?.config
        do {
            return try await client.callTool(
                name: tool,
                arguments: arguments,
                timeoutSeconds: config?.toolTimeoutSeconds,
                maxTotalTimeoutSeconds: config?.toolMaxTotalTimeoutSeconds,
                cancellation: cancellation,
                onProgress: onProgress
            )
        } catch let error as MCPAuthError where error.requiresAuthorization {
            requireAuthorization(name, client: client, error: error)
            throw MCPManagerError.authorizationRequired(name)
        }
    }

    /// The connected client of a server, connecting if needed (bounded by the
    /// server's startup timeout).
    public func client(for name: String, cancellation: CancellationHandle? = nil) async throws -> MCPClient {
        guard !isShutDown else { throw MCPManagerError.shutDown }
        guard let server = servers[name] else { throw MCPManagerError.unknownServer(name) }
        // A connection that dropped before its close was observed is stale.
        if case .connected = server.state, let client = server.client, await client.isConnected {
            return client
        }
        guard let task = ensureConnecting(name) else { throw MCPManagerError.shutDown }
        do {
            return try await MCPWait.value(
                of: task,
                timeoutSeconds: server.config.startupTimeoutSeconds,
                cancellation: cancellation,
                what: "connecting to MCP server \"\(name)\""
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if case .authorizationRequired? = servers[name]?.state {
                throw MCPManagerError.authorizationRequired(name)
            }
            throw MCPManagerError.unavailable(name, MCPClient.describe(error))
        }
    }

    // MARK: - Connecting

    private func ensureConnecting(_ name: String) -> Task<MCPClient, Error>? {
        guard !isShutDown, var server = servers[name] else { return nil }
        if let task = server.connectTask { return task }
        server.reconnectTask?.cancel()
        server.reconnectTask = nil
        server.generation = nextGeneration()
        let generation = server.generation
        server.state = .connecting
        let task = Task<MCPClient, Error> { [weak self] in
            guard let self else { throw MCPManagerError.shutDown }
            return try await self.performConnect(name: name, generation: generation)
        }
        server.connectTask = task
        servers[name] = server
        return task
    }

    private func performConnect(name: String, generation: Int) async throws -> MCPClient {
        guard let current = servers[name] else { throw MCPManagerError.unknownServer(name) }
        let config = current.config
        var client: MCPClient?
        do {
            let created = MCPClient(
                transport: try transportFactory(config, current.auth),
                clientName: clientName,
                clientVersion: clientVersion,
                requestTimeoutSeconds: config.toolTimeoutSeconds
            )
            client = created
            await created.setToolsListChangedHandler { [weak self, weak created] in
                guard let created else { return }
                await self?.refreshTools(name: name, client: created)
            }
            await created.setCloseHandler { [weak self, weak created] error in
                guard let created else { return }
                await self?.connectionDropped(name: name, client: created, error: error)
            }
            try await created.connect(timeoutSeconds: config.startupTimeoutSeconds)
            let tools = await created.supportsTools
                ? try await created.listTools(timeoutSeconds: config.startupTimeoutSeconds)
                : []
            let info = await created.serverInfo
            guard !isShutDown, var server = servers[name], server.generation == generation else {
                await created.close()
                throw MCPManagerError.shutDown
            }
            server.client = created
            server.tools = tools
            server.serverInfo = info
            server.state = .connected
            server.connectTask = nil
            server.failures = 0
            servers[name] = server
            rebuildTools()
            return created
        } catch {
            await client?.close()
            if !isShutDown, var server = servers[name], server.generation == generation {
                server.client = nil
                server.connectTask = nil
                if let authError = Self.authorizationError(in: error) {
                    server.state = .authorizationRequired(authError.errorDescription)
                    server.failures = 0
                    servers[name] = server
                    rebuildTools()
                } else {
                    server.state = .failed(MCPClient.describe(error))
                    server.failures += 1
                    servers[name] = server
                    scheduleReconnect(name)
                }
            }
            throw error
        }
    }

    /// The authorization error inside `error`, if connecting failed for that.
    static func authorizationError(in error: Error) -> MCPAuthError? {
        if let auth = error as? MCPAuthError, auth.requiresAuthorization { return auth }
        return nil
    }

    private func requireAuthorization(_ name: String, client: MCPClient, error: MCPAuthError) {
        // Only the live connection's own failure counts: a late error from a
        // connection already replaced must not undo a reconnect.
        guard var server = servers[name], server.client === client else { return }
        server.state = .authorizationRequired(error.errorDescription)
        server.client = nil
        server.reconnectTask?.cancel()
        server.reconnectTask = nil
        server.generation = nextGeneration()
        servers[name] = server
        rebuildTools()
        Task { await client.close() }
    }

    private func scheduleReconnect(_ name: String) {
        guard !isShutDown, var server = servers[name], server.reconnectTask == nil,
              server.failures <= reconnectPolicy.maxAttempts, reconnectPolicy.maxAttempts > 0
        else { return }
        let failures = max(1, server.failures)
        guard failures <= reconnectPolicy.maxAttempts else { return }
        let delay = reconnectPolicy.delay(afterFailures: failures)
        let generation = server.generation
        server.reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.backgroundReconnect(name: name, generation: generation)
        }
        servers[name] = server
    }

    private func backgroundReconnect(name: String, generation: Int) {
        guard var server = servers[name], server.generation == generation else { return }
        server.reconnectTask = nil
        servers[name] = server
        switch server.state {
        case .failed, .disconnected:
            _ = ensureConnecting(name)
        default:
            break
        }
    }

    private func refreshTools(name: String, client: MCPClient) async {
        guard var server = servers[name], server.client === client else { return }
        server.toolsRevision += 1
        let revision = server.toolsRevision
        servers[name] = server
        guard let tools = try? await client.listTools(timeoutSeconds: server.config.startupTimeoutSeconds) else { return }
        guard var current = servers[name], current.client === client, current.toolsRevision == revision,
              !isShutDown else { return }
        current.tools = tools
        servers[name] = current
        rebuildTools()
    }

    private func connectionDropped(name: String, client: MCPClient, error: Error?) {
        guard var server = servers[name], server.client === client, !isShutDown else { return }
        server.client = nil
        server.state = .disconnected(error.map(MCPClient.describe) ?? "Connection closed")
        server.failures = 1
        servers[name] = server
        scheduleReconnect(name)
    }

    // MARK: - Tools

    private func rebuildTools() {
        var entries: [(server: String, tool: MCPTool)] = []
        if !isShutDown {
            for name in order {
                guard let server = servers[name] else { continue }
                if case .closed = server.state { continue }
                for tool in server.tools where server.config.exposure(forTool: tool.name) != .hidden {
                    entries.append((name, tool))
                }
            }
        }
        let names = MCPToolNaming.assignNames(entries.map { ($0.server, $0.tool.name) })
        var signature: [String] = []
        var result: [MCPAgentTool] = []
        for (index, entry) in entries.enumerated() {
            let server = entry.server
            let agentTool = MCPToolAdapter.makeAgentTool(
                server: server,
                tool: entry.tool,
                name: names[index],
                limits: resultLimits
            ) { [weak self] toolName, arguments, cancellation, onProgress in
                guard let self else { throw MCPManagerError.shutDown }
                return try await self.callTool(
                    server: server,
                    tool: toolName,
                    arguments: arguments,
                    cancellation: cancellation,
                    onProgress: onProgress
                )
            }
            result.append(MCPAgentTool(tool: agentTool, server: server))
            signature.append("\(names[index])\u{0}\(entry.tool.hashValue)")
        }
        agentTools = result
        guard signature != toolsSignature else { return }
        toolsSignature = signature
        let observers = toolObservers.map(\.handler)
        let snapshot = result
        let previous = deliveryChain
        // Deliver one change after another, in the order they happened.
        deliveryChain = Task {
            await previous?.value
            for handler in observers { await handler(snapshot) }
        }
    }
}

/// Errors of `MCPManager` tool calls.
public enum MCPManagerError: Error, LocalizedError, Sendable, Equatable {
    case unknownServer(String)
    case duplicateServer(String)
    case unavailable(String, String)
    case authorizationRequired(String)
    case shutDown

    public var errorDescription: String? {
        switch self {
        case .unknownServer(let name): return "Unknown MCP server \"\(name)\""
        case .duplicateServer(let name): return "MCP server \"\(name)\" already exists"
        case .unavailable(let name, let reason): return "MCP server \"\(name)\" is not available: \(reason)"
        case .authorizationRequired(let name): return "MCP server \"\(name)\" requires authorization."
        case .shutDown: return "MCP servers were shut down"
        }
    }
}

/// Waiting on an unstructured task with a timeout and cancellation, without
/// waiting for the task itself to finish when either fires.
enum MCPWait {
    static func value<T: Sendable>(
        of task: Task<T, Error>,
        timeoutSeconds: Double,
        cancellation: CancellationHandle?,
        what: String
    ) async throws -> T {
        let box = OneShot<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                box.set(continuation)
                let waiter = Task {
                    do { box.resume(.success(try await task.value)) } catch { box.resume(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
                    if !Task.isCancelled {
                        box.resume(.failure(MCPError.timeout(method: what, seconds: timeoutSeconds)))
                    }
                }
                let registration = cancellation?.onCancel { _ in box.resume(.failure(CancellationError())) }
                box.onResume {
                    waiter.cancel()
                    timer.cancel()
                    registration?.cancel()
                }
            }
        } onCancel: {
            box.resume(.failure(CancellationError()))
        }
    }

    final class OneShot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?
        private var done = false
        private var cleanup: (@Sendable () -> Void)?

        func set(_ continuation: CheckedContinuation<T, Error>) {
            let pending: Result<T, Error>? = lock.withLock {
                if let early { return early }
                self.continuation = continuation
                return nil
            }
            if let pending { continuation.resume(with: pending) }
        }

        func onResume(_ action: @escaping @Sendable () -> Void) {
            let runNow: Bool = lock.withLock {
                if done { return true }
                cleanup = action
                return false
            }
            if runNow { action() }
        }

        func resume(_ result: Result<T, Error>) {
            let (continuation, cleanup): (CheckedContinuation<T, Error>?, (@Sendable () -> Void)?) = lock.withLock {
                if done { return (nil, nil) }
                done = true
                let pair = (self.continuation, self.cleanup)
                if self.continuation == nil { early = result }
                self.continuation = nil
                self.cleanup = nil
                return pair
            }
            continuation?.resume(with: result)
            cleanup?()
        }
    }
}
