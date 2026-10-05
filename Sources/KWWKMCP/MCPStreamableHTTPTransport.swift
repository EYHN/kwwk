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
///
/// With `auth`, every request carries the provider's bearer token. A 401
/// calls the provider's `onUnauthorized` once and retries; a second 401
/// fails with `MCPAuthError.unauthorizedAfterRetry`. A 403
/// `insufficient_scope` runs step-up re-authorization for an OAuth client
/// (at most `maxStepUpRetries` times per request) and otherwise fails with
/// `MCPAuthError.insufficientScope`. Only requests the server refused are
/// retried; nothing that ran is sent twice.
public final class MCPStreamableHTTPTransport: MCPTransport, @unchecked Sendable {
    public let url: URL
    public let headers: [String: String]
    public let requestTimeoutSeconds: Double
    public let auth: MCPTransportAuth?
    public let maxStepUpRetries: Int

    private let httpClient: any HTTPClient
    private let authHTTPClient: any MCPAuthHTTPClient
    private let authProvider: (any MCPAuthProvider)?
    /// Shared by 401 recovery, proactive refresh and step-up.
    private let authGate = MCPAuthRunGate()
    private let lock = NSLock()
    private var sessionId: String?
    private var protocolVersion: String?
    private var continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?
    private var listenTask: Task<Void, Never>?
    private var closed = false
    /// Scope accumulated from challenges and step-up (union).
    private var scope: String?
    private var resourceMetadataURL: URL?
    /// Cancelled by `close()`; every request carries it.
    private let lifetime = CancellationHandle()

    /// - Parameters:
    ///   - headers: Extra request headers. A token from `auth` replaces any
    ///     `Authorization` header here.
    ///   - httpClient: Injected for tests; defaults to a fresh URLSession client.
    ///   - requestTimeoutSeconds: Idle timeout of each POST.
    ///   - auth: How to authenticate; nil sends `headers` only.
    ///   - authHTTPClient: Client of the OAuth requests (discovery, tokens).
    ///   - maxStepUpRetries: Step-up re-authorizations per request.
    public init(
        url: URL,
        headers: [String: String] = [:],
        httpClient: (any HTTPClient)? = nil,
        requestTimeoutSeconds: Double = MCPClient.defaultRequestTimeoutSeconds,
        auth: MCPTransportAuth? = nil,
        authHTTPClient: (any MCPAuthHTTPClient)? = nil,
        maxStepUpRetries: Int = 1
    ) {
        self.url = url
        self.headers = headers
        self.httpClient = httpClient ?? URLSessionHTTPClient()
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.auth = auth
        let authHTTP = authHTTPClient ?? URLSessionMCPAuthHTTPClient()
        self.authHTTPClient = authHTTP
        switch auth {
        case .provider(let provider):
            self.authProvider = provider
        case .oauth(let provider, let interactive):
            self.authProvider = MCPOAuthAdapter(
                provider: provider, serverURL: url, interactive: interactive, httpClient: authHTTP, gate: authGate
            )
        case nil:
            self.authProvider = nil
        }
        self.maxStepUpRetries = max(0, maxStepUpRetries)
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
        try await send(message, isAuthRetry: false, stepUpRetries: 0)
    }

