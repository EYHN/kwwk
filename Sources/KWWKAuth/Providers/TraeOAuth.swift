import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Trae, ByteDance's IDE. It publishes no API: an account is signed in to the
// way its desktop client signs in, and its models are asked through the
// client's own gate (`TraeProvider`).
//
// The sign-in is the two-step loopback flow of the client: a page that calls
// back with an auth code, and an exchange of that code for a JWT and its
// refresh token. Every constant here is a client's own value, from captures
// of its login and from its `main.js` (`buildLoginUrl`,
// `exchangeTokenByAuthCode`, `_buildDeviceInfo`), as recorded by
// dsh-account-hub's `src/trae-cn-oauth.ts` and `src/trae-cn-product.ts` for
// the China build, and by cockpit-tools' `trae-intl-oauth.rs` and 10router's
// `trae-intl-oauth.js` for the international one. None is a secret: public
// client ids, the builds the page is asked for, the paths of the two
// `ExchangeToken` endpoints.
//
// Written for Apelin by JanXiao (owngoal-dev/Apelin#40), who ran both builds'
// sign-ins against live accounts, and brought here from there.

/// One Trae build. The China build and the international one are separate
/// services: the same sign-in and the same wire at their own hosts, with
/// their own accounts and models. A token of one is refused by the other.
public struct TraeSite: Sendable, Hashable {
    /// The `OAuthStore` key, and the `model.provider` scope.
    public let id: String
    public let name: String
    /// The origin of the build's remote gate: chats and the model directory
    /// hang off it.
    public let gateway: String
    /// The account gate a login is renewed at when it recorded none.
    public let accountGateway: String

    public init(id: String, name: String, gateway: String, accountGateway: String) {
        self.id = id
        self.name = name
        self.gateway = gateway
        self.accountGateway = accountGateway
    }

    /// The China build, which its users call Trae CN.
    public static let china = TraeSite(
        id: "trae",
        name: "Trae CN",
        gateway: "https://trae-api-cn.mchost.guru",
        accountGateway: "https://api.trae.cn"
    )
    /// The international build.
    public static let international = TraeSite(
        id: "trae-intl",
        name: "Trae",
        gateway: "https://core-normal.trae.ai",
        accountGateway: "https://core-normal.trae.ai"
    )
    public static let all: [TraeSite] = [.china, .international]

    public static func site(id: String) -> TraeSite? {
        all.first { $0.id == id }
    }
}

/// Constants and the pieces the sign-in, the renewal and the chat provider
/// share.
public enum TraeOAuth {
    static let clientID = "ono9krqynydwx5"

    static let authorizationPath = "/authorization"
    static let callbackPath = "/authorize"
    /// The sign-in's `ExchangeToken`, which is not the renewal's.
    static let signInExchangePath = "/trae/api/v3/oauth/ExchangeToken"
    static let renewalExchangePath = "/cloudide/api/v3/trae/oauth/ExchangeToken"

    /// The code a gate answers a token of the other build with, and a
    /// refresh token it no longer takes.
    static let invalidRefreshTokenCode = 20101

    // MARK: Extras

    /// The account's id: `UserID` of a renewal, `x-uid` of a request.
    public static let userIDExtra = "userId"
    /// The device id the sign-in registered, sent as `x-device-id`.
    public static let deviceIDExtra = "checkinDeviceId"
    /// The machine id the sign-in sent, sent again as `x-machine-id`.
    public static let machineIDExtra = "machineId"
    /// The account gate that accepted the sign-in, which its renewals go to:
    /// the international build has several and only one serves an account.
    public static let accountGatewayExtra = "oauthHost"

    // MARK: One build's values

