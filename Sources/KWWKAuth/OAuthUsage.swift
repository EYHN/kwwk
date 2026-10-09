import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Subscription usage: how much of a login's rate windows is spent, read the
// way each provider's own CLI reads it. Read-only — it authenticates with the
// access token and never touches the refresh chain. API keys are pay-per-token
// and have no windows.

/// Which window a reading describes. The main subscription's 5-hour and
/// weekly windows keep their well-known names; any other length, and every
/// model-specific allowance, keeps the provider's slot name.
public enum OAuthUsageWindowKind: String, Codable, Sendable, CaseIterable {
    case fiveHour
    case sevenDay
    case primary
    case secondary
}

/// One rate window of a subscription, normalized across providers.
public struct OAuthUsageWindow: Codable, Sendable, Equatable {
    public var window: OAuthUsageWindowKind
    /// How much of the window is spent, 0–100.
    public var usedPercent: Double
    /// When the window resets, in Unix milliseconds; nil when unstated.
    public var resetsAt: Int64?
    /// The provider's own window length in seconds, when it reports one.
    public var windowSeconds: Int?
    /// Nil for the main subscription, otherwise the provider's model bucket.
    public var limitID: String?
    public var limitName: String?

    public init(
        window: OAuthUsageWindowKind,
        usedPercent: Double,
        resetsAt: Int64?,
        windowSeconds: Int?,
        limitID: String? = nil,
        limitName: String? = nil
    ) {
        self.window = window
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.limitID = limitID
        self.limitName = limitName
    }
}

/// Why a usage read produced nothing. Neither case says anything about the
/// login itself: a usage endpoint failing is never a reason to park it.
public enum OAuthUsageError: Error, LocalizedError, Sendable, Equatable {
    /// The provider asked to be left alone for this many seconds.
    case rateLimited(retryAfterSeconds: Int)
    /// The endpoint could not be reached or read. `status` is the provider's
    /// HTTP status when it answered.
    case unavailable(providerId: String, status: Int?, detail: String)

    public var errorDescription: String? {
        switch self {
        case .rateLimited(let seconds):
            "usage is rate limited for \(seconds) s"
        case .unavailable(let providerId, let status?, let detail):
            "the \(providerId) usage endpoint returned \(status): \(detail)"
        case .unavailable(let providerId, nil, let detail):
            "the \(providerId) usage endpoint could not be read: \(detail)"
        }
    }
}

/// One provider's usage wire protocol.
public protocol OAuthUsageReader: Sendable {
    var providerId: String { get }
    func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow]
}

public enum OAuthUsage {
    /// The providers whose subscriptions expose a usage endpoint kwwk reads.
    public static let readers: [String: any OAuthUsageReader] = Dictionary(
        uniqueKeysWithValues: ([
            AnthropicUsageReader(),
            OpenAICodexUsageReader(),
            KimiCodingUsageReader(),
        ] as [any OAuthUsageReader]).map { ($0.providerId, $0) }
    )

