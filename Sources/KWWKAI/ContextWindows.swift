import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What providers have said about a model's context window in this process,
/// layered over the catalog's figure.
///
/// A catalog window is a property of the model; the window a request is
/// actually served at can be a property of the account. Kimi For Coding is the
/// measured case (2026-10-07): models.dev lists `k3` at 1,048,576 tokens, the
/// account's own model list reports 262,144 on a Plus plan, and every larger
/// request is refused with HTTP 401 "Your current plan supports only k3 up to
/// 256K context". Planning against the catalog figure means compaction never
/// fires before the provider starts refusing.
///
/// Two sources lower the window a request is planned against
/// (``Model/effectiveContextWindow``), and neither ever raises it above the
/// model's own `contextWindow`, which already carries any host ceiling:
///
/// - **Discovery.** A provider with a per-account model list registers a
///   ``Discovery``; the Agent refreshes it before planning a request, at most
///   once per ``refreshInterval`` (``failureRetryInterval`` after a failure).
///   The latest answer replaces the previous one, so a plan change is picked up.
/// - **Rejection.** A context-overflow failure that states the limit it
///   enforced (``ProviderContextLimit/reportedLimit(in:)``) records that limit.
///   Rejections only ever lower the window and last for the process, so a
///   provider whose model list disagrees with its enforcement cannot make the
///   Agent overflow again each time discovery refreshes.
public final class ContextWindows: @unchecked Sendable {
    public static let shared = ContextWindows()

    /// Asks the provider for `model`'s window on the account `auth` belongs
    /// to. Nil means the provider did not say; a thrown error is a failed
    /// lookup, retried after ``failureRetryInterval``.
    public typealias Discovery = @Sendable (_ model: Model, _ auth: ResolvedProviderAuth?) async throws -> Int?

    public let refreshInterval: TimeInterval
    public let failureRetryInterval: TimeInterval

    private struct Key: Hashable {
        let provider: String
        let id: String
        let baseURL: String

        init(_ model: Model) {
            provider = model.provider
            id = model.id
            baseURL = model.baseURL
        }
    }

    private struct Entry {
        var discovered: Int?
        var rejected: Int?
        var nextDiscovery: Date?
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var discoveries: [String: Discovery]
    private var inFlight: [Key: Task<Void, Never>] = [:]

    /// Smallest limit a rejection may record. Anything lower is far more
    /// likely a misread number than a real context window.
    static let minimumRecordedWindow = 1_024