    /// Everything one build's sign-in needs that the other's does not share.
    struct Profile: Sendable {
        let site: TraeSite
        /// Where the sign-in page is, when it is known without asking. Nil
        /// asks `GetLoginGuidance` first, as the international client does:
        /// its page is not one fixed host.
        let fixedLoginHost: String?
        /// The gates to ask for a sign-in host, in order.
        let guidanceURLs: [String]
        let pluginVersion: String
        let appVersion: String
        let appType: String
        let deviceBrand: String
        /// The `x_device_type` the page is told, also `DeviceInfo.OSInfo`.
        let osInfo: String
        let osVersion: String
        /// The page's `channel_name`; nil sends none, as the international
        /// client does.
        let channelName: String?
        /// The international client sends a UUID as its machine id; the
        /// China client 64 hex digits.
        let machineIDIsUUID: Bool
        /// A device id the client sends as a constant; nil generates one.
        let fixedDeviceID: String?
        /// The account gates the exchange may use, in order. A sign-in only
        /// reaches the one that serves its region, so every one is tried.
        let exchangeOrigins: [String]

        static let china = Profile(
            site: .china,
            fixedLoginHost: "https://www.trae.cn",
            guidanceURLs: [],
            pluginVersion: "2.3.83560",
            appVersion: "3.3.100",
            appType: "stable",
            deviceBrand: "",
            osInfo: "windows",
            osVersion: "Windows 10 Home",
            channelName: "common",
            machineIDIsUUID: false,
            fixedDeviceID: nil,
            exchangeOrigins: ["https://api.trae.cn"]
        )

        static let international = Profile(
            site: .international,
            fixedLoginHost: nil,
            guidanceURLs: [
                "https://api.marscode.com/cloudide/api/v3/trae/GetLoginGuidance",
                "https://api.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
                "https://www.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
            ],
            pluginVersion: "local",
            appVersion: "3.5.54",
            appType: "stable",
            deviceBrand: "unknown",
            osInfo: "unknown",
            osVersion: "unknown",
            channelName: nil,
            machineIDIsUUID: true,
            fixedDeviceID: "0",
            // The gates the client's `product.json` publishes for its account
            // service: the default, Singapore and the US one, then the ones
            // the API's own hosts serve.
            exchangeOrigins: [
                "https://grow-normal.trae.ai",
                "https://growsg-normal.trae.ai",
                "https://grow-normal.traeapi.us",
                "https://api.marscode.com",
                "https://api.trae.ai",
                "https://www.trae.ai",
            ]
        )

        static func of(_ site: TraeSite) -> Profile {
            site == .international ? .international : .china
        }
    }

    // MARK: The sign-in page

    /// Where a build's sign-in page is: the host it publishes, or the one
    /// `GetLoginGuidance` names. When no gate answers, the sign-in says so
    /// rather than opening a page that would not know the client.
    static func signInHost(
        profile: Profile,
        loginTraceID: String,
        client: HTTPClient
    ) async throws -> String {
        if let fixed = profile.fixedLoginHost { return fixed }
        let body = try JSONSerialization.data(
            withJSONObject: ["loginTraceID": loginTraceID, "login_trace_id": loginTraceID],
            options: [.sortedKeys]
        )
        var failures: [String] = []
        for address in profile.guidanceURLs {
            guard let url = URL(string: address) else { continue }
            do {
                let (response, data) = try await client.request(
                    url: url,
                    method: "POST",
                    headers: GateEnvelope.jsonHeaders,
                    body: body
                )
                guard response.statusCode == 200, let root = GateEnvelope.object(data),
                      let host = guidanceHost(root) else {
                    failures.append("\(address): no sign-in host")
                    continue
                }
                return host
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(address): \(error.localizedDescription)")
            }
        }
        throw OAuthError.transport(
            "\(profile.site.name)'s sign-in page could not be found (\(failures.joined(separator: "; ")))"
        )
    }

    /// `Result.LoginHost`, whichever spelling the gate answers with.
    static func guidanceHost(_ root: [String: Any]) -> String? {
        let keys = ["LoginHost", "loginHost", "LoginURL", "loginUrl"]
        for layer in ["Result", "result", "data"] {
            if let inner = root[layer] as? [String: Any], let host = GateEnvelope.firstString(inner, keys) {
                return host
            }
        }
        return GateEnvelope.firstString(root, keys)
    }