    private func send(_ message: JSONRPCMessage, isAuthRetry: Bool, stepUpRetries: Int) async throws {
        let body = try message.encoded()
        let token = try await currentToken()
        var requestHeaders = baseHeaders(token: token)
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
            if status == 401 {
                try await handleUnauthorized(response: response, body: text, rejectedToken: token, isAuthRetry: isAuthRetry)
                try checkStillWanted()
                return try await send(message, isAuthRetry: true, stepUpRetries: stepUpRetries)
            }
            if status == 403 {
                let challenge = MCPAuthChallenge(header: response.value(forHTTPHeaderField: "WWW-Authenticate"))
                if challenge.error == "insufficient_scope" {
                    try await stepUp(challenge: challenge, retries: stepUpRetries)
                    try checkStillWanted()
                    return try await send(message, isAuthRetry: isAuthRetry, stepUpRetries: stepUpRetries + 1)
                }
            }
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

    /// Finish an OAuth authorization started by this transport's provider
    /// (`redirectToAuthorization`), from the callback's query parameters.
    /// The caller checks `state` first.
    public func finishAuthorization(callbackParameters: [String: String]) async throws {
        guard let provider = auth?.oauthProvider else {
            throw MCPAuthError.providerMisconfigured("finishAuthorization requires an OAuth client provider")
        }
        let (scope, metadataURL) = lock.withLock { (self.scope, self.resourceMetadataURL) }
        try await MCPOAuth.finishAuthorization(
            provider,
            serverURL: url,
            callbackParameters: callbackParameters,
            scope: scope,
            resourceMetadataURL: metadataURL,
            httpClient: authHTTPClient
        )
    }

    // MARK: - Auth

    /// A refused request is retried only while its sender still waits: the
    /// client cancels the sending task on timeout or cancellation, and a
    /// request nobody waits for must not reach the server.
    private func checkStillWanted() throws {
        try Task.checkCancellation()
        if lifetime.isCancelled { throw MCPError.connectionClosed(details: nil) }
    }

    private func currentToken() async throws -> String? {
        guard let authProvider else { return nil }
        return try await authProvider.token()
    }

    /// A 401: remember the challenge, then let the provider recover once.
    private func handleUnauthorized(response: HTTPURLResponse, body: String, rejectedToken: String?, isAuthRetry: Bool) async throws {
        let challenge = MCPAuthChallenge(header: response.value(forHTTPHeaderField: "WWW-Authenticate"))
        lock.withLock {
            if let metadataURL = challenge.resourceMetadataURL { resourceMetadataURL = metadataURL }
            scope = MCPOAuth.scopeUnion(scope, challenge.scope)
        }
        guard let authProvider else {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MCPAuthError.unauthorized(trimmed.isEmpty ? nil : "MCP server requires authorization: \(trimmed)")
        }
        guard !isAuthRetry else { throw MCPAuthError.unauthorizedAfterRetry }
        try await authProvider.onUnauthorized(MCPUnauthorizedContext(
            serverURL: url,
            challenge: challenge,
            rejectedToken: rejectedToken
        ))
    }

    /// SEP-2350 step-up: re-authorize for the union of the scope requested
    /// so far, the token's scope and the challenged scope, skipping refresh
    /// when that union exceeds what the token was granted.
    private func stepUp(challenge: MCPAuthChallenge, retries: Int) async throws {
        guard let provider = auth?.oauthProvider, retries < maxStepUpRetries else {
            throw MCPAuthError.insufficientScope(requiredScope: challenge.scope, description: challenge.errorDescription)
        }
        let tokens = try await provider.tokens(nil)
        let (union, metadataURL): (String?, URL?) = lock.withLock {
            if let metadataURL = challenge.resourceMetadataURL { resourceMetadataURL = metadataURL }
            scope = MCPOAuth.scopeUnion(scope, tokens?.scope, challenge.scope)
            return (scope, resourceMetadataURL)
        }
        let interactive = auth?.isInteractive ?? false
        let url = url
        let http = authHTTPClient
        let result = try await authGate.run {
            try await MCPOAuth.auth(provider, options: MCPOAuthOptions(
                serverURL: url,
                scope: union,
                resourceMetadataURL: metadataURL,
                forceReauthorization: MCPOAuth.isStrictScopeSuperset(union, of: tokens?.scope),
                interactive: interactive,
                httpClient: http
            ))
        }
        guard result == .authorized else {
            throw MCPAuthError.insufficientScope(requiredScope: union, description: challenge.errorDescription)
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
        let storedToken: String?
        if let adapter = authProvider as? MCPOAuthAdapter {
            storedToken = try? await adapter.storedToken()
        } else {
            storedToken = try? await currentToken()
        }
        let deleteHeaders = baseHeaders(token: storedToken)
        if let (_, bytes) = try? await httpClient.stream(
            url: url, method: "DELETE", headers: deleteHeaders, body: nil,
            cancellation: nil, timeoutSeconds: 5
        ) {
            do { for try await _ in bytes {} } catch {}
        }
    }

    // MARK: - Internals

    private func baseHeaders(token: String?) -> [String: String] {
        var result = headers
        if let token {
            for key in result.keys where key.lowercased() == "authorization" { result.removeValue(forKey: key) }
            result["Authorization"] = "Bearer \(token)"
        }
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

    /// Server-to-client stream. Optional in the spec, so failures only end
    /// it. A 401 gets the provider's one recovery, like a request.
    private func listen(isAuthRetry: Bool = false) async {
        do {
            let token = try await currentToken()
            var requestHeaders = baseHeaders(token: token)
            requestHeaders["Accept"] = "text/event-stream"
            let (response, bytes) = try await httpClient.stream(
                url: url, method: "GET", headers: requestHeaders, body: nil,
                cancellation: lifetime, timeoutSeconds: 24 * 60 * 60
            )
            if response.statusCode == 401, authProvider != nil, !isAuthRetry {
                let text = await Self.collectText(bytes, limit: 4_000)
                try await handleUnauthorized(response: response, body: text, rejectedToken: token, isAuthRetry: false)
                await listen(isAuthRetry: true)
                return
            }
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
