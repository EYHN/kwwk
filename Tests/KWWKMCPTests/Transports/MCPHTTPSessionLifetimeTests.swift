import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKMCP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A real HTTP server in Python: `POST /mcp` always answers 401 with a
/// `WWW-Authenticate` challenge, like an MCP server nobody signed in to, and
/// `GET /slow` streams a line every 100 ms for about three seconds.
private enum UnauthorizedMCPServer {
    static let script = #"""
import sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        body = b'{"error":"authentication failed"}'
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Bearer resource_metadata="http://127.0.0.1/.well-known/oauth-protected-resource", scope="read write"')
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for index in range(30):
            line = ("line %d\n" % index).encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(line), line))
            self.wfile.flush()
            time.sleep(0.1)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
sys.stdout.write("%d\n" % server.server_address[1])
sys.stdout.flush()
server.serve_forever()
"""#

    /// Starts the server and returns it with the port it listens on.
    static func start() throws -> (process: Process, port: Int, directory: URL)? {
        guard let python = FakeMCPServer.python else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-mcp-401-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("server.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [scriptURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([0x0A]) {
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            process.terminate()
            return nil
        }
        return (process, port, directory)
    }
}

/// A host that holds no token yet: the person has not signed in.
private struct SignedOutProvider: MCPAuthProvider {
    func token() async throws -> String? { nil }
}

@Suite("MCP HTTP transport session lifetime", .serialized)
struct MCPHTTPSessionLifetimeTests {
    // Regression (2026-11-11): on Linux a worker died right after its agent
    // added a Connection nobody had signed in to. The server's 401 closed
    // the transport, the transport released the `URLSession` it had made for
    // itself, and swift-corelibs-foundation aborted the process ("_MultiHandle
    // deallocated with non-zero retain count") while a model request was
    // still streaming on another session. The abort is a race inside curl's
    // callbacks and did not fire on the Linux CI image before the fix, so
    // this guards the behaviour (connections come and go, other requests
    // keep streaming) rather than proving the crash is gone; transports now
    // share `URLSessionHTTPClient.shared` and release no session at all.
    @Test("a refused MCP connection leaves a request streaming elsewhere alone")
    func refusedConnectionKeepsOtherRequestsAlive() async throws {
        guard let server = try UnauthorizedMCPServer.start() else { return }
        defer {
            server.process.terminate()
            try? FileManager.default.removeItem(at: server.directory)
        }
        let base = "http://127.0.0.1:\(server.port)"

        // The model request: a response that keeps streaming throughout.
        let model = URLSessionHTTPClient()
        let (response, bytes) = try await model.stream(
            url: URL(string: "\(base)/slow")!,
            method: "GET",
            headers: [:],
            body: nil,
            cancellation: nil
        )
        #expect(response.statusCode == 200)
        let streamed = Task<String, Error> {
            var data = Data()
            for try await chunk in bytes { data.append(chunk) }
            return String(decoding: data, as: UTF8.self)
        }

        // Meanwhile servers nobody signed in to are added and refused, each
        // on a transport of its own that closes at once.
        for round in 0..<5 {
            let manager = MCPManager(
                configs: [MCPServerConfig(
                    name: "refused\(round)",
                    transport: .http(url: URL(string: "\(base)/mcp")!),
                    startupTimeoutSeconds: 10
                )],
                auth: ["refused\(round)": .provider(SignedOutProvider())]
            )
            await manager.waitForStartup(timeout: 10)
            let state = await manager.statuses().first?.state
            guard case .authorizationRequired = state else {
                Issue.record("expected the server to need authorization, got \(String(describing: state))")
                await manager.shutdown()
                continue
            }
            await manager.shutdown()
        }

        let text = try await streamed.value
        #expect(text.hasPrefix("line 0\n"))
        #expect(text.hasSuffix("line 29\n"))
    }
}
