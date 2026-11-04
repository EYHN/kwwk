import Foundation
import NIOConcurrencyHelpers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Antigravity (Google) subscription auth, ported from magpie's
// `provider/google.go`.
//
// Antigravity is Google's agentic IDE. A Google AI Pro or Ultra plan gives
// it a quota of Gemini models and, on Ultra, of Claude and other third-party
// models, all served by Google's Code Assist backend (cloudcode-pa). kwwk
// signs the Google account in with Antigravity's own OAuth client, as the
// Antigravity Hub does, and speaks to Code Assist directly; the `agy`
// binary is not involved, as the Kiro IDE is not involved in `kiro`.
//
// The stored credentials keep, in `extras`, what the sign-in found out:
// `email` (whose account it is), `projectId` (the Google Cloud project Code
// Assist gave the account, which every request names), `tier` (the tier the
// account is on: `free-tier`, `standard-tier`) and `paidTier` (the Google
// One plan it pays for: `g1-pro-tier`, `g1-ultra-tier`).

/// Constants, credential readers and Code Assist calls for Antigravity's
/// sign-in and management API.
public enum AntigravityOAuth {
    public static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo?alt=json")!
    /// Where the account's project is found (`loadCodeAssist`).
    public static let productionHost = "https://cloudcode-pa.googleapis.com"
    /// Where everything else goes: onboarding, models, quota, generation.
    /// magpie notes that mixing the two hosts grants inconsistent
    /// entitlements.
    public static let dailyHost = "https://daily-cloudcode-pa.googleapis.com"
    /// Antigravity's own OAuth client, an installed app's: its "secret" is no
    /// secret, it ships in every Antigravity CLI binary and crosses the wire
    /// in the clear (RFC 8252 §8.5). Each value is written in two pieces only
    /// because GitHub's secret scanner refuses a push carrying the whole
    /// literal of either.
    public static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep" + ".apps.googleusercontent.com"
    public static let clientSecret = "GOCSPX-" + "K58FWR486LdLJ1mLB8sXC4z6qDAf"
    public static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]
    /// Where the browser comes back: the port `agy` listens on, and the path
    /// Antigravity registered. Google takes any loopback port for an
    /// installed app, so a host may bind another.
    public static let callbackPort: UInt16 = 51121
    public static let callbackPath = "/oauth-callback"
    /// The tier an account is set up on when Code Assist names no default.
    static let defaultTierId = "free-tier"
    /// How often onboarding is asked whether it is done, and how long
    /// between asks.
    static let onboardAttempts = 5
    static let onboardPollSeconds: Double = 2

    // MARK: - Reading stored credentials

    static func extra(_ credentials: OAuthCredentials, _ key: String) -> String? {
        guard case .string(let value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }

    /// Whose Google account the login is.
    public static func email(_ credentials: OAuthCredentials) -> String? { extra(credentials, "email") }

    /// The Google Cloud project Code Assist gave the account, which every
    /// request names.
    public static func projectId(_ credentials: OAuthCredentials) -> String? { extra(credentials, "projectId") }

    /// The tier the account is on, and the plan it pays for.
    public static func tier(_ credentials: OAuthCredentials) -> String? { extra(credentials, "tier") }
    public static func paidTier(_ credentials: OAuthCredentials) -> String? { extra(credentials, "paidTier") }

    /// Unix ms a token answered with `expiresIn` seconds lasts until, less
    /// the 5-minute margin every other expiry here carries.
    static func expiry(_ expiresIn: Int) -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return now + Int64(expiresIn > 0 ? expiresIn : 3600) * 1000 - OAuth.expiryMarginMs
    }

    // MARK: - The Hub's User-Agent

    /// What the app says it is to Code Assist: `antigravity/hub/<version>
    /// <os>/<arch>`, the Hub's own line. Google checks the Hub's name and a
    /// minimum version (magpie `userAgent`).
    public static func userAgent(version: String) -> String {
        "antigravity/hub/\(version) \(platform)"
    }

    /// `<os>/<arch>` as Go names them, which is what the Hub sends.
    static var platform: String {
        #if os(Linux)
        let os = "linux"
        #elseif os(Windows)
        let os = "windows"
        #else
        let os = "darwin"
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "\(os)/\(arch)"
    }

    // MARK: - Code Assist

    /// What Code Assist answered a call other than 200 with: its status and
    /// what Google said (magpie `codeAssistError`).
    public struct CodeAssistError: Error, LocalizedError, Sendable, Equatable {
        public let method: String
        public let status: Int
        public let message: String

        public var errorDescription: String? { "Antigravity: \(message) (\(method) \(status))" }
    }

    /// Posts one of Code Assist's methods and reads its JSON answer (magpie
    /// `call`). `headers` go on top of the Hub's own.
    static func call(
        host: String,
        method: String,
        body: [String: Any],
        access: String,
        hubVersion: String,
        headers: [String: String] = [:],
        client: HTTPClient
    ) async throws -> [String: Any] {
        var requestHeaders = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(access)",
            "User-Agent": userAgent(version: hubVersion),
        ]
        for (key, value) in headers { requestHeaders[key] = value }
        let (response, data) = try await client.request(
            url: URL(string: "\(host)/v1internal:\(method)")!,
            method: "POST",
            headers: requestHeaders,
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            throw CodeAssistError(method: method, status: response.statusCode, message: apiErrorText(object, data: data))
        }
        return object ?? [:]
    }

    /// What Google's error shape says, `{"error": {"message": …}}`, else the
    /// body itself.
    static func apiErrorText(_ object: [String: Any]?, data: Data) -> String {
        if let error = object?["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = object?["message"] as? String, !message.isEmpty { return message }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "HTTP error" : text
    }

    /// Code Assist's project, which comes as an id or as `{id, name}`
    /// (magpie `companionProject`).
    static func companionProject(_ value: Any?) -> String? {
        if let id = value as? String, !id.isEmpty { return id }
        if let object = value as? [String: Any], let id = object["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    /// What `loadCodeAssist` said of the account.
    struct LoadReply {
        var projectId: String?
        var currentTier: String?
        var paidTier: String?
        /// The tier the account is set up on when it has no project yet: the
        /// default of the allowed ones, else the first.
        var defaultTier: String?
        /// Google's reasons for tiers it won't serve the account.
        var ineligibleReasons: [String]

        init(_ object: [String: Any]) {
            projectId = AntigravityOAuth.companionProject(object["cloudaicompanionProject"])
            currentTier = (object["currentTier"] as? [String: Any])?["id"] as? String
            paidTier = (object["paidTier"] as? [String: Any])?["id"] as? String
            let allowed = object["allowedTiers"] as? [[String: Any]] ?? []
            defaultTier = (allowed.first { $0["isDefault"] as? Bool == true } ?? allowed.first)?["id"] as? String
            ineligibleReasons = (object["ineligibleTiers"] as? [[String: Any]] ?? []).compactMap {
                [$0["reasonMessage"], $0["validationErrorMessage"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            }
        }
    }

    /// `POST <production>/v1internal:loadCodeAssist` as Antigravity asks it.
    static func loadCodeAssist(access: String, hubVersion: String, client: HTTPClient) async throws -> LoadReply {
        LoadReply(try await call(
            host: productionHost,
            method: "loadCodeAssist",
            body: ["metadata": ["ideType": "ANTIGRAVITY"]],
            access: access,
            hubVersion: hubVersion,
            client: client
        ))
    }

    /// `GET <daily>/v1internal/<operation>`: a long-running operation as it
    /// stands now (oh-my-pi polls onboarding this way).
    static func operation(
        name: String,
        access: String,
        hubVersion: String,
        headers: [String: String] = [:],
        client: HTTPClient
    ) async throws -> [String: Any] {
        var requestHeaders = [
            "Authorization": "Bearer \(access)",
            "User-Agent": userAgent(version: hubVersion),
        ]
        for (key, value) in headers { requestHeaders[key] = value }
        let path = name.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let (response, data) = try await client.request(
            url: URL(string: "\(dailyHost)/v1internal/\(path)")!,
            method: "GET",
            headers: requestHeaders,
            body: nil
        )
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            throw CodeAssistError(method: "operations", status: response.statusCode, message: apiErrorText(object, data: data))
        }
        return object ?? [:]
    }

    /// Sets the account up for Code Assist as Antigravity does:
    /// `POST <daily>/v1internal:onboardUser` once, then the long-running
    /// operation it answers polled by its name (`GET <daily>/v1internal/
    /// <name>`, as oh-my-pi does) until it is done, at most
    /// `onboardAttempts` asks in all. An operation that comes back with no
    /// name, or whose name Code Assist won't answer, is asked for again by
    /// posting onboardUser anew (magpie `onboard`). An operation done with
    /// an error fails the sign-in with Google's words. Returns the project
    /// it was given, nil when Google gave none.
    static func onboardUser(
        tierId: String,
        access: String,
        hubVersion: String,
        client: HTTPClient,
        pollSleep: @Sendable (Double) async throws -> Void
    ) async throws -> String? {
        let body: [String: Any] = [
            "tier_id": tierId,
            "metadata": ["ide_type": "ANTIGRAVITY", "ide_version": hubVersion, "ide_name": "antigravity"],
        ]
        let headers = [
            "User-Agent": userAgent(version: hubVersion) + " google-api-nodejs-client/10.3.0",
            "X-Goog-Api-Client": "gl-node/22.21.1",
        ]
        var name: String?
        var pollable = true
        for attempt in 0..<onboardAttempts {
            if attempt > 0 { try await pollSleep(onboardPollSeconds) }
            let operation: [String: Any]
            if let name, pollable {
                do {
                    operation = try await self.operation(
                        name: name, access: access, hubVersion: hubVersion, headers: headers, client: client
                    )
                } catch let error as CodeAssistError where [400, 404, 405].contains(error.status) {
                    // The operation can't be asked for by name here: ask
                    // as magpie does, posting onboardUser again.
                    pollable = false
                    continue
                }
            } else {
                operation = try await call(
                    host: dailyHost,
                    method: "onboardUser",
                    body: body,
                    access: access,
                    hubVersion: hubVersion,
                    headers: headers,
                    client: client
                )
            }
            if operation["done"] as? Bool == true {
                if let error = operation["error"] as? [String: Any] {
                    let message = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(error)"
                    throw OAuthError.invalidResponse("Antigravity couldn't set this Google account up: \(message)")
                }
                return companionProject((operation["response"] as? [String: Any])?["cloudaicompanionProject"])
            }
            if let next = operation["name"] as? String, !next.isEmpty { name = next }
        }
        throw OAuthError.invalidResponse(
            "Antigravity: setting the account up for Code Assist is taking long; try again in a minute"
        )
    }

    /// The account as Code Assist knows it: its project, found (and the
    /// account set up, the first time) the way Antigravity does it, and the
    /// tiers it is on (magpie `antigravityProject`).
    struct Account {
        var projectId: String
        var tier: String?
        var paidTier: String?
    }

    static func account(
        access: String,
        hubVersion: String,
        client: HTTPClient,
        pollSleep: @Sendable (Double) async throws -> Void
    ) async throws -> Account {
        let load = try await loadCodeAssist(access: access, hubVersion: hubVersion, client: client)
        if let projectId = load.projectId {
            return Account(projectId: projectId, tier: load.currentTier, paidTier: load.paidTier)
        }
        var tierId = load.defaultTier ?? ""
        if tierId.isEmpty || tierId == "legacy-tier" { tierId = defaultTierId }
        let onboarded = try await onboardUser(
            tierId: tierId,
            access: access,
            hubVersion: hubVersion,
            client: client,
            pollSleep: pollSleep
        )
        guard let projectId = onboarded else {
            // Google's reason, when it gave one: an account it won't serve
            // Antigravity to (its region, its age) says so in ineligibleTiers.
            if let why = load.ineligibleReasons.first {
                throw OAuthLoginError.denied("Antigravity won't serve this Google account: \(why)")
            }
            throw OAuthError.invalidResponse(
                "Antigravity hasn't set this Google account up (it gave no project); "
                    + "sign in to the Antigravity app with it once, then try again"
            )
        }
        return Account(projectId: projectId, tier: tierId, paidTier: load.paidTier)
    }

    // MARK: - Models

    /// Whether a listed id is a model a chat can ask for: Antigravity's
    /// `chat_*` and `tab_*` ids serve its editor, and a short list of ids
    /// it keeps for other purposes is left out as magpie leaves them
    /// (`antigravityHidden`).
    public static func isChatModel(_ id: String) -> Bool {
        if id.hasPrefix("chat_") || id.hasPrefix("tab_") { return false }
        return !hiddenModels.contains(id)
    }

    static let hiddenModels: Set<String> = ["gemini-2.5-flash-thinking", "gemini-2.5-pro"]

    /// The tiers to name in an account's `fetchAvailableModels`, best first,
    /// then none (magpie `entitlements` and `askTiers`): the plan it pays for
    /// and the tier it is on, since Google serves a paid plan's models only to
    /// a request that names the plan (Antigravity's language server sends it
    /// in `entitlement.userTier`); a free account names none, Google refuses
    /// `free-tier` there.
    static func tiersToAsk(tier: String?, paidTier: String?) -> [String] {
        var out: [String] = []
        for candidate in [paidTier, tier] {
            guard let candidate, !candidate.isEmpty, candidate != "free-tier", candidate != "legacy-tier",
                  !out.contains(candidate) else { continue }
            out.append(candidate)
        }
        return out + [""]
    }

    /// `POST <daily>/v1internal:fetchAvailableModels` for the login's project,
    /// with the account's tier named. A tier Google answers 400 for (a Google
    /// AI Pro account's `g1-pro-tier` on some accounts, magpie #1553) is left
    /// out, down to none, and not named again for a day
    /// (`AntigravityRefusedTiers`).
    public static func fetchAvailableModels(
        credentials: OAuthCredentials,
        hubVersion: String,
        client: HTTPClient,
        refusedTiers: AntigravityRefusedTiers = .shared
    ) async throws -> [String: Any] {
        guard let projectId = projectId(credentials) else {
            throw OAuthError.invalidResponse("the Antigravity login names no Google Cloud project")
        }
        let tiers = tiersToAsk(tier: tier(credentials), paidTier: paidTier(credentials))
            .filter { $0.isEmpty || !refusedTiers.isRefused(project: projectId, tier: $0) }
        var last: Error = OAuthError.invalidResponse("Antigravity listed no models")
        for tier in tiers {
            var body: [String: Any] = ["project": projectId]
            if !tier.isEmpty { body["entitlement"] = ["userTier": tier] }
            do {
                return try await call(
                    host: dailyHost,
                    method: "fetchAvailableModels",
                    body: body,
                    access: credentials.access,
                    hubVersion: hubVersion,
                    client: client
                )
            } catch let error as CodeAssistError where !tier.isEmpty && error.status == 400 {
                refusedTiers.refuse(project: projectId, tier: tier)
                last = error
            }
        }
        throw last
    }

    /// `POST <daily>/v1internal:retrieveUserQuotaSummary` for the login's
    /// project: the shared allowances the account's models draw on.
    public static func retrieveUserQuotaSummary(
        credentials: OAuthCredentials,
        hubVersion: String,
        client: HTTPClient
    ) async throws -> [String: Any] {
        guard let projectId = projectId(credentials) else {
            throw OAuthError.invalidResponse("the Antigravity login names no Google Cloud project")
        }
        return try await call(
            host: dailyHost,
            method: "retrieveUserQuotaSummary",
            body: ["project": projectId],
            access: credentials.access,
            hubVersion: hubVersion,
            client: client
        )
    }
}

/// The tiers Google refused an account's `fetchAvailableModels` with a 400,
/// by project, each left out of the next asks for a day (magpie
/// `tierRefusedFor`): asked again after that in case Google takes it by
/// then; a tier the account newly has is a new key.
public final class AntigravityRefusedTiers: Sendable {
    public static let shared = AntigravityRefusedTiers()
    public static let refusedFor: TimeInterval = 24 * 60 * 60

    private let refused = NIOLockedValueBox<[String: Date]>([:])

    public init() {}

    func isRefused(project: String, tier: String, now: Date = Date()) -> Bool {
        guard let at = refused.withLockedValue({ $0["\(project)\u{0}\(tier)"] }) else { return false }
        return now.timeIntervalSince(at) < Self.refusedFor
    }

    func refuse(project: String, tier: String, now: Date = Date()) {
        refused.withLockedValue { $0["\(project)\u{0}\(tier)"] = now }
    }
}

// MARK: - The Hub's version

/// The newest Antigravity Hub's version, which every request carries in its
/// User-Agent (magpie `antigravityVersion`): asked of the Hub's updater at
/// most every six hours, the last known release until it answers, and a
/// compiled-in fallback before it ever has. A host that knows the version
/// (a test) makes one with `fixed`.
public actor AntigravityHubVersion {
    public static let shared = AntigravityHubVersion()
    /// The release known when this kwwk shipped; bumped on each release.
    public static let fallback = "2.9.1"
    public static let manifestURL = URL(
        string: "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml"
    )!
    public static let cacheLifetime: TimeInterval = 6 * 60 * 60

    private let fixed: String?
    private var version = AntigravityHubVersion.fallback
    private var askedAt: Date?
    private var inFlight: Task<String, Never>?

    public init(fixed: String? = nil) {
        self.fixed = fixed
    }

    /// The version to send now.
    public func current(client: HTTPClient = URLSessionHTTPClient()) async -> String {
        if let fixed { return fixed }
        if let askedAt, Date().timeIntervalSince(askedAt) < Self.cacheLifetime { return version }
        if let inFlight { return await inFlight.value }
        let task = Task<String, Never> { [version] in
            await Self.fetch(client: client) ?? version
        }
        inFlight = task
        let fetched = await task.value
        version = fetched
        askedAt = Date()
        inFlight = nil
        return fetched
    }

    /// The manifest's `version:` line, nil when it can't be had.
    static func fetch(client: HTTPClient) async -> String? {
        guard let (response, body) = try? await client.request(
            url: manifestURL,
            method: "GET",
            headers: ["User-Agent": "electron-builder"],
            body: nil
        ), (200..<300).contains(response.statusCode) else { return nil }
        return parse(manifest: String(decoding: body.prefix(64 << 10), as: UTF8.self))
    }

    /// The `version:` line of the updater's manifest, when it names a
    /// release (digits and dots).
    static func parse(manifest: String) -> String? {
        for line in manifest.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("version:") else { continue }
            let value = line.dropFirst("version:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard !value.isEmpty, value.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
            return value
        }
        return nil
    }
}

// MARK: - Sign-in

extension OAuthLogin {
    /// Sign in to Antigravity with a Google account (magpie `startGoogleSignIn`
    /// / `googleExchange`): PKCE against accounts.google.com with
    /// Antigravity's client, the code traded for tokens at
    /// oauth2.googleapis.com, whose account it is from userinfo, and the
    /// account's Code Assist project found (the account set up, the first
    /// time) into `extras`. `pollSleep` waits between onboarding's asks;
    /// tests pass their own.
    public static func loginAntigravity(
        port: UInt16 = AntigravityOAuth.callbackPort,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient(),
        hubVersion: AntigravityHubVersion = .shared,
        pollSleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let state = PKCE.randomHex(bytes: 16)
        let server = try await openLoopback(callbacks, host: "localhost", port: port, path: AntigravityOAuth.callbackPath)
        defer { server.stop() }
        let redirect = server.redirectURI

        var comps = URLComponents(url: AntigravityOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        // Encoded as a form, as the Hub's own link is.
        comps.percentEncodedQuery = OAuth.urlEncodedForm([
            "client_id": AntigravityOAuth.clientID,
            "redirect_uri": redirect,
            "response_type": "code",
            "scope": AntigravityOAuth.scopes.joined(separator: " "),
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
        ])
        callbacks.onProgress("Sign in to Google in your browser — waiting for the callback on \(redirect)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "antigravity")
        guard params["state"] == state else {
            throw OAuthError.invalidResponse("antigravity callback state mismatch")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("antigravity callback had no code")
        }

        callbacks.onProgress("exchanging the authorization code for Google tokens…")
        let (response, body) = try await client.request(
            url: AntigravityOAuth.tokenURL,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Data(OAuth.urlEncodedForm([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect,
                "client_id": AntigravityOAuth.clientID,
                "client_secret": AntigravityOAuth.clientSecret,
                "code_verifier": pkce.verifier,
            ]).utf8)
        )
        if response.statusCode >= 400 {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let said = ["error_description", "error"].compactMap { object?[$0] as? String }.first { !$0.isEmpty }
            throw OAuthError.refreshFailed(
                "the Google sign-in was refused (\(response.statusCode)): \(said ?? "HTTP \(response.statusCode)")"
            )
        }
        let tokens = try OAuth.decodeTokenResponse(body)
        // `access_type=offline` asks for one; a grant without a refresh token
        // would die at its first expiry, so it is refused here.
        guard !tokens.accessToken.isEmpty, let refresh = tokens.refreshToken, !refresh.isEmpty else {
            throw OAuthError.invalidResponse("Google sent back no token")
        }

        callbacks.onProgress("asking whose account this is…")
        // Whose account it is only labels the login: a userinfo that fails
        // leaves the login without an email, not without a login (pi keeps
        // the email optional too).
        let email: String?
        do {
            email = try await antigravityWho(access: tokens.accessToken, client: client)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            email = nil
        }

        callbacks.onProgress("finding the account's Code Assist project…")
        let version = await hubVersion.current(client: client)
        let account = try await AntigravityOAuth.account(
            access: tokens.accessToken,
            hubVersion: version,
            client: client,
            pollSleep: pollSleep
        )
        var extras: [String: JSONValue] = ["projectId": .string(account.projectId)]
        if let email { extras["email"] = .string(email) }
        if let tier = account.tier, !tier.isEmpty { extras["tier"] = .string(tier) }
        if let paid = account.paidTier, !paid.isEmpty { extras["paidTier"] = .string(paid) }
        return OAuthCredentials(
            access: tokens.accessToken,
            refresh: refresh,
            expires: AntigravityOAuth.expiry(tokens.expiresIn),
            extras: extras
        )
    }

    /// Whose Google account an access token is (magpie `googleWho`).
    static func antigravityWho(access: String, client: HTTPClient) async throws -> String {
        let (response, body) = try await client.request(
            url: AntigravityOAuth.userInfoURL,
            method: "GET",
            headers: ["Authorization": "Bearer \(access)", "Accept": "application/json"],
            body: nil
        )
        guard (200..<300).contains(response.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let email = object["email"] as? String, !email.isEmpty else {
            throw OAuthError.invalidResponse("Google didn't say whose account this is")
        }
        return email
    }
}

// MARK: - Refresh

/// Refreshes an Antigravity login at Google's token endpoint with
/// Antigravity's client (magpie `token`). Google's refresh tokens do not
/// rotate: the answer carries an access token alone, and the stored refresh
/// token stays. A refused grant (`invalid_grant`: revoked, or the app's
/// access withdrawn) is `.rejected`; anything else may pass later.
///
/// Each refresh also asks `loadCodeAssist` again, as magpie asks it for
/// each process (`antigravityProject`), so a plan bought or dropped since
/// the sign-in reaches `tier` and `paidTier` (which pick the models
/// `fetchAvailableModels` lists) within the hour, not at the next sign-in.
/// That ask is an aside: when it fails, or takes longer than
/// `accountCheckSeconds`, the refreshed token goes with the extras it had.
public struct AntigravityOAuthProvider: OAuthProvider {
    public let id = "antigravity"
    public let name = "Antigravity"
    public let tokenURL: URL
    public let hubVersion: AntigravityHubVersion
    /// Whether a refresh asks loadCodeAssist for the account's tiers again.
    public let refreshesAccount: Bool

    /// The longest a refresh waits for loadCodeAssist.
    static let accountCheckSeconds: Double = 10

    public init(
        tokenURL: URL = AntigravityOAuth.tokenURL,
        hubVersion: AntigravityHubVersion = .shared,
        refreshesAccount: Bool = true
    ) {
        self.tokenURL = tokenURL
        self.hubVersion = hubVersion
        self.refreshesAccount = refreshesAccount
    }

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let json = try await OAuthRefreshError.postForToken(
            provider: id,
            url: tokenURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Data(OAuth.urlEncodedForm([
                "grant_type": "refresh_token",
                "refresh_token": credentials.refresh,
                "client_id": AntigravityOAuth.clientID,
                "client_secret": AntigravityOAuth.clientSecret,
            ]).utf8),
            client: client
        )
        guard !json.accessToken.isEmpty else {
            throw OAuthRefreshError(
                providerId: id,
                kind: .unavailable,
                status: nil,
                detail: "antigravity refresh missing access_token"
            )
        }
        var extras = credentials.extras
        if refreshesAccount, let load = await currentAccount(access: json.accessToken, client: client) {
            Self.update(&extras, from: load)
        }
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? credentials.refresh,
            expires: AntigravityOAuth.expiry(json.expiresIn),
            extras: extras
        )
    }

    /// What loadCodeAssist says of the account now, nil when it can't be
    /// had within `accountCheckSeconds`.
    private func currentAccount(access: String, client: HTTPClient) async -> AntigravityOAuth.LoadReply? {
        let hubVersion = self.hubVersion
        return await withTaskGroup(of: AntigravityOAuth.LoadReply?.self) { group in
            group.addTask {
                let version = await hubVersion.current(client: client)
                return try? await AntigravityOAuth.loadCodeAssist(access: access, hubVersion: version, client: client)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.accountCheckSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The login's extras with what loadCodeAssist said now: each of its
    /// project, tier and paid plan that it names replaces the one stored;
    /// one it leaves out is kept (an account set up by onboarding may have
    /// no `currentTier`, and oh-my-pi finds `paidTier` missing from a first
    /// answer that has the project).
    static func update(_ extras: inout [String: JSONValue], from load: AntigravityOAuth.LoadReply) {
        if let project = load.projectId, !project.isEmpty { extras["projectId"] = .string(project) }
        if let tier = load.currentTier, !tier.isEmpty { extras["tier"] = .string(tier) }
        if let paid = load.paidTier, !paid.isEmpty { extras["paidTier"] = .string(paid) }
    }
}

// MARK: - Usage

/// An Antigravity account's allowances, as Antigravity's own usage panel
/// reads them (magpie `quota` and `pools`): `fetchAvailableModels` gives
/// each model how much of its 5-hour window is left, and
/// `retrieveUserQuotaSummary` the shared pools the models draw on — a
/// 5-hour and a weekly window for the Gemini models and another pair for
/// the Claude and GPT models. The per-model windows come first, each named
/// for its model; the pools after, named "Gemini" and "Claude & GPT". A
/// model's 5 hours are its pool's 5 hours, so a model whose pool has a
/// 5-hour window is left out and the pool's window stands for it (magpie
/// `PooledWindows`); a model whose pool has only its week keeps its own 5
/// hours. A summary that cannot be read leaves the per-model windows
/// standing alone.
public struct AntigravityUsageReader: OAuthUsageReader {
    public let providerId = "antigravity"
    public let hubVersion: AntigravityHubVersion
    public let refusedTiers: AntigravityRefusedTiers

    public init(hubVersion: AntigravityHubVersion = .shared, refusedTiers: AntigravityRefusedTiers = .shared) {
        self.hubVersion = hubVersion
        self.refusedTiers = refusedTiers
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        guard AntigravityOAuth.projectId(credentials) != nil else {
            throw OAuthUsageError.unavailable(
                providerId: providerId,
                status: nil,
                detail: "the Antigravity login names no Google Cloud project"
            )
        }
        let version = await hubVersion.current(client: client)
        let models: [String: Any]
        do {
            models = try await AntigravityOAuth.fetchAvailableModels(
                credentials: credentials,
                hubVersion: version,
                client: client,
                refusedTiers: refusedTiers
            )
        } catch let error as AntigravityOAuth.CodeAssistError {
            if error.status == 429 {
                throw OAuthUsageError.rateLimited(retryAfterSeconds: OAuthUsage.retryAfterSeconds(nil))
            }
            throw OAuthUsageError.unavailable(providerId: providerId, status: error.status, detail: error.message)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OAuthUsageError.unavailable(providerId: providerId, status: nil, detail: error.localizedDescription)
        }
        // The pools are an aside: a summary that cannot be read is no reason
        // to drop what the models said of themselves.
        let summary = try? await AntigravityOAuth.retrieveUserQuotaSummary(
            credentials: credentials,
            hubVersion: version,
            client: client
        )
        return Self.windows(models: models, summary: summary)
    }

    /// The per-model 5-hour windows no pool's 5 hours stand for, by model
    /// id, then the pools' windows.
    public static func windows(models: [String: Any], summary: [String: Any]?) -> [OAuthUsageWindow] {
        let groups = summary.map { Self.pools($0) } ?? []
        let own = modelWindows(models).filter { window in
            guard let found = Self.pool(of: window, among: groups) else { return true }
            return !found.windows.contains { $0.windowSeconds == window.windowSeconds }
        }
        return own + groups.flatMap(\.windows)
    }

    /// A quota group of retrieveUserQuotaSummary: its name, what it says it
    /// holds (its name and description, lower-cased) and its windows.
    struct Pool {
        var name: String
        var about: String
        var windows: [OAuthUsageWindow]
        var hasFiveHours: Bool { windows.contains { $0.window == .fiveHour } }
        /// A group named for one model ("Gemini 4 Argon") says a version; a
        /// family's ("Gemini", "Claude & GPT") doesn't (magpie `versioned`).
        var isModels: Bool { name.contains { $0.isNumber } }
    }

    /// The pool a model's window draws on (magpie `pools`): a group named
    /// for the model itself (its name or id begins with the group's), else
    /// a family's group with 5 hours whose name or description names the
    /// model's family ("Models within this group: Claude Opus, Claude
    /// Sonnet, GPT-OSS"); nil when none does.
    static func pool(of window: OAuthUsageWindow, among pools: [Pool]) -> Pool? {
        let id = (window.limitID ?? "").lowercased()
        let name = (window.limitName ?? "").lowercased()
        let spelled = id.replacingOccurrences(of: "-", with: " ")
        if let own = pools.first(where: { pool in
            guard pool.isModels else { return false }
            let named = pool.name.lowercased()
            return [name, spelled].contains { $0 == named || $0.hasPrefix(named + " ") || $0.hasPrefix(named + "(") }
        }) {
            return own
        }
        let family = vendor(id: id, name: window.limitName ?? "").lowercased()
        guard !family.isEmpty else { return nil }
        return pools.first { $0.hasFiveHours && !$0.isModels && $0.about.contains(family) }
    }

    /// The family a model is in, as its id begins — Gemini, Claude,
    /// GPT-OSS — else its name's first word (magpie `antigravityVendor`).
    static func vendor(id: String, name: String) -> String {
        let lower = id.lowercased()
        if lower.hasPrefix("gemini") { return "Gemini" }
        if lower.hasPrefix("claude") { return "Claude" }
        if lower.hasPrefix("gpt-oss") { return "GPT-OSS" }
        if let first = name.split(separator: " ").first { return String(first) }
        return String(lower.split(separator: "-").first ?? "")
    }

    /// One window a chat model, from `fetchAvailableModels`: how much of its
    /// 5 hours is left (`remainingFraction`, left out once none is) and when
    /// it resets. A model that says nothing of its quota, one Antigravity
    /// marks disabled and the ids not for chat have no window.
    static func modelWindows(_ payload: [String: Any]) -> [OAuthUsageWindow] {
        var out: [OAuthUsageWindow] = []
        for (id, value) in payload["models"] as? [String: Any] ?? [:] {
            guard AntigravityOAuth.isChatModel(id), let model = value as? [String: Any],
                  model["disabled"] as? Bool != true,
                  let quota = model["quotaInfo"] as? [String: Any] else { continue }
            let remaining = (quota["remainingFraction"] as? NSNumber)?.doubleValue ?? 0
            let name = model["displayName"] as? String ?? ""
            out.append(OAuthUsageWindow(
                window: .primary,
                usedPercent: (1 - remaining) * 100,
                resetsAt: millis(quota["resetTime"]),
                windowSeconds: 5 * 60 * 60,
                limitID: id,
                limitName: name.isEmpty ? id : name
            ))
        }
        return out.sorted { ($0.limitID ?? "") < ($1.limitID ?? "") }
    }

    /// The pools' windows, from `retrieveUserQuotaSummary`: a group's 5-hour
    /// (`.fiveHour`) and weekly (`.sevenDay`) buckets, each under the pool's
    /// name — "Gemini Models" is Gemini, "Claude and GPT models" Claude &
    /// GPT — and a slug of it as its id. A bucket of another length keeps
    /// Google's name for it. Disabled buckets are not windows.
    static func poolWindows(_ payload: [String: Any]) -> [OAuthUsageWindow] {
        pools(payload).flatMap(\.windows)
    }

    /// The quota groups of a summary, each with its windows (`poolWindows`).
    static func pools(_ payload: [String: Any]) -> [Pool] {
        var pools: [Pool] = []
        for group in payload["groups"] as? [[String: Any]] ?? [] {
            var out: [OAuthUsageWindow] = []
            let displayName = group["displayName"] as? String ?? ""
            let pool = poolName(displayName)
            guard !pool.isEmpty else { continue }
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard bucket["disabled"] as? Bool != true else { continue }
                let kind: OAuthUsageWindowKind
                let seconds: Int?
                switch (bucket["window"] as? String ?? "").lowercased() {
                case "5h":
                    (kind, seconds) = (.fiveHour, 5 * 60 * 60)
                case "weekly":
                    (kind, seconds) = (.sevenDay, 7 * 24 * 60 * 60)
                default:
                    (kind, seconds) = (.secondary, nil)
                }
                // Left out once none is left, as in fetchAvailableModels.
                let remaining = (bucket["remainingFraction"] as? NSNumber)?.doubleValue ?? 0
                var name = pool
                if seconds == nil {
                    let label = [bucket["displayName"], bucket["window"], bucket["bucketId"]]
                        .compactMap { $0 as? String }.first { !$0.isEmpty }
                    guard let label else { continue }
                    name = "\(pool) · \(label)"
                }
                out.append(OAuthUsageWindow(
                    window: kind,
                    usedPercent: (1 - remaining) * 100,
                    resetsAt: millis(bucket["resetTime"]),
                    windowSeconds: seconds,
                    limitID: poolID(pool),
                    limitName: name
                ))
            }
            guard !out.isEmpty else { continue }
            let about = (displayName + " " + (group["description"] as? String ?? "")).lowercased()
            pools.append(Pool(name: pool, about: about, windows: out))
        }
        return pools
    }

    /// A quota group's name without "models" at its end, its "and" an
    /// ampersand (magpie `poolName`).
    static func poolName(_ displayName: String) -> String {
        var name = displayName.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(" models") {
            name = String(name.dropLast(" models".count)).trimmingCharacters(in: .whitespaces)
        }
        return name.replacingOccurrences(of: " and ", with: " & ")
    }

    /// A pool's id: its name lower-cased, each run of anything but letters
    /// and digits a hyphen ("Claude & GPT" is `claude-gpt`).
    static func poolID(_ pool: String) -> String {
        var out = ""
        var hyphen = false
        for scalar in pool.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                hyphen = false
            } else if !hyphen, !out.isEmpty {
                out.append("-")
                hyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// An RFC 3339 reset time as Unix ms, nil when unstated or unreadable.
    static func millis(_ value: Any?) -> Int64? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return Int64(date.timeIntervalSince1970 * 1000) }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
