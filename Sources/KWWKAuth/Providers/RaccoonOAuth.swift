import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Raccoon (xiaohuanxiong.com), SenseTime's office assistant. It is apart from
// SenseTime's model platform (token.sensenova.cn): its own accounts, its own
// gate, its own credits. An account is signed in to the way Raccoon's desktop
// client signs in, by the portal's authorisation page, and its models are
// asked on the gate that client uses (`RaccoonProvider`).
//
// The values are the desktop client's own, as recorded by dsh-providers-hub's
// `raccoon-adapter.ts` and `raccoon-product.ts`. Written for Apelin by
// JanXiao (owngoal-dev/Apelin#40), who ran the sign-in and a chat against a
// live account, and brought here from there.

/// Constants and the pieces the sign-in, the renewal and the chat provider
/// share.
public enum RaccoonOAuth {
    /// The `OAuthStore` key, and the `model.provider` scope.
    public static let providerId = "raccoon"
    public static let name = "Raccoon"

    public static let origin = "https://xiaohuanxiong.com"
    /// The sign-in by authorisation code, and the renewal.
    static let authBase = origin + "/api/web/auth/v1"
    static let callbackPath = "/auth/callback"
    /// The name the page reports the client as: the desktop client's own.
    static let appName = "办公小浣熊客户端"

    /// `office_identity`, which every request carries as `X-Org-Code`. It
    /// comes back from the sign-in and cannot be derived.
    public static let officeIdentityExtra = "officeIdentity"

    /// `<origin>/code/authorize`, which answers 307 to the page that signs
    /// the account in.
    ///
    /// `login_source` is `desktop`: the page chooses its client by it. Left
    /// to itself the page then navigates to `office-raccoon://auth/callback`,
    /// a scheme only the desktop client handles: a browser stays on the
    /// signed-in view and the code is lost. Naming a loopback `redirect`
    /// with `desktop_callback=loopback` makes the page deliver the code over
    /// http instead, the mode the client's own page offers for this case.
    static func authorizeURL(state: String, redirect: String) -> URL {
        var components = URLComponents(string: origin + "/code/authorize")!
        components.queryItems = [
            URLQueryItem(name: "login_source", value: "desktop"),
            URLQueryItem(name: "appname", value: appName),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect", value: redirect),
            URLQueryItem(name: "desktop_callback", value: "loopback"),
        ]
        return components.url!
    }

