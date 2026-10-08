import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import KWWKAI

@Suite("KWWKAI's legacy login hooks keep their default loopback")
struct OAuthLoginCompatibilityTests {
    @Test("The two-hook API receives a real callback with the requested host and path", arguments: [
        ("localhost", UInt16(53992), "/auth/callback"),
        ("127.0.0.1", UInt16(53993), "/callback"),
    ])
    func defaultLoopback(host: String, port: UInt16, path: String) async throws {
        let callbacks = KWWKAI.OAuthLogin.Callbacks(onAuthURL: { _ in }, onProgress: { _ in })
        let factory = try #require(callbacks.loopback)
        let listener = try factory(host, port, path)
        defer { listener.stop() }
        #expect(listener.redirectURI == "http://\(host):\(port)\(path)")
        try await listener.listen()

        let url = try #require(URL(string: "\(listener.redirectURI)?code=legacy&state=echoed"))
        _ = try await URLSession.shared.data(from: url)
        let params = try await listener.waitForCallback()
        #expect(params["code"] == "legacy")
        #expect(params["state"] == "echoed")
    }

    @Test("The full initializer keeps an explicit custom factory instead of the default")
    func explicitFactory() throws {
        let callbacks = OAuthLogin.Callbacks(
            onAuthURL: { _ in }, onProgress: { _ in },
            loopback: { host, port, path in
                try OAuthCallbackServer(
                    port: port, path: path, successHTML: "custom",
                    redirectHost: host, surfacesProviderErrors: true
                )
            }
        )
        let factory = try #require(callbacks.loopback)
        let listener = try factory("127.0.0.1", 53994, "/custom")
        defer { listener.stop() }
        let server = try #require(listener as? OAuthCallbackServer)
        #expect(server.successHTML == "custom")
        #expect(server.redirectURI == "http://127.0.0.1:53994/custom")
    }

    @Test("An explicit nil still opts out of the default listener")
    func explicitNil() async throws {
        let callbacks = OAuthLogin.Callbacks(
            onAuthURL: { _ in }, onProgress: { _ in }, loopback: nil
        )
        #expect(callbacks.loopback == nil)
        await #expect(throws: OAuthLoginError.noLoopbackListener) {
            _ = try await OAuthLogin.loginOpenAICodex(callbacks: callbacks)
        }
    }
}
