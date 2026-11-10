import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import Testing
import KWWKAuth

/// A Kiro loopback that plays the browser: each step builds the next request
/// from the sign-in page's address and from where the last reply sent it on.
final class ScriptedKiroLoopback: KiroLoopbackListener, @unchecked Sendable {
    typealias Step = @Sendable (_ page: [String: String], _ sentOnTo: [String: String]) -> (String, [String: String])

    static let port: UInt16 = 4649
    private let lock = NSLock()
    private var steps: [Step]
    private var page: [String: String] = [:]
    private(set) var pageURL: URL?
    private(set) var replies: [KiroCallbackReply] = []
    private(set) var offeredPorts: [UInt16] = []
    private(set) var stopped = false

    init(_ steps: [Step]) {
        self.steps = steps
    }

    /// `Callbacks` that tell the loopback which page the sign-in opened.
    var callbacks: OAuthLogin.Callbacks {
        OAuthLogin.Callbacks(onAuthURL: { [self] url in
            lock.withLock {
                pageURL = url
                page = queryOf(url)
            }
        })
    }

    /// The addresses the browser was redirected to, in order.
    var redirects: [URL] {
        lock.withLock {
            replies.compactMap { if case .redirect(let url) = $0 { return url }; return nil }
        }
    }

    func listen(ports: [UInt16]) async throws -> UInt16 {
        lock.withLock { offeredPorts = ports }
        return Self.port
    }

    func nextCallback() async throws -> KiroCallback {
        let request: (String, [String: String])? = lock.withLock {
            guard !steps.isEmpty else { return nil }
            let sentOnTo = replies.reversed().lazy.compactMap { reply -> URL? in
                if case .redirect(let url) = reply { return url }
                return nil
            }.first.map(queryOf) ?? [:]
            return steps.removeFirst()(page, sentOnTo)
        }
        guard let request else { throw CancellationError() }
        return KiroCallback(path: request.0, params: request.1) { [self] reply in
            lock.withLock { replies.append(reply) }
        }
    }

    func stop() { lock.withLock { stopped = true } }
}