    /// The authorisation code the page came back with. A redirect that names
    /// another state is not this sign-in's; one that names none is taken,
    /// since the code itself is single-use.
    static func code(_ params: [String: String], state: String) throws -> String {
        let code = (params["code"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw OAuthError.invalidResponse("\(name)'s page returned no sign-in code")
        }
        if let returned = params["state"], !returned.isEmpty, returned != state {
            throw OAuthError.invalidResponse("\(name)'s page returned another sign-in's code")
        }
        return code
    }

    // MARK: Answers

    /// A token as the gate gave it, at sign-in or renewal.
    struct Token: Sendable, Equatable {
        var access: String
        var refresh: String
        /// Unix ms of the access token's end, less the renewal margin;
        /// `.max` when neither the gate nor the token says one.
        var expires: Int64
        var officeIdentity: String
    }

    /// The token in the gate's answer; nil when it carries none.
    static func token(_ root: [String: Any]) -> Token? {
        let data = (root["data"] ?? root["Data"]) as? [String: Any] ?? root
        guard let access = GateEnvelope.firstString(data, ["access_token", "accessToken"]) else { return nil }
        return Token(
            access: access,
            refresh: GateEnvelope.firstString(data, ["refresh_token", "refreshToken"]) ?? "",
            expires: expiry(data["expires_at"] ?? data["expiresAt"] ?? data["exp"], access: access),
            officeIdentity: GateEnvelope.firstString(data, ["office_identity", "officeIdentity"]) ?? ""
        )
    }

    /// The gate's refusal in words, and whether it says the token is
    /// refused or has ended, which only a new sign-in mends.
    static func refusal(_ root: [String: Any]) -> (message: String, endsLogin: Bool)? {
        guard let refusal = GateEnvelope.refusal(root) else { return nil }
        return (
            meaning(of: refusal.code) ?? refusal.said ?? "code \(refusal.code)",
            [200001, 200003, 200012].contains(refusal.code)
        )
    }

    /// The gate's business codes, in words. A code not known here keeps the
    /// gate's own.
    static func meaning(of code: Int) -> String? {
        switch code {
        case 200001: "Raccoon refused this token; sign in again"
        case 200003, 200012: "the Raccoon sign-in has expired; sign in again"
        case 200009: "this Raccoon account is disabled"
        case 200035: "that sign-in code was not found or has already been used; sign in again"
        case 200402: "this Raccoon account has no credits left"
        case 200429: "Raccoon is rate limiting this account"
        default: nil
        }
    }

    /// `expires_at` is Unix seconds or milliseconds; an answer that says
    /// none is read from the token, and a token that says none never lapses.
    static func expiry(_ raw: Any?, access: String) -> Int64 {
        guard let number = raw as? NSNumber, number.doubleValue > 0 else {
            return OAuth.jwtExpiryMillis(access) ?? .max
        }
        let whole = Int64(number.doubleValue)
        return (whole > 1_000_000_000_000 ? whole : whole * 1000) - OAuth.expiryMarginMs
    }

    static func credentials(_ token: Token, keeping base: OAuthCredentials? = nil) -> OAuthCredentials {
        var extras = base?.extras ?? [:]
        // A renewal that does not name the office keeps the sign-in's.
        if !token.officeIdentity.isEmpty { extras[officeIdentityExtra] = .string(token.officeIdentity) }
        return OAuthCredentials(
            access: token.access,
            // The gate rotates the refresh token; one it does not answer
            // with is the one that was sent.
            refresh: token.refresh.isEmpty ? (base?.refresh ?? "") : token.refresh,
            expires: token.expires,
            extras: extras
        )
    }
}

// MARK: - Sign-in

extension OAuthLogin {
    /// Raccoon's web-authorisation sign-in, as its desktop client makes it:
    ///
    /// 1. listen on `127.0.0.1:<any port>/auth/callback` and open the
    ///    portal's authorisation page, which signs the account in (a phone
    ///    number, WeChat or a QR code, its choice);
    /// 2. the page comes back to the loopback with `code` and `state`;
    /// 3. `POST /api/web/auth/v1/login_with_authorization_code` answers the
    ///    access token, its refresh token and the office identity that
    ///    gates the account's calls.
    ///
    /// The page takes a loopback redirect only with a state of sixty-four
    /// hex digits and a port above 1023.
    public static func loginRaccoon(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let name = RaccoonOAuth.name
        let listener = try await openLoopback(
            callbacks,
            host: "127.0.0.1",
            port: 0,
            path: RaccoonOAuth.callbackPath
        )
        defer { listener.stop() }

        let state = PKCE.randomHex(bytes: 32)
        let page = RaccoonOAuth.authorizeURL(state: state, redirect: listener.redirectURI)
        callbacks.onProgress("Sign in to \(name) in your browser — this finishes by itself…")
        let params = try await present(page, callbacks: callbacks) {
            try await listener.waitForCallback()
        }
        try checkCallbackError(params, provider: name)
        let code = try RaccoonOAuth.code(params, state: state)

        callbacks.onProgress("exchanging the sign-in code…")
        let (response, answer) = try await client.request(
            url: URL(string: RaccoonOAuth.authBase + "/login_with_authorization_code")!,
            method: "POST",
            headers: GateEnvelope.jsonHeaders,
            body: try JSONSerialization.data(withJSONObject: ["authorization_code": code])
        )
        guard let root = GateEnvelope.object(answer) else {
            throw OAuthError.invalidResponse("\(name) gave an unreadable answer (HTTP \(response.statusCode))")
        }
        if let refusal = RaccoonOAuth.refusal(root) {
            throw OAuthLoginError.denied("\(name): \(refusal.message)")
        }
        guard response.statusCode == 200, let token = RaccoonOAuth.token(root) else {
            throw OAuthError.invalidResponse("\(name) gave no token (HTTP \(response.statusCode))")
        }
        return RaccoonOAuth.credentials(token)
    }
}

// MARK: - Renewal

/// Trades the refresh token for a fresh access token: `POST
/// /api/web/auth/v1/refresh`. (Not `/refresh_token`, which answers 404.) The
/// gate rotates the refresh token on every renewal.
public struct RaccoonOAuthProvider: OAuthProvider {
    public let id = RaccoonOAuth.providerId
    public let name = RaccoonOAuth.name

    public init() {}

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let (response, answer) = try await OAuthRefreshError.post(
            provider: id,
            url: URL(string: RaccoonOAuth.authBase + "/refresh")!,
            headers: GateEnvelope.jsonHeaders,
            body: try JSONSerialization.data(withJSONObject: ["refresh_token": credentials.refresh]),
            client: client
        )
        func failed(_ kind: OAuthRefreshError.Kind, _ detail: String) -> OAuthRefreshError {
            OAuthRefreshError(providerId: id, kind: kind, status: response.statusCode, detail: detail)
        }
        guard let root = GateEnvelope.object(answer) else {
            throw failed(.unavailable, "\(name) gave an unreadable answer")
        }
        if let refusal = RaccoonOAuth.refusal(root) {
            throw failed(refusal.endsLogin ? .rejected : .unavailable, refusal.message)
        }
        guard let token = RaccoonOAuth.token(root) else {
            throw failed(.unavailable, "\(name) gave no refreshed token")
        }
        return RaccoonOAuth.credentials(token, keeping: credentials)
    }
}
