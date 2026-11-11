import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAuth

// The answers below are the shapes Raccoon's gate gives, from the captures
// JanXiao's sign-in for Apelin was written against (owngoal-dev/Apelin#40).

private let tokenGiven = #"""
{"code":0,"data":{"access_token":"access-1","refresh_token":"refresh-1","expires_at":1790801493,"office_identity":"org-1","office_org_name":"Office","office_org_role":"member"}}
"""#

private func ok(_ body: String) -> QueuedHTTPClient.Answer {
    .response(status: 200, body: body)
}

private func json(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func signIn(
    _ client: QueuedHTTPClient,
    presenter: RecordingPresenter = RecordingPresenter(),
    params: [String: String] = ["code": "code-1"],
    echoState: Bool = true,
    made: (@Sendable (String, UInt16, String) -> Void)? = nil
) async throws -> OAuthCredentials {
    var callbacks = quietCallbacksBase
    callbacks.browser = presenter
    callbacks.loopback = { host, port, path in
        made?(host, port, path)
        let loopback = ScriptedLoopback(
            host: host,
            port: port == 0 ? 49_152 : port,
            path: path,
            params: params,
            echoState: echoState
        )
        presenter.loopback = loopback
        return loopback
    }
    return try await OAuthLogin.loginRaccoon(callbacks: callbacks, client: client)
}

@Suite("Raccoon sign-in")
struct RaccoonSignInTests {
    @Test("The page is asked for a loopback redirect, with a state of sixty-four hex digits, and its code is exchanged")
    func browserFlow() async throws {
        let client = QueuedHTTPClient([ok(tokenGiven)])
        let presenter = RecordingPresenter()
        let asked = Asked()
        let credentials = try await signIn(client, presenter: presenter) { host, port, path in
            asked.set("\(host):\(port)\(path)")
        }
        // Any free port: the page only needs one it can name, above 1023.
        #expect(asked.value == "127.0.0.1:0/auth/callback")

        let page = try #require(presenter.shown.first)
        #expect(page.absoluteString.hasPrefix("https://xiaohuanxiong.com/code/authorize?"))
        let items = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["login_source", "appname", "state", "redirect", "desktop_callback"])
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        // The page chooses its client by `login_source`.
        #expect(query["login_source"] == "desktop")
        #expect(query["appname"] == "办公小浣熊客户端")
        #expect(page.absoluteString.contains("appname=%E5%8A%9E%E5%85%AC"))
        // Without these two the page navigates to a scheme no browser handles.
        #expect(query["redirect"] == "http://127.0.0.1:49152/auth/callback")
        #expect(query["desktop_callback"] == "loopback")
        #expect(query["state"]?.count == 64)
        #expect(query["state"]?.allSatisfy(\.isHexDigit) == true)

        let exchange = client.requests[0]
        #expect(exchange.method == "POST")
        #expect(exchange.url.absoluteString
            == "https://xiaohuanxiong.com/api/web/auth/v1/login_with_authorization_code")
        #expect(exchange.headers == ["Content-Type": "application/json", "Accept": "application/json"])
        #expect(try json(exchange.body) as? [String: String] == ["authorization_code": "code-1"])

        #expect(credentials.access == "access-1")
        #expect(credentials.refresh == "refresh-1")
        #expect(credentials.expires == 1_790_801_493_000 - 5 * 60 * 1000)
        #expect(credentials.extras == ["officeIdentity": .string("org-1")])
    }

    @Test("A redirect that names another sign-in's state is refused; one that names none is taken")
    func state() async throws {
        let unasked = QueuedHTTPClient([])
        await #expect(throws: OAuthError.self) {
            _ = try await signIn(unasked, params: ["code": "code-1", "state": "someone-else"], echoState: false)
        }
        #expect(unasked.requestCount == 0)

        let credentials = try await signIn(QueuedHTTPClient([ok(tokenGiven)]), echoState: false)
        #expect(credentials.access == "access-1")
    }

    @Test("A page the user left ends the sign-in cancelled, and a redirect with no code is refused")
    func redirects() async {
        await #expect(throws: OAuthLoginError.cancelled) {
            _ = try await signIn(QueuedHTTPClient([]), params: ["error": "access_denied"])
        }
        await #expect(throws: OAuthError.self) {
            _ = try await signIn(QueuedHTTPClient([]), params: ["code": " "])
        }
    }

    @Test("The gate's refusal is said in words: a spent code by what it is, an unknown one in the gate's own")
    func refused() async {
        await #expect(throws: OAuthLoginError.denied(
            "Raccoon: that sign-in code has already been used; sign in again"
        )) {
            _ = try await signIn(QueuedHTTPClient([ok(#"{"code":200035,"message":"used"}"#)]))
        }
        await #expect(throws: OAuthLoginError.denied("Raccoon: 稍后再试")) {
            _ = try await signIn(QueuedHTTPClient([ok(#"{"code":"500123","msg":"稍后再试"}"#)]))
        }
        await #expect(throws: OAuthError.self) {
            _ = try await signIn(QueuedHTTPClient([ok(#"{"code":0,"data":{}}"#)]))
        }
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: String?
    var value: String? { lock.withLock { asked } }
    func set(_ value: String) { lock.withLock { asked = value } }
}

@Suite("Raccoon renewal")
struct RaccoonRenewalTests {
    private let stored = OAuthCredentials(
        access: "access-old",
        refresh: "refresh-old",
        expires: 0,
        extras: ["officeIdentity": .string("org-1"), "accountName": .string("kept")]
    )

    @Test("A renewal posts the refresh token to /refresh and takes the rotated one")
    func renews() async throws {
        let client = QueuedHTTPClient([
            ok(#"{"code":0,"data":{"access_token":"access-new","refresh_token":"refresh-new","expires_at":1790801493459}}"#),
        ])
        let renewed = try await RaccoonOAuthProvider().refresh(stored, using: client)

        let request = client.requests[0]
        #expect(request.method == "POST")
        // Not `/refresh_token`, which answers 404.
        #expect(request.url.absoluteString == "https://xiaohuanxiong.com/api/web/auth/v1/refresh")
        #expect(try json(request.body) as? [String: String] == ["refresh_token": "refresh-old"])

        #expect(renewed.access == "access-new")
        #expect(renewed.refresh == "refresh-new")
        #expect(renewed.expires == 1_790_801_493_459 - 5 * 60 * 1000)
        // The office stays the sign-in's unless the renewal names it again.
        #expect(renewed.extras == stored.extras)
    }

    @Test("A renewal that names the office again, and rotates nothing, is taken as it is")
    func officeNamedAgain() async throws {
        let client = QueuedHTTPClient([
            ok(#"{"data":{"access_token":"access-new","office_identity":"org-2"}}"#),
        ])
        let renewed = try await RaccoonOAuthProvider().refresh(stored, using: client)
        #expect(renewed.refresh == "refresh-old")
        #expect(renewed.expires == .max)
        #expect(renewed.extras["officeIdentity"] == .string("org-2"))
        #expect(renewed.extras["accountName"] == .string("kept"))
    }

    @Test("A refused or ended token ends the login; any other refusal may pass")
    func refusals() async {
        func kind(_ answer: QueuedHTTPClient.Answer) async -> OAuthRefreshError.Kind? {
            do {
                _ = try await RaccoonOAuthProvider().refresh(stored, using: QueuedHTTPClient([answer]))
                return nil
            } catch {
                return (error as? OAuthRefreshError)?.kind
            }
        }
        for code in [200001, 200003, 200012] {
            #expect(await kind(ok(#"{"code":\#(code),"message":"no"}"#)) == .rejected)
        }
        #expect(await kind(.response(status: 401, body: "{}")) == .rejected)
        #expect(await kind(ok(#"{"code":200429,"message":"slow down"}"#)) == .unavailable)
        #expect(await kind(ok(#"{"code":0,"data":{}}"#)) == .unavailable)
        #expect(await kind(.response(status: 404, body: "")) == .unavailable)
        #expect(await kind(.failure(URLError(.timedOut))) == .unavailable)
    }
}
