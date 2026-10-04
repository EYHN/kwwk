import Foundation
import KWWKAI

/// JSON-RPC 2.0 client for one MCP server.
///
/// ```swift
/// let client = MCPClient(transport: MCPStdioTransport(command: "my-server"))
/// try await client.connect()
/// let tools = try await client.listTools()
/// let result = try await client.callTool(name: tools[0].name, arguments: [:])
/// await client.close()
/// ```
///
/// The client answers server `ping` requests, rejects other server requests
/// with "method not found", forwards `notifications/tools/list_changed` to
/// the registered handler and maps `notifications/progress` to the request
/// that asked for it (each progress update also restarts that request's
/// timeout). Cancelled and timed-out requests send `notifications/cancelled`.
public actor MCPClient {
    /// Protocol version requested in `initialize`.
    public static let protocolVersion = "2025-06-18"
    /// Versions accepted in the server's `initialize` answer.
    public static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let defaultRequestTimeoutSeconds: Double = 60
    public static let defaultConnectTimeoutSeconds: Double = 30

    public nonisolated let transport: any MCPTransport
    public nonisolated let clientName: String
    public nonisolated let clientVersion: String
    public nonisolated let requestTimeoutSeconds: Double

    /// `serverInfo` of the `initialize` result.
    public private(set) var serverInfo: MCPServerInfo?
    /// Server `instructions` of the `initialize` result, trimmed; nil if empty.
    public private(set) var instructions: String?
    /// Raw `capabilities` of the `initialize` result.
    public private(set) var serverCapabilities: JSONValue?
    /// Protocol version the server chose.
    public private(set) var negotiatedProtocolVersion: String?
    /// True between a successful `connect()` and the connection closing.
    public private(set) var isConnected = false

    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutSeconds: Double
        var timeoutTask: Task<Void, Never>?
        var sendTask: Task<Void, Never>?
        var cancelRegistration: CancellationRegistration?
        var onProgress: (@Sendable (MCPProgress) -> Void)?
    }

    private var nextID = 1
    private var pending: [JSONRPCID: Pending] = [:]
    private var readerTask: Task<Void, Never>?
    private var started = false
    private var closed = false
    private var toolsChangedHandler: (@Sendable () async -> Void)?
    private var closeHandler: (@Sendable (Error?) async -> Void)?
    private var notificationHandler: (@Sendable (String, JSONValue?) async -> Void)?

    /// - Parameters:
    ///   - requestTimeoutSeconds: Default timeout of every request.
    public init(
        transport: any MCPTransport,
        clientName: String = "kwwk",
        clientVersion: String = "1.0.0",
        requestTimeoutSeconds: Double = MCPClient.defaultRequestTimeoutSeconds
    ) {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    // MARK: - Handlers

    /// Called (on a fresh task) whenever the server sends
    /// `notifications/tools/list_changed`.
    public func setToolsListChangedHandler(_ handler: (@Sendable () async -> Void)?) {
        toolsChangedHandler = handler
    }

    /// Called once when the connection drops without `close()`; the error
    /// describes why (process exit with stderr tail, stream failure).
    public func setCloseHandler(_ handler: (@Sendable (Error?) async -> Void)?) {
        closeHandler = handler
    }

    /// Receives every server notification not handled by the client itself
    /// (e.g. `notifications/message` log lines).
    public func setNotificationHandler(_ handler: (@Sendable (String, JSONValue?) async -> Void)?) {
        notificationHandler = handler
    }

    // MARK: - Lifecycle

    /// Start the transport, run the `initialize` handshake and send
    /// `notifications/initialized`. On failure the transport is closed and
    /// the error is rethrown (with stderr context where available).
    public func connect(timeoutSeconds: Double = MCPClient.defaultConnectTimeoutSeconds) async throws {
        guard !started else { throw MCPError.protocolError("client already connected") }
        guard !closed else { throw MCPError.notConnected }
        started = true
        do {
            let stream = try await transport.start()
            readerTask = Task { [weak self] in
                do {
                    for try await message in stream {
                        await self?.handle(message)
                    }
                    await self?.transportClosed(nil)
                } catch {
                    await self?.transportClosed(error)
                }
            }
            let result = try await request(
                method: "initialize",
                params: [
                    "protocolVersion": .string(Self.protocolVersion),
                    "capabilities": .object([:]),
                    "clientInfo": ["name": .string(clientName), "version": .string(clientVersion)],
                ],
                timeoutSeconds: timeoutSeconds
            )
            guard case .object = result else {
                throw MCPError.protocolError("initialize returned no result object")
            }
            let version = result["protocolVersion"]?.mcpString ?? Self.protocolVersion
            guard Self.supportedProtocolVersions.contains(version) else {
                throw MCPError.protocolError("server uses unsupported protocol version \(version)")
            }
            negotiatedProtocolVersion = version
            serverCapabilities = result["capabilities"]
            if let info = result["serverInfo"] {
                serverInfo = MCPServerInfo(
                    name: info["name"]?.mcpString ?? "",
                    version: info["version"]?.mcpString,
                    title: info["title"]?.mcpString
                )
            }
            let text = result["instructions"]?.mcpString?.trimmingCharacters(in: .whitespacesAndNewlines)
            instructions = (text?.isEmpty ?? true) ? nil : text
            try await notify(method: "notifications/initialized")
            await transport.didInitialize(protocolVersion: version)
            isConnected = true
        } catch {
            let diagnostics = transport.diagnostics
            await close()
            if let diagnostics, !(error is CancellationError), !"\(Self.describe(error))".contains(diagnostics) {
                throw MCPConnectError(message: Self.describe(error), diagnostics: diagnostics)
            }
            throw error
        }
    }

    /// Close the connection. Pending requests fail with `connectionClosed`.
    public func close() async {
        guard !closed else { return }
        closed = true
        isConnected = false
        failAll(MCPError.connectionClosed(details: nil))
        await transport.close()
        readerTask?.cancel()
        readerTask = nil
    }

    // MARK: - Requests

    /// Whether the server declared the `tools` capability (or declared no
    /// capabilities object at all, which some minimal servers do).
    public var supportsTools: Bool {
        guard let capabilities = serverCapabilities, case .object(let object) = capabilities else { return true }
        return object["tools"] != nil
    }

    /// All tools of the server, following `nextCursor` pagination.
    public func listTools(timeoutSeconds: Double? = nil) async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request(
                method: "tools/list",
                params: params.isEmpty ? nil : .object(params),
                timeoutSeconds: timeoutSeconds
            )
            if case .array(let items)? = result["tools"] {
                tools.append(contentsOf: items.compactMap(MCPTool.init(json:)))
            }
            cursor = result["nextCursor"]?.mcpString
            if let next = cursor {
                if next.isEmpty || !seenCursors.insert(next).inserted { cursor = nil }
            }
        } while cursor != nil
        return tools
    }

    /// Call a tool. `arguments` should be an object; anything else is sent as
    /// `{}`. Cancelling `cancellation` (or the calling task) sends
    /// `notifications/cancelled` and throws `CancellationError`.
    public func callTool(
        name: String,
        arguments: JSONValue,
        timeoutSeconds: Double? = nil,
        cancellation: CancellationHandle? = nil,
        onProgress: (@Sendable (MCPProgress) -> Void)? = nil
    ) async throws -> MCPCallToolResult {
        let args: JSONValue
        if case .object = arguments { args = arguments } else { args = .object([:]) }
        let result = try await request(
            method: "tools/call",
            params: ["name": .string(name), "arguments": args],
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            onProgress: onProgress
        )
        return MCPCallToolResult(json: result)
    }

    /// Send `ping` and wait for the answer.
    public func ping(timeoutSeconds: Double? = nil) async throws {
        _ = try await request(method: "ping", params: nil, timeoutSeconds: timeoutSeconds)
    }

    /// Send an arbitrary request and return its `result`.
    public func request(
        method: String,
        params: JSONValue?,
        timeoutSeconds: Double? = nil,
        cancellation: CancellationHandle? = nil,
        onProgress: (@Sendable (MCPProgress) -> Void)? = nil
    ) async throws -> JSONValue {
        guard !closed else { throw MCPError.notConnected }
        guard started else { throw MCPError.notConnected }
        try cancellation?.throwIfCancelled()
        try Task.checkCancellation()
        let id = JSONRPCID.int(nextID)
        nextID += 1
        var finalParams = params
        if onProgress != nil {
            var object = params?.objectValue ?? [:]
            var meta = object["_meta"]?.objectValue ?? [:]
            meta["progressToken"] = id.json
            object["_meta"] = .object(meta)
            finalParams = .object(object)
        }
        let message = JSONRPCMessage.request(id: id, method: method, params: finalParams)
        let timeout = timeoutSeconds ?? requestTimeoutSeconds
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                var entry = Pending(
                    method: method,
                    continuation: continuation,
                    timeoutSeconds: timeout,
                    onProgress: onProgress
                )
                let transport = self.transport
                entry.sendTask = Task { [weak self] in
                    do {
                        try await transport.send(message)
                    } catch is CancellationError {
                        return
                    } catch {
                        await self?.fail(id: id, error: error)
                    }
                }
                pending[id] = entry
                scheduleTimeout(id: id)
                if let cancellation {
                    let registration = cancellation.onCancel { [weak self] reason in
                        Task { await self?.cancelRequest(id: id, reason: reason ?? "Cancelled") }
                    }
                    pending[id]?.cancelRegistration = registration
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelRequest(id: id, reason: "Cancelled") }
        }
    }

    /// Send a notification.
    public func notify(method: String, params: JSONValue? = nil) async throws {
        try await transport.send(.notification(method: method, params: params))
    }

    // MARK: - Internals

    private func scheduleTimeout(id: JSONRPCID) {
        guard var entry = pending[id] else { return }
        entry.timeoutTask?.cancel()
        let seconds = entry.timeoutSeconds
        entry.timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.timedOut(id: id)
        }
        pending[id] = entry
    }

    private func timedOut(id: JSONRPCID) {
        guard let entry = pending[id] else { return }
        sendCancelled(id: id, method: entry.method, reason: "Request timed out")
        finish(id: id, with: .failure(MCPError.timeout(method: entry.method, seconds: entry.timeoutSeconds)))
    }

    private func cancelRequest(id: JSONRPCID, reason: String) {
        guard let entry = pending[id] else { return }
        sendCancelled(id: id, method: entry.method, reason: reason)
        finish(id: id, with: .failure(CancellationError()))
    }

    private func sendCancelled(id: JSONRPCID, method: String, reason: String) {
        // The spec forbids cancelling `initialize`.
        guard method != "initialize", !closed else { return }
        let transport = self.transport
        let message = JSONRPCMessage.notification(
            method: "notifications/cancelled",
            params: ["requestId": id.json, "reason": .string(reason)]
        )
        Task { try? await transport.send(message) }
    }

    private func fail(id: JSONRPCID, error: Error) {
        finish(id: id, with: .failure(error))
    }

    private func finish(id: JSONRPCID, with result: Result<JSONValue, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        entry.cancelRegistration?.cancel()
        entry.sendTask?.cancel()
        entry.continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) {
            finish(id: id, with: .failure(error))
        }
    }

    private func handle(_ message: JSONRPCMessage) {
        switch message {
        case .response(let id, let result):
            finish(id: id, with: .success(result))
        case .error(let id, let error):
            guard let id else { return }
            finish(id: id, with: .failure(MCPError.server(code: error.code, message: error.message, data: error.data)))
        case .request(let id, let method, _):
            let reply: JSONRPCMessage
            if method == "ping" {
                reply = .response(id: id, result: .object([:]))
            } else {
                reply = .error(
                    id: id,
                    error: JSONRPCErrorObject(code: JSONRPCErrorObject.methodNotFound, message: "Method not found: \(method)")
                )
            }
            let transport = self.transport
            Task { try? await transport.send(reply) }
        case .notification(let method, let params):
            switch method {
            case "notifications/tools/list_changed":
                if let handler = toolsChangedHandler {
                    Task { await handler() }
                }
            case "notifications/progress":
                handleProgress(params)
            default:
                if let handler = notificationHandler {
                    Task { await handler(method, params) }
                }
            }
        }
    }

    private func handleProgress(_ params: JSONValue?) {
        guard let params, let id = JSONRPCID(json: params["progressToken"]),
              let entry = pending[id], let progress = params["progress"]?.mcpNumber
        else { return }
        scheduleTimeout(id: id)
        entry.onProgress?(MCPProgress(
            progress: progress,
            total: params["total"]?.mcpNumber,
            message: params["message"]?.mcpString
        ))
    }

    private func transportClosed(_ error: Error?) async {
        guard !closed else { return }
        let wasConnected = isConnected
        isConnected = false
        let closeError: Error
        if let error, error is MCPError {
            closeError = error
        } else if let error {
            closeError = MCPError.connectionClosed(details: Self.describe(error))
        } else {
            closeError = MCPError.connectionClosed(details: transport.diagnostics)
        }
        failAll(closeError)
        closed = true
        await transport.close()
        if wasConnected, let handler = closeHandler {
            await handler(closeError)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// A failed `connect()` with the server's stderr tail attached.
public struct MCPConnectError: Error, LocalizedError, Sendable {
    public var message: String
    public var diagnostics: String?

    public var errorDescription: String? {
        if let diagnostics, !diagnostics.isEmpty { return "\(message)\n\(diagnostics)" }
        return message
    }
}
