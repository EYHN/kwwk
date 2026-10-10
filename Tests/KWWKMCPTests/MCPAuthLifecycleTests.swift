import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKMCP

/// A bearer-token provider whose `onUnauthorized` moves to the next token,
/// or refuses when there is none.
final class SteppingTokenProvider: MCPAuthProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private(set) var unauthorizedCalls: [MCPUnauthorizedContext] = []

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func setTokens(_ tokens: [String]) { lock.withLock { self.tokens = tokens } }

    func token() async throws -> String? { lock.withLock { tokens.first } }

    func onUnauthorized(_ context: MCPUnauthorizedContext) async throws {
        let recovered = lock.withLock { () -> Bool in
            unauthorizedCalls.append(context)
            guard tokens.count > 1 else { return false }
            tokens.removeFirst()
            return true
        }
        if !recovered { throw MCPAuthError.unauthorized("sign in again") }
    }
}

@Suite("MCP auth in the transport and manager")
struct MCPAuthLifecycleTests {
    let url = URL(string: "https://mcp.example.com/mcp")!

    private func transport(_ server: FakeHTTPMCPServer, _ auth: MCPTransportAuth?) -> MCPStreamableHTTPTransport {
        MCPStreamableHTTPTransport(url: url, headers: ["Authorization": "Bearer static"], httpClient: server, auth: auth)
    }

