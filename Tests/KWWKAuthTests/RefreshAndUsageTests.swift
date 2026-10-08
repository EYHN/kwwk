import Foundation
import Testing
import KWWKAuth

@Suite("Refresh failures say whether the login survives")
struct RefreshErrorTests {
    private let stale = OAuthCredentials(access: "old", refresh: "r-old", expires: 0)

    private func refreshError(
        _ provider: any OAuthProvider, _ answer: QueuedHTTPClient.Answer
    ) async -> OAuthRefreshError? {
        do {
            _ = try await provider.refresh(stale, using: QueuedHTTPClient([answer]))
            return nil
        } catch let error as OAuthRefreshError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test("A refused grant parks the login; 429, 5xx, transport and unreadable answers do not", arguments: [
        "anthropic", "openai-codex", "kimi-coding", "xai", "cursor",
    ])
    func classification(providerId: String) async throws {
        let provider: any OAuthProvider = switch providerId {
        case "anthropic": AnthropicOAuthProvider()
        case "openai-codex": OpenAICodexOAuthProvider()
        case "kimi-coding": KimiCodingOAuthProvider(identity: .init(deviceId: "d", deviceName: "n", deviceModel: "m", osVersion: "o"))
        case "xai": XaiOAuthProvider()
        default: CursorOAuthProvider()
        }
        let rejected = await refreshError(provider, .response(status: 400, body: #"{"error":"invalid_grant"}"#))
        #expect(rejected?.kind == .rejected)
        #expect(rejected?.status == 400)
        #expect(rejected?.providerId == providerId)
        #expect(await refreshError(provider, .response(status: 401, body: "{}"))?.kind == .rejected)
        #expect(await refreshError(provider, .response(status: 429, body: "{}"))?.kind == .unavailable)
        #expect(await refreshError(provider, .response(status: 503, body: "busy"))?.kind == .unavailable)
        #expect(await refreshError(provider, .failure(URLError(.timedOut)))?.kind == .unavailable)
        #expect(await refreshError(provider, .response(status: 200, body: "<html>"))?.kind == .unavailable)
    }

    @Test("Claude rotations retain extras, use the returned refresh token and apply the expiry margin")
    func anthropicRotation() async throws {
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let stale = OAuthCredentials(access: "old", refresh: "r-old", expires: 0, extras: ["owner": "kept"])
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"new","refresh_token":"r-new","expires_in":28800}"#),
        ])
        let refreshed = try await AnthropicOAuthProvider().refresh(stale, using: client)
        #expect(refreshed.access == "new")
        #expect(refreshed.refresh == "r-new")
        #expect(refreshed.extras == stale.extras)
        #expect(refreshed.expires >= before + (28800 - 300) * 1000)
        #expect(refreshed.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (28800 - 300) * 1000)
        let data = try #require(client.requests.first?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body["refresh_token"] == stale.refresh)
        #expect(body["grant_type"] == "refresh_token")
    }

    @Test("A token answer without expires_in gets an hour")
    func missingExpiresIn() async throws {
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let refreshed = try await XaiOAuthProvider().refresh(
            stale, using: QueuedHTTPClient([.response(status: 200, body: #"{"access_token":"a"}"#)])
        )
        #expect(refreshed.refresh == "r-old")
        #expect(refreshed.expires >= before + 55 * 60 * 1000)
        #expect(refreshed.expires <= before + 60 * 60 * 1000)
    }
}

@Suite("Kimi refresh presents the device its login was approved on")
struct KimiDeviceRefreshTests {
    private let fallback = KimiDeviceIdentity(
        deviceId: "fallback-id", deviceName: "airbuild-backend", deviceModel: "Linux x86_64", osVersion: "Linux"
    )

    @Test("The id recorded in the credentials wins over the provider's own")
    func recordedIdWins() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ka2","refresh_token":"kr2","expires_in":900}"#),
        ])
        let refreshed = try await KimiCodingOAuthProvider(identity: fallback).refresh(
            OAuthCredentials(access: "ka", refresh: "kr", expires: 0, extras: ["deviceId": "login-id"]),
            using: client
        )
        #expect(client.header("X-Msh-Device-Id", request: 0) == "login-id")
        #expect(client.header("X-Msh-Device-Name", request: 0) == "airbuild-backend")
        #expect(refreshed.extras["deviceId"] == .string("login-id"))
        #expect(refreshed.refresh == "kr2")
    }

    @Test("A login that recorded no id gets the one it was refreshed with")
    func missingIdIsRecorded() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"ka2","refresh_token":"kr2","expires_in":900}"#),
        ])
        let refreshed = try await KimiCodingOAuthProvider(identity: fallback).refresh(
            OAuthCredentials(access: "ka", refresh: "kr", expires: 0), using: client
        )
        #expect(client.header("X-Msh-Device-Id", request: 0) == "fallback-id")
        #expect(refreshed.extras["deviceId"] == .string("fallback-id"))
    }
}

