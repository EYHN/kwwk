import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

// Kiro (AWS) subscription auth, ported from magpie's `provider/kiro.go` and
// `provider/kiro_signin.go`.
//
// Kiro signs in on its own page, app.kiro.dev, the way the Kiro IDE does:
// the page offers Google, GitHub, AWS Builder ID and IAM Identity Center and
// sends the browser back to a port on this machine. Google and GitHub come
// back with a code Kiro's auth service trades for tokens. Builder ID and
// Identity Center come back with where to sign in at AWS, which is then done
// with an OIDC client registered for this sign-in, as the IDE does.
//
// The stored credentials keep, in `extras`, the fields magpie keeps in its
// `kiro-auth-token.json` (the IDE's shape): `authMethod` (`social` | `IdC`),
// `provider`, `region`, `profileArn`, and for an AWS sign-in the registered
// client's `clientId` / `clientSecret`, which its refresh needs.

/// Constants and credential readers for Kiro's sign-in and management API.
public enum KiroOAuth {
    /// Kiro's sign-in page.
    public static let portalURL = URL(string: "https://app.kiro.dev/signin")!
    /// Kiro's auth service, which trades a Google or GitHub code for tokens.
    public static let authServiceURL = "https://prod.us-east-1.auth.desktop.kiro.dev"
    /// The ports Kiro's sign-in page sends the browser back to, the IDE's.
    public static let callbackPorts: [UInt16] = [3128, 4649, 6588, 8008, 9091, 49153, 50153, 51153, 52153, 53153]
    /// The paths the page and AWS come back on.
    public static let callbackPaths: Set<String> = ["/oauth/callback", "/signin/callback"]
    /// What the IDE asks AWS for.
    public static let scopes = [
        "codewhisperer:completions", "codewhisperer:analysis", "codewhisperer:conversations",
        "codewhisperer:transformations", "codewhisperer:taskassist",
    ]
    /// A Builder ID sign-in has no profile of its own, and Kiro won't list one
    /// for it (List-Available-Profiles is a 403, "AWS Builder ID is not
    /// supported for this operation"); the Kiro IDE and kiro-cli name this
    /// service profile for it instead, so its models, usage and chat are
    /// asked with it too (magpie #422).
    public static let builderIDProfile = "arn:aws:codewhisperer:us-east-1:638616132270:profile/AAAACCCCXXXX"

    /// How the desktop app names itself when it refreshes a social sign-in.
    static let desktopUserAgent = "Kiro-Desktop/0.2.13 (darwin; arm64)"
    /// How the IDE names itself to Kiro's auth service and AWS's sign-in: its
    /// version, then a machine id (a SHA-256, here of this host's name).
    static let ideUserAgent: String = {
        var name = [CChar](repeating: 0, count: 256)
        let host = gethostname(&name, name.count - 1) == 0
            ? String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        let digest = SHA256.hash(data: Data("kwwk:\(host)".utf8))
        return "KiroIDE-1.1.70-" + digest.map { String(format: "%02x", $0) }.joined()
    }()

    static func oidcURL(region: String) -> String { "https://oidc.\(region).amazonaws.com" }
    static func refreshURL(region: String) -> String { "https://prod.\(region).auth.desktop.kiro.dev/refreshToken" }
    /// Kiro's management API in a region: profiles, models, usage.
    package static func managementURL(region: String) -> String { "https://management.\(region).kiro.dev/" }

