import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET https://api.anthropic.com/api/oauth/usage` under the OAuth beta
/// header: shared windows and model-scoped weekly limits shown by Claude.
public struct AnthropicUsageReader: OAuthUsageReader {
    public let providerId = "anthropic"
    public let url: URL

    public init(url: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!) {
        self.url = url
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        let (response, body) = try await OAuthUsage.get(
            url,
            headers: [
                "Authorization": "Bearer \(credentials.access)",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
            ],
            provider: providerId,
            client: client
        )
        do {
            return try Self.windows(fromJSON: body)
        } catch {
            throw OAuthUsageError.unavailable(
                providerId: providerId, status: response.statusCode,
                detail: "undecodable body: \(error)"
            )
        }
    }

    /// Normalizes shared and model-specific windows without touching credentials.
    public static func windows(fromJSON body: Data) throws -> [OAuthUsageWindow] {
        let payload = try JSONDecoder().decode(Payload.self, from: body)
        var windows: [OAuthUsageWindow] = []
        var sharedFiveHour: OAuthUsageWindow?
        var sharedSevenDay: OAuthUsageWindow?
        var seen: Set<String> = []
        for limit in payload.limits ?? [] {
            guard let percent = limit.percent else { continue }
            let used = min(100, max(0, percent))
            switch limit.kind {
            case "session":
                guard sharedFiveHour == nil else { continue }
                sharedFiveHour = OAuthUsageWindow(
                    window: .fiveHour,
                    usedPercent: used,
                    resetsAt: limit.usage.resetsAtMillis,
                    windowSeconds: 5 * 60 * 60
                )
            case "weekly_all":
                guard sharedSevenDay == nil else { continue }
                sharedSevenDay = OAuthUsageWindow(
                    window: .sevenDay,
                    usedPercent: used,
                    resetsAt: limit.usage.resetsAtMillis,
                    windowSeconds: 7 * 24 * 60 * 60
                )
            case "weekly_scoped":
                guard let name = limit.scope?.model?.displayName?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                let id = "anthropic:weekly:" + name.lowercased()
                guard seen.insert(id).inserted else { continue }
                // is_active identifies the binding limit, not whether a quota
                // exists. An inactive Fable limit still has usage to display.
                var dto = OAuthUsageWindow(
                    window: .primary,
                    usedPercent: used,
                    resetsAt: limit.usage.resetsAtMillis,
                    windowSeconds: 7 * 24 * 60 * 60
                )
                dto.limitID = id
                dto.limitName = name
                windows.append(dto)
            default:
                continue
            }
        }
        // Anthropic emptied `seven_day_opus` and `seven_day_sonnet` once the
        // same numbers rode the `limits` array, so the array is the durable
        // source for the shared windows too. The top-level fields stay as the
        // fallback for as long as they are populated.
        windows.insert(contentsOf: [
            sharedFiveHour ?? payload.fiveHour.map { $0.dto(window: .fiveHour, seconds: 5 * 60 * 60) },
            sharedSevenDay ?? payload.sevenDay.map { $0.dto(window: .sevenDay, seconds: 7 * 24 * 60 * 60) },
        ].compactMap { $0 }, at: 0)
        return windows
    }

    /// One `limits[]` entry: the shared `session` / `weekly_all` windows and
    /// the per-model `weekly_scoped` caps all arrive in this one shape.
    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?
                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }
            let model: Model?
        }

        let kind: String?
        let percent: Double?
        let scope: Scope?
        let usage: Window

        enum CodingKeys: String, CodingKey { case kind, percent, scope }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decodeIfPresent(String.self, forKey: .kind)
            percent = try values.decodeIfPresent(Double.self, forKey: .percent)
            scope = try values.decodeIfPresent(Scope.self, forKey: .scope)
            usage = try Window(from: decoder)
        }
    }

    private struct Payload: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case limits
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    /// The OAuth usage body's `utilization` is percent used (0–100), just
    /// like `used_percentage`. Never infer a fraction from a value <= 1:
    /// 1 means 1% used, not an exhausted window. `resets_at` is an
    /// ISO 8601 timestamp, sometimes with fractional seconds, sometimes a
    /// bare Unix-seconds number.
    private struct Window: Decodable {
        let usedPercent: Double
        let resetsAtMillis: Int64?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let percentage = try container.decodeIfPresent(Double.self, forKey: .usedPercentage) {
                usedPercent = percentage
            } else if let utilization = try container.decodeIfPresent(Double.self, forKey: .utilization) {
                usedPercent = utilization
            } else {
                usedPercent = 0
            }

            if let seconds = (try? container.decodeIfPresent(Int64.self, forKey: .resetsAt)) ?? nil {
                resetsAtMillis = seconds * 1000
            } else if let text = try container.decodeIfPresent(String.self, forKey: .resetsAt),
                      let date = Self.parseISO8601(text) {
                resetsAtMillis = Int64(date.timeIntervalSince1970 * 1000)
            } else {
                resetsAtMillis = nil
            }
        }

        func dto(window: OAuthUsageWindowKind, seconds: Int) -> OAuthUsageWindow {
            OAuthUsageWindow(
                window: window,
                usedPercent: min(100, max(0, usedPercent)),
                resetsAt: resetsAtMillis,
                windowSeconds: seconds
            )
        }

        static func parseISO8601(_ text: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: text)
        }
    }
}