@Suite("Subscription usage")
struct UsageTests {
    @Test("Codex: only the main subscription's exact 5-hour and weekly windows take their names")
    func codexWindows() throws {
        let body = Data(#"""
        {
          "rate_limit": {
            "primary_window": {"used_percent": 42.5, "limit_window_seconds": 18000, "reset_at": 1790000000},
            "secondary_window": {"used_percent": 120, "limit_window_seconds": 604800, "reset_at": 1790500000}
          },
          "additional_rate_limits": [
            {"limit_name": "GPT-5.5 Pro", "metered_feature": "gpt55pro",
             "rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 18000, "reset_at": 1790000100},
                            "secondary_window": {"used_percent": 0, "limit_window_seconds": 0}}},
            {"rate_limit": {"primary_window": {"used_percent": 5, "limit_window_seconds": 18000}}}
          ]
        }
        """#.utf8)
        let windows = try OpenAICodexUsageReader.windows(fromJSON: body)
        #expect(windows == [
            OAuthUsageWindow(window: .fiveHour, usedPercent: 42.5, resetsAt: 1_790_000_000_000, windowSeconds: 18000),
            OAuthUsageWindow(window: .sevenDay, usedPercent: 100, resetsAt: 1_790_500_000_000, windowSeconds: 604_800),
            OAuthUsageWindow(
                window: .primary, usedPercent: 10, resetsAt: 1_790_000_100_000, windowSeconds: 18000,
                limitID: "gpt55pro", limitName: "GPT-5.5 Pro"
            ),
        ])
    }

    @Test("Codex: a weekly-only plan reports no 5-hour window")
    func codexWeeklyOnly() throws {
        let body = Data(#"{"rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":604800}}}"#.utf8)
        let windows = try OpenAICodexUsageReader.windows(fromJSON: body)
        #expect(windows.map(\.window) == [.sevenDay])
    }

    @Test("Codex routes by the stored account id and asks as the CLI")
    func codexRequest() async throws {
        let client = QueuedHTTPClient([.response(status: 200, body: #"{"rate_limit":null}"#)])
        let windows = try await OpenAICodexUsageReader().usage(
            OAuthCredentials(access: "tok", refresh: "", expires: .max, extras: ["accountId": "acct-1"]),
            using: client
        )
        #expect(windows.isEmpty)
        #expect(client.header("ChatGPT-Account-Id", request: 0) == "acct-1")
        #expect(client.header("Authorization", request: 0) == "Bearer tok")
        #expect(client.header("User-Agent", request: 0) == "codex-cli")
    }

    @Test("Kimi: rows by nearest duration, the summary standing in for the week")
    func kimiWindows() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let payload: [String: Any] = [
            "limits": [
                ["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                 "detail": ["limit": 200, "remaining": 150, "resetTime": "2026-09-21T10:00:18.443553353Z"]],
            ],
            "usage": ["limit": "1000", "used": "250", "reset_in": 3600],
        ]
        let windows = KimiCodingUsageReader.windows(from: payload, now: now)
        #expect(windows.count == 2)
        #expect(windows[0].window == .fiveHour)
        #expect(windows[0].usedPercent == 25)
        #expect(windows[0].windowSeconds == 18000)
        #expect(windows[0].resetsAt == 1_789_984_818_000)
        #expect(windows[1].window == .sevenDay)
        #expect(windows[1].usedPercent == 25)
        #expect(windows[1].resetsAt == 1_790_003_600_000)
    }

    @Test("A 429 carries its Retry-After; other failures are unavailable")
    func failures() async throws {
        let creds = OAuthCredentials(access: "t", refresh: "", expires: .max)
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 30)) {
            _ = try await KimiCodingUsageReader().usage(
                creds, using: QueuedHTTPClient([.response(status: 429, body: "", headers: ["Retry-After": "30"])])
            )
        }
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 120)) {
            _ = try await KimiCodingUsageReader().usage(
                creds, using: QueuedHTTPClient([.response(status: 429, body: "")])
            )
        }
        await #expect(throws: OAuthUsageError.unavailable(providerId: "kimi-coding", status: 502, detail: "bad gateway")) {
            _ = try await KimiCodingUsageReader().usage(
                creds, using: QueuedHTTPClient([.response(status: 502, body: "bad gateway")])
            )
        }
    }

    @Test("Retry-After: seconds, an HTTP date, a day at most, 120 otherwise")
    func retryAfter() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(OAuthUsage.retryAfterSeconds("12.2", now: now) == 13)
        #expect(OAuthUsage.retryAfterSeconds("999999", now: now) == 86_400)
        #expect(OAuthUsage.retryAfterSeconds("1e100", now: now) == 86_400)
        #expect(OAuthUsage.retryAfterSeconds("Mon, 21 Sep 2026 14:14:20 GMT", now: now) == 60)
        for invalid in [nil, "soon", "-1", "nan", "0"] as [String?] {
            #expect(OAuthUsage.retryAfterSeconds(invalid, now: now) == 120)
        }
    }
}
