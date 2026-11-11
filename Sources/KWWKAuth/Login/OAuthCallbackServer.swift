import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1

/// Single-shot localhost HTTP server used during OAuth authorization-code
/// flows. Binds 127.0.0.1 on a known port, waits for one request matching
/// the registered path, captures the query parameters, and replies with a
/// "You can close this tab" page.
///
/// Port 0 binds whichever port is free, for a provider that takes any
/// loopback redirect (Trae, Raccoon); `redirectURI` names the bound one once
/// `listen()` has returned.
///
/// Backed by SwiftNIO so the same implementation runs on macOS and Linux —
/// the previous `Network.framework` version only linked on Apple.
public final class OAuthCallbackServer: Sendable {
    /// The port asked for; 0 asks for any free one (see `redirectURI`).
    public let port: UInt16
    public let path: String
    public let successHTML: String
    public let errorHTML: String
    /// The host named in `redirectURI`. The listener binds 127.0.0.1 either
    /// way; a provider that registered the numeric host (Devin) needs it
    /// spelled that way in the authorize request.
    public let redirectHost: String
    /// Resolve a redirect that carries `error=` with its parameters, so the
    /// flow can tell a user's "deny" from a failure. Off keeps the original
    /// behavior: such a redirect throws `OAuthError.invalidResponse`.
    public let surfacesProviderErrors: Bool

    private let group: MultiThreadedEventLoopGroup
    private let state = NIOLockedValueBox(State())

    private struct State {
        var channel: Channel?
        /// The port the listener holds, which is the one asked for unless
        /// that was 0.
        var boundPort: UInt16?
        var continuation: CheckedContinuation<[String: String], Error>?
        var resolved = false
        var cancelled = false
        // A callback can land between `start()` binding the port and
        // `waitForCallback()` registering its continuation (fast redirects; the
        // login flow hands out the URL before it awaits). Buffer that early
        // result so the wait returns it instead of "already resolved".
        var pendingResult: Result<[String: String], OAuthError>?
    }

