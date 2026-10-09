import Foundation
import Testing
import KWWKAuth

@Suite("Claude subscription windows")
struct AnthropicUsageTests {
    @Test("Utilization stays a percentage even below one", arguments: [0.0, 0.42, 1.0, 42.0, 100.0])
    func percentages(used: Double) throws {
        let windows = try AnthropicUsageReader.windows(fromJSON: Data("""
            {"five_hour":{"utilization":\(used)},"seven_day":{"used_percentage":\(used)}}
            """.utf8))
        #expect(windows.allSatisfy { $0.usedPercent == used && $0.limitID == nil })
        #expect(windows.map(\.window) == [.fiveHour, .sevenDay])
    }

    @Test("Shared limits lead legacy fields; model buckets remain separate and deduplicated", arguments: [false, true])
    func limits(isActive: Bool) throws {
        let windows = try AnthropicUsageReader.windows(fromJSON: Data("""
            {"five_hour":{"utilization":5},"seven_day":{"utilization":99},"limits":[
              {"kind":"session","percent":60,"resets_at":"2026-09-20T00:00:00.500Z"},
              {"kind":"weekly_all","percent":26,"resets_at":1789862400},
              {"kind":"weekly_all","percent":99},
              {"kind":"weekly_scoped","percent":0.42,"resets_at":"2026-09-20T00:00:00Z",
               "is_active":\(isActive),"scope":{"model":{"display_name":" Fable "}}},
              {"kind":"weekly_scoped","percent":80,"scope":{"model":{"display_name":"fable"}}},
              {"kind":"weekly_scoped","percent":80},
              {"kind":"weekly_scoped","scope":{"model":{"display_name":"Missing usage"}}},
              {"kind":"unknown","percent":77}
            ]}
            """.utf8))
        #expect(windows == [
            OAuthUsageWindow(window: .fiveHour, usedPercent: 60, resetsAt: 1_789_862_400_500, windowSeconds: 18000),
            OAuthUsageWindow(window: .sevenDay, usedPercent: 26, resetsAt: 1_789_862_400_000, windowSeconds: 604800),
            OAuthUsageWindow(window: .primary, usedPercent: 0.42, resetsAt: 1_789_862_400_000,
                             windowSeconds: 604800, limitID: "anthropic:weekly:fable", limitName: "Fable"),
        ])
    }

    @Test("Legacy fields fill missing shared windows and percentages clamp")
    func legacyFallback() throws {
        let windows = try AnthropicUsageReader.windows(fromJSON: Data(#"""
            {"five_hour":{"used_percentage":-1,"resets_at":"unknown"},
             "seven_day":{"utilization":120},"limits":[
               {"kind":"weekly_scoped","percent":43,"scope":{"model":{"display_name":"Fable"}}}
            ]}
            """#.utf8))
        #expect(windows.map(\.usedPercent) == [0, 100, 43])
        #expect(windows.first?.resetsAt == nil)
    }

    @Test("Usage uses only the access token, preserving rate-limit and unreadable-answer errors")
    func requestAndFailures() async throws {
        let credentials = OAuthCredentials(access: "access", refresh: "never-send", expires: .max)
        let client = QueuedHTTPClient([.response(status: 200, body: "{}")])
        _ = try await AnthropicUsageReader().usage(credentials, using: client)
        let request = try #require(client.requests.first)
        #expect(request.method == "GET" && request.body == nil)
        #expect(request.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(client.header("Authorization", request: 0) == "Bearer access")
        #expect(client.header("anthropic-beta", request: 0) == "oauth-2025-04-20")
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 30)) {
            _ = try await AnthropicUsageReader().usage(credentials, using: QueuedHTTPClient([
                .response(status: 429, body: "", headers: ["Retry-After": "30"]),
            ]))
        }
        do {
            _ = try await AnthropicUsageReader().usage(credentials, using: QueuedHTTPClient([
                .response(status: 200, body: "<html>"),
            ]))
            Issue.record("Unreadable usage succeeded")
        } catch let error as OAuthUsageError {
            guard case .unavailable(let provider, _, _) = error else {
                Issue.record("Unreadable usage became a rate limit")
                return
            }
            #expect(provider == "anthropic")
        }
    }
}