    /// Seconds to wait from a `Retry-After` value: delta-seconds or an HTTP
    /// date, at most a day; 120 when absent or unreadable.
    public static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> Int {
        if let value = header.flatMap(Double.init), value.isFinite, value > 0 {
            return Int(min(86_400, value.rounded(.up)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = header.flatMap(formatter.date(from:)), date > now {
            return Int(min(86_400, date.timeIntervalSince(now).rounded(.up)))
        }
        return 120
    }

    /// GETs `url`, mapping a 429 to `.rateLimited` and any other failure to
    /// `.unavailable`.
    static func get(
        _ url: URL,
        headers: [String: String],
        provider: String,
        client: HTTPClient
    ) async throws -> (HTTPURLResponse, Data) {
        let response: HTTPURLResponse
        let body: Data
        do {
            (response, body) = try await client.request(url: url, method: "GET", headers: headers, body: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OAuthUsageError.unavailable(providerId: provider, status: nil, detail: error.localizedDescription)
        }
        if response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            throw OAuthUsageError.rateLimited(retryAfterSeconds: retryAfterSeconds(retryAfter))
        }
        if response.statusCode >= 400 {
            throw OAuthUsageError.unavailable(
                providerId: provider,
                status: response.statusCode,
                detail: String((String(data: body, encoding: .utf8) ?? "").prefix(300))
            )
        }
        return (response, body)
    }
}

// MARK: - OpenAI Codex (ChatGPT plan)

/// `GET https://chatgpt.com/backend-api/wham/usage`, the endpoint the Codex
/// CLI itself reads. Requests route by ChatGPT account: the id rides
/// `extras.accountId`, with the access token's own claim as the fallback.
public struct OpenAICodexUsageReader: OAuthUsageReader {
    public let providerId = "openai-codex"
    public let url: URL

    public init(url: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!) {
        self.url = url
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        let accountId: String
        if case .string(let stored)? = credentials.extras["accountId"], !stored.isEmpty {
            accountId = stored
        } else if let claimed = OpenAICodexOAuthProvider.extractAccountId(fromJWT: credentials.access) {
            accountId = claimed
        } else {
            throw OAuthUsageError.unavailable(
                providerId: providerId, status: nil,
                detail: "the stored login carries no ChatGPT account id"
            )
        }
        let (response, body) = try await OAuthUsage.get(
            url,
            headers: [
                "Authorization": "Bearer \(credentials.access)",
                "ChatGPT-Account-Id": accountId,
                "Accept": "application/json",
                "User-Agent": "codex-cli",
            ],
            provider: providerId,
            client: client
        )
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: body)
        } catch {
            throw OAuthUsageError.unavailable(
                providerId: providerId, status: response.statusCode,
                detail: "undecodable body: \(error)"
            )
        }
        return Self.windows(from: payload)
    }

    /// The normalization, separate from the wire for tests.
    public static func windows(fromJSON body: Data) throws -> [OAuthUsageWindow] {
        windows(from: try JSONDecoder().decode(Payload.self, from: body))
    }

    static func windows(from payload: Payload) -> [OAuthUsageWindow] {
        var windows = payload.rateLimit?.windows() ?? []
        for limit in payload.additionalRateLimits ?? [] {
            // Never substitute a model-specific quota for the main subscription.
            guard let id = limit.meteredFeature ?? limit.limitName, !id.isEmpty else { continue }
            windows += limit.rateLimit?.windows(limitID: id, limitName: limit.limitName) ?? []
        }
        return windows
    }

    struct Payload: Decodable {
        let rateLimit: RateLimit?
        let additionalRateLimits: [AdditionalRateLimit]?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
    }

    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        func windows(limitID: String? = nil, limitName: String? = nil) -> [OAuthUsageWindow] {
            let slots: [(OAuthUsageWindowKind, Window?)] = [
                (.primary, primaryWindow), (.secondary, secondaryWindow),
            ]
            return slots.compactMap { slot, window in
                guard let window else { return nil }
                // A zero-length window is disabled, not a 0%-used allowance.
                if let seconds = window.limitWindowSeconds, seconds <= 0 { return nil }
                // Only the main subscription's exact 5-hour and weekly
                // windows take the well-known names; never fabricate one.
                let kind: OAuthUsageWindowKind
                switch (limitID, window.limitWindowSeconds) {
                case (nil, 18000): kind = .fiveHour
                case (nil, 604800): kind = .sevenDay
                default: kind = slot
                }
                return OAuthUsageWindow(
                    window: kind,
                    usedPercent: window.usedPercent,
                    resetsAt: window.resetAt.map { $0 * 1000 },
                    windowSeconds: window.limitWindowSeconds,
                    limitID: limitID,
                    limitName: limitName
                )
            }
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAt: Int64?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
    }
}

// MARK: - Kimi For Coding (Moonshot coding plan)

/// `GET https://api.kimi.com/coding/v1/usages`, the endpoint the Kimi CLI's
/// `/usage` command reads with nothing but the Bearer token.
///
/// The payload is loosely specified and the CLI parses it tolerantly, so this
/// does too: `limits` rows carry a `window` (`duration` + `timeUnit`) and a
/// `detail` with `limit` and either `used` or `remaining`; a top-level
/// `usage` object is the weekly summary. Resets arrive as ISO timestamps —
/// sometimes with nanosecond fractions — or as seconds-until under a handful
/// of spellings.
public struct KimiCodingUsageReader: OAuthUsageReader {
    public let providerId = "kimi-coding"
    public let url: URL

    public init(url: URL = URL(string: "https://api.kimi.com/coding/v1/usages")!) {
        self.url = url
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        let (response, body) = try await OAuthUsage.get(
            url,
            headers: [
                "Authorization": "Bearer \(credentials.access)",
                "Accept": "application/json",
            ],
            provider: providerId,
            client: client
        )
        guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw OAuthUsageError.unavailable(
                providerId: providerId, status: response.statusCode, detail: "undecodable body"
            )
        }
        return Self.windows(from: payload)
    }

