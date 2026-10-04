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
    /// The connection dropped after it was established. The next tool call
    /// reconnects.
    case disconnected(String)
    /// Connecting failed. The next tool call of the server retries.
    case failed(String)
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

/// Owns the connections to a set of MCP servers and the agent tools they
/// contribute.
///
/// `start()` connects every server concurrently in the background. Tools
/// appear once their server connected; observers registered with
/// `onToolsChanged` hear about every change (servers connecting, servers
/// announcing `tools/list_changed`, shutdown). A tool call on a server that
/// is still connecting waits for it; a call on a server whose connection
/// dropped or failed reconnects first.
public actor MCPManager {
    public nonisolated let clientName: String
    public nonisolated let clientVersion: String
    private let transportFactory: MCPTransportFactory

    private struct Server {
        var config: MCPServerConfig
        var state: MCPServerState = .connecting
        var client: MCPClient?
        var tools: [MCPTool] = []
        var serverInfo: MCPServerInfo?
        var connectTask: Task<MCPClient, Error>?
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

    /// - Parameters:
    ///   - configs: Servers to manage. Later duplicates of a name are ignored.
    ///   - transportFactory: Builds transports; defaults to stdio / streamable
    ///     HTTP from the config.
    public init(
        configs: [MCPServerConfig],
        clientName: String = "kwwk",
        clientVersion: String = "1.0.0",
        transportFactory: @escaping MCPTransportFactory = MCPTransports.make
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.transportFactory = transportFactory
        for config in configs where servers[config.name] == nil {
            order.append(config.name)
            servers[config.name] = Server(config: config)
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
            server.generation += 1
            if let client = server.client { clients.append(client) }
            server.client = nil
            server.state = .closed
            servers[name] = server
        }
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.close() }
            }
        }
        rebuildTools()
        await deliveryChain?.value
    }

    // MARK: - Queries

    /// Agent tools of all connected servers, hidden tools excluded, in config
    /// order then server order.
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

    // MARK: - Tool calls

    /// Call a tool by its server-side name, waiting for (or re-establishing)
    /// the connection first. Used by the agent tools' `execute`.
    public func callTool(
        server name: String,
        tool: String,
        arguments: JSONValue,
        cancellation: CancellationHandle? = nil,
        onProgress: (@Sendable (MCPProgress) -> Void)? = nil
    ) async throws -> MCPCallToolResult {
        let client = try await client(for: name, cancellation: cancellation)
        return try await client.callTool(
            name: tool,
            arguments: arguments,
            timeoutSeconds: servers[name]?.config.toolTimeoutSeconds,
            cancellation: cancellation,
            onProgress: onProgress
        )
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
            throw MCPManagerError.unavailable(name, MCPClient.describe(error))
        }
    }

    // MARK: - Connecting

    private func ensureConnecting(_ name: String) -> Task<MCPClient, Error>? {
        guard !isShutDown, var server = servers[name] else { return nil }
        if let task = server.connectTask { return task }
        server.generation += 1
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
        guard let config = servers[name]?.config else { throw MCPManagerError.unknownServer(name) }
        var client: MCPClient?
        do {
            let created = MCPClient(
                transport: try transportFactory(config),
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
            guard !isShutDown, var current = servers[name], current.generation == generation else {
                await created.close()
                throw MCPManagerError.shutDown
            }
            current.client = created
            current.tools = tools
            current.serverInfo = info
            current.state = .connected
            current.connectTask = nil
            servers[name] = current
            rebuildTools()
            return created
        } catch {
            await client?.close()
            if !isShutDown, var current = servers[name], current.generation == generation {
                current.state = .failed(MCPClient.describe(error))
                current.client = nil
                current.connectTask = nil
                servers[name] = current
            }
            throw error
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
        servers[name] = server
    }

    // MARK: - Tools

    private func rebuildTools() {
        var entries: [(server: String, tool: MCPTool)] = []
        if !isShutDown {
            for name in order {
                guard let server = servers[name] else { continue }
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
                name: names[index]
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
    case unavailable(String, String)
    case shutDown

    public var errorDescription: String? {
        switch self {
        case .unknownServer(let name): return "Unknown MCP server \"\(name)\""
        case .unavailable(let name, let reason): return "MCP server \"\(name)\" is not available: \(reason)"
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
