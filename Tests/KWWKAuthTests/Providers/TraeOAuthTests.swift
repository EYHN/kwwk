import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAuth

// The answers below are the shapes the two builds' gates give, from the
// captures JanXiao's sign-in for Apelin was written against
// (owngoal-dev/Apelin#40). The constants are the clients' own, so these pin
// what fails silently when it is wrong: `client_id` snake_case on the page
// and `ClientID` PascalCase in the exchange body, the parameters a page needs
// before it calls back at all, and the device block the service validates.

private let exchangeGiven = #"""
{"ResponseMetadata":{},"Result":{"BoundDeviceID":"wl2k1e2endpp32","ClientID":"ono9krqynydwx5","DeviceBindStatus":"BOUND","RefreshExpireAt":1805143893459,"RefreshToken":"refresh-1","Token":"jwt-1","TokenExpireAt":1790801493459,"UserJwt":"user-jwt"}}
"""#

private let invalidRefreshToken = #"{"Code":20101,"Message":"refresh token is invalid"}"#

private func ok(_ body: String) -> QueuedHTTPClient.Answer {
    .response(status: 200, body: body)
}

private func json(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func exchange(
    _ profile: TraeOAuth.Profile,
    _ client: QueuedHTTPClient,
    origins: [String]? = nil
) async throws -> (token: TraeOAuth.Token, origin: String) {
    try await TraeOAuth.exchange(
        authCode: "code-1",
        codeVerifier: "verifier",
        machineID: String(repeating: "a", count: 64),
        deviceID: "2996599860772203",
        profile: profile,
        client: client,
        origins: origins
    )
}

@Suite("Trae sign-in")
struct TraeSignInTests {
    // MARK: - The sign-in page

    @Test("The China page carries the client's parameters in its order")
    func chinaPage() throws {
        let url = try TraeOAuth.loginURL(
            loginHost: "https://www.trae.cn",
            redirect: "http://127.0.0.1:53692/authorize",
            machineID: String(repeating: "a", count: 64),
            deviceID: "2996599860772203",
            loginTraceID: "trace-1",
            pkce: PKCE(verifier: "verifier", challenge: "challenge"),
            profile: .china
        )
        #expect(url.absoluteString.hasPrefix("https://www.trae.cn/authorization?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == [
            "login_version", "auth_from", "login_channel", "plugin_version", "auth_type",
            "client_id", "redirect", "login_trace_id", "auth_callback_url", "machine_id",
            "device_id", "x_device_id", "x_machine_id", "x_device_brand", "x_device_type",
            "x_os_version", "x_env", "x_app_version", "x_app_type", "code_challenge",
            "code_challenge_method", "channel_name",
        ])
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        // snake_case here: a page that cannot find it shows "authenticating"
        // for ever.
        #expect(values["client_id"] == "ono9krqynydwx5")
        #expect(values["clientID"] == nil)
        // Each of these, missing, is a page that neither errors nor calls back.
        #expect(values["auth_type"] == "local")
        #expect(values["login_channel"] == "native_ide")
        #expect(values["login_version"] == "1")
        #expect(values["plugin_version"] == "2.3.83560")
        #expect(values["x_app_version"] == "3.3.100")
        // `S256`, not `SHA-256`: the page compares the literal.
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["code_challenge"] == "challenge")
        #expect(values["auth_callback_url"] == "http://127.0.0.1:53692/authorize")
        #expect(values["redirect"] == "0")
        #expect(values["channel_name"] == "common")
        #expect(values["x_device_type"] == "windows")
        #expect(values["device_id"] == values["x_device_id"])
        #expect(values["machine_id"] == values["x_machine_id"])
    }

    @Test("The international page carries that build's values, at the host it was told")
    func internationalPage() throws {
        let url = try TraeOAuth.loginURL(
            loginHost: "www.trae.ai",
            redirect: "http://127.0.0.1:53692/authorize",
            machineID: "0F8B2A4C-1D3E-4A5B-9C7D-2E1F0A3B4C5D",
            deviceID: "0",
            loginTraceID: "trace-1",
            pkce: PKCE(verifier: "verifier", challenge: "challenge"),
            profile: .international
        )
        #expect(url.absoluteString.hasPrefix("https://www.trae.ai/authorization?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(values["plugin_version"] == "local")
        #expect(values["x_app_version"] == "3.5.54")
        #expect(values["x_device_brand"] == "unknown")
        #expect(values["x_device_type"] == "unknown")
        #expect(values["x_os_version"] == "unknown")
        #expect(values["device_id"] == "0")
        #expect(values["machine_id"] == "0F8B2A4C-1D3E-4A5B-9C7D-2E1F0A3B4C5D")
        // It sends no channel name, and the China one does.
        #expect(values["channel_name"] == nil)
        #expect(values["client_id"] == "ono9krqynydwx5")
    }

    @Test("A device id is sixteen decimal digits")
    func deviceID() {
        for _ in 0..<20 {
            let device = TraeOAuth.randomDeviceID()
            #expect(device.count == 16)
            #expect(device.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }

    // MARK: - The sign-in host

    @Test("The China build's page is fixed; the international one asks each gate until one names it")
    func signInHost() async throws {
        let none = QueuedHTTPClient([])
        #expect(try await TraeOAuth.signInHost(profile: .china, loginTraceID: "t", client: none)
            == "https://www.trae.cn")
        #expect(none.requestCount == 0)

        let client = QueuedHTTPClient([
            .response(status: 503, body: "busy"),
            ok(#"{"Result":{"LoginHost":"https://www.trae.ai"}}"#),
        ])
        #expect(try await TraeOAuth.signInHost(profile: .international, loginTraceID: "trace-1", client: client)
            == "https://www.trae.ai")
        #expect(client.requests.map(\.url.absoluteString) == [
            "https://api.marscode.com/cloudide/api/v3/trae/GetLoginGuidance",
            "https://api.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
        ])
        #expect(client.requests[1].method == "POST")
        #expect(try json(client.requests[1].body) as? [String: String]
            == ["loginTraceID": "trace-1", "login_trace_id": "trace-1"])

        // Either spelling, at either depth.
        #expect(TraeOAuth.guidanceHost(["loginHost": "www.trae.ai"]) == "www.trae.ai")
        #expect(TraeOAuth.guidanceHost(["Result": ["loginUrl": "https://www.trae.ai"]]) == "https://www.trae.ai")
        #expect(TraeOAuth.guidanceHost(["nothing": 1]) == nil)
    }

    @Test("A sign-in whose gates name no page fails rather than opening one that would not know the client")
    func noSignInHost() async {
        let client = QueuedHTTPClient(Array(repeating: ok("{}"), count: 3))
        await #expect(throws: OAuthError.self) {
            _ = try await TraeOAuth.signInHost(profile: .international, loginTraceID: "t", client: client)
        }
        #expect(client.requestCount == 3)
    }

    // MARK: - The callback

    @Test("The callback is read from authCodeInfo, with the user block beside it")
    func callback() throws {
        let callback = try TraeOAuth.callback([
            "authCodeInfo": #"{"AuthCode":"code-1","ExpireAt":1790801493459}"#,
            "userInfo": #"{"UserID":"user-1","ScreenName":"someone"}"#,
            "loginTraceID": "trace-1",
        ], site: .china)
        #expect(callback == TraeOAuth.Callback(authCode: "code-1", userID: "user-1"))
    }

    @Test("A callback without an auth code is refused rather than half-read")
    func callbackWithoutCode() {
        // The page's non-PKCE branch hands back a refresh token instead.
        for params in [["refreshToken": "refresh-1"], ["authCodeInfo": "not json"], [:]] {
            #expect(throws: OAuthError.self) { try TraeOAuth.callback(params, site: .china) }
        }
    }

    @Test("access_denied ends the sign-in cancelled; any other error is the page's refusal")
    func callbackError() throws {
        try TraeOAuth.checkCallbackError(["authCodeInfo": "{}"], site: .china)
        #expect(throws: OAuthLoginError.cancelled) {
            try TraeOAuth.checkCallbackError(["error": "access_denied"], site: .china)
        }
        #expect(throws: OAuthLoginError.denied("Trae CN server_error: try again")) {
            try TraeOAuth.checkCallbackError(["error_code": "server_error", "message": "try again"], site: .china)
        }
    }

    // MARK: - The exchange

    @Test("The exchange posts the five fields and reads the token, its end and the bound device")
    func exchangeBody() async throws {
        let client = QueuedHTTPClient([ok(exchangeGiven)])
        let exchanged = try await exchange(.china, client)
        #expect(exchanged.origin == "https://api.trae.cn")
        #expect(exchanged.token == TraeOAuth.Token(
            access: "jwt-1",
            refresh: "refresh-1",
            expires: 1_790_801_493_459 - 5 * 60 * 1000,
            boundDeviceID: "wl2k1e2endpp32"
        ))

        let request = client.requests[0]
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.trae.cn/trae/api/v3/oauth/ExchangeToken")
        #expect(request.headers == [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "x-cloudide-token": "",
        ])
        let body = try json(request.body)
        // PascalCase in the body, where the page's query is snake_case.
        #expect(Set(body.keys) == ["ClientID", "AuthCode", "CodeVerifier", "DeviceInfo", "IDEVersion"])
        #expect(body["ClientID"] as? String == "ono9krqynydwx5")
        #expect(body["AuthCode"] as? String == "code-1")
        #expect(body["CodeVerifier"] as? String == "verifier")
        #expect(body["IDEVersion"] as? String == "3.3.100")
        let device = try #require(body["DeviceInfo"] as? [String: Any])
        #expect(Set(device.keys) == [
            "DeviceID", "MachineID", "PlatformCode", "DeviceType", "DeviceName", "DeviceModel",
            "ClientVersion", "DevicePublicKey", "DeviceBrand", "DeviceCPU", "OSInfo", "OSVersion",
        ])
        #expect(device["DeviceID"] as? String == "2996599860772203")
        #expect(device["MachineID"] as? String == String(repeating: "a", count: 64))
        #expect(device["PlatformCode"] as? String == "IDE_PC")
        #expect(device["OSInfo"] as? String == "windows")
        // An empty key answers 400 "invalid parameter", so it must be real.
        let key = try #require(device["DevicePublicKey"] as? String)
        #expect(key.hasPrefix("-----BEGIN PUBLIC KEY-----"))
        #expect((try? P256.Signing.PublicKey(pemRepresentation: key)) != nil)
    }

    @Test("The international exchange falls through its gates to the one that answers, and keeps it")
    func exchangeFallsThrough() async throws {
        let client = QueuedHTTPClient([
            .response(status: 502, body: "<html>"),
            ok(#"{"Code":10101,"Message":"invalid parameter"}"#),
            ok(#"{"Result":{"AccessToken":"jwt-intl","RefreshToken":"refresh-intl","ExpiresAt":1790801493}}"#),
        ])
        let exchanged = try await exchange(.international, client)
        #expect(exchanged.token.access == "jwt-intl")
        #expect(exchanged.token.refresh == "refresh-intl")
        // Seconds are read as seconds.
        #expect(exchanged.token.expires == 1_790_801_493_000 - 5 * 60 * 1000)
        #expect(exchanged.origin == "https://grow-normal.traeapi.us")
        #expect(client.requests.map(\.url.host) == [
            "grow-normal.trae.ai", "growsg-normal.trae.ai", "grow-normal.traeapi.us",
        ])
        #expect(try json(client.requests[0].body)["IDEVersion"] as? String == "3.5.54")
    }

    @Test("An account of the other build is named as that, not as a failed exchange", arguments: [
        (TraeSite.china, "Trae"), (TraeSite.international, "Trae CN"),
    ])
    func otherBuild(site: TraeSite, other: String) async {
        let client = QueuedHTTPClient([ok(invalidRefreshToken)])
        await #expect(throws: OAuthLoginError.denied(
            "this account belongs to the other Trae build; sign in to \(other) instead"
        )) {
            _ = try await exchange(.of(site), client, origins: ["https://gate.example"])
        }
    }

    @Test("A refusal is read from the envelope and said in the gate's words")
    func refused() async {
        let client = QueuedHTTPClient([ok(#"{"Code":10101,"Message":"invalid parameter"}"#)])
        await #expect(throws: OAuthLoginError.denied("Trae CN: https://api.trae.cn: invalid parameter")) {
            _ = try await exchange(.china, client)
        }
    }

    @Test("A token's end is read as seconds, milliseconds or a date, else from the JWT, else never")
    func expiry() {
        let margin: Int64 = 5 * 60 * 1000
        // As a gate's JSON gives them.
        #expect(TraeOAuth.expiry(NSNumber(value: 1_790_801_493), access: "") == 1_790_801_493_000 - margin)
        #expect(TraeOAuth.expiry(NSNumber(value: 1_790_801_493_459 as Int64), access: "")
            == 1_790_801_493_459 - margin)
        #expect(TraeOAuth.expiry("1790801493", access: "") == 1_790_801_493_000 - margin)
        #expect(TraeOAuth.expiry("2026-10-01T00:00:00Z", access: "") == 1_790_812_800_000 - margin)
        #expect(TraeOAuth.expiry(nil, access: jwt(["exp": 1_790_801_493])) == 1_790_801_493_000 - margin)
        #expect(TraeOAuth.expiry(nil, access: "opaque") == .max)
    }

    @Test("A JWT whose callback carried no user block still names its account")
    func jwtUser() {
        #expect(TraeOAuth.jwtUserID(jwt(["user_id": "user-1"])) == "user-1")
        #expect(TraeOAuth.jwtUserID("not-a-jwt") == "")
    }

    // MARK: - The whole flow

    @Test("The sign-in listens on any port at /authorize, opens the page with that address, and keeps what renewals and requests need")
    func wholeFlow() async throws {
        let client = QueuedHTTPClient([ok(exchangeGiven)])
        let presenter = RecordingPresenter()
        let made = MadeLoopback()
        var callbacks = quietCallbacksBase
        callbacks.browser = presenter
        callbacks.loopback = { host, port, path in
            let loopback = ScriptedLoopback(
                // What a listener asked for port 0 names once it is bound.
                host: host,
                port: port == 0 ? 49_152 : port,
                path: path,
                params: [
                    "authCodeInfo": #"{"AuthCode":"code-1"}"#,
                    "userInfo": #"{"UserID":"user-1"}"#,
                ],
                echoState: false
            )
            made.set(loopback, asked: (host, port, path))
            return loopback
        }
        let credentials = try await OAuthLogin.loginTrae(site: .china, callbacks: callbacks, client: client)

        let asked = try #require(made.asked)
        #expect(asked.host == "127.0.0.1")
        #expect(asked.port == 0)
        #expect(asked.path == "/authorize")
        #expect(made.loopback?.listened == true)
        #expect(made.loopback?.stopped == true)

        let page = try #require(presenter.shown.first)
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
        )
        #expect(page.host == "www.trae.cn")
        #expect(query["auth_callback_url"] == "http://127.0.0.1:49152/authorize")
        let machineID = try #require(query["machine_id"])
        let deviceID = try #require(query["device_id"])
        #expect(machineID.count == 64 && machineID.allSatisfy(\.isHexDigit))
        #expect(deviceID.count == 16)

        // The page's challenge is the verifier the exchange sent, hashed.
        let body = try json(client.requests[0].body)
        let verifier = try #require(body["CodeVerifier"] as? String)
        #expect(query["code_challenge"] == PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        #expect((body["DeviceInfo"] as? [String: Any])?["MachineID"] as? String == machineID)

        #expect(credentials.access == "jwt-1")
        #expect(credentials.refresh == "refresh-1")
        #expect(credentials.expires == 1_790_801_493_459 - 5 * 60 * 1000)
        #expect(credentials.extras == [
            "userId": .string("user-1"),
            "deviceId": .string("wl2k1e2endpp32"),
            "checkinDeviceId": .string(deviceID),
            "machineId": .string(machineID),
            "oauthHost": .string("https://api.trae.cn"),
        ])
    }
}

private final class MadeLoopback: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loopback: ScriptedLoopback?
    private(set) var asked: (host: String, port: UInt16, path: String)?

    func set(_ loopback: ScriptedLoopback, asked: (String, UInt16, String)) {
        lock.withLock {
            self.loopback = loopback
            self.asked = asked
        }
    }
}

@Suite("Trae renewal")
struct TraeRenewalTests {
    private let stored = OAuthCredentials(
        access: "jwt-old",
        refresh: "refresh-old",
        expires: 0,
        extras: [
            "userId": .string("user-1"),
            "machineId": .string("machine-1"),
            "checkinDeviceId": .string("device-1"),
            "oauthHost": .string("https://grow-normal.traeapi.us"),
        ]
    )

    @Test("A renewal goes to the gate the sign-in recorded, rotates the refresh token and keeps the account")
    func renews() async throws {
        let client = QueuedHTTPClient([
            ok(#"{"Result":{"Token":"jwt-new","RefreshToken":"refresh-new","TokenExpireAt":1790801493459}}"#),
        ])
        let renewed = try await TraeOAuthProvider(site: .international).refresh(stored, using: client)

        let request = client.requests[0]
        #expect(request.method == "POST")
        #expect(request.url.absoluteString
            == "https://grow-normal.traeapi.us/cloudide/api/v3/trae/oauth/ExchangeToken")
        #expect(request.headers == ["Content-Type": "application/json", "Accept": "application/json"])
        #expect(try json(request.body) as? [String: String] == [
            "ClientID": "ono9krqynydwx5",
            "RefreshToken": "refresh-old",
            "ClientSecret": "-",
            "UserID": "user-1",
        ])

        #expect(renewed.access == "jwt-new")
        #expect(renewed.refresh == "refresh-new")
        #expect(renewed.expires == 1_790_801_493_459 - 5 * 60 * 1000)
        #expect(renewed.extras == stored.extras)
    }

    @Test("A login that recorded no gate is renewed at its build's own, and keeps a refresh token the gate did not rotate")
    func defaultGate() async throws {
        var credentials = stored
        credentials.extras["oauthHost"] = nil
        let client = QueuedHTTPClient([ok(#"{"Result":{"Token":"jwt-new"}}"#)])
        let renewed = try await TraeOAuthProvider(site: .china).refresh(credentials, using: client)
        #expect(client.requests[0].url.host == "api.trae.cn")
        #expect(renewed.refresh == "refresh-old")
        #expect(renewed.expires == .max)
    }

    @Test("A refresh token the gate no longer takes ends the login; any other refusal may pass")
    func refusals() async {
        func kind(_ answer: QueuedHTTPClient.Answer) async -> OAuthRefreshError.Kind? {
            do {
                _ = try await TraeOAuthProvider(site: .china).refresh(stored, using: QueuedHTTPClient([answer]))
                return nil
            } catch {
                return (error as? OAuthRefreshError)?.kind
            }
        }
        #expect(await kind(ok(invalidRefreshToken)) == .rejected)
        #expect(await kind(.response(status: 401, body: "{}")) == .rejected)
        #expect(await kind(ok(#"{"Code":10000,"Message":"busy"}"#)) == .unavailable)
        #expect(await kind(ok("{}")) == .unavailable)
        #expect(await kind(ok("<html>")) == .unavailable)
        #expect(await kind(.response(status: 503, body: "")) == .unavailable)
        #expect(await kind(.failure(URLError(.timedOut))) == .unavailable)
    }
}
