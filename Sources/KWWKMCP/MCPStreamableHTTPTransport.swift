import Foundation
import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// MCP "streamable HTTP" transport (spec 2025-03-26 and later).
///
/// Every client message is POSTed to `url` with
/// `Accept: application/json, text/event-stream`. The server answers with a
/// single JSON body, an SSE stream of messages, or `202 Accepted` for
/// notifications and responses. The `Mcp-Session-Id` the server assigns is
/// sent back on every later request, `MCP-Protocol-Version` once
/// `initialize` completed. After initialization a GET request opens the
/// optional server-to-client SSE stream (used for notifications such as
/// `tools/list_changed`); servers that answer 405 simply don't offer it.
/// `close()` aborts every in-flight request and deletes the session. When
/// the server forgets the session (404), the inbound stream ends with
/// `sessionExpired`, so the owner sees a dropped connection and reconnects.
public final class MCPStreamableHTTPTransport: MCPTransport, @unchecked Sendable {
    public let url: URL
    public let headers: [String: String]
    public let requestTimeoutSeconds: Double

    private let httpClient: any HTTPClient
    private let lock = NSLock()
    private var sessionId: String?
    private var protocolVersion: String?
    private var continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?
    private var listenTask: Task<Void, Never>?
    private var closed = false
    /// Cancelled by `close()`; every request carries it.
    private let lifetime = CancellationHandle()

    /// - Parameters:
    ///   - headers: Extra request headers (e.g. `Authorization`).
    ///   - httpClient: Injected for tests; defaults to a fresh URLSession client.
    ///   - requestTimeoutSeconds: Idle timeout of each POST.
    public init(
        url: URL,
        headers: [String: String] = [:],
        httpClient: (any HTTPClient)? = nil,
        requestTimeoutSeconds: Double = MCPClient.defaultRequestTimeoutSeconds
    ) {
        self.url = url
        self.headers = headers
        self.httpClient = httpClient ?? URLSessionHTTPClient()
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    /// The session id assigned by the server, if any.
    public var currentSessionId: String? {
        lock.withLock { sessionId }
    }

    public func start() async throws -> AsyncThrowingStream<JSONRPCMessage, Error> {
        let (stream, continuation) = AsyncThrowingStream<JSONRPCMessage, Error>.makeStream()
        try lock.withLock {
            guard self.continuation == nil, !closed else {
                throw MCPError.protocolError("transport already started")
            }
            self.continuation = continuation
        }
        return stream
    }

    public func send(_ message: JSONRPCMessage) async throws {
        let body = try message.encoded()
        var requestHeaders = baseHeaders()
        requestHeaders["Content-Type"] = "application/json"
        requestHeaders["Accept"] = "application/json, text/event-stream"
        let isInitialize: Bool
        if case .request(_, "initialize", _) = message { isInitialize = true } else { isInitialize = false }

        let (response, bytes) = try await httpClient.stream(
            url: url,
            method: "POST",
            headers: requestHeaders,
            body: body,
            cancellation: lifetime,
            timeoutSeconds: requestTimeoutSeconds
        )
        if let assigned = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !assigned.isEmpty {
            lock.withLock { sessionId = assigned }
        }
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            let text = await Self.collectText(bytes, limit: 4_000)
            if status == 404, !isInitialize, requestHeaders["Mcp-Session-Id"] != nil {
                finish(throwing: MCPError.sessionExpired)
                throw MCPError.sessionExpired
            }
            throw MCPError.http(status: status, body: text)
        }
        if status == 202 || status == 204 {
            for try await _ in bytes {}
            return
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            for try await event in parseSSE(bytes: bytes) {
                yield(Self.messages(fromSSE: event))
            }
        } else {
            var data = Data()
            for try await chunk in bytes { data.append(chunk) }
            guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return }
            yield(try JSONRPCMessage.decodeAll(data))
        }
    }

    public func didInitialize(protocolVersion: String) async {
        let shouldListen: Bool = lock.withLock {
            self.protocolVersion = protocolVersion
            return listenTask == nil && !closed
        }
        guard shouldListen else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.listen()
        }
        lock.withLock { listenTask = task }
    }

    public func close() async {
        let (task, continuation, session, alreadyClosed) = lock.withLock {
            () -> (Task<Void, Never>?, AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?, String?, Bool) in
            let result = (listenTask, self.continuation, sessionId, closed)
            closed = true
            listenTask = nil
            self.continuation = nil
            return result
        }
        guard !alreadyClosed else { return }
        lifetime.cancel(reason: "MCP transport closed")
        task?.cancel()
        continuation?.finish()
        guard session != nil else { return }
        // Best effort: tell the server the session is over. Servers that do
        // not support explicit termination answer 405.
        let deleteHeaders = baseHeaders()
        if let (_, bytes) = try? await httpClient.stream(
            url: url, method: "DELETE", headers: deleteHeaders, body: nil,
            cancellation: nil, timeoutSeconds: 5
        ) {
            do { for try await _ in bytes {} } catch {}
        }
    }

    // MARK: - Internals

    private func baseHeaders() -> [String: String] {
        var result = headers
        lock.withLock {
            if let sessionId { result["Mcp-Session-Id"] = sessionId }
            if let protocolVersion { result["MCP-Protocol-Version"] = protocolVersion }
        }
        return result
    }

    /// End the inbound stream: the connection is over.
    private func finish(throwing error: Error) {
        lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }?.finish(throwing: error)
    }

    private func yield(_ messages: [JSONRPCMessage]) {
        guard let continuation = lock.withLock({ self.continuation }) else { return }
        for message in messages { continuation.yield(message) }
    }

    /// Server-to-client stream. Optional in the spec, so failures only end it.
    private func listen() async {
        var requestHeaders = baseHeaders()
        requestHeaders["Accept"] = "text/event-stream"
        do {
            let (response, bytes) = try await httpClient.stream(
                url: url, method: "GET", headers: requestHeaders, body: nil,
                cancellation: lifetime, timeoutSeconds: 24 * 60 * 60
            )
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard (200..<300).contains(response.statusCode), contentType.contains("text/event-stream") else {
                for try await _ in bytes {}
                return
            }
            for try await event in parseSSE(bytes: bytes) {
                yield(Self.messages(fromSSE: event))
            }
        } catch {
            // The listening stream is best effort; requests keep working.
        }
    }

    /// JSON-RPC messages carried by one SSE event. Events other than
    /// `message`, empty data (keep-alives / priming events) and invalid JSON
    /// yield nothing.
    public static func messages(fromSSE event: SSEMessage) -> [JSONRPCMessage] {
        guard event.event == "message" else { return [] }
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !data.isEmpty else { return [] }
        return (try? JSONRPCMessage.decodeAll(Data(data.utf8))) ?? []
    }

    /// Parse a complete SSE body into JSON-RPC messages.
    public static func messages(fromSSEBody body: String) -> [JSONRPCMessage] {
        let parser = SSEParser()
        parser.ingest(body)
        // Terminate a final line that lacks its newline.
        parser.ingest("\n")
        return parser.finish().flatMap { messages(fromSSE: $0) }
    }

    private static func collectText(_ bytes: AsyncThrowingStream<Data, Error>, limit: Int) async -> String {
        var data = Data()
        do {
            for try await chunk in bytes {
                data.append(chunk)
                if data.count >= limit { break }
            }
        } catch {}
        return String(decoding: data.prefix(limit), as: UTF8.self)
    }
}
