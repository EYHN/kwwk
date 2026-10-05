import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request of the authorization flow (metadata discovery, client
/// registration, token requests).
public struct MCPAuthHTTPRequest: Sendable, Hashable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// A complete HTTP response of the authorization flow.
public struct MCPAuthHTTPResponse: Sendable, Hashable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data
    /// The URL that answered (after any followed redirects).
    public var url: URL

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), url: URL) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
        self.url = url
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Sends the authorization flow's HTTP requests. Implementations must not
/// follow redirects themselves: `MCPAuthHTTP.send` applies the redirect
/// policy (same origin, method kept) on top.
public protocol MCPAuthHTTPClient: Sendable {
    func send(_ request: MCPAuthHTTPRequest) async throws -> MCPAuthHTTPResponse
}

/// The redirect policy and helpers shared by every authorization request.
public enum MCPAuthHTTP {
    /// At most this many redirects are followed.
    public static let maxRedirects = 5
    public static let defaultTimeoutSeconds: TimeInterval = 30

    /// Send `request`, following a redirect only while it keeps the method
    /// (GET, or 307/308) and stays within the request's origin, like the MCP
    /// TypeScript SDK's `fetchWithinOrigin`. Any other redirect is returned
    /// as is.
    public static func send(_ request: MCPAuthHTTPRequest, using client: any MCPAuthHTTPClient) async throws -> MCPAuthHTTPResponse {
        var current = request
        var followed = 0
        while true {
            let response = try await client.send(current)
            guard [301, 302, 303, 307, 308].contains(response.status),
                  followed < maxRedirects,
                  let location = response.header("location"),
                  let target = URL(string: location, relativeTo: current.url)?.absoluteURL
            else { return response }
            let keepsMethod = current.method.uppercased() == "GET" || response.status == 307 || response.status == 308
            guard keepsMethod, isSameOrigin(current.url, target), target.user == nil, target.password == nil else {
                return response
            }
            current.url = target
            followed += 1
        }
    }

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && effectivePort(a) == effectivePort(b)
    }

    static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// `application/x-www-form-urlencoded` body of `parameters`, in order.
    public static func formBody(_ parameters: [(String, String)]) -> Data {
        Data(parameters.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}

/// `MCPAuthHTTPClient` over `URLSession`. Redirects are never followed by
/// the session (`MCPAuthHTTP.send` decides), and requests run as delegate
/// tasks so the redirect veto applies on every platform, including
/// swift-corelibs-foundation.
public final class URLSessionMCPAuthHTTPClient: MCPAuthHTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let delegate: Delegate
    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = MCPAuthHTTP.defaultTimeoutSeconds) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = Delegate()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.timeoutSeconds = timeoutSeconds
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: MCPAuthHTTPRequest) async throws -> MCPAuthHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeoutSeconds)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        let task = session.dataTask(with: urlRequest)
        let delegate = self.delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(task: task, url: request.url, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Pending {
            var url: URL
            var continuation: CheckedContinuation<MCPAuthHTTPResponse, Error>
            var response: HTTPURLResponse?
            var data = Data()
        }

        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        func register(task: URLSessionTask, url: URL, continuation: CheckedContinuation<MCPAuthHTTPResponse, Error>) {
            lock.withLock { pending[task.taskIdentifier] = Pending(url: url, continuation: continuation) }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            lock.withLock { pending[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock { pending[dataTask.taskIdentifier]?.data.append(data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
            if let error {
                entry.continuation.resume(throwing: error)
                return
            }
            guard let http = entry.response ?? task.response as? HTTPURLResponse else {
                entry.continuation.resume(throwing: MCPAuthError.requestFailed("No HTTP response from \(entry.url.absoluteString)"))
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            entry.continuation.resume(returning: MCPAuthHTTPResponse(
                status: http.statusCode,
                headers: headers,
                body: entry.data,
                url: http.url ?? entry.url
            ))
        }
    }
}