    /// `<host>/authorization?<query>`, its parameters in the order the client
    /// sends them, so a capture can be compared line for line.
    ///
    /// The spellings are load-bearing, and each fails the same silent way, a
    /// page that shows "authenticating" for ever with no error and no
    /// callback: `client_id` is snake_case here (and `ClientID` in the
    /// exchange body); `auth_type=local`, `login_channel=native_ide` and
    /// `login_version=1` must each be there; `code_challenge_method` is the
    /// literal `S256`.
    static func loginURL(
        loginHost: String,
        redirect: String,
        machineID: String,
        deviceID: String,
        loginTraceID: String,
        pkce: PKCE,
        profile: Profile
    ) throws -> URL {
        guard let origin = origin(of: loginHost),
              var components = URLComponents(string: origin + authorizationPath) else {
            throw OAuthError.invalidResponse("\(profile.site.name) named no sign-in page")
        }
        var items = [
            URLQueryItem(name: "login_version", value: "1"),
            URLQueryItem(name: "auth_from", value: "trae"),
            URLQueryItem(name: "login_channel", value: "native_ide"),
            URLQueryItem(name: "plugin_version", value: profile.pluginVersion),
            URLQueryItem(name: "auth_type", value: "local"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect", value: "0"),
            URLQueryItem(name: "login_trace_id", value: loginTraceID),
            URLQueryItem(name: "auth_callback_url", value: redirect),
            URLQueryItem(name: "machine_id", value: machineID),
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "x_device_id", value: deviceID),
            URLQueryItem(name: "x_machine_id", value: machineID),
            URLQueryItem(name: "x_device_brand", value: profile.deviceBrand),
            URLQueryItem(name: "x_device_type", value: profile.osInfo),
            URLQueryItem(name: "x_os_version", value: profile.osVersion),
            URLQueryItem(name: "x_env", value: ""),
            URLQueryItem(name: "x_app_version", value: profile.appVersion),
            URLQueryItem(name: "x_app_type", value: profile.appType),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let channelName = profile.channelName {
            items.append(URLQueryItem(name: "channel_name", value: channelName))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw OAuthError.invalidResponse("\(profile.site.name)'s sign-in address could not be built")
        }
        return url
    }

    // MARK: The callback

    /// What the page called back with.
    struct Callback: Sendable, Equatable {
        /// `authCodeInfo.AuthCode`, exchanged for the token.
        var authCode: String
        /// `userInfo.UserID`, empty when the page sent no user block.
        var userID: String
    }

    /// Reads `authCodeInfo` out of the callback's query.
    ///
    /// The page is dual-mode: with a `code_challenge` it hands back an
    /// `authCodeInfo` for the client to exchange, without one it calls
    /// `GetRefreshToken` itself and hands back `refreshToken`. The sign-in
    /// always asks with PKCE, so a callback without an auth code is a
    /// failure, not a second flow.
    static func callback(_ params: [String: String], site: TraeSite) throws -> Callback {
        guard let info = params["authCodeInfo"].flatMap({ GateEnvelope.object(Data($0.utf8)) }),
              let authCode = GateEnvelope.firstString(info, ["AuthCode", "authCode"]) else {
            throw OAuthError.invalidResponse("\(site.name)'s page returned no sign-in code")
        }
        let user = params["userInfo"].flatMap { GateEnvelope.object(Data($0.utf8)) } ?? [:]
        return Callback(
            authCode: authCode,
            userID: GateEnvelope.firstString(user, ["UserID", "UserId", "userId"]) ?? ""
        )
    }

    /// `access_denied` is the user leaving the page; any other error is the
    /// page's own refusal.
    static func checkCallbackError(_ params: [String: String], site: TraeSite) throws {
        guard let error = GateEnvelope.firstString(params, ["error", "error_code", "errorCode"]) else { return }
        if error == "access_denied" { throw OAuthLoginError.cancelled }
        let description = GateEnvelope.firstString(params, ["error_description", "error_desc", "message"])
        throw OAuthLoginError.denied("\(site.name) \(error)" + (description.map { ": \($0)" } ?? ""))
    }

    // MARK: The exchange

    /// A token as a gate gave it, at sign-in or renewal.
    struct Token: Sendable, Equatable {
        var access: String
        var refresh: String
        /// Unix ms of the access token's end, less the renewal margin;
        /// `.max` when neither the gate nor the token says one.
        var expires: Int64
    }

    /// The token in a gate's answer; nil when it carries none.
    static func token(_ root: [String: Any]) -> Token? {
        let result = (root["Result"] ?? root["result"]) as? [String: Any] ?? root
        guard let access = GateEnvelope.firstString(
            result,
            ["Token", "token", "AccessToken", "accessToken", "access_token"]
        ) else { return nil }
        return Token(
            access: access,
            refresh: GateEnvelope.firstString(result, ["RefreshToken", "refreshToken", "refresh_token"]) ?? "",
            expires: expiry(
                result["TokenExpireAt"] ?? result["tokenExpireAt"] ?? result["ExpiresAt"] ?? result["expiresAt"],
                access: access
            )
        )
    }

    /// `POST <gate>/trae/api/v3/oauth/ExchangeToken`, the body exactly the
    /// five fields the client sends. No `ClientSecret` and no `DeviceProof`:
    /// both belong to the renewal, and this endpoint refuses them.
    ///
    /// Every gate of the build is tried, and the one that answers ends the
    /// call and is kept for the renewals. The builds' accounts do not cross
    /// over, so a gate that answers 20101 is the other build's account and
    /// the failure says so.
    static func exchange(
        authCode: String,
        codeVerifier: String,
        machineID: String,
        deviceID: String,
        profile: Profile,
        client: HTTPClient,
        origins: [String]? = nil
    ) async throws -> (token: Token, origin: String) {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "ClientID": clientID,
                "AuthCode": authCode,
                "CodeVerifier": codeVerifier,
                "DeviceInfo": deviceInfo(machineID: machineID, deviceID: deviceID, profile: profile),
                "IDEVersion": profile.appVersion,
            ] as [String: Any],
            options: [.sortedKeys]
        )
        var headers = GateEnvelope.jsonHeaders
        headers["x-cloudide-token"] = ""