    /// `limits` rows become candidates keyed by window length; the 5-hour and
    /// weekly windows are picked by nearest duration (±30 min and ±1 day),
    /// and the top-level `usage` summary stands in for the weekly window when
    /// no row claims it.
    public static func windows(from payload: [String: Any], now: Date = Date()) -> [OAuthUsageWindow] {
        struct Candidate {
            let seconds: Int
            let usedPercent: Double
            let resetsAt: Int64?
        }

        var candidates: [Candidate] = []
        for item in payload["limits"] as? [[String: Any]] ?? [] {
            let window = item["window"] as? [String: Any] ?? [:]
            let detail = item["detail"] as? [String: Any] ?? item
            guard let seconds = windowSeconds(window, fallback: detail),
                  let usedPercent = usedPercent(detail)
            else { continue }
            candidates.append(Candidate(
                seconds: seconds, usedPercent: usedPercent, resetsAt: resetsAtMillis(detail, now: now)
            ))
        }

        func nearest(to target: Int, tolerance: Int) -> Candidate? {
            candidates
                .filter { abs($0.seconds - target) <= tolerance }
                .min { abs($0.seconds - target) < abs($1.seconds - target) }
        }

        var windows: [OAuthUsageWindow] = []
        if let fiveHour = nearest(to: 5 * 60 * 60, tolerance: 30 * 60) {
            windows.append(OAuthUsageWindow(
                window: .fiveHour,
                usedPercent: fiveHour.usedPercent,
                resetsAt: fiveHour.resetsAt,
                windowSeconds: fiveHour.seconds
            ))
        }
        if let sevenDay = nearest(to: 7 * 24 * 60 * 60, tolerance: 24 * 60 * 60) {
            windows.append(OAuthUsageWindow(
                window: .sevenDay,
                usedPercent: sevenDay.usedPercent,
                resetsAt: sevenDay.resetsAt,
                windowSeconds: sevenDay.seconds
            ))
        } else if let summary = payload["usage"] as? [String: Any],
                  let usedPercent = usedPercent(summary) {
            windows.append(OAuthUsageWindow(
                window: .sevenDay,
                usedPercent: usedPercent,
                resetsAt: resetsAtMillis(summary, now: now),
                windowSeconds: 7 * 24 * 60 * 60
            ))
        }
        return windows
    }

    private static func windowSeconds(_ window: [String: Any], fallback: [String: Any]) -> Int? {
        let duration = intValue(window["duration"]) ?? intValue(fallback["duration"])
        guard let duration, duration > 0 else { return nil }
        let unit = (window["timeUnit"] as? String ?? fallback["timeUnit"] as? String ?? "").uppercased()
        if unit.contains("MINUTE") { return duration * 60 }
        if unit.contains("HOUR") { return duration * 60 * 60 }
        if unit.contains("DAY") { return duration * 24 * 60 * 60 }
        return duration
    }

    private static func usedPercent(_ detail: [String: Any]) -> Double? {
        guard let limit = intValue(detail["limit"]), limit > 0 else { return nil }
        let used = intValue(detail["used"])
            ?? intValue(detail["remaining"]).map { limit - $0 }
        guard let used else { return nil }
        return Double(used) / Double(limit) * 100
    }

    /// The CLI checks four spellings for a timestamp and three for a
    /// seconds-until; this accepts the same set.
    private static func resetsAtMillis(_ detail: [String: Any], now: Date) -> Int64? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let text = detail[key] as? String, let date = parseISO8601(text) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        for key in ["reset_in", "resetIn", "ttl"] {
            if let seconds = intValue(detail[key]), seconds > 0 {
                return Int64(now.timeIntervalSince1970 * 1000) + Int64(seconds) * 1000
            }
        }
        return nil
    }

    /// Kimi stamps nanosecond fractions (`…18.443553353Z`), which no
    /// `ISO8601DateFormatter` option accepts; the fraction says nothing at
    /// this resolution, so it is dropped before parsing.
    private static func parseISO8601(_ text: String) -> Date? {
        var trimmed = text
        if let dot = trimmed.firstIndex(of: "."),
           let zone = trimmed[dot...].firstIndex(where: { "Z+-".contains($0) }) {
            trimmed.removeSubrange(dot..<zone)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: number
        case let number as Double: Int(number)
        case let text as String: Int(text)
        case let number as NSNumber: number.intValue
        default: nil
        }
    }
}
