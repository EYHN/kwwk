import Foundation
import KWWKAgent
import KWWKAI

/// An MCP tool adapted for the agent.
public struct MCPAgentTool: Sendable {
    /// The agent tool (`mcp__<server>__<tool>`).
    public var tool: AgentTool
    /// Server name from the config.
    public var server: String
    /// Tool name as the server offers it.
    public var originalName: String
    /// Effective exposure: always `deferred`, since hidden tools are omitted.
    public var exposure: MCPToolExposure
    /// The tool as listed by the server (annotations, output schema, ...).
    public var mcpTool: MCPTool

    public init(tool: AgentTool, server: String, originalName: String, exposure: MCPToolExposure, mcpTool: MCPTool) {
        self.tool = tool
        self.server = server
        self.originalName = originalName
        self.exposure = exposure
        self.mcpTool = mcpTool
    }
}

/// Connection state of one configured server.
public enum MCPServerState: Sendable, Hashable {
    /// `enabled: false` in the config; never connects.
    case disabled
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
    public var config: MCPServerConfig
}

/// What the system prompt needs to know about a server.
public struct MCPServerSummary: Sendable, Hashable {
    public var name: String
    /// Configured description.
    public var description: String?
    /// Instructions from the server's `initialize` result.
    public var instructions: String?
    public var serverInfo: MCPServerInfo?
    public var state: MCPServerState
    /// Non-hidden tools the server contributes.
    public var toolCount: Int
    /// Exposures in use among those tools.
    public var exposures: Set<MCPToolExposure>

    /// One-line summary: the first line of the description, else of the
    /// instructions, else the server's title.
    public var summaryLine: String? {
        for candidate in [description, instructions, serverInfo?.title] {
            guard let text = candidate else { continue }
            let line = text.split(whereSeparator: \.isNewline).first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            if !line.isEmpty { return line }
        }
        return nil
    }
}