    /// An AWS region as it may stand in a host name. The region of an AWS
    /// sign-in arrives in the callback's query, so it is checked before a
    /// URL is built from it.
    static func isRegion(_ text: String) -> Bool {
        text.range(of: #"^[a-z]{2}(-[a-z]+)+-[0-9]+$"#, options: .regularExpression) != nil
    }

    // MARK: - Reading stored credentials

    static func extra(_ credentials: OAuthCredentials, _ key: String) -> String? {
        guard case .string(let value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }

    /// The profile ARN every Kiro call names, when the login holds one.
    public static func profileArn(_ credentials: OAuthCredentials) -> String? {
        extra(credentials, "profileArn")
    }

    /// The region the login signed in at, where its token is refreshed.
    public static func signInRegion(_ credentials: OAuthCredentials) -> String {
        extra(credentials, "region") ?? "us-east-1"
    }

    /// Where the account's API is: the region its profile is in, else the
    /// nearest of Kiro's two to where it signed in (magpie `kiroRegion`).
    public static func apiRegion(_ credentials: OAuthCredentials) -> String {
        apiRegion(profile: profileArn(credentials) ?? "", signedIn: signInRegion(credentials))
    }

    static func apiRegion(profile: String, signedIn: String) -> String {
        let parts = profile.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 4, !parts[3].isEmpty { return String(parts[3]) }
        return signedIn.hasPrefix("eu-") ? "eu-central-1" : "us-east-1"
    }

    /// Unix ms a token answered with `expiresIn` seconds lasts until, less
    /// the 5-minute margin every other expiry here carries. Kiro's answers
    /// may omit the lifetime; an hour then, as magpie takes it.
    static func expiry(_ expiresIn: Int) -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return now + Int64(expiresIn > 0 ? expiresIn : 3600) * 1000 - OAuth.expiryMarginMs
    }

    // MARK: - Profile

    /// The profile a sign-in that doesn't name one uses: Builder ID's, or the
    /// first Kiro lists in either of its regions (magpie `kiroProfile`).
    static func resolveProfile(
        access: String,
        authMethod: String,
        provider: String,
        client: HTTPClient
    ) async throws -> String {
        if provider.lowercased() == "builderid" { return builderIDProfile }
        var last = "Kiro has no profile for this sign-in"
        for region in ["us-east-1", "eu-central-1"] {
            let response: HTTPURLResponse
            let body: Data
            do {
                (response, body) = try await client.request(
                    url: URL(string: managementURL(region: region) + "List-Available-Profiles")!,
                    method: "POST",
                    headers: [
                        "Authorization": "Bearer \(access)",
                        "Accept": "application/json",
                        "Content-Type": "application/json",
                    ],
                    body: Data("{}".utf8)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A region that cannot be reached is no answer; the other is
                // still asked, as magpie asks it.
                last = "Kiro: \(error.localizedDescription)"
                continue
            }
            let text = String(decoding: body, as: UTF8.self)
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            guard (200..<300).contains(response.statusCode) else {
                // A Builder ID sign-in the page didn't say was one.
                if authMethod == "IdC", response.statusCode == 403, text.contains("Builder ID") {
                    return builderIDProfile
                }
                if let message = object?["message"] as? String, !message.isEmpty {
                    last = "Kiro: \(message) (\(response.statusCode))"
                } else {
                    last = "Kiro: HTTP \(response.statusCode)"
                }
                continue
            }
            for profile in object?["profiles"] as? [[String: Any]] ?? [] {
                if let arn = profile["arn"] as? String, !arn.isEmpty { return arn }
            }
        }
        throw OAuthError.invalidResponse(last)
    }
}

// MARK: - Sign-in

/// One request the browser made to the sign-in's port: Kiro's page coming
/// back, or AWS's.
public struct KiroCallback: Sendable {
    public var path: String
    public var params: [String: String]
    /// Answers the browser. Called once per callback.
    public var reply: @Sendable (KiroCallbackReply) -> Void

    public init(path: String, params: [String: String], reply: @escaping @Sendable (KiroCallbackReply) -> Void) {
        self.path = path
        self.params = params
        self.reply = reply
    }
}

/// What the browser is answered with.
public enum KiroCallbackReply: Sendable, Equatable {
    /// A page that ends the browser's part, or turns a stray request away.
    case page(succeeded: Bool, title: String, message: String)
    /// On to AWS's own sign-in.
    case redirect(URL)
}

/// The loopback listener of a Kiro sign-in.
///
/// It differs from `OAuthLoopbackListener` because the sign-in does: Kiro's
/// page chooses the path it comes back on, an AWS sign-in's first callback
/// carries no code and is answered with a redirect, and AWS then comes back
/// to the same port a second time.
public protocol KiroLoopbackListener: AnyObject, Sendable {
    /// Bind the first free port of `ports` on 127.0.0.1 and return it.
    func listen(ports: [UInt16]) async throws -> UInt16
    /// The next request on one of `KiroOAuth.callbackPaths`.
    func nextCallback() async throws -> KiroCallback
    /// Release the port. Idempotent.
    func stop()
}

extension OAuthLogin {
    /// Sign in to Kiro on app.kiro.dev (magpie `startKiroSignIn` /
    /// `kiroCallback`). A company's own identity provider is not offered:
    /// magpie leaves that one to `kiro-cli login`, and so does this.
    public static func loginKiro(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient(),
        listener: any KiroLoopbackListener = KiroCallbackServer()
    ) async throws -> OAuthCredentials {
        let port = try await listener.listen(ports: KiroOAuth.callbackPorts)
        defer { listener.stop() }
        let pkce = PKCE.random()
        let state = PKCE.randomHex(bytes: 24)
        // The page appends the path itself, so the redirect names none.
        let redirect = "http://localhost:\(port)"

        var comps = URLComponents(url: KiroOAuth.portalURL, resolvingAgainstBaseURL: false)!
        // Encoded as a form, the redirect's `:` and `/` escaped, as the IDE's
        // own link is (`URLQueryItem` would leave them bare).
        comps.percentEncodedQuery = OAuth.urlEncodedForm([
            "state": state,
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
            "redirect_uri": redirect,
            "redirect_from": "KiroIDE",
        ])
        callbacks.onProgress("Sign in to Kiro in your browser — waiting for the callback on \(redirect)…")
        return try await present(comps.url!, callbacks: callbacks) {
            try await kiroAwaitSignIn(
                listener: listener,
                port: port,
                redirect: redirect,
                state: state,
                verifier: pkce.verifier,
                callbacks: callbacks,
                client: client
            )
        }
    }

    /// An AWS sign-in, once Kiro's page has sent the browser on to it.
    private struct KiroAWSStep {
        var region: String
        var clientId: String
        var clientSecret: String
        var provider: String
        var state: String
        var verifier: String
    }

    /// Answers the browser's callbacks until one of them ends the sign-in.
    private static func kiroAwaitSignIn(
        listener: any KiroLoopbackListener,
        port: UInt16,
        redirect: String,
        state: String,
        verifier: String,
        callbacks: Callbacks,
        client: HTTPClient
    ) async throws -> OAuthCredentials {
        // Where AWS sends the browser back.
        let awsRedirect = "http://127.0.0.1:\(port)/oauth/callback"
        var aws: KiroAWSStep?
        while true {
            let callback = try await listener.nextCallback()
            let query = callback.params
            do {
                try checkCallbackError(query, provider: "kiro")
                // What the sign-in is kept as, beside its tokens.
                let authMethod: String
                let provider: String
                var extras: [String: JSONValue] = [:]
                let tokens: [String: Any]
                if let step = aws, query["state"] == step.state {
                    // Back from AWS.
                    guard let code = query["code"], !code.isEmpty else {
                        throw OAuthError.invalidResponse("AWS sent back no code")
                    }
                    callbacks.onProgress("exchanging the AWS authorization code for Kiro tokens…")
                    tokens = try await kiroSignInPost(
                        KiroOAuth.oidcURL(region: step.region) + "/token",
                        body: [
                            "clientId": step.clientId, "clientSecret": step.clientSecret,
                            "grantType": "authorization_code", "redirectUri": awsRedirect,
                            "code": code, "codeVerifier": step.verifier,
                        ],
                        client: client
                    )
                    (authMethod, provider) = ("IdC", step.provider)
                    extras = [
                        "region": .string(step.region),
                        "clientId": .string(step.clientId), "clientSecret": .string(step.clientSecret),
                    ]
                } else if query["state"] != state {
                    // Not ours: someone else's page, or a stale tab.
                    callback.reply(.page(
                        succeeded: false,
                        title: "This link isn't from kwwk's sign-in",
                        message: "Start it again from kwwk."
                    ))
                    continue
                } else {
                    let option = query["login_option"] ?? ""
                    switch option {
                    case "google", "github":
                        callbacks.onProgress("exchanging the authorization code for Kiro tokens…")
                        tokens = try await kiroSignInPost(
                            KiroOAuth.authServiceURL + "/oauth/token",
                            body: [
                                "code": query["code"] ?? "", "code_verifier": verifier,
                                "redirect_uri": "\(redirect)\(callback.path)?login_option=\(option)",
                            ],
                            client: client
                        )
                        (authMethod, provider) = ("social", option == "google" ? "Google" : "Github")
                        extras = ["region": "us-east-1"]
                        if let profile = tokens["profileArn"] as? String, !profile.isEmpty {
                            extras["profileArn"] = .string(profile)
                        }
                    case "builderid", "awsidc", "internal":
                        // On to AWS, with a client registered for this sign-in.
                        guard let issuer = query["issuer_url"], !issuer.isEmpty,
                              let region = query["idc_region"], KiroOAuth.isRegion(region) else {
                            throw OAuthError.invalidResponse("Kiro's page didn't say where to sign in at AWS")
                        }
                        let registered = try await kiroSignInPost(
                            KiroOAuth.oidcURL(region: region) + "/client/register",
                            body: [
                                "clientName": "Kiro IDE", "clientType": "public",
                                "scopes": KiroOAuth.scopes,
                                "grantTypes": ["authorization_code", "refresh_token"],
                                "redirectUris": ["http://127.0.0.1/oauth/callback"],
                                "issuerUrl": issuer,
                            ],
                            client: client
                        )
                        guard let clientId = registered["clientId"] as? String, !clientId.isEmpty else {
                            throw OAuthError.invalidResponse("AWS registered no client")
                        }
                        let pkce = PKCE.random()
                        let step = KiroAWSStep(
                            region: region,
                            clientId: clientId,
                            clientSecret: registered["clientSecret"] as? String ?? "",
                            provider: option == "builderid" ? "BuilderId" : option == "awsidc" ? "Enterprise" : "Internal",
                            state: PKCE.randomHex(bytes: 24),
                            verifier: pkce.verifier
                        )
                        aws = step
                        var authorize = URLComponents(string: KiroOAuth.oidcURL(region: region) + "/authorize")!
                        authorize.percentEncodedQuery = OAuth.urlEncodedForm([
                            "response_type": "code",
                            "client_id": clientId,
                            "redirect_uri": awsRedirect,
                            // AWS's authorize page takes them as `scopes`, comma-joined.
                            "scopes": KiroOAuth.scopes.joined(separator: ","),
                            "state": step.state,
                            "code_challenge": pkce.challenge,
                            "code_challenge_method": "S256",
                        ])
                        callback.reply(.redirect(authorize.url!))
                        continue
                    case "external_idp":
                        throw OAuthLoginError.denied(
                            "kwwk can't sign in to Kiro with a company's own identity provider"
                        )
                    default:
                        throw OAuthError.invalidResponse(
                            "Kiro's page came back with a sign-in kwwk doesn't know (\"\(option)\")"
                        )
                    }
                }
                guard let access = tokens["accessToken"] as? String, !access.isEmpty else {
                    throw OAuthError.invalidResponse("\(authMethod == "IdC" ? "AWS" : "Kiro") sent back no token")
                }
                extras["authMethod"] = .string(authMethod)
                extras["provider"] = .string(provider)
                if extras["profileArn"] == nil {
                    extras["profileArn"] = .string(try await KiroOAuth.resolveProfile(
                        access: access,
                        authMethod: authMethod,
                        provider: provider,
                        client: client
                    ))
                }
                callback.reply(.page(
                    succeeded: true,
                    title: "You're signed in",
                    message: "Kiro is added to kwwk. You can close this tab."
                ))
                return OAuthCredentials(
                    access: access,
                    refresh: tokens["refreshToken"] as? String ?? "",
                    expires: KiroOAuth.expiry(tokens["expiresIn"] as? Int ?? 0),
                    extras: extras
                )
            } catch {
                callback.reply(.page(
                    succeeded: false,
                    title: "Sign-in didn't finish",
                    message: error.displayDescription
                ))
                throw error
            }
        }
    }

    /// Posts JSON to Kiro's auth service or AWS's sign-in, as the IDE.
    private static func kiroSignInPost(
        _ url: String,
        body: [String: Any],
        client: HTTPClient
    ) async throws -> [String: Any] {
        guard let endpoint = URL(string: url) else {
            throw OAuthError.invalidResponse("the Kiro sign-in named an address that is not a URL")
        }
        let (response, data) = try await client.request(
            url: endpoint,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": KiroOAuth.ideUserAgent,
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            let said = ["error_description", "message", "error"]
                .compactMap { object?[$0] as? String }.first { !$0.isEmpty }
            throw OAuthError.refreshFailed(
                "the Kiro sign-in was refused (\(response.statusCode)): \(said ?? "HTTP \(response.statusCode)")"
            )
        }
        guard let object else {
            throw OAuthError.invalidResponse("could not decode the Kiro sign-in response")
        }
        return object
    }
}

// MARK: - Refresh

/// Refreshes a Kiro login the way its sign-in is refreshed (magpie
/// `refreshKiro`): a Google or GitHub one at Kiro's auth service, an AWS one
/// (Builder ID, Identity Center) at AWS's OIDC token endpoint with the client
/// registered at sign-in. Both answer in camelCase and may rotate the
/// refresh token.
public struct KiroOAuthProvider: OAuthProvider {
    public let id = "kiro"
    public let name = "Kiro"

    public init() {}

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let region = KiroOAuth.signInRegion(credentials)
        var extras = credentials.extras
        let url: String
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        let body: [String: String]
        if KiroOAuth.extra(credentials, "authMethod") == "IdC",
           let clientId = KiroOAuth.extra(credentials, "clientId") {
            url = KiroOAuth.oidcURL(region: region) + "/token"
            body = [
                "clientId": clientId,
                "clientSecret": KiroOAuth.extra(credentials, "clientSecret") ?? "",
                "refreshToken": credentials.refresh,
                "grantType": "refresh_token",
            ]
        } else {
            url = KiroOAuth.refreshURL(region: region)
            headers["User-Agent"] = KiroOAuth.desktopUserAgent
            body = ["refreshToken": credentials.refresh]
        }
        // The region is read from the stored login. One that gives no URL
        // is a login no refresh can use: a sign-in to make again, like a
        // refused grant.
        guard let endpoint = URL(string: url) else {
            throw OAuthRefreshError(
                providerId: id,
                kind: .rejected,
                status: nil,
                detail: "the stored Kiro login names a region that is not one; sign in again"
            )
        }
        let (response, data) = try await OAuthRefreshError.post(
            provider: id,
            url: endpoint,
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body),
            client: client
        )
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = object["accessToken"] as? String, !access.isEmpty else {
            throw OAuthRefreshError(
                providerId: id,
                kind: .unavailable,
                status: response.statusCode,
                detail: "kiro refresh missing accessToken"
            )
        }
        // A social refresh may name the profile anew.
        if let profile = object["profileArn"] as? String, !profile.isEmpty {
            extras["profileArn"] = .string(profile)
        }
        let rotated = object["refreshToken"] as? String ?? ""
        return OAuthCredentials(
            access: access,
            refresh: rotated.isEmpty ? credentials.refresh : rotated,
            expires: KiroOAuth.expiry(object["expiresIn"] as? Int ?? 0),
            extras: extras
        )
    }
}

