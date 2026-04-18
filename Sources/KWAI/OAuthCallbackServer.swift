#if canImport(Network)
import Foundation
import Network

/// Single-shot localhost HTTP server used during OAuth authorization code
/// flows. Binds 127.0.0.1 on a known port, waits for one request matching
/// the registered path, captures the query parameters, and replies with a
/// "You can close this tab" page.
public final class OAuthCallbackServer: @unchecked Sendable {
    public let port: UInt16
    public let path: String
    public let successHTML: String
    public let errorHTML: String

    private let listener: NWListener
    private let queue = DispatchQueue(label: "kw.oauth.callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var resolved = false
    private var cancelled = false

    public init(
        port: UInt16,
        path: String = "/callback",
        successHTML: String = OAuthCallbackServer.defaultSuccessHTML,
        errorHTML: String = OAuthCallbackServer.defaultErrorHTML
    ) throws {
        self.port = port
        self.path = path
        self.successHTML = successHTML
        self.errorHTML = errorHTML

        let params = NWParameters.tcp
        // Bind explicitly to loopback so nothing leaks to the LAN.
        if let options = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            options.version = .v4
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OAuthError.transport("invalid port \(port)")
        }
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    public var redirectURI: String {
        "http://localhost:\(port)\(path)"
    }

    /// Start listening. Idempotent.
    public func start() {
        listener.start(queue: queue)
    }

    /// Resolve with whichever completes first: a callback request
    /// (parameters) or `cancel()` (throws).
    public func waitForCallback() async throws -> [String: String] {
        start()
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if resolved {
                lock.unlock()
                cont.resume(throwing: OAuthError.transport("callback server already resolved"))
                return
            }
            if cancelled {
                lock.unlock()
                cont.resume(throwing: CancellationError())
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    /// Stop listening; subsequent connections are rejected.
    public func stop() {
        listener.cancel()
    }

    /// Unblock `waitForCallback()` with a `CancellationError`. Callers can
    /// use this to abort when the user declines manually.
    public func cancel() {
        let cont: CheckedContinuation<[String: String], Error>?
        lock.lock()
        if resolved { lock.unlock(); return }
        cancelled = true
        cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.readRequest(connection)
            }
        }
        connection.start(queue: queue)
    }

    private func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                self.resolveError(.transport("\(error)"))
                return
            }
            guard let data else {
                connection.cancel()
                return
            }
            // Parse the HTTP request line: `GET /callback?code=… HTTP/1.1`.
            guard let text = String(data: data, encoding: .utf8),
                  let firstLine = text.split(separator: "\r\n").first else {
                self.writeResponse(connection, status: 400, html: self.errorHTML("missing request line"))
                return
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.writeResponse(connection, status: 400, html: self.errorHTML("bad request line"))
                return
            }
            let rawPath = String(parts[1])
            guard let url = URL(string: "http://localhost\(rawPath)") else {
                self.writeResponse(connection, status: 400, html: self.errorHTML("bad URL"))
                return
            }
            guard url.path == self.path else {
                self.writeResponse(connection, status: 404, html: self.errorHTML("unknown path"))
                return
            }
            var params: [String: String] = [:]
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let items = components.queryItems {
                for item in items {
                    params[item.name] = item.value ?? ""
                }
            }

            if params["error"] != nil {
                self.writeResponse(connection, status: 400, html: self.errorHTML(params["error"] ?? "error"))
                self.resolveError(.invalidResponse(params["error"] ?? "OAuth error"))
                return
            }

            self.writeResponse(connection, status: 200, html: self.successHTML)
            self.resolveSuccess(params)
        }
    }

    private func writeResponse(_ connection: NWConnection, status: Int, html: String) {
        let reason: String = {
            switch status {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 404: return "Not Found"
            default: return "Error"
            }
        }()
        let body = Data(html.utf8)
        let response = """
        HTTP/1.1 \(status) \(reason)\r
        content-type: text/html; charset=utf-8\r
        content-length: \(body.count)\r
        connection: close\r
        \r

        """
        var bytes = Data(response.utf8)
        bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resolveSuccess(_ params: [String: String]) {
        let cont: CheckedContinuation<[String: String], Error>?
        lock.lock()
        if resolved { lock.unlock(); return }
        resolved = true
        cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: params)
        listener.cancel()
    }

    private func resolveError(_ error: OAuthError) {
        let cont: CheckedContinuation<[String: String], Error>?
        lock.lock()
        if resolved { lock.unlock(); return }
        resolved = true
        cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
        listener.cancel()
    }

    private func errorHTML(_ message: String) -> String {
        errorHTML.replacingOccurrences(of: "{{message}}", with: message)
    }

    // MARK: - Default pages

    public static let defaultSuccessHTML = """
    <!doctype html>
    <html><head><meta charset=utf-8><title>kw — login complete</title>
    <style>body{font-family:ui-sans-serif,system-ui;padding:3em;max-width:30em;margin:0 auto;color:#222}
    h1{color:#0a7}</style></head>
    <body><h1>Login complete</h1>
    <p>You can close this tab and return to your terminal.</p></body></html>
    """

    public static let defaultErrorHTML = """
    <!doctype html>
    <html><head><meta charset=utf-8><title>kw — login failed</title>
    <style>body{font-family:ui-sans-serif,system-ui;padding:3em;max-width:30em;margin:0 auto;color:#222}
    h1{color:#c33}</style></head>
    <body><h1>Login failed</h1><p>{{message}}</p></body></html>
    """
}
#endif
