import Foundation
import NIO
import NIOHTTP1

/// Single-shot localhost HTTP server used during OAuth authorization-code
/// flows. Binds 127.0.0.1 on a known port, waits for one request matching
/// the registered path, captures the query parameters, and replies with a
/// "You can close this tab" page.
///
/// Backed by SwiftNIO so the same implementation runs on macOS and Linux —
/// the previous `Network.framework` version only linked on Apple.
public final class OAuthCallbackServer: @unchecked Sendable {
    public let port: UInt16
    public let path: String
    public let successHTML: String
    public let errorHTML: String

    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()
    private var channel: Channel?
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
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        // Best-effort cleanup — the login flow calls `stop()` or `cancel()`
        // explicitly, but a leak-safe deinit prevents a zombie event loop
        // when callers drop the server without finishing the flow. Deinit can
        // run on the NIO event loop that just closed the callback channel, so
        // use the asynchronous shutdown API instead of blocking that thread.
        group.shutdownGracefully { _ in }
    }

    public var redirectURI: String {
        "http://localhost:\(port)\(path)"
    }

    /// Start listening. Idempotent.
    ///
    /// This synchronous compatibility entry point may block the calling thread
    /// while NIO binds the socket. Async library flows should prefer
    /// `waitForCallback()`, which starts via NIO's async future bridge and does
    /// not block the caller's executor.
    public func start() throws {
        lock.lock()
        if channel != nil { lock.unlock(); return }
        lock.unlock()

        let ch = try makeBootstrap().bind(host: "127.0.0.1", port: Int(port)).wait()
        lock.withLock { channel = ch }
    }

    private func startAsync() async throws {
        if lock.withLock({ channel != nil }) { return }

        let ch = try await makeBootstrap().bind(host: "127.0.0.1", port: Int(port)).get()
        lock.withLock { channel = ch }
    }

    private func makeBootstrap() -> ServerBootstrap {
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] child in
                let server = self
                return child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(CallbackHandler(server: server))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    }

    /// Resolve with whichever completes first: a callback request (query
    /// parameters), `cancel()`, or cancellation of the surrounding task —
    /// the latter two throw `CancellationError`. Task-cancellation awareness
    /// is what lets a login UI abort a browser handoff the user never
    /// completes.
    public func waitForCallback() async throws -> [String: String] {
        try await startAsync()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
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
        } onCancel: {
            cancel()
        }
    }

    /// Stop listening; subsequent connections are rejected.
    public func stop() {
        lock.lock()
        let ch = channel
        channel = nil
        lock.unlock()
        _ = ch?.close()
    }

    /// Unblock `waitForCallback()` with a `CancellationError`. Callers use
    /// this to abort when the user declines manually.
    public func cancel() {
        let cont: CheckedContinuation<[String: String], Error>?
        lock.lock()
        if resolved { lock.unlock(); return }
        cancelled = true
        cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())
        stop()
    }

    // MARK: - Called by `CallbackHandler` when a request resolves the flow

    fileprivate func resolveSuccess(_ params: [String: String]) {
        let cont: CheckedContinuation<[String: String], Error>?
        lock.lock()
        if resolved { lock.unlock(); return }
        resolved = true
        cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: params)
        stop()
    }

    fileprivate func resolveError(_ error: OAuthError) {
        let cont: CheckedContinuation<[String: String], Error>?
        lock.lock()
        if resolved { lock.unlock(); return }
        resolved = true
        cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
        stop()
    }

    fileprivate func errorHTMLFilled(_ message: String) -> String {
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

/// NIO handler installed at the end of the HTTP server pipeline. Reads the
/// request head, derives the callback parameters, writes back a small HTML
/// page, and hands the parameters (or error) to the `OAuthCallbackServer`.
private final class CallbackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private weak var server: OAuthCallbackServer?
    private var head: HTTPRequestHead?

    init(server: OAuthCallbackServer?) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
        case .body:
            break  // we don't care about body — OAuth redirect is a GET
        case .end:
            guard let head = head else {
                write(context: context, status: .badRequest, html: "<p>missing request line</p>")
                return
            }
            self.head = nil
            handle(context: context, head: head)
        }
    }

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard let server = server else {
            write(context: context, status: .internalServerError, html: "<p>server gone</p>")
            return
        }
        guard let url = URL(string: "http://localhost\(head.uri)") else {
            write(context: context, status: .badRequest, html: server.errorHTMLFilled("bad URL"))
            return
        }
        guard url.path == server.path else {
            write(context: context, status: .notFound, html: server.errorHTMLFilled("unknown path"))
            return
        }
        var params: [String: String] = [:]
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items { params[item.name] = item.value ?? "" }
        }
        if let err = params["error"] {
            write(context: context, status: .badRequest, html: server.errorHTMLFilled(err))
            server.resolveError(.invalidResponse(err))
            return
        }
        write(context: context, status: .ok, html: server.successHTML)
        server.resolveSuccess(params)
    }

    private func write(context: ChannelHandlerContext, status: HTTPResponseStatus, html: String) {
        let bodyBytes = Array(html.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/html; charset=utf-8")
        headers.add(name: "content-length", value: String(bodyBytes.count))
        headers.add(name: "connection", value: "close")

        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: bodyBytes.count)
        buffer.writeBytes(bodyBytes)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
