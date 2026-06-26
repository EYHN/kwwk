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

public struct URLSessionWebSocketClient: WebSocketClient {
    public let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeIsolatedSession()
    }

    public func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
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

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text):
            try await task.send(.string(text))
        case .data(let data):
            try await task.send(.data(data))
        }
    }

    func receive() async throws -> WebSocketMessage? {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return .text(text)
        case .data(let data):
            return .data(data)
        @unknown default:
            return nil
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
