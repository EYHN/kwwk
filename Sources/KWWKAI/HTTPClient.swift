import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP client abstraction used by streaming providers. Tests inject a
/// stub implementation; production code uses `URLSessionHTTPClient`.
public protocol HTTPClient: Sendable {
    /// Open a streaming POST request and return an async stream of response
    /// body chunks. Each element is one `didReceive data:` chunk exactly as it
    /// arrived off the socket — consumers (e.g. `SSEParser`, `parseAWSEventStream`)
    /// split it into lines/frames themselves. The returned `response` is the
    /// initial HTTP response.
    ///
    /// The stream is single-consumer and finishes (optionally throwing) when the
    /// request completes or errors. Cancelling the consuming task tears the
    /// stream down, which aborts the underlying transport. `cancellation`
    /// covers the window that consumer-task cancellation cannot reach: the
    /// await for response headers, before any stream exists to tear down.
    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
}

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    /// The long-lived session that owns the connection pool. Reused across every
    /// request so TCP/TLS connections are kept alive between API calls instead
    /// of paying a fresh handshake per request.
    public let session: URLSession
    private let delegate: StreamingSessionDelegate

    public init(session: URLSession? = nil) {
        let delegate = StreamingSessionDelegate()
        self.delegate = delegate
        // A `URLSession`'s delegate is fixed at creation, so an injected session
        // can only donate its configuration; we build our own session bound to
        // the demultiplexing delegate. Cookies/cache stay disabled either way.
        let configuration = session?.configuration ?? Self.isolatedConfiguration()
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        // Let in-flight tasks drain, then release the delegate the session
        // retains. Without this the session (and its delegate) would leak.
        session.finishTasksAndInvalidate()
    }

    public func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body

        let task = session.dataTask(with: request)
        let id = task.taskIdentifier
        // Bridge external cancellation for the request's whole lifetime.
        // `awaitHeader` below is resumed only by delegate callbacks, so a
        // cancelled consumer task cannot interrupt it — only cancelling the
        // URLSession task (which fires `didCompleteWithError`) can.
        let cancelRegistration = cancellation?.onCancel { [weak task] _ in task?.cancel() }
        // Register the body stream before `resume()` so early `didReceive`
        // callbacks find a continuation to feed. The stream aborts the request
        // when the consumer stops iterating (or its task is cancelled); either
        // termination also retires the cancellation listener.
        let stream = delegate.makeBodyStream(for: id, onCancel: { [weak task] in
            task?.cancel()
            cancelRegistration?.cancel()
        })
        task.resume()

        do {
            let http = try await delegate.awaitHeader(for: id)
            return (http, stream)
        } catch {
            task.cancel()
            cancelRegistration?.cancel()
            throw error
        }
    }
}

