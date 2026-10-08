import Foundation
import Crypto
import Testing
import KWWKAuth

@Suite("Sign-in through an app's presenter and loopback")
struct LoginSeamTests {
    private func callbacks(
        presenter: RecordingPresenter,
        params: [String: String],
        echoState: Bool = true,
        made: LoopbackBox
    ) -> OAuthLogin.Callbacks {
        var callbacks = quietCallbacksBase
        callbacks.browser = presenter
        callbacks.loopback = { host, port, path in
            let loopback = ScriptedLoopback(host: host, port: port, path: path, params: params, echoState: echoState)
            presenter.loopback = loopback
            made.set(loopback)
            return loopback
        }
        return callbacks
    }

    @Test("Claude binds its registered redirect and exchanges the verifier through the app's presenter")
    func anthropicThroughSeams() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"a","refresh_token":"r","expires_in":28800}"#),
        ])
        let presenter = RecordingPresenter()
        let made = LoopbackBox()
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let credentials = try await OAuthLogin.loginAnthropic(
            callbacks: callbacks(presenter: presenter, params: ["code": "the-code"], made: made),
            client: client
        )
        let loopback = try #require(made.value)
        #expect(loopback.redirectURI == "http://localhost:53692/callback")
        #expect(loopback.listened && loopback.stopped)
        let url = try #require(presenter.shown.first)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let state = try #require(query.first { $0.name == "state" }?.value)
        #expect(query.first { $0.name == "redirect_uri" }?.value == loopback.redirectURI)
        #expect(query.first { $0.name == "code_challenge" }?.value == PKCE.base64URL(Data(SHA256.hash(data: Data(state.utf8)))))
        let request = try #require(client.requests.first)
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body["state"] == state)
        #expect(body["code_verifier"] == state)
        #expect(body["code"] == "the-code")
        #expect(body["redirect_uri"] == loopback.redirectURI)
        #expect(credentials.refresh == "r")
        #expect(credentials.expires >= before + (28800 - 300) * 1000)
        #expect(credentials.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (28800 - 300) * 1000)
    }

    @Test("Claude refuses missing or mismatched state and empty codes before exchanging", arguments: [
        ["code": "c"], ["code": "c", "state": "wrong"], ["code": "", "state": "wrong"],
    ])
    func anthropicInvalidCallback(params: [String: String]) async throws {
        let client = QueuedHTTPClient([])
        let made = LoopbackBox()
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginAnthropic(
                callbacks: callbacks(presenter: RecordingPresenter(), params: params, echoState: false, made: made),
                client: client
            )
        }
        #expect(client.requestCount == 0)
        #expect(made.value?.stopped == true)
    }

    @Test("Claude authorization denial cancels and releases the listener")
    func anthropicDenied() async throws {
        let made = LoopbackBox()
        let client = QueuedHTTPClient([])
        await #expect(throws: OAuthLoginError.cancelled) {
            _ = try await OAuthLogin.loginAnthropic(
                callbacks: callbacks(presenter: RecordingPresenter(), params: ["error": "access_denied"], made: made),
                client: client
            )
        }
        #expect(made.value?.stopped == true)
        #expect(client.requestCount == 0)
    }

    @Test("Claude grants must carry access and refresh tokens", arguments: [
        #"{"access_token":"a"}"#,
        #"{"access_token":"a","refresh_token":""}"#,
        #"{"access_token":"","refresh_token":"r"}"#,
    ])
    func anthropicNeedsCredentials(body: String) async throws {
        let made = LoopbackBox()
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginAnthropic(
                callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: made),
                client: QueuedHTTPClient([.response(status: 200, body: body)])
            )
        }
        #expect(made.value?.stopped == true)
    }

    @Test("Codex binds the registered redirect, shows the page through the presenter and keeps the account id")
    func codexThroughSeams() async throws {
        let access = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-7"]])
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"\#(access)","refresh_token":"r-1","expires_in":864000}"#),
        ])
        let presenter = RecordingPresenter()
        let made = LoopbackBox()
        let credentials = try await OAuthLogin.loginOpenAICodex(
            callbacks: callbacks(presenter: presenter, params: ["code": "the-code"], made: made),
            client: client
        )
        let loopback = try #require(made.value)
        #expect(loopback.redirectURI == "http://localhost:1455/auth/callback")
        #expect(loopback.listened && loopback.stopped)
        let shown = try #require(presenter.shown.first)
        #expect(shown.host == "auth.openai.com")
        #expect(credentials.refresh == "r-1")
        #expect(credentials.extras["accountId"] == .string("acct-7"))
        let form = String(data: client.requests[0].body ?? Data(), encoding: .utf8) ?? ""
        #expect(form.contains("code=the-code"))
    }

    @Test("A user who declines in the browser cancels the sign-in")
    func codexDenied() async throws {
        let presenter = RecordingPresenter()
        await #expect(throws: OAuthLoginError.cancelled) {
            _ = try await OAuthLogin.loginOpenAICodex(
                callbacks: callbacks(presenter: presenter, params: ["error": "access_denied"], made: LoopbackBox()),
                client: QueuedHTTPClient([])
            )
        }
    }

    @Test("A redirect without the flow's state is refused before any exchange")
    func codexStateRequired() async throws {
        let client = QueuedHTTPClient([])
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginOpenAICodex(
                callbacks: callbacks(
                    presenter: RecordingPresenter(), params: ["code": "c"], echoState: false, made: LoopbackBox()
                ),
                client: client
            )
        }
        #expect(client.requestCount == 0)
    }

    @Test("A Codex grant without a refresh token is refused")
    func codexNeedsRefresh() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"access_token":"a","expires_in":3600}"#),
        ])
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthLogin.loginOpenAICodex(
                callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: LoopbackBox()),
                client: client
            )
        }
    }

    @Test("Devin binds the numeric loopback host it registered")
    func devinHost() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"token":"devin-token"}"#),
        ])
        let made = LoopbackBox()
        let credentials = try await OAuthLogin.loginDevin(
            callbacks: callbacks(presenter: RecordingPresenter(), params: ["code": "c"], made: made),
            client: client
        )
        #expect(made.value?.redirectURI == "http://127.0.0.1:59653/callback")
        #expect(credentials.access == "devin-token")
        #expect(credentials.refresh == "")
    }

    @Test("A redirect flow with no loopback says so")
    func noLoopback() async throws {
        await #expect(throws: OAuthLoginError.noLoopbackListener) {
            _ = try await OAuthLogin.loginOpenAICodex(callbacks: quietCallbacksBase, client: QueuedHTTPClient([]))
        }
    }

    @Test("A device flow shows its code before the verification page opens")
    func deviceCodeFirst() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"device_code":"DC","user_code":"ABCD-1234","verification_uri":"https://auth.x.ai/activate","interval":0,"expires_in":900}"#),
            .response(status: 200, body: #"{"access_token":"xa","refresh_token":"xr","expires_in":3600}"#),
        ])
        let events = EventLog()
        let presenter = RecordingPresenter()
        presenter.events = events
        var callbacks = quietCallbacksBase
        callbacks.browser = presenter
        callbacks.onUserCode = { code, url in
            events.append("code \(code) \(url.host ?? "")")
        }
        let credentials = try await OAuthLogin.loginXai(callbacks: callbacks, client: client)
        #expect(events.entries == ["code ABCD-1234 auth.x.ai", "present"])
        #expect(credentials.refresh == "xr")
    }

    @Test("An expired device code times the sign-in out")
    func deviceCodeExpired() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://auth.x.ai/activate","interval":0,"expires_in":900}"#),
            .response(status: 400, body: #"{"error":"expired_token"}"#),
        ])
        await #expect(throws: OAuthLoginError.timedOut) {
            _ = try await OAuthLogin.loginXai(callbacks: quietCallbacksBase, client: client)
        }
    }

    @Test("A device poll rides out a thrown request")
    func devicePollRetriesTransport() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://auth.x.ai/activate","interval":0,"expires_in":900}"#),
            .failure(URLError(.networkConnectionLost)),
            .response(status: 200, body: #"{"access_token":"xa","refresh_token":"xr"}"#),
        ])
        let credentials = try await OAuthLogin.loginXai(callbacks: quietCallbacksBase, client: client)
        #expect(credentials.access == "xa")
    }

    @Test("Kimi records the device id it signed in with, using the app's fingerprint")
    func kimiRecordsDevice() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"device_code":"DC","user_code":"UC","verification_uri":"https://www.kimi.com/device","interval":0,"expires_in":900}"#),
            .response(status: 200, body: #"{"access_token":"ka","refresh_token":"kr","expires_in":900}"#),
        ])
        let identity = KimiDeviceIdentity(
            deviceId: "APP-DEVICE-1", deviceName: "Ada’s iPhone", deviceModel: "iOS arm64", osVersion: "27.0"
        )
        let credentials = try await OAuthLogin.loginKimiCoding(
            identity: identity, callbacks: quietCallbacksBase, client: client
        )
        #expect(credentials.extras["deviceId"] == .string("APP-DEVICE-1"))
        #expect(client.header("X-Msh-Device-Id", request: 0) == "APP-DEVICE-1")
        #expect(client.header("X-Msh-Device-Model", request: 1) == "iOS arm64")
        // Non-ASCII is stripped from header values.
        #expect(client.header("X-Msh-Device-Name", request: 0) == "Adas iPhone")
    }
}

final class LoopbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScriptedLoopback?
    var value: ScriptedLoopback? { lock.withLock { stored } }
    func set(_ loopback: ScriptedLoopback) { lock.withLock { stored = loopback } }
}
