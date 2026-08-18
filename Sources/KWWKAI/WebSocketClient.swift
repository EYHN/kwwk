import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

public protocol WebSocketConnection: Sendable {
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage?
    func close()
}

public protocol WebSocketClient: Sendable {
    func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection
}

/// Surfaced when the keepalive heartbeat declares a connection dead. The
/// description deliberately contains "connection" so `isRetryableError`
/// classifies it as transient and the agent loop replays the turn.
public struct WebSocketKeepaliveError: Error, CustomStringConvertible, Sendable {
    public let reason: String
    public var description: String { "WebSocket connection keepalive failed: \(reason)" }
}

public struct URLSessionWebSocketClient: WebSocketClient {
    /// The WebSocket transport a Responses provider gets when the caller
    /// names none: URLSession's on Apple platforms, nothing elsewhere.
    ///
    /// swift-corelibs-foundation's `URLSessionWebSocketTask` (Linux, on
    /// libcurl) hands each TCP read out as its own message: any frame over
    /// a few KB — a `response.completed` carrying reasoning
    /// `encrypted_content`, say — arrives as several `.string` fragments,
    /// none of them valid JSON, and the event is lost. The stream then
    /// waits for a terminal event that never comes until the keepalive
    /// tears it down, retries, and only reaches HTTP after
    /// `maxWebSocketFailures` such rounds. Measured with the 6.3.3 static
    /// musl SDK against an echo server: 1 KB intact, 15 KB in 7 pieces.
    /// The upstream fix (swift-corelibs-foundation#5255) is unmerged, so
    /// off Darwin the default is no WebSocket and the SSE path from the
    /// start. Pass a client explicitly to opt in anyway.
    public static var platformDefault: WebSocketClient? {
        #if canImport(Darwin)
            URLSessionWebSocketClient()
        #else
            nil
        #endif
    }

    public let session: URLSession
    /// Seconds between keepalive pings. `0` disables the heartbeat.
    public var pingIntervalSeconds: TimeInterval
    /// Fail-closed liveness deadline: if no inbound traffic (data frame or
    /// pong) arrives within this window the connection is declared dead and
    /// torn down, instead of waiting for a read to hit ENOTCONN mid-turn.
    /// Pongs alone aren't trusted as the liveness signal because they are
    /// not reliably surfaced on every platform.
    public var idleTimeoutSeconds: TimeInterval

    public init(
        session: URLSession? = nil,
        pingIntervalSeconds: TimeInterval = 10,
        idleTimeoutSeconds: TimeInterval = 60
    ) {
        self.session = session ?? Self.makeIsolatedSession()
        self.pingIntervalSeconds = pingIntervalSeconds
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }

    public func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(
            task: task,
            pingIntervalSeconds: pingIntervalSeconds,
            idleTimeoutSeconds: idleTimeoutSeconds
        )
    }
}

private extension URLSessionWebSocketClient {
    static func makeIsolatedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

private final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var lastInbound: DispatchTime = .now()
    private var keepaliveFailure: WebSocketKeepaliveError?
    private var heartbeat: Task<Void, Never>?

    init(task: URLSessionWebSocketTask, pingIntervalSeconds: TimeInterval, idleTimeoutSeconds: TimeInterval) {
        self.task = task
        guard pingIntervalSeconds > 0 else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pingIntervalSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard self.heartbeatTick(idleTimeoutSeconds: idleTimeoutSeconds) else { return }
            }
        }
    }

    deinit {
        heartbeat?.cancel()
    }

    func send(_ message: WebSocketMessage) async throws {
        do {
            switch message {
            case .text(let text):
                try await task.send(.string(text))
            case .data(let data):
                try await task.send(.data(data))
            }
        } catch {
            throw recordedKeepaliveFailure() ?? error
        }
    }

    func receive() async throws -> WebSocketMessage? {
        do {
            let message = try await task.receive()
            noteInbound()
            switch message {
            case .string(let text):
                return .text(text)
            case .data(let data):
                return .data(data)
            @unknown default:
                return nil
            }
        } catch {
            throw recordedKeepaliveFailure() ?? error
        }
    }

    func close() {
        heartbeat?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// One heartbeat cycle: declare the connection dead if the inbound
    /// deadline has passed, otherwise ping. Returns false once the
    /// connection has failed and the heartbeat should stop.
    private func heartbeatTick(idleTimeoutSeconds: TimeInterval) -> Bool {
        lock.lock()
        let failed = keepaliveFailure != nil
        let last = lastInbound
        lock.unlock()
        if failed { return false }

        let idleNs = DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds
        if idleTimeoutSeconds > 0, idleNs > UInt64(idleTimeoutSeconds * 1_000_000_000) {
            fail(reason: "no inbound traffic for \(Int(idleTimeoutSeconds))s")
            return false
        }

        task.sendPing { [weak self] error in
            guard let self else { return }
            if error == nil {
                self.noteInbound()
            }
            // A ping error is not failed immediately: some platforms report
            // spurious pong errors while data frames still flow. The
            // inbound-traffic deadline above catches a genuinely dead socket.
        }
        return true
    }

    private func fail(reason: String) {
        lock.lock()
        let alreadyFailed = keepaliveFailure != nil
        if !alreadyFailed {
            keepaliveFailure = WebSocketKeepaliveError(reason: reason)
        }
        lock.unlock()
        guard !alreadyFailed else { return }
        // Cancelling the task makes any pending receive()/send() throw;
        // the wrappers above replace that error with the keepalive failure.
        task.cancel(with: .abnormalClosure, reason: nil)
    }

    private func noteInbound() {
        lock.lock()
        lastInbound = .now()
        lock.unlock()
    }

    private func recordedKeepaliveFailure() -> WebSocketKeepaliveError? {
        lock.lock()
        defer { lock.unlock() }
        return keepaliveFailure
    }
}