    @Test("every request carries the provider's token; a 401 recovers once and retries")
    func unauthorizedRecovers() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["fresh"]
        let provider = SteppingTokenProvider(["stale", "fresh"])
        let client = MCPClient(transport: transport(server, .provider(provider)))
        try await client.connect(timeoutSeconds: 5)
        #expect(provider.unauthorizedCalls.count == 1)
        let context = try #require(provider.unauthorizedCalls.first)
        #expect(context.rejectedToken == "stale")
        #expect(context.challenge.scope == "read")
        #expect(context.challenge.resourceMetadataURL?.absoluteString
            == "https://mcp.example.com/.well-known/oauth-protected-resource/mcp")
        let posts = server.requests.filter { $0.method == "POST" }
        #expect(posts.first?.headers["Authorization"] == "Bearer stale")
        #expect(posts.dropFirst().allSatisfy { $0.headers["Authorization"] == "Bearer fresh" })
        await client.close()
    }

    @Test("a provider that cannot recover fails the request with its error")
    func unauthorizedFails() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["never"]
        let provider = SteppingTokenProvider(["stale"])
        let client = MCPClient(transport: transport(server, .provider(provider)))
        await #expect(throws: MCPAuthError.unauthorized("sign in again")) {
            try await client.connect(timeoutSeconds: 5)
        }
    }

    @Test("a second 401 after recovery fails without looping")
    func unauthorizedTwice() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["never"]
        let provider = SteppingTokenProvider(["a", "b", "c"])
        let client = MCPClient(transport: transport(server, .provider(provider)))
        await #expect(throws: MCPAuthError.unauthorizedAfterRetry) {
            try await client.connect(timeoutSeconds: 5)
        }
        #expect(provider.unauthorizedCalls.count == 1)
    }

    @Test("without a provider a 401 means authorization is required")
    func unauthorizedWithoutProvider() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["x"]
        let client = MCPClient(transport: transport(server, nil))
        await #expect(throws: MCPAuthError.self) { try await client.connect(timeoutSeconds: 5) }
    }

    @Test("403 insufficient_scope without an OAuth client reports the required scope")
    func insufficientScope() async throws {
        let server = FakeHTTPMCPServer()
        server.scopedTokens = ["admin"]
        let provider = SteppingTokenProvider(["reader"])
        let client = MCPClient(transport: transport(server, .provider(provider)))
        try await client.connect(timeoutSeconds: 5)
        await #expect(throws: MCPAuthError.insufficientScope(requiredScope: "write", description: "needs write")) {
            _ = try await client.callTool(name: "one", arguments: [:])
        }
        await client.close()
    }

    @Test("403 insufficient_scope with an OAuth client steps up and retries once")
    func stepUpSucceeds() async throws {
        let mcp = FakeHTTPMCPServer()
        mcp.scopedTokens = ["access-2"]
        let auth = FakeAuthServer()
        let provider = MemoryOAuthProvider()
        provider.client = MCPOAuthClientInformation(clientID: "client-1", issuer: "https://auth.example.com")
        provider.storedTokens = MCPOAuthTokens(
            accessToken: "access-1", refreshToken: "refresh-1", scope: "read write", issuer: "https://auth.example.com"
        )
        let transport = MCPStreamableHTTPTransport(
            url: url, httpClient: mcp, auth: .oauth(provider, interactive: false), authHTTPClient: auth
        )
        let client = MCPClient(transport: transport)
        try await client.connect(timeoutSeconds: 5)
        let result = try await client.callTool(name: "one", arguments: [:])
        #expect(result.content == [.text("called")])
        let calls = mcp.requests.filter { $0.body?["method"] == "tools/call" }
        #expect(calls.map { $0.headers["Authorization"] } == ["Bearer access-1", "Bearer access-2"])
        #expect(provider.redirects.isEmpty)
        await client.close()
    }

    @Test("a request whose sender gave up during 401 recovery is not sent again")
    func noRetryAfterCancel() async throws {
        final class SlowProvider: MCPAuthProvider, @unchecked Sendable {
            let lock = NSLock()
            var current = "stale"
            func token() async throws -> String? { lock.withLock { current } }
            func onUnauthorized(_ context: MCPUnauthorizedContext) async throws {
                try? await Task.sleep(nanoseconds: 300_000_000)
                lock.withLock { current = "fresh" }
            }
        }
        let server = FakeHTTPMCPServer()
        let provider = SlowProvider()
        let client = MCPClient(transport: transport(server, .provider(provider)))
        try await client.connect(timeoutSeconds: 5)
        server.acceptedTokens = ["fresh"]
        provider.lock.withLock { provider.current = "stale" }
        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(name: "one", arguments: [:], timeoutSeconds: 0.1)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let calls = server.requests.filter { $0.body?["method"] == "tools/call" }
        #expect(calls.count == 1)
        await client.close()
    }

    private func manager(_ server: FakeHTTPMCPServer, _ provider: SteppingTokenProvider?, policy: MCPReconnectPolicy = .none) -> MCPManager {
        let url = url
        return MCPManager(
            configs: [MCPServerConfig(name: "remote", transport: .http(url: url), startupTimeoutSeconds: 5)],
            auth: provider.map { ["remote": .provider($0)] } ?? [:],
            reconnectPolicy: policy,
            transportFactory: { config, auth in
                guard case .http(let url, let headers) = config.transport else { throw MCPError.notConnected }
                return MCPStreamableHTTPTransport(url: url, headers: headers, httpClient: server, auth: auth)
            }
        )
    }

    @Test("a server that needs authorization is left alone until the provider has a new token")
    func managerAuthorizationRequired() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["good"]
        let provider = SteppingTokenProvider(["bad"])
        let manager = manager(server, provider, policy: MCPReconnectPolicy(maxAttempts: 3, initialDelaySeconds: 0.01))
        await manager.waitForStartup(timeout: 5)
        guard case .authorizationRequired = await manager.statuses().first?.state else {
            Issue.record("expected authorizationRequired, got \(String(describing: await manager.statuses().first?.state))")
            return
        }
        #expect(await manager.tools().isEmpty)
        #expect(await manager.unavailableServers() == [ToolSourceStatus(name: "remote", reason: "requires authorization")])

        // Until the provider has another token the server is not asked
        // again: not in the background, not by a search, not by a call.
        let requests = server.requests.count
        try await Task.sleep(nanoseconds: 200_000_000)
        await manager.prepareForSearch(timeout: 1)
        await #expect(throws: MCPManagerError.authorizationRequired("remote")) {
            _ = try await manager.callTool(server: "remote", tool: "one", arguments: [:])
        }
        #expect(server.requests.count == requests)

        // The provider has a new token; the next search picks it up.
        provider.setTokens(["good"])
        await manager.prepareForSearch(timeout: 5)
        #expect(await manager.statuses().first?.state == .connected)
        #expect(await manager.tools().map(\.tool.name) == ["mcp__remote__one", "mcp__remote__two"])
        #expect(await manager.unavailableServers().isEmpty)
        await manager.shutdown()
    }

    @Test("a call picks up a new token for a server that needs authorization")
    func managerAuthorizationRetriedByCall() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["good"]
        let provider = SteppingTokenProvider(["bad"])
        let manager = manager(server, provider)
        await manager.waitForStartup(timeout: 5)
        guard case .authorizationRequired = await manager.statuses().first?.state else {
            Issue.record("expected authorizationRequired")
            return
        }
        provider.setTokens(["good"])
        let result = try await manager.callTool(server: "remote", tool: "one", arguments: [:])
        #expect(result.content == [.text("called")])
        #expect(await manager.statuses().first?.state == .connected)
        await manager.shutdown()
    }

    @Test("credentials refused on a call withdraw the server's tools")
    func managerRefusedOnCall() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["good"]
        let provider = SteppingTokenProvider(["good"])
        let manager = manager(server, provider)
        await manager.waitForStartup(timeout: 5)
        #expect(await manager.tools().count == 2)
        server.acceptedTokens = ["rotated"]
        await #expect(throws: MCPManagerError.authorizationRequired("remote")) {
            _ = try await manager.callTool(server: "remote", tool: "one", arguments: [:])
        }
        #expect(await manager.tools().isEmpty)
        #expect(await manager.unavailableServers() == [ToolSourceStatus(name: "remote", reason: "requires authorization")])
        await manager.shutdown()
    }

    @Test("a call refused for want of scope fails alone; the server stays connected")
    func managerInsufficientScope() async throws {
        let server = FakeHTTPMCPServer()
        server.scopedTokens = ["admin"]
        let manager = manager(server, SteppingTokenProvider(["reader"]))
        await manager.waitForStartup(timeout: 5)
        #expect(await manager.tools().count == 2)
        await #expect(throws: MCPManagerError.insufficientScope("remote", "write")) {
            _ = try await manager.callTool(server: "remote", tool: "one", arguments: [:])
        }
        #expect(await manager.statuses().first?.state == .connected)
        #expect(await manager.tools().count == 2)
        #expect(await manager.unavailableServers().isEmpty)
        // The refused call is not sent again.
        #expect(server.requests.filter { $0.body?["method"] == "tools/call" }.count == 1)
        await manager.shutdown()
    }

    @Test("a 401 to a server without an auth provider is an ordinary failure")
    func noProviderUnauthorizedIsFailure() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["secret"]
        let manager = manager(server, nil)
        await manager.waitForStartup(timeout: 5)
        guard case .failed = await manager.statuses().first?.state else {
            Issue.record("expected failed, got \(String(describing: await manager.statuses().first?.state))")
            return
        }
        #expect(await manager.unavailableServers() == [ToolSourceStatus(name: "remote", reason: "failed to connect")])
        await manager.shutdown()
    }

    @Test("concurrent calls on a server that needs authorization connect it once")
    func concurrentCallsConnectOnce() async throws {
        let server = FakeHTTPMCPServer()
        server.acceptedTokens = ["good"]
        let provider = SteppingTokenProvider(["bad"])
        let manager = manager(server, provider)
        await manager.waitForStartup(timeout: 5)
        provider.setTokens(["good"])
        let initializes = server.requests.filter { $0.body?["method"] == "initialize" }.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await manager.callTool(server: "remote", tool: "one", arguments: [:]) }
            }
            try await group.waitForAll()
        }
        #expect(server.requests.filter { $0.body?["method"] == "initialize" }.count == initializes + 1)
        await manager.shutdown()
    }

    @Test("an authorization error from the provider itself is a failure, not a refusal")
    func providerErrorIsNotRefusal() async throws {
        final class FailingProvider: MCPAuthProvider, @unchecked Sendable {
            func token() async throws -> String? { throw MCPAuthError.unauthorized("no session") }
        }
        let server = FakeHTTPMCPServer()
        let url = url
        let manager = MCPManager(
            configs: [MCPServerConfig(name: "remote", transport: .http(url: url), startupTimeoutSeconds: 5)],
            auth: ["remote": .provider(FailingProvider())],
            reconnectPolicy: .none,
            transportFactory: { config, auth in
                guard case .http(let url, let headers) = config.transport else { throw MCPError.notConnected }
                return MCPStreamableHTTPTransport(url: url, headers: headers, httpClient: server, auth: auth)
            }
        )
        await manager.waitForStartup(timeout: 5)
        guard case .failed = await manager.statuses().first?.state else {
            Issue.record("expected failed, got \(String(describing: await manager.statuses().first?.state))")
            return
        }
        #expect(server.requests.isEmpty)
        #expect(await manager.unavailableServers() == [ToolSourceStatus(name: "remote", reason: "failed to connect")])
        await manager.shutdown()
    }

    @Test("a released catalog unregisters its observer")
    func catalogObserverReleased() async throws {
        let server = FakeHTTPMCPServer()
        let manager = manager(server, nil)
        weak var released: ToolCatalog?
        do {
            let catalog = await manager.makeToolCatalog(searchWaitSeconds: 5)
            released = catalog
            await manager.waitForStartup(timeout: 5)
            #expect(catalog.registeredTools.count == 2)
        }
        #expect(released == nil)
        try await manager.addServer(MCPServerConfig(name: "second", transport: .http(url: url), startupTimeoutSeconds: 5))
        await manager.waitForStartup(timeout: 5)
        #expect(await waitUntil { await manager.observerCount == 0 })
        await manager.shutdown()
    }

    @Test("servers can be added and removed while running")
    func addRemove() async throws {
        let server = FakeHTTPMCPServer()
        let manager = manager(server, nil)
        let seen = Collector<[String]>()
        await manager.onToolsChanged { tools in seen.append(tools.map(\.tool.name)) }
        await manager.waitForStartup(timeout: 5)
        try await manager.addServer(MCPServerConfig(name: "second", transport: .http(url: url), startupTimeoutSeconds: 5))
        await manager.waitForStartup(timeout: 5)
        #expect(await manager.tools().map(\.server) == ["remote", "remote", "second", "second"])
        await #expect(throws: MCPManagerError.duplicateServer("second")) {
            try await manager.addServer(MCPServerConfig(name: "second", transport: .http(url: url)))
        }
        await manager.removeServer("remote")
        #expect(await manager.tools().map(\.server) == ["second", "second"])
        #expect(await manager.statuses().map(\.name) == ["second"])
        #expect(await waitUntil { seen.values.last?.count == 2 })
        await manager.shutdown()
    }

    @Test("a failed connection is retried in the background with backoff")
    func backgroundReconnect() async throws {
        let attempts = Collector<Int>()
        let server = FakeHTTPMCPServer()
        let url = url
        let manager = MCPManager(
            configs: [MCPServerConfig(name: "flaky", transport: .http(url: url), startupTimeoutSeconds: 5)],
            reconnectPolicy: MCPReconnectPolicy(maxAttempts: 3, initialDelaySeconds: 0.05, maxDelaySeconds: 0.1),
            transportFactory: { _, _ in
                attempts.append(1)
                if attempts.values.count < 3 { throw MCPError.spawnFailed("not yet") }
                return MCPStreamableHTTPTransport(url: url, httpClient: server)
            }
        )
        await manager.start()
        #expect(await waitUntil(timeout: 20) { await manager.statuses().first?.state == .connected })
        #expect(attempts.values.count == 3)
        #expect(await manager.tools().count == 2)
        await manager.shutdown()
    }

    @Test("results over the limit are cut, images left out, and the whole result spilled")
    func resultOptions() async throws {
        final class Spill: MCPResultSpill, @unchecked Sendable {
            var received: MCPSpilledResult?
            func spill(_ result: MCPSpilledResult) async throws -> String {
                received = result
                return "/tmp/full.txt"
            }
        }
        let spill = Spill()
        let long = String(repeating: "x", count: 1_000)
        let result = MCPCallToolResult(content: [
            .text(long),
            .image(data: "aGVsbG8=", mimeType: "image/png"),
        ])
        let converted = try await MCPToolAdapter.convert(
            server: "s", tool: "t", result: result,
            options: MCPResultOptions(maxTokens: 100, imageTokens: 50, spill: spill, files: nil)
        )
        guard case .text(let shown)? = converted.content.first, case .text(let note)? = converted.content.last else {
            Issue.record("unexpected blocks \(converted.content)")
            return
        }
        #expect(shown.text.count == 400)
        #expect(note.text.contains("showing 400 of 1000 characters"))
        #expect(note.text.contains("1 image left out"))
        #expect(note.text.contains("/tmp/full.txt"))
        #expect(spill.received?.text == long)
        #expect(spill.received?.images.count == 1)
        // Within the limit nothing changes.
        let small = try await MCPToolAdapter.convert(
            server: "s", tool: "t", result: MCPCallToolResult(content: [.text("hi")]), options: .default
        )
        #expect(small.content.count == 1)
    }

    @Test("a directory spill writes the text and images")
    func directorySpill() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-spill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = try await MCPDirectoryResultSpill(directory: directory).spill(MCPSpilledResult(
            server: "s-1", tool: "t", text: "full", images: [(data: "aGVsbG8=", mimeType: "image/png")]
        ))
        let paths = location.components(separatedBy: ", ")
        #expect(paths.count == 2)
        #expect(try String(contentsOfFile: paths[0], encoding: .utf8) == "full")
        #expect(paths[1].hasSuffix(".png"))
    }
}