/// Owns the connections to all configured MCP servers and the agent tools
/// they contribute.
///
/// `start()` connects every enabled server concurrently in the background.
/// Tools appear once their server connected; observers registered with
/// `onToolsChanged` hear about every change (servers connecting, servers
/// announcing `tools/list_changed`, shutdown). A tool call on a server that
/// is still connecting waits for it; a call on a server whose connection
/// dropped or failed reconnects first.
public actor MCPManager {
    public static let defaultStartupTimeoutSeconds: Double = 30

    public nonisolated let workingDirectory: String
    public nonisolated let clientName: String
    public nonisolated let clientVersion: String
    private let transportFactory: MCPTransportFactory

    private struct Server {
        var config: MCPServerConfig
        var state: MCPServerState
        var client: MCPClient?
        var tools: [MCPTool] = []
        var instructions: String?
        var serverInfo: MCPServerInfo?
        var connectTask: Task<MCPClient, Error>?
        var generation = 0

        var startupTimeout: Double {
            config.startupTimeoutSeconds ?? MCPManager.defaultStartupTimeoutSeconds
        }
    }

    private var servers: [String: Server] = [:]
    private var order: [String] = []
    private var agentTools: [MCPAgentTool] = []
    private var toolsSignature: [String] = []
    private var toolObservers: [(id: UUID, handler: @Sendable ([MCPAgentTool]) async -> Void)] = []
    private var statusObservers: [(id: UUID, handler: @Sendable ([MCPServerStatus]) async -> Void)] = []
    private var deliveryChain: Task<Void, Never>?
    private var started = false
    private var isShutDown = false

    /// - Parameters:
    ///   - configs: Servers to manage. Later duplicates of a name are ignored.
    ///   - workingDirectory: Session directory; relative stdio `cwd` values
    ///     resolve against it.
    ///   - transportFactory: Builds transports; defaults to stdio / streamable
    ///     HTTP from the config.
    public init(
        configs: [MCPServerConfig],
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        clientName: String = "kwwk",
        clientVersion: String = "1.0.0",
        transportFactory: MCPTransportFactory? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.transportFactory = transportFactory ?? { config, directory in
            try MCPTransports.make(for: config, workingDirectory: directory)
        }
        for config in configs where servers[config.name] == nil {
            order.append(config.name)
            servers[config.name] = Server(config: config, state: config.enabled ? .connecting : .disabled)
        }
    }

    // MARK: - Lifecycle

    /// Begin connecting every enabled server in the background. Idempotent.
    public func start() {
        guard !started, !isShutDown else { return }
        started = true
        for name in order {
            _ = ensureConnecting(name)
        }
    }

    /// Wait until every connection attempt in flight settled (connected or
    /// failed), or `timeout` seconds passed. Starts the manager if needed.
    /// Returns true when everything settled in time.
    @discardableResult
    public func waitForStartup(timeout: TimeInterval) async -> Bool {
        start()
        let tasks = order.compactMap { servers[$0]?.connectTask }
        guard !tasks.isEmpty else { return true }
        let all = Task<Void, Error> {
            for task in tasks { _ = try? await task.value }
        }
        do {
            try await MCPWait.value(of: all, timeoutSeconds: timeout, cancellation: nil, what: "MCP startup")
            return true
        } catch {
            return false
        }
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
        notifyStatus()
        await deliveryChain?.value
    }

    // MARK: - Queries

    /// Agent tools of all connected servers, hidden tools excluded, in config
    /// order then server order.
    public func tools() -> [MCPAgentTool] {
        agentTools
    }

    /// Status of every configured server, in config order.
    public func statuses() -> [MCPServerStatus] {
        order.compactMap { name in
            guard let server = servers[name] else { return nil }
            return MCPServerStatus(
                name: name,
                state: server.state,
                toolCount: server.tools.count,
                serverInfo: server.serverInfo,
                config: server.config
            )
        }
    }

    /// State of one server, nil when unknown.
    public func state(of server: String) -> MCPServerState? {
        servers[server]?.state
    }

    /// Summaries of enabled servers for a system-prompt section.
    public func serverSummaries() -> [MCPServerSummary] {
        order.compactMap { name in
            guard let server = servers[name], server.config.enabled else { return nil }
            let visible = server.tools.map { server.config.exposure(forTool: $0.name) }.filter { $0 != .hidden }
            return MCPServerSummary(
                name: name,
                description: server.config.description,
                instructions: server.instructions,
                serverInfo: server.serverInfo,
                state: server.state,
                toolCount: visible.count,
                exposures: Set(visible)
            )
        }
    }

    /// Render summaries as a system-prompt section listing the servers whose
    /// tools are not all declared directly (so the model knows to search for
    /// them). Returns nil when there is nothing to list.
    public static func renderServersSection(_ summaries: [MCPServerSummary], maxLineLength: Int = 200) -> String? {
        let listed = summaries.filter { summary in
            summary.exposures.contains(.deferred) || (summary.toolCount == 0 && summary.state != .disabled)
        }
        guard !listed.isEmpty else { return nil }
        var lines = ["MCP servers (their tools are named mcp__<server>__<tool>; search for them before use):"]
        for summary in listed {
            var line = "- \(summary.name)"
            if let text = summary.summaryLine {
                let clipped = text.count > maxLineLength ? String(text.prefix(maxLineLength - 1)) + "…" : text
                line += ": \(clipped)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Observers

    /// Register a handler called with the full tool list whenever it changes.
    /// Calls are delivered in order. Returns a token for
    /// `removeObserver(_:)`.
    @discardableResult
    public func onToolsChanged(_ handler: @escaping @Sendable ([MCPAgentTool]) async -> Void) -> UUID {
        let id = UUID()
        toolObservers.append((id, handler))
        return id
    }

    /// Register a handler called with all statuses whenever a server's state
    /// changes.
    @discardableResult
    public func onStatusChanged(_ handler: @escaping @Sendable ([MCPServerStatus]) async -> Void) -> UUID {
        let id = UUID()
        statusObservers.append((id, handler))
        return id
    }

    public func removeObserver(_ id: UUID) {
        toolObservers.removeAll { $0.id == id }
        statusObservers.removeAll { $0.id == id }
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
        let timeout = servers[name]?.config.toolTimeoutSeconds
        return try await client.callTool(
            name: tool,
            arguments: arguments,
            timeoutSeconds: timeout,
            cancellation: cancellation,
            onProgress: onProgress
        )
    }

    /// The connected client of a server, connecting if needed (bounded by the
    /// server's startup timeout).
    public func client(for name: String, cancellation: CancellationHandle? = nil) async throws -> MCPClient {
        guard !isShutDown else { throw MCPManagerError.shutDown }
        guard let server = servers[name] else { throw MCPManagerError.unknownServer(name) }
        guard server.config.enabled else { throw MCPManagerError.disabled(name) }
        if case .connected = server.state, let client = server.client { return client }
        guard let task = ensureConnecting(name) else { throw MCPManagerError.shutDown }
        do {
            return try await MCPWait.value(
                of: task,
                timeoutSeconds: server.startupTimeout,
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
        guard !isShutDown, var server = servers[name], server.config.enabled else { return nil }
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
        notifyStatus()
        return task
    }

    private func performConnect(name: String, generation: Int) async throws -> MCPClient {
        guard let server = servers[name] else { throw MCPManagerError.unknownServer(name) }
        let config = server.config
        let startupTimeout = server.startupTimeout
        var client: MCPClient?
        do {
            let transport = try transportFactory(config, workingDirectory)
            let created = MCPClient(
                transport: transport,
                clientName: clientName,
                clientVersion: clientVersion,
                requestTimeoutSeconds: config.toolTimeoutSeconds ?? MCPClient.defaultRequestTimeoutSeconds
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
            try await created.connect(timeoutSeconds: startupTimeout)
            let tools = await created.supportsTools ? try await created.listTools(timeoutSeconds: startupTimeout) : []
            guard !isShutDown, servers[name]?.generation == generation else {
                await created.close()
                throw MCPManagerError.shutDown
            }
            let instructions = await created.instructions
            let info = await created.serverInfo
            if var current = servers[name] {
                current.client = created
                current.tools = tools
                current.instructions = instructions
                current.serverInfo = info
                current.state = .connected
                current.connectTask = nil
                servers[name] = current
            }
            rebuildTools()
            notifyStatus()
            return created
        } catch {
            await client?.close()
            if !isShutDown, var current = servers[name], current.generation == generation {
                current.state = .failed(MCPClient.describe(error))
                current.client = nil
                current.connectTask = nil
                servers[name] = current
                notifyStatus()
            }
            throw error
        }
    }

    private func refreshTools(name: String, client: MCPClient) async {
        guard let server = servers[name], server.client === client else { return }
        guard let tools = try? await client.listTools(timeoutSeconds: server.startupTimeout) else { return }
        guard var current = servers[name], current.client === client, !isShutDown else { return }
        current.tools = tools
        servers[name] = current
        rebuildTools()
        notifyStatus()
    }

    private func connectionDropped(name: String, client: MCPClient, error: Error?) {
        guard var server = servers[name], server.client === client, !isShutDown else { return }
        server.client = nil
        server.state = .disconnected(error.map(MCPClient.describe) ?? "Connection closed")
        servers[name] = server
        notifyStatus()
    }

    // MARK: - Tools

    private func rebuildTools() {
        var entries: [(server: String, tool: MCPTool, exposure: MCPToolExposure)] = []
        if !isShutDown {
            for name in order {
                guard let server = servers[name], server.config.enabled else { continue }
                for tool in server.tools {
                    let exposure = server.config.exposure(forTool: tool.name)
                    if exposure != .hidden { entries.append((name, tool, exposure)) }
                }
            }
        }
        let names = MCPToolNaming.assignNames(entries.map { ($0.server, $0.tool.name) })
        var signature: [String] = []
        var result: [MCPAgentTool] = []
        for (index, entry) in entries.enumerated() {
            let name = names[index]
            let server = entry.server
            let agentTool = MCPToolAdapter.makeAgentTool(
                server: server,
                tool: entry.tool,
                name: name
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
            result.append(MCPAgentTool(
                tool: agentTool,
                server: server,
                originalName: entry.tool.name,
                exposure: entry.exposure,
                mcpTool: entry.tool
            ))
            signature.append("\(name)\u{0}\(entry.exposure.rawValue)\u{0}\(entry.tool.hashValue)")
        }
        agentTools = result
        guard signature != toolsSignature else { return }
        toolsSignature = signature
        let observers = toolObservers.map(\.handler)
        let snapshot = result
        enqueue { for handler in observers { await handler(snapshot) } }
    }

    private func notifyStatus() {
        guard !statusObservers.isEmpty else { return }
        let snapshot = statuses()
        let observers = statusObservers.map(\.handler)
        enqueue { for handler in observers { await handler(snapshot) } }
    }

    /// Deliver observer callbacks one after another, in the order the
    /// changes happened.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = deliveryChain
        deliveryChain = Task {
            await previous?.value
            await work()
        }
    }
}

/// Errors of `MCPManager` tool calls.
public enum MCPManagerError: Error, LocalizedError, Sendable, Equatable {
    case unknownServer(String)
    case disabled(String)
    case unavailable(String, String)
    case shutDown

    public var errorDescription: String? {
        switch self {
        case .unknownServer(let name): return "Unknown MCP server \"\(name)\""
        case .disabled(let name): return "MCP server \"\(name)\" is disabled"
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