private func queryOf(_ url: URL) -> [String: String] {
    var out: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        out[item.name] = item.value ?? ""
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

private let tokenAnswer = #"{"accessToken":"idc-at","refreshToken":"idc-rt","expiresIn":3600}"#
private let registerAnswer = #"{"clientId":"cid","clientSecret":"csecret","clientSecretExpiresAt":1790000000}"#

/// Kiro's page coming back with an AWS sign-in to go on to.
private func awsOption(_ option: String, region: String = "us-east-1") -> ScriptedKiroLoopback.Step {
    { page, _ in
        ("/signin/callback", [
            "login_option": option, "issuer_url": "https://view.awsapps.com/start",
            "idc_region": region, "state": page["state"] ?? "",
        ])
    }
}

/// AWS coming back with its code.
private let awsBack: ScriptedKiroLoopback.Step = { _, authorize in
    ("/oauth/callback", ["code": "awscode", "state": authorize["state"] ?? ""])
}

// Ported from magpie's kiro_signin_test.go, which answers Kiro's auth service
// and AWS's sign-in checking what the IDE would send.
@Suite("Kiro sign-in on app.kiro.dev")
struct KiroSignInTests {
    @Test("Google: the page's code is traded at Kiro's auth service, as the IDE")
    func google() async throws {
        let loopback = ScriptedKiroLoopback([{ page, _ in
            ("/oauth/callback", ["login_option": "google", "code": "gcode", "state": page["state"] ?? ""])
        }])
        let client = QueuedHTTPClient([.response(status: 200, body: """
            {"accessToken":"social-at","refreshToken":"social-rt",\
            "profileArn":"arn:aws:codewhisperer:us-east-1:1:profile/P","expiresIn":3600}
            """)])
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let credentials = try await OAuthLogin.loginKiro(
            callbacks: loopback.callbacks,
            client: client,
            listener: loopback
        )

        // The page is opened as the IDE opens it, to come back to one of its ports.
        let page = try #require(loopback.pageURL)
        let query = queryOf(page)
        #expect(page.absoluteString.hasPrefix("https://app.kiro.dev/signin?"))
        #expect(query["redirect_from"] == "KiroIDE")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["redirect_uri"] == "http://localhost:4649")
        #expect(loopback.offeredPorts == [3128, 4649, 6588, 8008, 9091, 49153, 50153, 51153, 52153, 53153])
        // Byte for byte what magpie's `url.Values.Encode` opens (keys sorted,
        // the redirect's `:` and `/` escaped).
        #expect(page.absoluteString == "https://app.kiro.dev/signin?code_challenge=\(query["code_challenge"] ?? "")"
            + "&code_challenge_method=S256&redirect_from=KiroIDE&redirect_uri=http%3A%2F%2Flocalhost%3A4649"
            + "&state=\(query["state"] ?? "")")
        #expect(loopback.stopped)

        #expect(client.requestCount == 1)
        #expect(client.requests[0].url.absoluteString == "https://prod.us-east-1.auth.desktop.kiro.dev/oauth/token")
        #expect(client.header("User-Agent", request: 0)?.hasPrefix("KiroIDE-") == true)
        #expect(client.header("Content-Type", request: 0) == "application/json")
        let body = try jsonBody(client, request: 0)
        #expect(body["code"] as? String == "gcode")
        #expect(s256(body["code_verifier"] as? String ?? "") == query["code_challenge"])
        #expect(body["redirect_uri"] as? String == "http://localhost:4649/oauth/callback?login_option=google")

        #expect(credentials.access == "social-at")
        #expect(credentials.refresh == "social-rt")
        #expect(credentials.extras == [
            "authMethod": "social", "provider": "Google", "region": "us-east-1",
            "profileArn": "arn:aws:codewhisperer:us-east-1:1:profile/P",
        ])
        #expect(credentials.expires >= before + (3600 - 300) * 1000)
        #expect(credentials.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3600 - 300) * 1000)
        #expect(loopback.replies == [.page(
            succeeded: true, title: "You're signed in", message: "Kiro is added to kwwk. You can close this tab."
        )])
    }

    @Test("Builder ID goes on to AWS with a client registered for it, and takes the service profile")
    func builderID() async throws {
        let loopback = ScriptedKiroLoopback([
            awsOption("builderid"),
            // A stale tab's answer is turned away, and the sign-in goes on.
            { _, _ in ("/oauth/callback", ["code": "awscode", "state": "nope"]) },
            awsBack,
        ])
        let client = QueuedHTTPClient([
            .response(status: 200, body: registerAnswer),
            .response(status: 200, body: tokenAnswer),
        ])
        let credentials = try await OAuthLogin.loginKiro(
            callbacks: loopback.callbacks,
            client: client,
            listener: loopback
        )

        #expect(client.requests[0].url.absoluteString == "https://oidc.us-east-1.amazonaws.com/client/register")
        let register = try jsonBody(client, request: 0)
        #expect(register["clientName"] as? String == "Kiro IDE")
        #expect(register["clientType"] as? String == "public")
        #expect(register["issuerUrl"] as? String == "https://view.awsapps.com/start")
        #expect(register["grantTypes"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(register["redirectUris"] as? [String] == ["http://127.0.0.1/oauth/callback"])
        #expect(register["scopes"] as? [String] == [
            "codewhisperer:completions", "codewhisperer:analysis", "codewhisperer:conversations",
            "codewhisperer:transformations", "codewhisperer:taskassist",
        ])

        let authorize = try #require(loopback.redirects.first)
        let sent = queryOf(authorize)
        #expect(authorize.absoluteString.hasPrefix("https://oidc.us-east-1.amazonaws.com/authorize?"))
        #expect(sent["client_id"] == "cid")
        #expect(sent["response_type"] == "code")
        #expect(sent["scopes"]?.contains("codewhisperer:conversations,") == true)
        #expect(sent["redirect_uri"] == "http://127.0.0.1:4649/oauth/callback")
        #expect(sent["code_challenge_method"] == "S256")
        #expect(authorize.absoluteString == "https://oidc.us-east-1.amazonaws.com/authorize"
            + "?client_id=cid&code_challenge=\(sent["code_challenge"] ?? "")&code_challenge_method=S256"
            + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A4649%2Foauth%2Fcallback&response_type=code"
            + "&scopes=codewhisperer%3Acompletions%2Ccodewhisperer%3Aanalysis%2Ccodewhisperer%3Aconversations"
            + "%2Ccodewhisperer%3Atransformations%2Ccodewhisperer%3Ataskassist&state=\(sent["state"] ?? "")")

        #expect(client.requestCount == 2)
        #expect(client.requests[1].url.absoluteString == "https://oidc.us-east-1.amazonaws.com/token")
        let token = try jsonBody(client, request: 1)
        #expect(token["grantType"] as? String == "authorization_code")
        #expect(token["code"] as? String == "awscode")
        #expect(token["clientId"] as? String == "cid")
        #expect(token["clientSecret"] as? String == "csecret")
        #expect(token["redirectUri"] as? String == "http://127.0.0.1:4649/oauth/callback")
        #expect(s256(token["codeVerifier"] as? String ?? "") == sent["code_challenge"])

        // Kiro lists no profile for Builder ID, so none is asked for (magpie #422).
        #expect(credentials.access == "idc-at")
        #expect(credentials.refresh == "idc-rt")
        #expect(credentials.extras == [
            "authMethod": "IdC", "provider": "BuilderId", "region": "us-east-1",
            "clientId": "cid", "clientSecret": "csecret", "profileArn": .string(KiroOAuth.builderIDProfile),
        ])
        #expect(loopback.replies.count == 3)
        #expect(loopback.replies[1] == .page(
            succeeded: false, title: "This link isn't from kwwk's sign-in", message: "Start it again from kwwk."
        ))
    }

    @Test("Identity Center has its profile listed, in whichever of Kiro's regions holds it")
    func identityCenter() async throws {
        let loopback = ScriptedKiroLoopback([awsOption("awsidc", region: "eu-west-1"), awsBack])
        let client = QueuedHTTPClient([
            .response(status: 200, body: registerAnswer),
            .response(status: 200, body: tokenAnswer),
            .response(status: 200, body: #"{"profiles":[]}"#),
            .response(
                status: 200,
                body: #"{"profiles":[{"arn":""},{"arn":"arn:aws:codewhisperer:eu-central-1:9:profile/E"}]}"#
            ),
        ])
        let credentials = try await OAuthLogin.loginKiro(
            callbacks: loopback.callbacks,
            client: client,
            listener: loopback
        )
        #expect(client.requests[0].url.host == "oidc.eu-west-1.amazonaws.com")
        #expect(client.requests[1].url.host == "oidc.eu-west-1.amazonaws.com")
        #expect(client.requests[2].url.absoluteString == "https://management.us-east-1.kiro.dev/List-Available-Profiles")
        #expect(client.requests[3].url.absoluteString == "https://management.eu-central-1.kiro.dev/List-Available-Profiles")
        #expect(client.requests[2].method == "POST")
        #expect(client.requests[2].body == Data("{}".utf8))
        #expect(client.header("Authorization", request: 2) == "Bearer idc-at")
        #expect(credentials.extras["provider"] == "Enterprise")
        #expect(credentials.extras["region"] == "eu-west-1")
        #expect(KiroOAuth.profileArn(credentials) == "arn:aws:codewhisperer:eu-central-1:9:profile/E")
        #expect(KiroOAuth.apiRegion(credentials) == "eu-central-1")
    }

    @Test("A region that cannot be reached is passed over for Kiro's other one")
    func profileRegionUnreachable() async throws {
        let loopback = ScriptedKiroLoopback([awsOption("awsidc"), awsBack])
        let client = QueuedHTTPClient([
            .response(status: 200, body: registerAnswer),
            .response(status: 200, body: tokenAnswer),
            .failure(URLError(.cannotConnectToHost)),
            .response(status: 200, body: #"{"profiles":[{"arn":"arn:aws:codewhisperer:eu-central-1:9:profile/E"}]}"#),
        ])
        let credentials = try await OAuthLogin.loginKiro(
            callbacks: loopback.callbacks,
            client: client,
            listener: loopback
        )
        #expect(client.requests[3].url.host == "management.eu-central-1.kiro.dev")
        #expect(KiroOAuth.profileArn(credentials) == "arn:aws:codewhisperer:eu-central-1:9:profile/E")
    }

    @Test("An AWS sign-in Kiro answers as Builder ID takes Builder ID's profile")
    func builderIDFoundByKirosAnswer() async throws {
        let loopback = ScriptedKiroLoopback([awsOption("awsidc"), awsBack])
        let client = QueuedHTTPClient([
            .response(status: 200, body: registerAnswer),
            .response(status: 200, body: tokenAnswer),
            .response(status: 403, body: #"{"message":"AWS Builder ID is not supported for this operation."}"#),
        ])
        let credentials = try await OAuthLogin.loginKiro(
            callbacks: loopback.callbacks,
            client: client,
            listener: loopback
        )
        #expect(client.requestCount == 3)
        #expect(KiroOAuth.profileArn(credentials) == KiroOAuth.builderIDProfile)
    }

    @Test("A sign-in Kiro lists no profile for fails, saying what Kiro said")
    func noProfile() async throws {
        let loopback = ScriptedKiroLoopback([awsOption("awsidc"), awsBack])
        let client = QueuedHTTPClient([
            .response(status: 200, body: registerAnswer),
            .response(status: 200, body: tokenAnswer),
            .response(status: 403, body: #"{"message":"User is not authorized"}"#),
            .response(status: 200, body: #"{"profiles":[]}"#),
        ])
        do {
            _ = try await OAuthLogin.loginKiro(callbacks: loopback.callbacks, client: client, listener: loopback)
            Issue.record("signed in with no profile")
        } catch {
            #expect(error.localizedDescription.contains("Kiro: User is not authorized (403)"))
        }
        guard case .page(succeeded: false, _, _)? = loopback.replies.last else {
            Issue.record("the browser wasn't told: \(loopback.replies)")
            return
        }
    }

    @Test("A company's own identity provider is refused, and said so")
    func externalIdP() async throws {
        let loopback = ScriptedKiroLoopback([{ page, _ in
            ("/oauth/callback", ["login_option": "external_idp", "state": page["state"] ?? ""])
        }])
        let client = QueuedHTTPClient([])
        await #expect(throws: OAuthLoginError.denied("kwwk can't sign in to Kiro with a company's own identity provider")) {
            _ = try await OAuthLogin.loginKiro(callbacks: loopback.callbacks, client: client, listener: loopback)
        }
        #expect(client.requestCount == 0)
        #expect(loopback.replies == [.page(
            succeeded: false, title: "Sign-in didn't finish",
            message: "the provider refused the sign-in: kwwk can't sign in to Kiro with a company's own identity provider"
        )])
    }

    @Test("A sign-in declined on the page is the user's cancel")
    func declined() async throws {
        let loopback = ScriptedKiroLoopback([{ _, _ in ("/oauth/callback", ["error": "access_denied"]) }])
        await #expect(throws: OAuthLoginError.cancelled) {
            _ = try await OAuthLogin.loginKiro(
                callbacks: loopback.callbacks,
                client: QueuedHTTPClient([]),
                listener: loopback
            )
        }
    }

    @Test("A refused exchange says why; an answer without a token is no sign-in")
    func refusedExchange() async throws {
        let github: ScriptedKiroLoopback.Step = { page, _ in
            ("/oauth/callback", ["login_option": "github", "code": "c", "state": page["state"] ?? ""])
        }
        var loopback = ScriptedKiroLoopback([github])
        do {
            _ = try await OAuthLogin.loginKiro(
                callbacks: loopback.callbacks,
                client: QueuedHTTPClient([.response(
                    status: 400,
                    body: #"{"error":"invalid_grant","error_description":"code expired"}"#
                )]),
                listener: loopback
            )
            Issue.record("a refused exchange signed in")
        } catch {
            #expect(error.localizedDescription.contains("the Kiro sign-in was refused (400): code expired"))
        }
        loopback = ScriptedKiroLoopback([github])
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginKiro(
                callbacks: loopback.callbacks,
                client: QueuedHTTPClient([.response(status: 200, body: "{}")]),
                listener: loopback
            )
        }
    }

    @Test("A page that names no AWS region to sign in at registers nothing")
    func awsWithoutRegion() async throws {
        let loopback = ScriptedKiroLoopback([{ page, _ in
            ("/signin/callback", [
                "login_option": "awsidc",
                "idc_region": "evil.example/",
                "issuer_url": "https://x",
                "state": page["state"] ?? ""
            ])
        }])
        let client = QueuedHTTPClient([])
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginKiro(callbacks: loopback.callbacks, client: client, listener: loopback)
        }
        #expect(client.requestCount == 0)
    }
}

