import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import Testing
@testable import KWWKAuth

// Ported from the Antigravity cases of magpie's google_test.go and
// antigravity_tier_test.go, which answer Google's token endpoint and Code
// Assist checking what the Antigravity Hub would send.

private func query(_ url: URL) -> [String: String] {
    var out: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        out[item.name] = item.value ?? ""
    }
    return out
}

private func form(_ data: Data?) throws -> [String: String] {
    let text = String(decoding: try #require(data), as: UTF8.self)
    var out: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        out[parts[0].removingPercentEncoding ?? parts[0]] = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
    }
    return out
}

private func jsonBody(_ client: QueuedHTTPClient, request index: Int) throws -> [String: Any] {
    let data = try #require(client.requests[index].body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func s256(_ verifier: String) -> String {
    PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
}

private let hubVersion = AntigravityHubVersion(fixed: "3.1.4")
private let hubAgent = "antigravity/hub/3.1.4 \(AntigravityOAuth.platform)"

private let tokenAnswer = #"{"access_token":"ag-at","refresh_token":"ag-rt","expires_in":3599,"scope":"openid","token_type":"Bearer"}"#
private let whoAnswer = #"{"id":"1","email":"ag@example.com","verified_email":true}"#
/// A Google AI Pro account as loadCodeAssist answers it (CLIProxyAPI #6186).
private let proLoad = """
    {"currentTier":{"id":"standard-tier","name":"Antigravity","userDefinedCloudaicompanionProject":true,"usesGcpTos":true},
    "paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"},
    "cloudaicompanionProject":"aicode-consumers",
    "ineligibleTiers":[{"tierId":"free-tier","reasonCode":"VALIDATION_REQUIRED","validationErrorMessage":"Verify your account to continue."}]}
    """

/// Callbacks whose loopback answers the redirect with `params`, the state
/// the page carried echoed back.
private func scripted(_ params: [String: String], presenter: RecordingPresenter, made: LoopbackBox) -> OAuthLogin.Callbacks {
    var callbacks = quietCallbacksBase
    callbacks.browser = presenter
    callbacks.loopback = { host, port, path in
        let loopback = ScriptedLoopback(host: host, port: port, path: path, params: params, echoState: true)
        presenter.loopback = loopback
        made.set(loopback)
        return loopback
    }
    return callbacks
}