        var failures: [String] = []
        var otherBuild = false
        for origin in origins ?? profile.exchangeOrigins {
            guard let url = URL(string: origin + signInExchangePath) else { continue }
            do {
                let (response, answer) = try await client.request(
                    url: url,
                    method: "POST",
                    headers: headers,
                    body: body
                )
                guard let root = GateEnvelope.object(answer) else {
                    failures.append("\(origin): unreadable answer (HTTP \(response.statusCode))")
                    continue
                }
                if let refusal = refusal(root) {
                    if refusal.isInvalidRefreshToken { otherBuild = true }
                    failures.append("\(origin): \(refusal.message)")
                    continue
                }
                guard response.statusCode == 200 else {
                    failures.append("\(origin): HTTP \(response.statusCode)")
                    continue
                }
                guard let token = token(root) else {
                    failures.append("\(origin): no token")
                    continue
                }
                return (token, origin)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(origin): \(error.localizedDescription)")
            }
        }
        if otherBuild {
            let other: TraeSite = profile.site == .china ? .international : .china
            throw OAuthLoginError.denied(
                "this account belongs to the other Trae build; sign in to \(other.name) instead"
            )
        }
        throw OAuthLoginError.denied("\(profile.site.name): \(failures.joined(separator: "; "))")
    }

    /// The twelve fields the client sends. The ones it takes from the
    /// machine (brand, CPU, model) are empty rather than guessed, and the
    /// public key is a real EC P-256 SPKI PEM: the service validates it, and
    /// an empty one answers 400 "invalid parameter".
    static func deviceInfo(machineID: String, deviceID: String, profile: Profile) -> [String: Any] {
        [
            "DeviceID": deviceID,
            "MachineID": machineID,
            "PlatformCode": "IDE_PC",
            "DeviceType": "PC",
            "DeviceName": ProcessInfo.processInfo.hostName,
            "DeviceModel": profile.deviceBrand,
            "ClientVersion": profile.appVersion,
            "DevicePublicKey": P256.Signing.PrivateKey().publicKey.pemRepresentation,
            "DeviceBrand": profile.deviceBrand,
            "DeviceCPU": "",
            "OSInfo": profile.osInfo,
            "OSVersion": profile.osVersion,
        ]
    }

    // MARK: Small helpers

    /// A gate's refusal in its words, and whether it says the refresh token
    /// (or auth code) is not this gate's to take: the other build's, or one
    /// that is spent.
    static func refusal(_ root: [String: Any]) -> (message: String, isInvalidRefreshToken: Bool)? {
        guard let refusal = GateEnvelope.refusal(root) else { return nil }
        let message = refusal.said ?? "code \(refusal.code)"
        return (
            message,
            refusal.code == invalidRefreshTokenCode || message.lowercased().contains("refresh token is invalid")
        )
    }

    /// Sixteen decimal digits, the shape the China page checks its
    /// `device_id` for.
    static func randomDeviceID() -> String {
        (0..<16).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// `https://host[:port]` of an address a page or a gate named; nil when
    /// it names no host.
    static func origin(of address: String) -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty
        else { return nil }
        let scheme = components.scheme?.lowercased() ?? "https"
        guard let port = components.port else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// The user id a JWT carries, for a callback that sent no user block.
    static func jwtUserID(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return "" }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload), let claims = GateEnvelope.object(data) else { return "" }
        return GateEnvelope.firstString(claims, ["user_id", "userId", "uid", "sub", "UserID"]) ?? ""
    }

    /// When a token ends, as Unix ms less the renewal margin. `TokenExpireAt`
    /// is Unix seconds or milliseconds, or a date; an answer that says none
    /// is read from the JWT, and a token that says none either never lapses.
    static func expiry(_ raw: Any?, access: String) -> Int64 {
        func unix(_ value: Double) -> Int64 {
            let whole = Int64(value)
            return (whole > 1_000_000_000_000 ? whole : whole * 1000) - OAuth.expiryMarginMs
        }
        if let number = raw as? NSNumber, number.doubleValue > 0 {
            return unix(number.doubleValue)
        }
        if let text = raw as? String, !text.isEmpty {
            if let seconds = Double(text), seconds > 0 { return unix(seconds) }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                return Int64(date.timeIntervalSince1970 * 1000) - OAuth.expiryMarginMs
            }
        }
        return OAuth.jwtExpiryMillis(access) ?? .max
    }
}

