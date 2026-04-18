import Foundation

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

    public init(session: URLSession = .shared) {
        self.session = session
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

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }

        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            let task = Task {
                do {
                    for try await byte in bytes {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
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
