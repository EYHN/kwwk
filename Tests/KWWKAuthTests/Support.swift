import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KWWKAuth

/// Answers queued responses in order and records every request.
final class QueuedHTTPClient: HTTPClient, @unchecked Sendable {
    enum Answer {
        case response(status: Int, body: String, headers: [String: String] = [:])
        case failure(any Error)
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private(set) var requests: [(url: URL, method: String, headers: [String: String], body: Data?)] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    var requestCount: Int { lock.withLock { requests.count } }

    func header(_ name: String, request index: Int) -> String? {
        lock.withLock {
            requests[index].headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let answer: Answer = lock.withLock {
            requests.append((url, method, headers, body))
            return answers.removeFirst()
        }
        switch answer {
        case .failure(let error):
            throw error
        case .response(let status, let body, let extra):
            var fields = ["content-type": "application/json"]
            for (key, value) in extra { fields[key] = value }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields
            )!
            let data = Data(body.utf8)
            return (response, AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            })
        }
    }
}

/// A loopback that answers the flow with fixed redirect parameters, filling
/// in the `state` the authorize URL carried when asked to.
final class ScriptedLoopback: OAuthLoopbackListener, @unchecked Sendable {
    let redirectURI: String
    private let lock = NSLock()
    private var params: [String: String]
    private var stateFrom: URL?
    private let echoState: Bool
    private(set) var listened = false
    private(set) var stopped = false

    init(host: String, port: UInt16, path: String, params: [String: String], echoState: Bool) {
        redirectURI = "http://\(host):\(port)\(path)"
        self.params = params
        self.echoState = echoState
    }

    func authorizeURLShown(_ url: URL) {
        lock.withLock { stateFrom = url }
    }

    func listen() async throws { lock.withLock { listened = true } }

    func waitForCallback() async throws -> [String: String] {
        lock.withLock {
            var result = params
            if echoState, let url = stateFrom,
               let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                   .queryItems?.first(where: { $0.name == "state" })?.value {
                result["state"] = state
            }
            return result
        }
    }

    func stop() { lock.withLock { stopped = true } }
}

/// A presenter that records what it was asked to show, tells the loopback
/// about it, and runs the work.
final class RecordingPresenter: OAuthBrowserPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var shown: [URL] = []
    var loopback: ScriptedLoopback?
    var events: EventLog?

    func run<Outcome: Sendable>(
        _ url: URL,
        while work: @escaping @Sendable () async throws -> Outcome
    ) async throws -> Outcome {
        let loopback = lock.withLock { () -> ScriptedLoopback? in
            shown.append(url)
            return self.loopback
        }
        events?.append("present")
        loopback?.authorizeURLShown(url)
        return try await work()
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
}

/// An unsigned JWT whose payload is `claims`.
func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "e30.\(encoded).sig"
}

let quietCallbacksBase = OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in })
