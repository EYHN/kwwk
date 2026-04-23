import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Timeouts (model API)

/// Seconds for `URLRequest` and for `URLSession` resource budget. Defaults are
/// ~60s in Foundation and can cause `NSURLErrorDomain -1001` on slow first byte
/// or long streaming responses; 3600s matches multi-minute agent turns.
public enum KWWKHTTPTimeLimits {
    public static let requestTimeout: TimeInterval = 3600
    public static let resourceTimeout: TimeInterval = 24 * 3600
}

/// Minimal HTTP client abstraction used by streaming providers. Tests inject a
/// stub implementation; production code uses `URLSessionHTTPClient`.
public protocol HTTPClient: Sendable {
    /// Open a streaming POST request and return an async byte stream of the
    /// response body. The returned `response` is the initial HTTP response.
    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>)
}

public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession

    private static let longTimeoutSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = KWWKHTTPTimeLimits.requestTimeout
        c.timeoutIntervalForResource = KWWKHTTPTimeLimits.resourceTimeout
        return URLSession(configuration: c)
    }()

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.longTimeoutSession
    }

    public func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        request.timeoutInterval = KWWKHTTPTimeLimits.requestTimeout
        return try await streamViaDelegate(base: session, request: request)
    }
}

/// Drives a `URLSessionDataTask` through a delegate that forwards the initial
/// `HTTPURLResponse` and every `didReceive data:` chunk into an
/// `AsyncThrowingStream<UInt8, Error>`. Each call spins up its own
/// `URLSession` (delegates are per-session) and tears it down when the body
/// stream is drained or the consumer cancels.
///
/// Uniform across Apple and Linux: Apple also has `URLSession.bytes(for:)`
/// but keeping one code path saves us from debugging two subtly different
/// streams. The delegate-based path is a thin shim over `URLSessionDataTask`
/// — same behavior, same back-pressure semantics on both OSes.
private func streamViaDelegate(
    base: URLSession,
    request: URLRequest
) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
    let delegate = StreamingDelegate()
    let driver = URLSession(
        configuration: base.configuration,
        delegate: delegate,
        delegateQueue: nil
    )
    let task = driver.dataTask(with: request)
    let stream = delegate.makeByteStream(onCancel: { task.cancel() })
    task.resume()

    do {
        let http = try await delegate.awaitResponse()
        return (http, stream)
    } catch {
        task.cancel()
        driver.finishTasksAndInvalidate()
        throw error
    }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var headerContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var headerResolved = false
    private var pendingHeaders: Result<HTTPURLResponse, Error>?
    private var bodyContinuation: AsyncThrowingStream<UInt8, Error>.Continuation?
    /// Error from `didCompleteWithError` that arrived before the body stream
    /// was constructed. Replayed into the stream once it opens.
    private var pendingCompletion: Error??

    func awaitResponse() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                if let pending = pendingHeaders {
                    pendingHeaders = nil
                    headerResolved = true
                    switch pending {
                    case .success(let http): cont.resume(returning: http)
                    case .failure(let err):  cont.resume(throwing: err)
                    }
                } else {
                    headerContinuation = cont
                }
            }
        }
    }

    func makeByteStream(onCancel: @escaping @Sendable () -> Void) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream<UInt8, Error> { continuation in
            lock.withLock {
                bodyContinuation = continuation
                // Replay a completion that landed before the consumer started
                // draining — typical when the server closed the connection
                // between `didReceive response:` and the caller hooking in.
                if let pending = pendingCompletion {
                    pendingCompletion = nil
                    if let err = pending { continuation.finish(throwing: err) }
                    else { continuation.finish() }
                }
            }
            continuation.onTermination = { _ in onCancel() }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            deliverHeader(.failure(HTTPClientError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        deliverHeader(.success(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cont = lock.withLock { bodyContinuation }
        guard let cont else { return }
        // `yield(contentsOf:)` on a Data wraps it in a Sequence<UInt8>, which
        // yields without copying and keeps the stream back-pressured.
        for byte in data { cont.yield(byte) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            // If `didReceive response:` never fired (DNS/connect failure),
            // surface the error on the header continuation instead.
            if !headerResolved {
                if let cont = headerContinuation {
                    headerContinuation = nil
                    headerResolved = true
                    cont.resume(throwing: error ?? HTTPClientError.invalidResponse)
                } else {
                    pendingHeaders = .failure(error ?? HTTPClientError.invalidResponse)
                    headerResolved = true
                }
            }
            if let body = bodyContinuation {
                if let err = error { body.finish(throwing: err) }
                else { body.finish() }
                bodyContinuation = nil
            } else {
                pendingCompletion = .some(error)
            }
        }
        session.finishTasksAndInvalidate()
    }

    private func deliverHeader(_ result: Result<HTTPURLResponse, Error>) {
        lock.withLock {
            guard !headerResolved else { return }
            headerResolved = true
            if let cont = headerContinuation {
                headerContinuation = nil
                switch result {
                case .success(let http): cont.resume(returning: http)
                case .failure(let err):  cont.resume(throwing: err)
                }
            } else {
                pendingHeaders = result
            }
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
        body: Data?
    ) async throws -> (HTTPURLResponse, Data) {
        let (response, stream) = try await self.stream(
            url: url, method: method, headers: headers, body: body
        )
        var buffer = Data()
        for try await byte in stream { buffer.append(byte) }
        return (response, buffer)
    }
}
