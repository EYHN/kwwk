import Foundation
import Testing
@testable import KWWKCli
@testable import KWWKMCP

@Suite("MCP OAuth in the CLI")
struct MCPOAuthCLITests {
    private func load(_ json: String) throws -> (MCPConfigFile.Loaded, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-mcpoauth-\(UUID().uuidString)")
        let kwwk = root.appendingPathComponent("home/.kwwk")
        try FileManager.default.createDirectory(at: kwwk, withIntermediateDirectories: true)
        try json.write(to: kwwk.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        let loaded = MCPConfigFile.load(
            cwd: root.appendingPathComponent("project").path,
            homeDirectory: root.appendingPathComponent("home").path,
            trustProject: false,
            environment: ["SECRET": "s3"]
        )
        return (loaded, root)
    }

    @Test("HTTP servers use OAuth unless they send Authorization or opt out")
    func oauthDefaults() throws {
        let (loaded, root) = try load("""
        {"mcpServers": {
          "plain": {"url": "https://a.example/mcp"},
          "keyed": {"url": "https://b.example/mcp", "headers": {"Authorization": "Bearer x"}},
          "off": {"url": "https://c.example/mcp", "oauth": false},
          "custom": {"url": "https://d.example/mcp", "toolMaxTotalTimeout": 600, "oauth": {
            "clientName": "Codex", "scope": "read", "clientId": "id", "clientSecret": "${SECRET}",
            "clientMetadataUrl": "https://client.example/c.json", "callbackPort": 4567}},
          "local": {"command": "x"}
        }}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(loaded.warnings.isEmpty)
        let byName = Dictionary(uniqueKeysWithValues: loaded.entries.map { ($0.server.name, $0) })
        #expect(byName["plain"]?.oauth == MCPOAuthSettings())
        #expect(byName["keyed"]?.oauth == nil)
        #expect(byName["off"]?.oauth == nil)
        #expect(byName["local"]?.oauth == nil)
        let custom = try #require(byName["custom"]?.oauth)
        #expect(custom.clientName == "Codex")
        #expect(custom.scope == "read")
        #expect(custom.clientID == "id")
        #expect(custom.clientSecret == "s3")
        #expect(custom.clientMetadataURL?.absoluteString == "https://client.example/c.json")
        #expect(custom.callbackPort == 4567)
        #expect(byName["custom"]?.server.toolMaxTotalTimeoutSeconds == 600)
    }

    @Test("invalid oauth settings become warnings")
    func invalidOAuth() throws {
        let (loaded, root) = try load("""
        {"mcpServers": {"bad": {"url": "https://a.example/mcp", "oauth": {"callbackPort": 99999}}}}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(loaded.entries.isEmpty)
        #expect(loaded.warnings.contains { $0.contains("oauth.callbackPort") })
    }

    @Test("the file store keeps one record per server, mode 0600, and ignores a moved server")
    func fileStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-mcpstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mcp-oauth.json")
        let store = MCPOAuthFileStore(url: url)
        let serverURL = URL(string: "https://a.example/mcp")!
        let provider = CLIMCPOAuthProvider(
            server: "a", serverURL: serverURL, settings: MCPOAuthSettings(), store: store, callbackPort: 4567
        )
        await store.remember(port: 4567, server: "a")
        try await provider.saveTokens(MCPOAuthTokens(accessToken: "t1", refreshToken: "r1"), context: nil)
        try await provider.saveClientInformation(MCPOAuthClientInformation(clientID: "c1"), context: nil)
        #expect(try await provider.tokens(nil)?.accessToken == "t1")
        #expect(try await provider.clientInformation(nil)?.clientID == "c1")
        #expect(provider.redirectURL.absoluteString == "http://127.0.0.1:4567/callback")
        #expect(provider.clientMetadata.redirectURIs == ["http://127.0.0.1:4567/callback"])

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let records = MCPOAuthFileStore.readRecords(url: url)
        #expect(records["a"]?.callbackPort == 4567)
        #expect(MCPOAuthCLI.callbackPort(
            server: "a", serverURL: serverURL, settings: MCPOAuthSettings(), records: records
        ) == 4567)

        // The same name at another URL starts clean.
        let moved = CLIMCPOAuthProvider(
            server: "a", serverURL: URL(string: "https://b.example/mcp")!, settings: MCPOAuthSettings(), store: store, callbackPort: 1
        )
        #expect(try await moved.tokens(nil) == nil)

        try await provider.invalidateCredentials(.tokens)
        #expect(try await provider.tokens(nil) == nil)
        #expect(try await provider.clientInformation(nil)?.clientID == "c1")
        try await store.remove(server: "a")
        #expect(try await provider.clientInformation(nil) == nil)
    }

    @Test("a pre-registered client is used as configured and never overwritten")
    func preregistered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-mcpstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = MCPOAuthSettings()
        settings.clientID = "fixed"
        settings.clientSecret = "shh"
        let provider = CLIMCPOAuthProvider(
            server: "a", serverURL: URL(string: "https://a.example/mcp")!, settings: settings,
            store: MCPOAuthFileStore(url: root.appendingPathComponent("s.json")), callbackPort: 1
        )
        try await provider.saveClientInformation(MCPOAuthClientInformation(clientID: "dynamic"), context: nil)
        let client = try await provider.clientInformation(nil)
        #expect(client?.clientID == "fixed")
        #expect(client?.clientSecret == "shh")
        #expect(provider.clientMetadata.tokenEndpointAuthMethod == "client_secret_post")
    }
}