// MARK: - Sign-in

extension OAuthLogin {
    /// Trae's browser sign-in, as its desktop client makes it:
    ///
    /// 1. make a PKCE pair, a machine id, a device id and a trace id;
    /// 2. ask `GetLoginGuidance` where the page is (international only);
    /// 3. listen on `127.0.0.1:<any port>/authorize` and open
    ///    `<host>/authorization`;
    /// 4. the page calls back with `authCodeInfo`, a JSON string holding
    ///    `AuthCode`, and `userInfo`;
    /// 5. `POST <gate>/trae/api/v3/oauth/ExchangeToken` answers the JWT and
    ///    its refresh token.
    public static func loginTrae(
        site: TraeSite,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let profile = TraeOAuth.Profile.of(site)
        let listener = try await openLoopback(
            callbacks,
            host: "127.0.0.1",
            port: 0,
            path: TraeOAuth.callbackPath
        )
        defer { listener.stop() }

        let pkce = PKCE.random()
        let machineID = profile.machineIDIsUUID ? UUID().uuidString : PKCE.randomHex(bytes: 32)
        let deviceID = profile.fixedDeviceID ?? TraeOAuth.randomDeviceID()
        let loginTraceID = UUID().uuidString

        callbacks.onProgress("requesting a \(site.name) sign-in page…")
        let page = try TraeOAuth.loginURL(
            loginHost: try await TraeOAuth.signInHost(
                profile: profile,
                loginTraceID: loginTraceID,
                client: client
            ),
            redirect: listener.redirectURI,
            machineID: machineID,
            deviceID: deviceID,
            loginTraceID: loginTraceID,
            pkce: pkce,
            profile: profile
        )
        callbacks.onProgress("Sign in to \(site.name) in your browser — this finishes by itself…")
        let params = try await present(page, callbacks: callbacks) {
            try await listener.waitForCallback()
        }
        try TraeOAuth.checkCallbackError(params, site: site)
        let callback = try TraeOAuth.callback(params, site: site)

        callbacks.onProgress("exchanging the sign-in code…")
        let exchanged = try await TraeOAuth.exchange(
            authCode: callback.authCode,
            codeVerifier: pkce.verifier,
            machineID: machineID,
            deviceID: deviceID,
            profile: profile,
            client: client
        )
        let token = exchanged.token
        var extras: [String: JSONValue] = [
            TraeOAuth.deviceIDExtra: .string(deviceID),
            TraeOAuth.machineIDExtra: .string(machineID),
            TraeOAuth.accountGatewayExtra: .string(exchanged.origin),
        ]
        let userID = callback.userID.isEmpty ? TraeOAuth.jwtUserID(token.access) : callback.userID
        if !userID.isEmpty { extras[TraeOAuth.userIDExtra] = .string(userID) }
        return OAuthCredentials(
            access: token.access,
            refresh: token.refresh,
            expires: token.expires,
            extras: extras
        )
    }
}