    public init(
        port: UInt16,
        path: String = "/callback",
        successHTML: String = OAuthCallbackServer.defaultSuccessHTML,
        errorHTML: String = OAuthCallbackServer.defaultErrorHTML,
        redirectHost: String = "localhost",
        surfacesProviderErrors: Bool = false
    ) throws {
        self.port = port
        self.path = path
        self.successHTML = successHTML
        self.errorHTML = errorHTML
        self.redirectHost = redirectHost
        self.surfacesProviderErrors = surfacesProviderErrors
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

    /// The query parameters that mark a request as the provider's redirect:
    /// the authorization code every OAuth flow here answers with, and
    /// `authCodeInfo`, which Trae's page answers with in its place.
    static let redirectParameters: Set<String> = ["code", "authCodeInfo"]

    public var redirectURI: String {
        let bound = state.withLockedValue { $0.boundPort } ?? port
        return "http://\(redirectHost):\(bound)\(path)"
    }

    /// Start listening. Idempotent.
    ///
    /// This synchronous compatibility entry point may block the calling thread
    /// while NIO binds the socket. Async library flows should prefer
    /// `waitForCallback()`, which starts via NIO's async future bridge and does
    /// not block the caller's executor.
    public func start() throws {
        if state.withLockedValue({ $0.channel != nil }) { return }

        let ch = try makeBootstrap().bind(host: "127.0.0.1", port: Int(port)).wait()
        hold(ch)
    }

    private func startAsync() async throws {
        // Already listening, or already resolved (`stop()` ran after an early
        // callback) — don't re-bind a port nobody will answer on.
        if state.withLockedValue({ $0.channel != nil || $0.resolved }) { return }

        let ch = try await makeBootstrap().bind(host: "127.0.0.1", port: Int(port)).get()
        hold(ch)
    }

    private func hold(_ channel: Channel) {
        state.withLockedValue { state in
            state.channel = channel
            state.boundPort = channel.localAddress?.port.flatMap { UInt16(exactly: $0) }
        }
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
                // Decide under the lock; resume (if at all) after releasing it.
                let immediate: Result<[String: String], Error>? = state.withLockedValue { state in
                    if state.resolved {
                        let result = state.pendingResult
                        state.pendingResult = nil
                        if let result {
                            return result.mapError { $0 as Error }
                        }
                        return .failure(OAuthError.transport("callback server already resolved"))
                    }
                    if state.cancelled {
                        return .failure(CancellationError())
                    }
                    state.continuation = cont
                    return nil
                }
                if let immediate {
                    cont.resume(with: immediate)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    /// Stop listening; subsequent connections are rejected.
    public func stop() {
        let ch = state.withLockedValue { state -> Channel? in
            let ch = state.channel
            state.channel = nil
            return ch
        }
        _ = ch?.close()
    }

    /// Unblock `waitForCallback()` with a `CancellationError`. Callers use
    /// this to abort when the user declines manually.
    public func cancel() {
        let outcome: (resolved: Bool, cont: CheckedContinuation<[String: String], Error>?) =
            state.withLockedValue { state in
                if state.resolved { return (true, nil) }
                state.cancelled = true
                let cont = state.continuation
                state.continuation = nil
                return (false, cont)
            }
        if outcome.resolved { return }
        outcome.cont?.resume(throwing: CancellationError())
        stop()
    }

    // MARK: - Called by `CallbackHandler` when a request resolves the flow

    fileprivate func resolve(_ result: Result<[String: String], OAuthError>) {
        let outcome: (alreadyResolved: Bool, cont: CheckedContinuation<[String: String], Error>?) =
            state.withLockedValue { state in
                if state.resolved { return (true, nil) }
                state.resolved = true
                let cont = state.continuation
                state.continuation = nil
                if cont == nil { state.pendingResult = result }
                return (false, cont)
            }
        if outcome.alreadyResolved { return }
        outcome.cont?.resume(with: result)
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
        // A page that reports back with a request of its own asks first
        // whether it may; the answer is the headers `write` puts on every
        // response.
        if head.method == .OPTIONS {
            write(context: context, status: .noContent, html: "")
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
            if server.surfacesProviderErrors {
                server.resolve(.success(params))
            } else {
                server.resolve(.failure(.invalidResponse(err)))
            }
            return
        }
        // Only a request that actually carries the authorization `code` (or
        // Trae's `authCodeInfo`) resolves the flow. Anything else hitting the
        // path (browser favicon probe, health check, a request with no
        // query) gets a 404 and the server keeps waiting — otherwise a stray
        // request would kill the pending login with an empty parameter set.
        guard OAuthCallbackServer.redirectParameters.contains(where: { params[$0] != nil }) else {
            write(context: context, status: .notFound, html: server.errorHTMLFilled("missing authorization code"))
            return
        }
        write(context: context, status: .ok, html: server.successHTML)
        server.resolve(.success(params))
    }

    private func write(context: ChannelHandlerContext, status: HTTPResponseStatus, html: String) {
        let bodyBytes = Array(html.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/html; charset=utf-8")
        headers.add(name: "content-length", value: String(bodyBytes.count))
        headers.add(name: "connection", value: "close")
        // What Trae's desktop client answers its sign-in page with, for a
        // page that reports back with a fetch rather than a navigation. The
        // body is the static page above either way.
        headers.add(name: "access-control-allow-origin", value: "*")
        headers.add(name: "access-control-allow-methods", value: "GET,POST,OPTIONS")
        headers.add(name: "access-control-allow-headers", value: "content-type")

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

// MARK: - Loopback for `OAuthLogin`

extension OAuthCallbackServer: OAuthLoopbackListener {
    public func listen() async throws {
        try await startAsync()
    }
}

extension OAuthLogin {
    /// The default NIO-backed listener. Hosts can supply their own factory
    /// through `Callbacks` without changing any provider flow.
    public static let nioLoopback: OAuthLoopbackFactory = { host, port, path in
        try OAuthCallbackServer(
            port: port,
            path: path,
            redirectHost: host,
            surfacesProviderErrors: true
        )
    }
}