@Suite("Kiro's default loopback")
struct KiroCallbackServerTests {
    /// A session that reports redirects instead of following them.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    @Test("It answers both callback paths over real HTTP, twice on one port, with a page or a redirect")
    func servesTwice() async throws {
        let server = KiroCallbackServer()
        defer { server.stop() }
        // Port 0 has the system pick a free one.
        let port = try await server.listen(ports: [0])
        #expect(port != 0)
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        async let first = session.data(from: URL(string: "http://127.0.0.1:\(port)/signin/callback?login_option=builderid&state=s")!)
        var callback = try await server.nextCallback()
        #expect(callback.path == "/signin/callback")
        #expect(callback.params == ["login_option": "builderid", "state": "s"])
        callback.reply(.redirect(URL(string: "https://oidc.us-east-1.amazonaws.com/authorize?state=a")!))
        let (_, redirect) = try await first
        #expect((redirect as? HTTPURLResponse)?.statusCode == 302)
        #expect((redirect as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
            == "https://oidc.us-east-1.amazonaws.com/authorize?state=a")

        async let second = session.data(from: URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=c&state=a")!)
        callback = try await server.nextCallback()
        #expect(callback.path == "/oauth/callback")
        callback.reply(.page(succeeded: true, title: "You're signed in", message: "<Kiro> is added."))
        let (page, done) = try await second
        #expect((done as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("&lt;Kiro&gt; is added."))

        let (_, stray) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect((stray as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("With every port taken it says so")
    func portsBusy() async throws {
        let holder = KiroCallbackServer()
        defer { holder.stop() }
        let port = try await holder.listen(ports: [0])
        let server = KiroCallbackServer()
        defer { server.stop() }
        await #expect(throws: OAuthError.self) {
            _ = try await server.listen(ports: [port])
        }
    }
}

// Ported from magpie's kiro_test.go.
@Suite("Kiro refresh")
struct KiroRefreshTests {
    private let social = OAuthCredentials(
        access: "old",
        refresh: "rt",
        expires: 0,
        extras: [
            "authMethod": "social", "provider": "Google", "region": "us-east-1",
            "profileArn": "arn:aws:codewhisperer:us-east-1:1:profile/P",
        ]
    )
    private let idc = OAuthCredentials(
        access: "old",
        refresh: "rt",
        expires: 0,
        extras: [
            "authMethod": "IdC", "provider": "Enterprise", "region": "eu-west-1",
            "clientId": "cid", "clientSecret": "sec",
            "profileArn": "arn:aws:codewhisperer:eu-central-1:1:profile/P",
        ]
    )

    @Test("A Google or GitHub login is refreshed at Kiro's auth service, as the desktop app")
    func socialRefresh() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"accessToken":"new","refreshToken":"rt2","expiresIn":3600}"#),
        ])
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let refreshed = try await KiroOAuthProvider().refresh(social, using: client)
        #expect(client.requests[0].url.absoluteString == "https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken")
        #expect(client.requests[0].method == "POST")
        #expect(client.header("User-Agent", request: 0) == "Kiro-Desktop/0.2.13 (darwin; arm64)")
        #expect(client.header("Content-Type", request: 0) == "application/json")
        #expect(client.header("Accept", request: 0) == "application/json")
        #expect(try jsonBody(client, request: 0) as? [String: String] == ["refreshToken": "rt"])
        #expect(refreshed.access == "new")
        #expect(refreshed.refresh == "rt2")
        #expect(refreshed.extras == social.extras)
        #expect(refreshed.expires >= before + (3600 - 300) * 1000)
        #expect(refreshed.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3600 - 300) * 1000)
    }

    @Test("A social refresh that names the profile anew replaces it")
    func socialProfile() async throws {
        let client = QueuedHTTPClient([
            .response(
                status: 200,
                body: #"{"accessToken":"new","profileArn":"arn:aws:codewhisperer:eu-central-1:2:profile/Q"}"#
            ),
        ])
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let refreshed = try await KiroOAuthProvider().refresh(social, using: client)
        #expect(KiroOAuth.profileArn(refreshed) == "arn:aws:codewhisperer:eu-central-1:2:profile/Q")
        // No new refresh token keeps the old one; no lifetime is an hour.
        #expect(refreshed.refresh == "rt")
        #expect(refreshed.expires >= before + (3600 - 300) * 1000)
        #expect(refreshed.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3600 - 300) * 1000)
    }

    @Test("An AWS login is refreshed at AWS's OIDC, in its own region, with the client registered at sign-in")
    func idcRefresh() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"accessToken":"new","refreshToken":"rt2","expiresIn":28800}"#),
        ])
        let refreshed = try await KiroOAuthProvider().refresh(idc, using: client)
        #expect(client.requests[0].url.absoluteString == "https://oidc.eu-west-1.amazonaws.com/token")
        #expect(client.header("User-Agent", request: 0) == nil)
        #expect(try jsonBody(client, request: 0) as? [String: String] == [
            "clientId": "cid", "clientSecret": "sec", "refreshToken": "rt", "grantType": "refresh_token",
        ])
        #expect(refreshed.access == "new")
        #expect(refreshed.refresh == "rt2")
        #expect(refreshed.extras == idc.extras)
    }

    @Test("A refused grant parks the login; other failures do not", arguments: ["social", "idc"])
    func classification(kind: String) async throws {
        let credentials = kind == "social" ? social : idc
        func kindOf(_ answer: QueuedHTTPClient.Answer) async -> OAuthRefreshError.Kind? {
            do {
                _ = try await KiroOAuthProvider().refresh(credentials, using: QueuedHTTPClient([answer]))
                return nil
            } catch let error as OAuthRefreshError {
                #expect(error.providerId == "kiro")
                return error.kind
            } catch {
                Issue.record("unexpected error \(error)")
                return nil
            }
        }
        #expect(await kindOf(.response(status: 400, body: #"{"error":"invalid_grant"}"#)) == .rejected)
        #expect(await kindOf(.response(status: 401, body: "{}")) == .rejected)
        #expect(await kindOf(.response(status: 403, body: "<html>")) == .unavailable)
        #expect(await kindOf(.response(status: 503, body: "busy")) == .unavailable)
        #expect(await kindOf(.failure(URLError(.timedOut))) == .unavailable)
        #expect(await kindOf(.response(status: 200, body: "{}")) == .unavailable)
    }

    @Test("A stored region that gives no URL is a sign-in to make again, and nothing is sent", arguments: ["social", "idc"])
    func unusableRegion(kind: String) async throws {
        var credentials = kind == "social" ? social : idc
        credentials.extras["region"] = "a:b"
        let client = QueuedHTTPClient([])
        do {
            _ = try await KiroOAuthProvider().refresh(credentials, using: client)
            Issue.record("the refresh went through")
        } catch let error as OAuthRefreshError {
            #expect(error.providerId == "kiro")
            #expect(error.kind == .rejected)
            #expect(error.status == nil)
        }
        #expect(client.requests.isEmpty)
    }

    @Test("A stored region that parses but is not a region sends nothing", arguments: [
        ("social", "evil.com/x"), ("idc", "evil.com/x"),
        ("social", "us-east-1.evil.com"), ("idc", "us-east-1.evil.com"), ("idc", "attacker.example#"),
    ])
    func hostileRegion(kind: String, region: String) async throws {
        var credentials = kind == "social" ? social : idc
        credentials.extras["region"] = .string(region)
        let client = QueuedHTTPClient([.response(status: 200, body: #"{"accessToken":"stolen"}"#)])
        await #expect(throws: OAuthRefreshError.self) {
            _ = try await KiroOAuthProvider().refresh(credentials, using: client)
        }
        #expect(client.requests.isEmpty)
    }

    @Test("A region is used only when it is one; a missing one falls back", arguments: [
        ("arn:aws:codewhisperer:us-east-1.evil.com:1:profile/P", "us-east-1", nil),
        ("arn:aws:codewhisperer:evil.com/x:1:profile/P", "us-east-1", nil),
        ("arn:aws:codewhisperer:eu-central-1:1:profile/P", "evil.com/x", nil),
        ("", "us-east-1.evil.com", nil),
        ("", "", "us-east-1"),
    ] as [(String, String, String?)])
    func validatedRegion(profile: String, signedIn: String, expected: String?) {
        var extras: [String: JSONValue] = [:]
        if !profile.isEmpty { extras["profileArn"] = .string(profile) }
        if !signedIn.isEmpty { extras["region"] = .string(signedIn) }
        let credentials = OAuthCredentials(access: "a", refresh: "r", expires: .max, extras: extras)
        #expect(KiroOAuth.apiRegion(credentials) == expected)
    }

    @Test("The API is in the profile's region, else the nearest of Kiro's two to the sign-in", arguments: [
        ("arn:aws:codewhisperer:eu-central-1:1:profile/P", "us-east-1", "eu-central-1"),
        ("arn:aws:codewhisperer:us-east-1:1:profile/P", "", "us-east-1"),
        ("", "eu-west-2", "eu-central-1"),
        ("", "ap-southeast-1", "us-east-1"),
    ])
    func region(profile: String, signedIn: String, expected: String) {
        var extras: [String: JSONValue] = [:]
        if !profile.isEmpty { extras["profileArn"] = .string(profile) }
        if !signedIn.isEmpty { extras["region"] = .string(signedIn) }
        let credentials = OAuthCredentials(access: "a", refresh: "r", expires: .max, extras: extras)
        #expect(KiroOAuth.apiRegion(credentials) == expected)
    }
}

@Suite("Kiro usage")
struct KiroUsageTests {
    private let credentials = OAuthCredentials(
        access: "tok",
        refresh: "r",
        expires: .max,
        extras: ["region": "eu-west-1", "profileArn": "arn:aws:codewhisperer:eu-central-1:1:profile/P"]
    )

    // The shape Get-Usage-Limits answered with, on a free account (magpie
    // TestKiroLimits).
    private static let limits = """
        {"subscriptionInfo":{"subscriptionTitle":"KIRO FREE"},"userInfo":{"email":"me@example.com"},
        "usageBreakdownList":[{"displayName":"Credit","displayNamePlural":"Credits","currentUsageWithPrecision":12.5,\
        "usageLimitWithPrecision":50,"nextDateReset":1790000000,
        "freeTrialInfo":{"freeTrialStatus":"ACTIVE","currentUsageWithPrecision":100,"usageLimitWithPrecision":500,\
        "freeTrialExpiry":1791000000}}]}
        """

    @Test("The month's credits and a running free trial are each a window")
    func windows() async throws {
        let client = QueuedHTTPClient([.response(status: 200, body: Self.limits)])
        let windows = try await KiroUsageReader().usage(credentials, using: client)
        #expect(windows == [
            OAuthUsageWindow(
                window: .secondary, usedPercent: 20, resetsAt: 1_791_000_000_000, windowSeconds: nil,
                limitID: "free_trial", limitName: "Free trial"
            ),
            OAuthUsageWindow(
                window: .primary, usedPercent: 25, resetsAt: 1_790_000_000_000, windowSeconds: 2_592_000,
                limitName: "Credits"
            ),
        ])
        // Asked as kiro-cli asks, of the region the profile is in.
        let url = client.requests[0].url
        #expect(url.host == "management.eu-central-1.kiro.dev")
        #expect(url.path == "/Get-Usage-Limits")
        #expect(url.query == "isEmailRequired=true&origin=KIRO_CLI"
            + "&profileArn=arn%3Aaws%3Acodewhisperer%3Aeu-central-1%3A1%3Aprofile%2FP&resourceType=CREDIT")
        #expect(client.requests[0].method == "GET")
        #expect(client.header("Authorization", request: 0) == "Bearer tok")
    }

    @Test("An ended trial and a row without a limit are no windows; the reset may stand on the answer itself")
    func sparse() {
        let windows = KiroUsageReader.windows(from: [
            "nextDateReset": 1_790_000_000,
            "usageBreakdownList": [
                ["displayName": "Credit", "currentUsageWithPrecision": 5, "usageLimitWithPrecision": 10,
                 "freeTrialInfo": ["freeTrialStatus": "EXPIRED", "usageLimitWithPrecision": 500]],
                ["displayName": "Bonus", "usageLimitWithPrecision": 0],
            ],
        ])
        #expect(windows == [OAuthUsageWindow(
            window: .primary, usedPercent: 50, resetsAt: 1_790_000_000_000, windowSeconds: 2_592_000, limitName: "Credit"
        )])
    }

    @Test("A login without a profile, a 429 and a refusal read as no usage, not as a dead login")
    func failures() async throws {
        await #expect(throws: OAuthUsageError.unavailable(providerId: "kiro", status: nil, detail: "the Kiro login names no profile")) {
            _ = try await KiroUsageReader().usage(
                OAuthCredentials(access: "t", refresh: "", expires: .max),
                using: QueuedHTTPClient([])
            )
        }
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 30)) {
            _ = try await KiroUsageReader().usage(
                credentials,
                using: QueuedHTTPClient([.response(status: 429, body: "", headers: ["Retry-After": "30"])])
            )
        }
        await #expect(throws: OAuthUsageError.unavailable(providerId: "kiro", status: 403, detail: "no")) {
            _ = try await KiroUsageReader().usage(
                credentials,
                using: QueuedHTTPClient([.response(status: 403, body: "no")])
            )
        }
    }

    // Whether such a host still parses differs between Foundation builds;
    // either way the read ends in an error, never in a trap.
    @Test("A profile whose region is not one reads as no usage")
    func unusableRegion() async throws {
        var stored = credentials
        stored.extras["profileArn"] = "arn:aws:codewhisperer:a b:1:profile/P"
        await #expect(throws: OAuthUsageError.self) {
            _ = try await KiroUsageReader().usage(stored, using: QueuedHTTPClient([.response(status: 403, body: "no")]))
        }
    }

    @Test("A profile or sign-in region that parses but is not one sends nothing", arguments: [
        ("profileArn", "arn:aws:codewhisperer:us-east-1.evil.com:1:profile/P"),
        ("profileArn", "arn:aws:codewhisperer:evil.com/x:1:profile/P"),
        ("region", "evil.com/x"),
    ])
    func hostileRegion(key: String, value: String) async throws {
        var stored = credentials
        stored.extras[key] = .string(value)
        let client = QueuedHTTPClient([.response(status: 200, body: Self.limits)])
        await #expect(throws: OAuthUsageError.unavailable(
            providerId: "kiro", status: nil, detail: "the Kiro login's profile names a region that is not one"
        )) {
            _ = try await KiroUsageReader().usage(stored, using: client)
        }
        #expect(client.requests.isEmpty)
    }

    @Test("Kiro is among the providers whose usage is read")
    func registered() {
        #expect(OAuthUsage.readers["kiro"] is KiroUsageReader)
    }
}