// MARK: - Renewal

/// Trades the refresh token for a fresh JWT as Trae's client does: `POST
/// <gate>/cloudide/api/v3/trae/oauth/ExchangeToken`, at the account gate the
/// sign-in recorded. The exchange rotates the refresh token.
public struct TraeOAuthProvider: OAuthProvider {
    public let site: TraeSite
    public var id: String { site.id }
    public var name: String { site.name }

    public init(site: TraeSite) {
        self.site = site
    }

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let gateway = GateEnvelope.string(credentials.extras[TraeOAuth.accountGatewayExtra]) ?? site.accountGateway
        let body = try JSONSerialization.data(
            withJSONObject: [
                "ClientID": TraeOAuth.clientID,
                "RefreshToken": credentials.refresh,
                "ClientSecret": "-",
                "UserID": GateEnvelope.string(credentials.extras[TraeOAuth.userIDExtra]) ?? "",
            ],
            options: [.sortedKeys]
        )
        let (response, answer) = try await OAuthRefreshError.post(
            provider: id,
            url: URL(string: gateway + TraeOAuth.renewalExchangePath)!,
            headers: GateEnvelope.jsonHeaders,
            body: body,
            client: client
        )
        func failed(_ kind: OAuthRefreshError.Kind, _ detail: String) -> OAuthRefreshError {
            OAuthRefreshError(providerId: id, kind: kind, status: response.statusCode, detail: detail)
        }
        guard let root = GateEnvelope.object(answer) else {
            throw failed(.unavailable, "\(site.name) gave an unreadable answer")
        }
        if let refusal = TraeOAuth.refusal(root) {
            // A refresh token the gate no longer takes ends the login; which
            // of its other codes do isn't known, so none of them parks it.
            throw failed(
                refusal.isInvalidRefreshToken ? .rejected : .unavailable,
                refusal.message
            )
        }
        guard let token = TraeOAuth.token(root) else {
            throw failed(.unavailable, "\(site.name) gave no refreshed token")
        }
        var refreshed = credentials
        refreshed.access = token.access
        if !token.refresh.isEmpty { refreshed.refresh = token.refresh }
        refreshed.expires = token.expires
        return refreshed
    }
}
