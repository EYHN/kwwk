import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import KWWKAI
import KWWKMCP

/// `oauth` settings of one HTTP server in `mcp.json`.
struct MCPOAuthSettings: Sendable, Hashable {
    /// `client_name` for dynamic registration.
    var clientName: String = "kwwk"
    /// Scope to request when the server does not say.
    var scope: String?
    /// A pre-registered client.
    var clientID: String?
    var clientSecret: String?
    /// HTTPS URL of a client ID metadata document (SEP-991).
    var clientMetadataURL: URL?
    /// Fixed loopback callback port; chosen once and remembered when nil.
    var callbackPort: UInt16?
}

/// What kwwk stores for one server's OAuth client.
struct MCPOAuthRecord: Codable, Sendable, Hashable {
    var serverURL: String
    var client: MCPOAuthClientInformation?
    var tokens: MCPOAuthTokens?
    var codeVerifier: String?
    var discovery: MCPOAuthDiscoveryState?
    var callbackPort: UInt16?
}

/// MCP OAuth credentials on disk: `~/.kwwk/mcp-oauth.json`, mode 0600 in a
/// 0700 directory, keyed by server name. A record for a different server
/// URL is ignored. Every access re-reads the file, and writes happen under
/// an exclusive `flock`, so several kwwk processes never write back stale
/// (e.g. already rotated) tokens.
actor MCPOAuthFileStore {
    let url: URL
    /// Callback ports to remember with a server's record once it is written.
    private var rememberPort: [String: UInt16] = [:]

    init(url: URL) {
        self.url = url
    }

    static func defaultURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent(".kwwk/mcp-oauth.json")
    }

    /// The records on disk, read synchronously (startup).
    nonisolated static func readRecords(url: URL) -> [String: MCPOAuthRecord] {
        (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([String: MCPOAuthRecord].self, from: $0)
        } ?? [:]
    }

    func remember(port: UInt16, server: String) {
        rememberPort[server] = port
    }

    func record(server: String, serverURL: URL) -> MCPOAuthRecord {
        if let record = Self.readRecords(url: url)[server], record.serverURL == serverURL.absoluteString { return record }
        return MCPOAuthRecord(serverURL: serverURL.absoluteString)
    }

    func update(server: String, serverURL: URL, _ change: (inout MCPOAuthRecord) -> Void) throws {
        let port = rememberPort[server]
        try withFileLock {
            var all = Self.readRecords(url: url)
            var record = all[server].flatMap { $0.serverURL == serverURL.absoluteString ? $0 : nil }
                ?? MCPOAuthRecord(serverURL: serverURL.absoluteString)
            change(&record)
            if record.callbackPort == nil { record.callbackPort = port }
            all[server] = record
            try write(all)
        }
    }

    func remove(server: String) throws {
        try withFileLock {
            var all = Self.readRecords(url: url)
            guard all.removeValue(forKey: server) != nil else { return }
            try write(all)
        }
    }

    private func ensureDirectory() throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectory()
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw MCPAuthError.providerMisconfigured("Could not open \(url.path).lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MCPAuthError.providerMisconfigured("Could not lock \(url.path)") }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// Write atomically: a 0600 temporary file renamed over the store.
    private func write(_ all: [String: MCPOAuthRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(all)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".mcp-oauth-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw MCPAuthError.providerMisconfigured("Could not create \(temporary.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw MCPAuthError.providerMisconfigured("Could not write \(url.path)")
        }
    }
}

/// kwwk's OAuth client for one MCP server: credentials in
/// `MCPOAuthFileStore`, the user agent is the system browser, and the
/// redirect lands on `http://127.0.0.1:<port>/callback`. The transport runs
/// it non-interactively (refresh only), so only `login()` ever registers a
/// client, writes a verifier or opens the browser; a server that needs more
/// waits for `/mcp login`.
final class CLIMCPOAuthProvider: MCPOAuthClientRegistrationStore, MCPOAuthDiscoveryStore,
    MCPOAuthCredentialInvalidation, @unchecked Sendable {
    let server: String
    let serverURL: URL
    let settings: MCPOAuthSettings
    let store: MCPOAuthFileStore
    let callbackPort: UInt16

    private let lock = NSLock()
    private var pendingAuthorizationURL: URL?
    private var issuedState: String?

    init(server: String, serverURL: URL, settings: MCPOAuthSettings, store: MCPOAuthFileStore, callbackPort: UInt16) {
        self.server = server
        self.serverURL = serverURL
        self.settings = settings
        self.store = store
        self.callbackPort = callbackPort
    }

    var redirectURL: URL {
        URL(string: "http://127.0.0.1:\(callbackPort)/callback")!
    }

    var clientMetadata: MCPOAuthClientMetadata {
        MCPOAuthClientMetadata(
            redirectURIs: [redirectURL.absoluteString],
            clientName: settings.clientName,
            scope: settings.scope,
            grantTypes: ["authorization_code", "refresh_token"],
            tokenEndpointAuthMethod: settings.clientSecret == nil ? "none" : "client_secret_post"
        )
    }

    var clientMetadataURL: URL? { settings.clientMetadataURL }

    func state() async throws -> String? {
        let value = PKCE.randomHex(bytes: 32)
        lock.withLock { issuedState = value }
        return value
    }

    func clientInformation(_ context: MCPOAuthStorageContext?) async throws -> MCPOAuthClientInformation? {
        if let clientID = settings.clientID {
            return MCPOAuthClientInformation(clientID: clientID, clientSecret: settings.clientSecret)
        }
        return await store.record(server: server, serverURL: serverURL).client
    }

    func saveClientInformation(_ information: MCPOAuthClientInformation, context: MCPOAuthStorageContext?) async throws {
        guard settings.clientID == nil else { return }
        try await store.update(server: server, serverURL: serverURL) { $0.client = information }
    }

    func tokens(_ context: MCPOAuthStorageContext?) async throws -> MCPOAuthTokens? {
        await store.record(server: server, serverURL: serverURL).tokens
    }

    func saveTokens(_ tokens: MCPOAuthTokens, context: MCPOAuthStorageContext?) async throws {
        try await store.update(server: server, serverURL: serverURL) { $0.tokens = tokens }
    }

    func redirectToAuthorization(_ url: URL) async throws {
        lock.withLock { pendingAuthorizationURL = url }
        Browser.open(url)
    }

    func saveCodeVerifier(_ verifier: String) async throws {
        try await store.update(server: server, serverURL: serverURL) { $0.codeVerifier = verifier }
    }

    func codeVerifier() async throws -> String {
        guard let verifier = await store.record(server: server, serverURL: serverURL).codeVerifier else {
            throw MCPAuthError.providerMisconfigured("No PKCE code verifier saved for \(server)")
        }
        return verifier
    }

    func discoveryState() async throws -> MCPOAuthDiscoveryState? {
        await store.record(server: server, serverURL: serverURL).discovery
    }

    func saveDiscoveryState(_ state: MCPOAuthDiscoveryState) async throws {
        try await store.update(server: server, serverURL: serverURL) { $0.discovery = state }
    }

    func invalidateCredentials(_ scope: MCPOAuthCredentialScope) async throws {
        try await store.update(server: server, serverURL: serverURL) { record in
            switch scope {
            case .all:
                record.client = nil
                record.tokens = nil
                record.codeVerifier = nil
                record.discovery = nil
            case .client: record.client = nil
            case .tokens: record.tokens = nil
            case .verifier: record.codeVerifier = nil
            case .discovery: record.discovery = nil
            }
        }
    }

    // MARK: - Login

    /// Sign in with the browser: start the callback listener, run a fresh
    /// authorization (never just a refresh, so it also widens scope and
    /// switches accounts), check `state`, and exchange the code.
    func login(httpClient: any MCPAuthHTTPClient = URLSessionMCPAuthHTTPClient(), timeoutSeconds: Double = 300) async throws {
        let callback = try OAuthCallbackServer(port: callbackPort, path: "/callback")
        try callback.start()
        defer { callback.stop() }
        lock.withLock { pendingAuthorizationURL = nil }

        let result = try await MCPOAuth.auth(self, options: MCPOAuthOptions(
            serverURL: serverURL,
            forceReauthorization: true,
            httpClient: httpClient
        ))
        guard result == .redirect else { return }
        if let url = lock.withLock({ pendingAuthorizationURL }) {
            FileHandle.standardError.write(Data("If the browser did not open, visit:\n  \(url.absoluteString)\n".utf8))
        }
        let parameters = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await callback.waitForCallback() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw MCPAuthError.unauthorized("Timed out waiting for the browser")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
        let expected = lock.withLock { issuedState }
        guard let expected, parameters["state"] == expected else {
            throw MCPAuthError.unauthorized("The authorization callback's state did not match")
        }
        try await MCPOAuth.finishAuthorization(
            self,
            serverURL: serverURL,
            callbackParameters: parameters,
            httpClient: httpClient
        )
    }
}

enum MCPOAuthCLI {
    /// The callback port of `server`: configured, else remembered, else a
    /// new random one (remembered with the server's record, since a
    /// registered client is bound to its redirect URI).
    static func callbackPort(
        server: String,
        serverURL: URL,
        settings: MCPOAuthSettings,
        records: [String: MCPOAuthRecord]
    ) -> UInt16 {
        if let port = settings.callbackPort { return port }
        if let record = records[server], record.serverURL == serverURL.absoluteString, let port = record.callbackPort {
            return port
        }
        return UInt16.random(in: 49_152...65_000)
    }
}