private extension URLSessionHTTPClient {
    static func isolatedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// A single session-level delegate that demultiplexes callbacks by
/// `dataTask.taskIdentifier` into per-request header/body continuations. One
/// delegate (and one session) serves every concurrent request so the session's
/// connection pool is shared.
private final class StreamingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Per-request state. A request is removed once both its header result has
    /// been handed to `awaitHeader`'s continuation and its body stream has
    /// finished — either side may complete first.
    private struct TaskState {
        var headerContinuation: CheckedContinuation<HTTPURLResponse, Error>?
        var pendingHeader: Result<HTTPURLResponse, Error>?
        var headerResolved = false
        var headerDelivered = false
        var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        /// Completion that arrived before the body stream was constructed.
        var pendingCompletion: Error??
        var bodyFinished = false
    }

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]

    // MARK: - Registration (called from `stream(...)`)

    func makeBodyStream(for id: Int, onCancel: @escaping @Sendable () -> Void) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            let pending: Error?? = lock.withLock {
                var st = states[id] ?? TaskState()
                // Replay a completion that landed before the consumer hooked in
                // (server closed between `didReceive response:` and this call).
                if let p = st.pendingCompletion {
                    st.pendingCompletion = nil
                    st.bodyFinished = true
                    states[id] = st
                    removeIfDoneLocked(id)
                    return .some(p)
                }
                st.bodyContinuation = continuation
                states[id] = st
                return nil
            }
            if let pending {
                if let err = pending { continuation.finish(throwing: err) }
                else { continuation.finish() }
            }
            continuation.onTermination = { _ in onCancel() }
        }
    }

    func awaitHeader(for id: Int) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { cont in
            let pending: Result<HTTPURLResponse, Error>? = lock.withLock {
                var st = states[id] ?? TaskState()
                if let p = st.pendingHeader {
                    st.pendingHeader = nil
                    st.headerDelivered = true
                    states[id] = st
                    removeIfDoneLocked(id)
                    return p
                }
                st.headerContinuation = cont
                states[id] = st
                return nil
            }
            if let pending {
                switch pending {
                case .success(let http): cont.resume(returning: http)
                case .failure(let err):  cont.resume(throwing: err)
                }
            }
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let id = dataTask.taskIdentifier
        guard let http = response as? HTTPURLResponse else {
            deliverHeader(id, .failure(HTTPClientError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        deliverHeader(id, .success(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        let cont = lock.withLock { states[id]?.bodyContinuation }
        // Deliver the whole chunk in one yield — one stream element per socket
        // read, not one per byte.
        cont?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        enum HeaderAction { case none, resume(CheckedContinuation<HTTPURLResponse, Error>, Error) }
        enum BodyAction { case none, finish(AsyncThrowingStream<Data, Error>.Continuation, Error?) }

        let actions: (HeaderAction, BodyAction) = lock.withLock {
            guard var st = states[id] else { return (.none, .none) }
            var headerAction: HeaderAction = .none
            // If `didReceive response:` never fired (DNS/connect failure),
            // surface the error on the header continuation instead.
            if !st.headerResolved {
                st.headerResolved = true
                if let cont = st.headerContinuation {
                    st.headerContinuation = nil
                    st.headerDelivered = true
                    headerAction = .resume(cont, error ?? HTTPClientError.invalidResponse)
                } else {
                    st.pendingHeader = .failure(error ?? HTTPClientError.invalidResponse)
                }
            }
            var bodyAction: BodyAction = .none
            if let body = st.bodyContinuation {
                st.bodyContinuation = nil
                st.bodyFinished = true
                bodyAction = .finish(body, error)
            } else {
                st.pendingCompletion = .some(error)
            }
            states[id] = st
            removeIfDoneLocked(id)
            return (headerAction, bodyAction)
        }

        switch actions.0 {
        case .none: break
        case .resume(let cont, let error): cont.resume(throwing: error)
        }
        switch actions.1 {
        case .none: break
        case .finish(let body, let error):
            if let error { body.finish(throwing: error) } else { body.finish() }
        }
    }

    // MARK: - Helpers

    private func deliverHeader(_ id: Int, _ result: Result<HTTPURLResponse, Error>) {
        let continuation: CheckedContinuation<HTTPURLResponse, Error>? = lock.withLock {
            var st = states[id] ?? TaskState()
            guard !st.headerResolved else { states[id] = st; return nil }
            st.headerResolved = true
            if let cont = st.headerContinuation {
                st.headerContinuation = nil
                st.headerDelivered = true
                states[id] = st
                removeIfDoneLocked(id)
                return cont
            } else {
                st.pendingHeader = result
                states[id] = st
                return nil
            }
        }
        if let continuation {
            switch result {
            case .success(let http): continuation.resume(returning: http)
            case .failure(let err):  continuation.resume(throwing: err)
            }
        }
    }

    private func removeIfDoneLocked(_ id: Int) {
        guard let st = states[id] else { return }
        if st.headerDelivered && st.bodyFinished {
            states[id] = nil
        }
    }
}

public enum HTTPClientError: Error, LocalizedError {
    case invalidResponse
    case unexpectedStatus(Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "invalid HTTP response"
        case .unexpectedStatus(let code, let body):
            return "unexpected HTTP status \(code): \(body)"
        }
    }
}

public extension HTTPClient {
    /// Convenience: issue a one-shot request and collect the entire response
    /// body into a single `Data` buffer. Intended for OAuth token endpoints
    /// and other non-streaming calls.
    func request(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle? = nil
    ) async throws -> (HTTPURLResponse, Data) {
        let (response, stream) = try await self.stream(
            url: url, method: method, headers: headers, body: body, cancellation: cancellation
        )
        var buffer = Data()
        for try await chunk in stream { buffer.append(chunk) }
        return (response, buffer)
    }
}