    public init(
        refreshInterval: TimeInterval = 3_600,
        failureRetryInterval: TimeInterval = 300,
        discoveries: [String: Discovery] = ContextWindows.builtInDiscoveries(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.refreshInterval = refreshInterval
        self.failureRetryInterval = failureRetryInterval
        self.discoveries = discoveries
        self.now = now
    }

    /// Discoveries every process gets: providers whose model list reports
    /// the window the calling account is served at.
    public static func builtInDiscoveries() -> [String: Discovery] {
        ["kimi-coding": modelListDiscovery()]
    }

    /// The window to plan requests for `model` against: its own
    /// `contextWindow`, lowered by anything the provider has reported.
    public func effectiveWindow(for model: Model) -> Int {
        let entry = lock.withLock { entries[Key(model)] }
        var window = model.contextWindow
        for reported in [entry?.discovered, entry?.rejected].compactMap({ $0 }) where reported > 0 {
            window = min(window, reported)
        }
        return window
    }

    /// Installs (or with nil removes) the discovery for every model of
    /// `provider`.
    public func setDiscovery(_ discovery: Discovery?, forProvider provider: String) {
        lock.withLock { discoveries[provider] = discovery }
    }

    /// Runs `provider`'s discovery for `model` unless a recent answer (or a
    /// recent failure) is still current. Concurrent callers for one model
    /// share a single lookup. Never throws: a failed lookup leaves the window
    /// as it was.
    public func refreshIfNeeded(
        model: Model,
        auth: @escaping @Sendable () async throws -> ResolvedProviderAuth?
    ) async {
        let key = Key(model)
        let task: Task<Void, Never>? = lock.withLock {
            guard let discovery = discoveries[model.provider] else { return nil }
            if let running = inFlight[key] { return running }
            if let next = entries[key]?.nextDiscovery, next > now() { return nil }
            let task = Task { [self] in
                let outcome: Result<Int?, Error>
                do {
                    outcome = .success(try await discovery(model, try await auth()))
                } catch {
                    outcome = .failure(error)
                }
                finishDiscovery(key, outcome)
            }
            inFlight[key] = task
            return task
        }
        await task?.value
    }

    private func finishDiscovery(_ key: Key, _ outcome: Result<Int?, Error>) {
        lock.withLock {
            var entry = entries[key] ?? Entry()
            switch outcome {
            case .success(let window):
                entry.discovered = window.flatMap { $0 > 0 ? $0 : nil }
                entry.nextDiscovery = now().addingTimeInterval(refreshInterval)
            case .failure:
                entry.nextDiscovery = now().addingTimeInterval(failureRetryInterval)
            }
            entries[key] = entry
            inFlight[key] = nil
        }
    }

    /// Records the limit a context-overflow `failure` states for `model`, if
    /// it states one below the window currently planned against. Returns the
    /// recorded limit.
    @discardableResult
    public func recordRejection(_ failure: ProviderFailure, for model: Model) -> Int? {
        guard failure.category == .contextOverflow,
              let limit = failure.reportedContextLimit,
              limit >= Self.minimumRecordedWindow
        else { return nil }
        let key = Key(model)
        return lock.withLock {
            var entry = entries[key] ?? Entry()
            let current = [model.contextWindow, entry.discovered, entry.rejected]
                .compactMap { $0 }
                .filter { $0 > 0 }
                .min() ?? Int.max
            guard limit < current else { return nil }
            entry.rejected = limit
            entries[key] = entry
            return limit
        }
    }

    /// Forgets everything reported for `model`.
    public func reset(_ model: Model) {
        lock.withLock { entries[Key(model)] = nil }
    }

    // MARK: - Model lists

    /// Reads `GET {baseURL}/v1/models` — `{"data": [{"id", "context_length"}]}`,
    /// the shape Kimi For Coding answers with per account — and returns the
    /// entry for the model's id. Kimi's own CLI sizes its context this way.
    public static func modelListDiscovery(
        client: any HTTPClient = URLSessionHTTPClient(),
        timeoutSeconds: TimeInterval = 10
    ) -> Discovery {
        { model, auth in
            guard let token = auth?.token, !token.isEmpty else {
                throw ContextWindowDiscoveryError.missingCredentials
            }
            let base = auth?.baseURL ?? model.baseURL
            guard let url = URL(string: base)?.appendingPathComponent("v1").appendingPathComponent("models") else {
                throw ContextWindowDiscoveryError.invalidBaseURL(base)
            }
            var headers = model.headers ?? [:]
            for (name, value) in auth?.headers ?? [:] {
                headers[name] = value
            }
            headers["Authorization"] = "Bearer \(token)"
            headers["Accept"] = "application/json"
            let (response, stream) = try await client.stream(
                url: url,
                method: "GET",
                headers: headers,
                body: nil,
                cancellation: nil,
                timeoutSeconds: timeoutSeconds
            )
            var body = Data()
            for try await chunk in stream { body.append(chunk) }
            guard response.statusCode == 200 else {
                throw ContextWindowDiscoveryError.status(response.statusCode)
            }
            return try JSONDecoder().decode(ModelList.self, from: body)
                .data.first { $0.id == model.id }?
                .contextLength
        }
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable {
            let id: String
            let contextLength: Int?

            enum CodingKeys: String, CodingKey {
                case id
                case contextLength = "context_length"
            }
        }

        let data: [Entry]
    }
}

public enum ContextWindowDiscoveryError: Error, Equatable, LocalizedError {
    case missingCredentials
    case invalidBaseURL(String)
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: "no credentials to read the model list with"
        case .invalidBaseURL(let base): "model list base URL is invalid: \(base)"
        case .status(let status): "model list answered HTTP \(status)"
        }
    }
}

extension Model {
    /// The window requests for this model are planned against: its own
    /// `contextWindow`, lowered by what the provider has reported to this
    /// process (``ContextWindows``).
    public var effectiveContextWindow: Int {
        ContextWindows.shared.effectiveWindow(for: self)
    }
}

extension ProviderFailure {
    /// The context limit this failure says the provider enforced, if it says.
    public var reportedContextLimit: Int? {
        ProviderContextLimit.reportedLimit(
            in: [message, upstreamMessage].compactMap { $0 }.joined(separator: " ")
        )
    }
}
