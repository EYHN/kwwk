import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import KWWKAuth

@Suite("Auth-only hosts get the shared default loopback")
struct DefaultLoopbackTests {
    @Test("The default receives codes and provider errors over real HTTP", arguments: [
        (UInt16(53995), "code=auth-code&state=echoed", "code", "auth-code", 200),
        (UInt16(53996), "error=access_denied", "error", "access_denied", 400),
    ])
    func callback(port: UInt16, query: String, key: String, value: String, status: Int) async throws {
        let listener = try OAuthLogin.Callbacks().loopback("127.0.0.1", port, "/callback")
        defer { listener.stop() }
        try await listener.listen()
        let url = try #require(URL(string: "\(listener.redirectURI)?\(query)"))
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == status)
        let params = try await listener.waitForCallback()
        #expect(params[key] == value)
    }
}