// MARK: - Usage

/// `GET https://management.<region>.kiro.dev/Get-Usage-Limits`, the call
/// kiro-cli's `/usage` reads (magpie `kiroUsageLimits`). A plan's allowance
/// is a monthly count of credits; a free trial, while it runs, is a second
/// allowance with its own expiry.
public struct KiroUsageReader: OAuthUsageReader {
    public let providerId = "kiro"

    public init() {}

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        guard let profile = KiroOAuth.profileArn(credentials) else {
            throw OAuthUsageError.unavailable(
                providerId: providerId,
                status: nil,
                detail: "the Kiro login names no profile"
            )
        }
        let query = OAuth.urlEncodedForm([
            "origin": "KIRO_CLI", "profileArn": profile, "resourceType": "CREDIT", "isEmailRequired": "true",
        ])
        let base = KiroOAuth.managementURL(region: KiroOAuth.apiRegion(credentials))
        guard let url = URL(string: "\(base)Get-Usage-Limits?\(query)") else {
            throw OAuthUsageError.unavailable(
                providerId: providerId,
                status: nil,
                detail: "the Kiro login's profile names a region that is not one"
            )
        }
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
                providerId: providerId,
                status: response.statusCode,
                detail: "undecodable body"
            )
        }
        return Self.windows(from: payload)
    }

    /// The credits used of each allowance: a free trial's while it runs
    /// (`secondary`), then the month's (`primary`). Rows without a limit are
    /// not allowances.
    public static func windows(from payload: [String: Any]) -> [OAuthUsageWindow] {
        func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        func millis(_ seconds: Double) -> Int64? { seconds > 0 ? Int64(seconds) * 1000 : nil }
        var out: [OAuthUsageWindow] = []
        for row in payload["usageBreakdownList"] as? [[String: Any]] ?? [] {
            if let trial = row["freeTrialInfo"] as? [String: Any],
               (trial["freeTrialStatus"] as? String)?.uppercased() == "ACTIVE" {
                let limit = number(trial["usageLimitWithPrecision"])
                if limit > 0 {
                    out.append(OAuthUsageWindow(
                        window: .secondary,
                        usedPercent: 100 * number(trial["currentUsageWithPrecision"]) / limit,
                        resetsAt: millis(number(trial["freeTrialExpiry"])),
                        windowSeconds: nil,
                        limitID: "free_trial",
                        limitName: "Free trial"
                    ))
                }
            }
            let limit = number(row["usageLimitWithPrecision"])
            guard limit > 0 else { continue }
            let name = [row["displayNamePlural"], row["displayName"]]
                .compactMap { $0 as? String }.first { !$0.isEmpty } ?? "Credits"
            let reset = number(row["nextDateReset"])
            out.append(OAuthUsageWindow(
                window: .primary,
                usedPercent: 100 * number(row["currentUsageWithPrecision"]) / limit,
                resetsAt: millis(reset != 0 ? reset : number(payload["nextDateReset"])),
                windowSeconds: 30 * 24 * 60 * 60,
                limitName: name
            ))
        }
        return out
    }
}
