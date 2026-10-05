import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKMCP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// In-process fake of a streamable HTTP MCP server, plugged in as the
/// transport's `HTTPClient`.
final class FakeHTTPMCPServer: HTTPClient, @unchecked Sendable {
    struct Recorded: Sendable {
        var method: String
        var headers: [String: String]
        var body: JSONValue?
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    var requests: [Recorded] { lock.withLock { recorded } }
    let sessionId = "session-123"
    /// Answer tools/list with an expired session once.
    var expireSession = false
    /// When set, POSTs must carry one of these bearer tokens or get 401.
    var acceptedTokens: Set<String>?
    /// When set, tools/call needs one of these tokens or gets 403
    /// insufficient_scope.
    var scopedTokens: Set<String>?

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let json = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        lock.withLock { recorded.append(Recorded(method: method, headers: headers, body: json)) }
        switch method {
        case "GET":
            return respond(url, 405, [:], "")
        case "DELETE":
            return respond(url, 200, [:], "")
        default:
            break
        }
        guard let json, case .string(let rpcMethod)? = json["method"] else {
            return respond(url, 400, [:], "bad request")
        }
        let bearer = headers["Authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        if let acceptedTokens, !acceptedTokens.contains(bearer ?? "") {
            return respond(url, 401, [
                "WWW-Authenticate": #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="read""#,
            ], "unauthorized")
        }
        if rpcMethod == "tools/call", let scopedTokens, !scopedTokens.contains(bearer ?? "") {
            return respond(url, 403, [
                "WWW-Authenticate": #"Bearer error="insufficient_scope", scope="write", error_description="needs write""#,
            ], "forbidden")
        }
        let id = json["id"] ?? .null
        switch rpcMethod {
        case "initialize":
            let result: JSONValue = [
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "protocolVersion": "2025-03-26",
                    "capabilities": ["tools": .object([:])],
                    "serverInfo": ["name": "http-fake", "version": "0.1"],
                    "instructions": "  HTTP server  ",
                ],
            ]
            return respond(url, 200, ["Content-Type": "application/json", "Mcp-Session-Id": sessionId], text(result))
        case "tools/list":
            if expireSession {
                expireSession = false
                return respond(url, 404, [:], "unknown session")
            }
            let cursor = json["params"]?["cursor"]
            let page: JSONValue = cursor == nil
                ? ["tools": [["name": "one", "inputSchema": ["type": "object"]]], "nextCursor": "2"]
                : ["tools": [["name": "two", "inputSchema": ["type": "object"]]]]
            let sse = "event: message\ndata: \(text(["jsonrpc": "2.0", "id": id, "result": page]))\n\n"
            return respond(url, 200, ["Content-Type": "text/event-stream"], sse)
        case "tools/call":
            let token = json["params"]?["_meta"]?["progressToken"] ?? .null
            let progress: JSONValue = [
                "jsonrpc": "2.0", "method": "notifications/progress",
                "params": ["progressToken": token, "progress": 5, "message": "working"],
            ]
            let listChanged: JSONValue = ["jsonrpc": "2.0", "method": "notifications/tools/list_changed"]
            let response: JSONValue = [
                "jsonrpc": "2.0", "id": id,
                "result": ["content": [["type": "text", "text": "called"]]],
            ]
            let sse = ": comment\n\nid: 1\ndata: \(text(progress))\n\ndata: \(text(listChanged))\n\ndata: \(text(response))\n\n"
            return respond(url, 200, ["Content-Type": "text/event-stream; charset=utf-8"], sse, chunkSize: 7)
        default:
            if json["id"] == nil {
                return respond(url, 202, [:], "")
            }
            let error: JSONValue = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "nope"]]
            return respond(url, 200, ["Content-Type": "application/json"], text(error))
        }
    }

    private func text(_ value: JSONValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }

    private func respond(
        _ url: URL, _ status: Int, _ headers: [String: String], _ body: String, chunkSize: Int = 1 << 20
    ) -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let bytes = Array(body.utf8)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            var index = 0
            while index < bytes.count {
                let end = min(index + chunkSize, bytes.count)
                continuation.yield(Data(bytes[index..<end]))
                index = end
            }
            continuation.finish()
        }
        return (response, stream)
    }
}

@Suite("MCP streamable HTTP transport")
struct MCPHTTPTransportTests {
    @Test("handshake, session headers, JSON and SSE responses, DELETE on close")
    func roundTrip() async throws {
        let server = FakeHTTPMCPServer()
        let url = URL(string: "https://mcp.example.com/mcp")!
        let transport = MCPStreamableHTTPTransport(url: url, headers: ["Authorization": "Bearer t"], httpClient: server)
        let client = MCPClient(transport: transport)
        let changed = Collector<Int>()
        await client.setToolsListChangedHandler { changed.append(1) }
        try await client.connect(timeoutSeconds: 5)
        #expect(await client.instructions == "HTTP server")
        #expect(await client.negotiatedProtocolVersion == "2025-03-26")
        #expect(transport.currentSessionId == "session-123")

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["one", "two"])

        let progress = Collector<MCPProgress>()
        let result = try await client.callTool(name: "one", arguments: [:], onProgress: { progress.append($0) })
        #expect(result.content == [.text("called")])
        #expect(progress.values == [MCPProgress(progress: 5, message: "working")])
        #expect(await waitUntil { changed.values.count == 1 })

        await client.close()

        let requests = server.requests
        let posts = requests.filter { $0.method == "POST" }
        let initialize = try #require(posts.first)
        #expect(initialize.body?["method"] == "initialize")
        #expect(initialize.body?["params"]?["protocolVersion"] == "2025-11-25")
        #expect(initialize.body?["params"]?["clientInfo"]?["name"] == "kwwk")
        #expect(initialize.headers["Accept"] == "application/json, text/event-stream")
        #expect(initialize.headers["Authorization"] == "Bearer t")
        #expect(initialize.headers["Mcp-Session-Id"] == nil)
        #expect(initialize.headers["MCP-Protocol-Version"] == nil)
        let initialized = posts[1]
        #expect(initialized.body?["method"] == "notifications/initialized")
        #expect(initialized.headers["Mcp-Session-Id"] == "session-123")
        for later in posts.dropFirst(2) {
            #expect(later.headers["Mcp-Session-Id"] == "session-123")
            #expect(later.headers["MCP-Protocol-Version"] == "2025-03-26")
        }
        #expect(requests.contains { $0.method == "GET" && $0.headers["Accept"] == "text/event-stream" })
        let delete = try #require(requests.last)
        #expect(delete.method == "DELETE")
        #expect(delete.headers["Mcp-Session-Id"] == "session-123")
    }

    @Test("server errors surface as MCPError; an expired session ends the connection")
    func errors() async throws {
        let server = FakeHTTPMCPServer()
        let transport = MCPStreamableHTTPTransport(url: URL(string: "https://x.example/mcp")!, httpClient: server)
        let client = MCPClient(transport: transport)
        let closed = Collector<String>()
        await client.setCloseHandler { error in closed.append(error.map(MCPClient.describe) ?? "") }
        try await client.connect(timeoutSeconds: 5)
        await #expect(throws: MCPError.server(code: -32601, message: "nope", data: nil)) {
            _ = try await client.request(method: "resources/list", params: nil)
        }
        server.expireSession = true
        await #expect(throws: MCPError.sessionExpired) { _ = try await client.listTools() }
        // The owner hears about it and reconnects with a fresh session.
        #expect(await waitUntil { closed.values.count == 1 })
        #expect(await !client.isConnected)
    }
}