@Suite("Antigravity sign-in with a Google account")
struct AntigravitySignInTests {
    @Test("PKCE against accounts.google.com, the code traded with Antigravity's client, userinfo, loadCodeAssist into extras")
    func fullFlow() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: tokenAnswer),
            .response(status: 200, body: whoAnswer),
            .response(status: 200, body: proLoad),
        ])
        let presenter = RecordingPresenter()
        let made = LoopbackBox()
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let credentials = try await OAuthLogin.loginAntigravity(
            callbacks: scripted(["code": "gcode"], presenter: presenter, made: made),
            client: client,
            hubVersion: hubVersion
        )

        // The listener is the one every browser login binds, at agy's port
        // and Antigravity's path.
        let loopback = try #require(made.value)
        #expect(loopback.redirectURI == "http://localhost:51121/oauth-callback")
        #expect(loopback.listened)
        #expect(loopback.stopped)

        let page = try #require(presenter.shown.first)
        let shown = query(page)
        #expect(page.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
        #expect(shown["client_id"] == AntigravityOAuth.clientID)
        #expect(shown["redirect_uri"] == "http://localhost:51121/oauth-callback")
        #expect(shown["response_type"] == "code")
        #expect(shown["access_type"] == "offline")
        #expect(shown["prompt"] == "consent")
        #expect(shown["code_challenge_method"] == "S256")
        #expect(shown["scope"] == "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email "
            + "https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog "
            + "https://www.googleapis.com/auth/experimentsandconfigs")
        #expect(shown["state"]?.count == 32)

        #expect(client.requestCount == 3)
        let token = client.requests[0]
        #expect(token.url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(token.method == "POST")
        #expect(client.header("Content-Type", request: 0) == "application/x-www-form-urlencoded")
        let exchanged = try form(token.body)
        #expect(exchanged["grant_type"] == "authorization_code")
        #expect(exchanged["code"] == "gcode")
        #expect(exchanged["redirect_uri"] == "http://localhost:51121/oauth-callback")
        #expect(exchanged["client_id"] == AntigravityOAuth.clientID)
        #expect(exchanged["client_secret"] == AntigravityOAuth.clientSecret)
        #expect(s256(exchanged["code_verifier"] ?? "") == shown["code_challenge"])

        let who = client.requests[1]
        #expect(who.url.absoluteString == "https://www.googleapis.com/oauth2/v2/userinfo?alt=json")
        #expect(who.method == "GET")
        #expect(client.header("Authorization", request: 1) == "Bearer ag-at")

        // The project is found on the production host, as the Hub asks.
        let load = client.requests[2]
        #expect(load.url.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        #expect(client.header("Authorization", request: 2) == "Bearer ag-at")
        #expect(client.header("User-Agent", request: 2) == hubAgent)
        #expect(client.header("Content-Type", request: 2) == "application/json")
        let asked = try jsonBody(client, request: 2)
        #expect((asked["metadata"] as? [String: String]) == ["ideType": "ANTIGRAVITY"])

        #expect(credentials.access == "ag-at")
        #expect(credentials.refresh == "ag-rt")
        #expect(credentials.extras == [
            "email": "ag@example.com", "projectId": "aicode-consumers",
            "tier": "standard-tier", "paidTier": "g1-pro-tier",
        ])
        #expect(credentials.expires >= before + (3599 - 300) * 1000)
        #expect(credentials.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3599 - 300) * 1000)
        #expect(AntigravityOAuth.email(credentials) == "ag@example.com")
        #expect(AntigravityOAuth.projectId(credentials) == "aicode-consumers")
        #expect(AntigravityOAuth.tier(credentials) == "standard-tier")
        #expect(AntigravityOAuth.paidTier(credentials) == "g1-pro-tier")
    }

    @Test("An account with no project is set up on the daily host, its operation polled until done (oh-my-pi)")
    func onboard() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: tokenAnswer),
            .response(status: 200, body: whoAnswer),
            .response(status: 200, body: #"{"allowedTiers":[{"id":"free-tier","name":"Antigravity","isDefault":true}]}"#),
            .response(status: 200, body: #"{"done":false,"name":"operations/1"}"#),
            .response(status: 200, body: #"{"done":true,"response":{"cloudaicompanionProject":{"id":"ag-proj","name":"x"}}}"#),
        ])
        let presenter = RecordingPresenter()
        let slept = EventLog()
        let credentials = try await OAuthLogin.loginAntigravity(
            callbacks: scripted(["code": "gcode"], presenter: presenter, made: LoopbackBox()),
            client: client,
            hubVersion: hubVersion,
            pollSleep: { seconds in slept.append("\(seconds)") }
        )
        #expect(client.requestCount == 5)
        #expect(client.requests[3].url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:onboardUser")
        #expect(client.requests[3].method == "POST")
        for index in [3, 4] {
            #expect(client.header("User-Agent", request: index) == hubAgent + " google-api-nodejs-client/10.3.0")
            #expect(client.header("X-Goog-Api-Client", request: index) == "gl-node/22.21.1")
            #expect(client.header("Authorization", request: index) == "Bearer ag-at")
        }
        let body = try jsonBody(client, request: 3)
        #expect(body["tier_id"] as? String == "free-tier")
        #expect((body["metadata"] as? [String: String]) == [
            "ide_type": "ANTIGRAVITY", "ide_version": "3.1.4", "ide_name": "antigravity",
        ])
        // The operation is asked for by its name, not onboarded again.
        #expect(client.requests[4].url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal/operations/1")
        #expect(client.requests[4].method == "GET")
        #expect(client.requests[4].body == nil)
        // Asked after a pause, once the operation says it isn't done.
        #expect(slept.entries == ["2.0"])
        #expect(credentials.extras == ["email": "ag@example.com", "projectId": "ag-proj", "tier": "free-tier"])
    }

    @Test("An operation Code Assist won't answer by name is onboarded again (magpie); one done with an error fails saying why")
    func onboardFallbacks() async throws {
        var client = QueuedHTTPClient([
            .response(status: 200, body: tokenAnswer),
            .response(status: 200, body: whoAnswer),
            .response(status: 200, body: #"{"allowedTiers":[{"id":"free-tier","isDefault":true}]}"#),
            .response(status: 200, body: #"{"done":false,"name":"operations/1"}"#),
            .response(status: 404, body: #"{"error":{"code":404,"message":"Not found","status":"NOT_FOUND"}}"#),
            .response(status: 200, body: #"{"done":false,"name":"operations/1"}"#),
            .response(status: 200, body: #"{"done":true,"response":{"cloudaicompanionProject":"ag-proj"}}"#),
        ])
        let credentials = try await OAuthLogin.loginAntigravity(
            callbacks: scripted(["code": "c"], presenter: RecordingPresenter(), made: LoopbackBox()),
            client: client,
            hubVersion: hubVersion,
            pollSleep: { _ in }
        )
        #expect(client.requestCount == 7)
        #expect(client.requests[4].method == "GET")
        for index in [5, 6] {
            #expect(client.requests[index].url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:onboardUser")
            #expect(client.requests[index].method == "POST")
        }
        #expect(AntigravityOAuth.projectId(credentials) == "ag-proj")

        client = QueuedHTTPClient([
            .response(status: 200, body: tokenAnswer),
            .response(status: 200, body: whoAnswer),
            .response(status: 200, body: #"{"allowedTiers":[{"id":"free-tier","isDefault":true}]}"#),
            .response(status: 200, body: #"{"done":false,"name":"operations/2"}"#),
            .response(status: 200, body: #"{"name":"operations/2","done":true,"error":{"code":9,"message":"Precondition failed"}}"#),
        ])
        do {
            _ = try await OAuthLogin.loginAntigravity(
                callbacks: scripted(["code": "c"], presenter: RecordingPresenter(), made: LoopbackBox()),
                client: client,
                hubVersion: hubVersion,
                pollSleep: { _ in }
            )
            Issue.record("signed in through a failed onboarding")
        } catch {
            #expect(error.localizedDescription.contains("Precondition failed"))
        }
        #expect(client.requestCount == 5)
    }

    @Test("A userinfo that fails leaves the login without an email, not without a login (pi)")
    func noEmail() async throws {
        for who in [QueuedHTTPClient.Answer.response(status: 500, body: "busy"), .response(status: 200, body: #"{"id":"1"}"#),
                    .failure(URLError(.timedOut))] {
            let client = QueuedHTTPClient([
                .response(status: 200, body: tokenAnswer),
                who,
                .response(status: 200, body: proLoad),
            ])
            let credentials = try await OAuthLogin.loginAntigravity(
                callbacks: scripted(["code": "c"], presenter: RecordingPresenter(), made: LoopbackBox()),
                client: client,
                hubVersion: hubVersion
            )
            #expect(client.requestCount == 3)
            #expect(AntigravityOAuth.email(credentials) == nil)
            #expect(credentials.extras == ["projectId": "aicode-consumers", "tier": "standard-tier", "paidTier": "g1-pro-tier"])
        }
    }

    @Test("Onboarding that never finishes, and an account Google won't serve, fail the sign-in saying why")
    func onboardFailures() async throws {
        var client = QueuedHTTPClient([
            .response(status: 200, body: tokenAnswer),
            .response(status: 200, body: whoAnswer),
            .response(status: 200, body: #"{"allowedTiers":[{"id":"legacy-tier","isDefault":true}]}"#),
        ] + Array(repeating: QueuedHTTPClient.Answer.response(status: 200, body: #"{"done":false}"#), count: 5))
        do {
            _ = try await OAuthLogin.loginAntigravity(
                callbacks: scripted(["code": "c"], presenter: RecordingPresenter(), made: LoopbackBox()),
                client: client,
                hubVersion: hubVersion,
                pollSleep: { _ in }
            )
            Issue.record("signed in with no project")
        } catch {
            #expect(error.localizedDescription.contains("taking long"))
        }
        // legacy-tier is no tier to set an account up on: free-tier goes.
        #expect(client.requestCount == 8)
        #expect(try jsonBody(client, request: 3)["tier_id"] as? String == "free-tier")

        client = QueuedHTTPClient([
            .response(status: 200, body: tokenAnswer),
            .response(status: 200, body: whoAnswer),
            .response(status: 200, body: #"{"ineligibleTiers":[{"tierId":"free-tier","reasonCode":"INELIGIBLE_ACCOUNT","reasonMessage":"Antigravity is not available in your region."}]}"#),
            .response(status: 200, body: #"{"done":true,"response":{}}"#),
        ])
        await #expect(throws: OAuthLoginError.denied(
            "Antigravity won't serve this Google account: Antigravity is not available in your region."
        )) {
            _ = try await OAuthLogin.loginAntigravity(
                callbacks: scripted(["code": "c"], presenter: RecordingPresenter(), made: LoopbackBox()),
                client: client,
                hubVersion: hubVersion,
                pollSleep: { _ in }
            )
        }
    }

    @Test("A declined page is the user's cancel; a refused exchange and a grant without a refresh token are no sign-in")
    func refusals() async throws {
        await #expect(throws: OAuthLoginError.cancelled) {
            _ = try await OAuthLogin.loginAntigravity(
                callbacks: scripted(["error": "access_denied"], presenter: RecordingPresenter(), made: LoopbackBox()),
                client: QueuedHTTPClient([]),
                hubVersion: hubVersion
            )
        }
        do {
            _ = try await OAuthLogin.loginAntigravity(
                callbacks: scripted(["code": "c"], presenter: RecordingPresenter(), made: LoopbackBox()),
                client: QueuedHTTPClient([.response(
                    status: 400, body: #"{"error":"invalid_grant","error_description":"Bad Request"}"#
                )]),
                hubVersion: hubVersion
            )
            Issue.record("a refused exchange signed in")
        } catch {
            #expect(error.localizedDescription.contains("the Google sign-in was refused (400): Bad Request"))
        }
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginAntigravity(
                callbacks: scripted(["code": "c"], presenter: RecordingPresenter(), made: LoopbackBox()),
                client: QueuedHTTPClient([.response(status: 200, body: #"{"access_token":"a","expires_in":3600}"#)]),
                hubVersion: hubVersion
            )
        }
        // A callback with another state is not ours.
        var callbacks = scripted(["code": "c", "state": "nope"], presenter: RecordingPresenter(), made: LoopbackBox())
        callbacks.loopback = { host, port, path in
            ScriptedLoopback(host: host, port: port, path: path, params: ["code": "c", "state": "nope"], echoState: false)
        }
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginAntigravity(callbacks: callbacks, client: QueuedHTTPClient([]), hubVersion: hubVersion)
        }
    }
}

@Suite("Antigravity refresh")
struct AntigravityRefreshTests {
    private let credentials = OAuthCredentials(
        access: "old",
        refresh: "rt",
        expires: 0,
        extras: ["email": "ag@example.com", "projectId": "ag-proj", "tier": "free-tier"]
    )

    @Test("The token is refreshed at Google with Antigravity's client; the refresh token does not rotate")
    func refresh() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"new","expires_in":3599,"scope":"x","token_type":"Bearer"}"#),
            .response(status: 200, body: #"{"currentTier":{"id":"free-tier"},"cloudaicompanionProject":"ag-proj"}"#),
        ])
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let refreshed = try await AntigravityOAuthProvider(hubVersion: hubVersion).refresh(credentials, using: client)
        #expect(client.requests[0].url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(client.requests[0].method == "POST")
        #expect(client.header("Content-Type", request: 0) == "application/x-www-form-urlencoded")
        #expect(try form(client.requests[0].body) == [
            "grant_type": "refresh_token", "refresh_token": "rt",
            "client_id": AntigravityOAuth.clientID, "client_secret": AntigravityOAuth.clientSecret,
        ])
        #expect(refreshed.access == "new")
        #expect(refreshed.refresh == "rt")
        #expect(refreshed.extras == credentials.extras)
        // The account is asked of again with the new token.
        #expect(client.requestCount == 2)
        #expect(client.requests[1].url.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        #expect(client.header("Authorization", request: 1) == "Bearer new")
        #expect(refreshed.expires >= before + (3599 - 300) * 1000)
        #expect(refreshed.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3599 - 300) * 1000)
    }

    @Test("A refresh takes the plan the account is on now; a loadCodeAssist that fails keeps what the login had")
    func tierRefreshed() async throws {
        let token = QueuedHTTPClient.Answer.response(status: 200, body: #"{"access_token":"new","expires_in":3599}"#)
        // Bought Google AI Pro since the sign-in.
        var client = QueuedHTTPClient([token, .response(status: 200, body: proLoad)])
        var refreshed = try await AntigravityOAuthProvider(hubVersion: hubVersion).refresh(credentials, using: client)
        #expect(refreshed.extras == [
            "email": "ag@example.com", "projectId": "aicode-consumers", "tier": "standard-tier", "paidTier": "g1-pro-tier",
        ])
        // A tier it doesn't name is kept.
        client = QueuedHTTPClient([token, .response(status: 200, body: #"{"cloudaicompanionProject":"ag-proj"}"#)])
        refreshed = try await AntigravityOAuthProvider(hubVersion: hubVersion).refresh(credentials, using: client)
        #expect(refreshed.extras == credentials.extras)
        // A failed ask is no failed refresh.
        for answer in [QueuedHTTPClient.Answer.response(status: 503, body: "busy"), .failure(URLError(.timedOut))] {
            client = QueuedHTTPClient([token, answer])
            refreshed = try await AntigravityOAuthProvider(hubVersion: hubVersion).refresh(credentials, using: client)
            #expect(refreshed.access == "new")
            #expect(refreshed.extras == credentials.extras)
        }
        // A host may leave the account alone.
        client = QueuedHTTPClient([token])
        refreshed = try await AntigravityOAuthProvider(hubVersion: hubVersion, refreshesAccount: false).refresh(credentials, using: client)
        #expect(client.requestCount == 1)
        #expect(refreshed.extras == credentials.extras)
    }

    @Test("A refused grant parks the login; other failures do not")
    func classification() async throws {
        func kindOf(_ answer: QueuedHTTPClient.Answer) async -> OAuthRefreshError.Kind? {
            do {
                _ = try await AntigravityOAuthProvider().refresh(credentials, using: QueuedHTTPClient([answer]))
                return nil
            } catch let error as OAuthRefreshError {
                #expect(error.providerId == "antigravity")
                return error.kind
            } catch {
                Issue.record("unexpected error \(error)")
                return nil
            }
        }
        #expect(await kindOf(.response(status: 400, body: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)) == .rejected)
        #expect(await kindOf(.response(status: 401, body: "{}")) == .rejected)
        #expect(await kindOf(.response(status: 403, body: "<html>")) == .unavailable)
        #expect(await kindOf(.response(status: 503, body: "busy")) == .unavailable)
        #expect(await kindOf(.failure(URLError(.timedOut))) == .unavailable)
        #expect(await kindOf(.response(status: 200, body: "{}")) == .unavailable)
    }

    @Test("Antigravity is a refreshed subscription, listed after Kiro, with a refresher and a usage reader of its own")
    func registered() {
        let ids = OAuthSubscriptions.providers.map(\.id)
        let kiro = try? #require(ids.firstIndex(of: "kiro"))
        #expect(kiro.map { ids[$0 + 1] } == "antigravity")
        #expect(OAuthSubscriptions.provider(id: "antigravity") == .init(id: "antigravity", name: "Antigravity", upkeep: .refreshed))
        #expect(OAuthSubscriptions.refresher(providerId: "antigravity") is AntigravityOAuthProvider)
        #expect(OAuthUsage.readers["antigravity"] is AntigravityUsageReader)
        #expect(OAuthSubscriptions.usageIds.contains("antigravity"))
    }
}

@Suite("Antigravity's Hub version")
struct AntigravityHubVersionTests {
    @Test("The updater's manifest names the version; anything else keeps the last known")
    func manifest() {
        #expect(AntigravityHubVersion.parse(manifest: "version: 3.1.4\npath: x.zip\n") == "3.1.4")
        #expect(AntigravityHubVersion.parse(manifest: "path: x.zip\nversion: '2.10.0'\n") == "2.10.0")
        #expect(AntigravityHubVersion.parse(manifest: "version: latest\n") == nil)
        #expect(AntigravityHubVersion.parse(manifest: "path: x.zip\n") == nil)
        #expect(AntigravityHubVersion.fallback.allSatisfy { $0.isNumber || $0 == "." })
    }

    @Test("It is asked of the updater once, then cached; a failed ask keeps the fallback")
    func cached() async {
        let client = QueuedHTTPClient([.response(status: 200, body: "version: 3.1.4\n")])
        let version = AntigravityHubVersion()
        #expect(await version.current(client: client) == "3.1.4")
        #expect(await version.current(client: client) == "3.1.4")
        #expect(client.requestCount == 1)
        #expect(client.requests[0].url == AntigravityHubVersion.manifestURL)
        #expect(client.header("User-Agent", request: 0) == "electron-builder")

        let down = AntigravityHubVersion()
        #expect(await down.current(client: QueuedHTTPClient([.failure(URLError(.cannotConnectToHost))])) == AntigravityHubVersion.fallback)
        #expect(await AntigravityHubVersion(fixed: "9.9.9").current(client: QueuedHTTPClient([])) == "9.9.9")
    }

    @Test("The User-Agent is the Hub's line")
    func userAgent() {
        let agent = AntigravityOAuth.userAgent(version: "3.1.4")
        #expect(agent.range(of: #"^antigravity/hub/3\.1\.4 (darwin|linux|windows)/(arm64|amd64)$"#, options: .regularExpression) != nil)
    }
}

@Suite("Antigravity usage")
struct AntigravityUsageTests {
    private let credentials = OAuthCredentials(
        access: "tok",
        refresh: "r",
        expires: .max,
        extras: ["email": "ag@example.com", "projectId": "aicode-consumers", "tier": "standard-tier", "paidTier": "g1-pro-tier"]
    )

    /// fetchAvailableModels as it answered on 2026-10-20 (magpie's fixture),
    /// cut to a few rows, with the quota spent unevenly.
    private static let models = """
        {"models":{
        "gemini-3.8-flash-high":{"displayName":"Gemini 3.8 Flash (High)","maxTokens":1048576,"quotaInfo":{"remainingFraction":0.9545545,"resetTime":"2099-01-01T05:00:00Z"}},
        "gemini-3.8-flash-low":{"displayName":"Gemini 3.8 Flash (Low)","quotaInfo":{"remainingFraction":1,"resetTime":"2099-01-01T05:00:00Z"}},
        "claude-opus-4-6-thinking":{"displayName":"Claude Opus 4.6 (Thinking)","quotaInfo":{"remainingFraction":0.7}},
        "claude-sonnet-4-6":{"quotaInfo":{"resetTime":"2099-01-01T03:00:00Z"}},
        "gemini-4-argon-disabled":{"displayName":"Gemini 4 Argon","disabled":true,"quotaInfo":{"remainingFraction":1}},
        "gemini-2.5-pro":{"displayName":"Gemini 2.5 Pro","quotaInfo":{"remainingFraction":1}},
        "gemini-3.1-flash-image":{"displayName":"Gemini 3.1 Flash Image"},
        "tab_flash_lite_preview":{"quotaInfo":{"remainingFraction":1}},
        "chat_20706":{"quotaInfo":{"remainingFraction":1}}},
        "defaultAgentModelId":"gemini-3.8-flash-high"}
        """

    /// retrieveUserQuotaSummary as Antigravity answers (Antigravity-Manager#3185).
    private static let summary = """
        {"groups":[
        {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.75,"resetTime":"2099-01-07T00:00:00Z","displayName":"Weekly Limit"},
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.9545545,"resetTime":"2099-01-01T05:00:00Z","displayName":"Five Hour Limit"}]},
        {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[
          {"bucketId":"3p-weekly","window":"weekly","resetTime":"2099-01-06T00:00:00Z"},
          {"bucketId":"3p-5h","window":"5h","remainingFraction":0.7,"resetTime":"2099-01-01T03:00:00Z"},
          {"bucketId":"3p-x","window":"5h","remainingFraction":1,"disabled":true}]}]}
        """

    private static let jan1at3 = Int64(Date(timeIntervalSince1970: 4_070_919_600).timeIntervalSince1970 * 1000)
    private static let jan1at5 = jan1at3 + 2 * 60 * 60 * 1000
    private static let jan6 = Int64(Date(timeIntervalSince1970: 4_071_340_800).timeIntervalSince1970 * 1000)
    private static let jan7 = jan6 + 24 * 60 * 60 * 1000

    @Test("The pools' 5 hours and week stand for their models' 5 hours, as Antigravity's own panel reads them (magpie PooledWindows)")
    func windows() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: Self.models),
            .response(status: 200, body: Self.summary),
        ])
        let reader = AntigravityUsageReader(hubVersion: hubVersion, refusedTiers: AntigravityRefusedTiers())
        let windows = try await reader.usage(credentials, using: client)
        let five = 5 * 60 * 60
        #expect(windows == [
            // Every model's 5 hours are its pool's 5 hours: none is listed
            // twice. The pools, each window under its pool's name; a bucket
            // with no fraction has none left, a disabled one is no window.
            OAuthUsageWindow(window: .sevenDay, usedPercent: 25, resetsAt: Self.jan7, windowSeconds: 7 * 24 * 60 * 60,
                             limitID: "gemini", limitName: "Gemini"),
            OAuthUsageWindow(window: .fiveHour, usedPercent: (1 - 0.9545545) * 100, resetsAt: Self.jan1at5, windowSeconds: five,
                             limitID: "gemini", limitName: "Gemini"),
            OAuthUsageWindow(window: .sevenDay, usedPercent: 100, resetsAt: Self.jan6, windowSeconds: 7 * 24 * 60 * 60,
                             limitID: "claude-gpt", limitName: "Claude & GPT"),
            OAuthUsageWindow(window: .fiveHour, usedPercent: (1 - 0.7) * 100, resetsAt: Self.jan1at3, windowSeconds: five,
                             limitID: "claude-gpt", limitName: "Claude & GPT"),
        ])

        // Asked as the Hub asks, of the daily host, with the paid plan named.
        #expect(client.requestCount == 2)
        #expect(client.requests[0].url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
        #expect(client.requests[0].method == "POST")
        #expect(client.header("Authorization", request: 0) == "Bearer tok")
        #expect(client.header("User-Agent", request: 0) == hubAgent)
        let asked = try jsonBody(client, request: 0)
        #expect(asked["project"] as? String == "aicode-consumers")
        #expect((asked["entitlement"] as? [String: String]) == ["userTier": "g1-pro-tier"])
        #expect(client.requests[1].url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        #expect(try jsonBody(client, request: 1) as? [String: String] == ["project": "aicode-consumers"])
    }

    @Test("Without a pool's 5 hours a model keeps its own: one whose pool has only its week, one named for a pool of its own, one no pool names")
    func pooled() throws {
        let five = 5 * 60 * 60
        func object(_ json: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let models = try object("""
            {"models":{
            "gemini-4-argon-high":{"displayName":"Gemini 4 Argon (High)","quotaInfo":{"remainingFraction":0.5}},
            "gemini-3.8-flash-high":{"displayName":"Gemini 3.8 Flash (High)","quotaInfo":{"remainingFraction":0.9}},
            "claude-opus-4-6-thinking":{"displayName":"Claude Opus 4.6 (Thinking)","quotaInfo":{"remainingFraction":0.7}},
            "mystery-1":{"displayName":"Mystery 1","quotaInfo":{"remainingFraction":0.2}}}}
            """)
        // Argon's own quota, a week only: its 5 hours stay, and the family's
        // pool doesn't take it. Claude's pool has only its week: Claude keeps
        // its 5 hours. Gemini's has its 5 hours, which stand for Flash's.
        let summary = try object("""
            {"groups":[
            {"displayName":"Gemini 4 Argon","buckets":[{"window":"weekly","remainingFraction":0.6}]},
            {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
              {"window":"5h","remainingFraction":0.9},{"window":"weekly","remainingFraction":0.8}]},
            {"displayName":"Claude and GPT models","description":"Claude Opus, Claude Sonnet, GPT-OSS","buckets":[
              {"window":"weekly","remainingFraction":0.4}]}]}
            """)
        let windows = AntigravityUsageReader.windows(models: models, summary: summary)
        #expect(windows.map { "\($0.limitID ?? "")/\($0.windowSeconds ?? 0)" } == [
            "claude-opus-4-6-thinking/\(five)", "gemini-4-argon-high/\(five)", "mystery-1/\(five)",
            "gemini-4-argon/604800", "gemini/\(five)", "gemini/604800", "claude-gpt/604800",
        ])
        // No summary: every model stands alone.
        #expect(AntigravityUsageReader.windows(models: models, summary: nil).count == 4)
        #expect(AntigravityUsageReader.vendor(id: "gpt-oss-120b-medium", name: "") == "GPT-OSS")
        #expect(AntigravityUsageReader.vendor(id: "x-1", name: "Mystery 1") == "Mystery")
    }

    @Test("A tier Google refuses with a 400 is left out, down to none, and not named again for a day (magpie #1553)")
    func tierRefused() async throws {
        let refused = AntigravityRefusedTiers()
        let reader = AntigravityUsageReader(hubVersion: hubVersion, refusedTiers: refused)
        let invalid = #"{"error":{"code":400,"message":"Request contains an invalid argument.","status":"INVALID_ARGUMENT"}}"#
        var client = QueuedHTTPClient([
            .response(status: 400, body: invalid),
            .response(status: 400, body: invalid),
            .response(status: 200, body: Self.models),
            .failure(URLError(.cannotConnectToHost)),
        ])
        let windows = try await reader.usage(credentials, using: client)
        // The summary could not be read: the models' windows stand alone.
        #expect(windows.count == 4)
        #expect(windows.allSatisfy { $0.window == .primary })
        #expect(client.requestCount == 4)
        #expect((try jsonBody(client, request: 0)["entitlement"] as? [String: String]) == ["userTier": "g1-pro-tier"])
        #expect((try jsonBody(client, request: 1)["entitlement"] as? [String: String]) == ["userTier": "standard-tier"])
        #expect(try jsonBody(client, request: 2)["entitlement"] == nil)

        // The next reading names neither refused tier.
        client = QueuedHTTPClient([.response(status: 200, body: Self.models), .response(status: 200, body: "{}")])
        _ = try await reader.usage(credentials, using: client)
        #expect(client.requestCount == 2)
        #expect(try jsonBody(client, request: 0)["entitlement"] == nil)

        // A free account names none to begin with.
        let free = OAuthCredentials(access: "t", refresh: "r", expires: .max, extras: ["projectId": "p", "tier": "free-tier"])
        client = QueuedHTTPClient([.response(status: 200, body: Self.models), .response(status: 200, body: "{}")])
        _ = try await reader.usage(free, using: client)
        #expect(try jsonBody(client, request: 0)["entitlement"] == nil)
        #expect(AntigravityOAuth.tiersToAsk(tier: "free-tier", paidTier: "free-tier") == [""])
        #expect(AntigravityOAuth.tiersToAsk(tier: "standard-tier", paidTier: "g1-ultra-tier") == ["g1-ultra-tier", "standard-tier", ""])
    }

    @Test("A login without a project, a 429 and a refusal read as no usage, not as a dead login")
    func failures() async throws {
        let reader = AntigravityUsageReader(hubVersion: hubVersion, refusedTiers: AntigravityRefusedTiers())
        await #expect(throws: OAuthUsageError.unavailable(
            providerId: "antigravity", status: nil, detail: "the Antigravity login names no Google Cloud project"
        )) {
            _ = try await reader.usage(OAuthCredentials(access: "t", refresh: "", expires: .max), using: QueuedHTTPClient([]))
        }
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 120)) {
            _ = try await reader.usage(credentials, using: QueuedHTTPClient([.response(status: 429, body: "{}")]))
        }
        await #expect(throws: OAuthUsageError.unavailable(providerId: "antigravity", status: 403, detail: "The caller does not have permission")) {
            _ = try await reader.usage(credentials, using: QueuedHTTPClient([.response(
                status: 403, body: #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#
            )]))
        }
    }

    @Test("Pool names are magpie's: 'models' dropped, 'and' an ampersand, the id a slug")
    func poolNames() {
        #expect(AntigravityUsageReader.poolName("Gemini Models") == "Gemini")
        #expect(AntigravityUsageReader.poolName("Claude and GPT models") == "Claude & GPT")
        #expect(AntigravityUsageReader.poolName("Gemini 4 Argon") == "Gemini 4 Argon")
        #expect(AntigravityUsageReader.poolID("Claude & GPT") == "claude-gpt")
        #expect(AntigravityUsageReader.poolID("Gemini 4 Argon") == "gemini-4-argon")
        // A bucket of another length keeps Google's name for it.
        let windows = AntigravityUsageReader.windows(models: [:], summary: [
            "groups": [["displayName": "Gemini 4 Argon", "buckets": [
                ["bucketId": "argon-daily", "window": "daily", "displayName": "Daily Limit", "remainingFraction": 0.5],
            ]]],
        ])
        #expect(windows == [OAuthUsageWindow(
            window: .secondary, usedPercent: 50, resetsAt: nil, windowSeconds: nil,
            limitID: "gemini-4-argon", limitName: "Gemini 4 Argon · Daily Limit"
        )])
    }
}
