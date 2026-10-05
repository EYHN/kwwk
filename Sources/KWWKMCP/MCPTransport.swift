import Foundation
import KWWKAI

/// A bidirectional channel carrying JSON-RPC messages to and from one MCP
/// server.
///
/// `start()` returns the stream of inbound messages. The stream finishes when
/// the connection closes — normally after `close()`, or with an error when the
/// server went away (process exit, HTTP failure of the listening stream).
public protocol MCPTransport: AnyObject, Sendable {
    /// Open the connection and return the inbound message stream. Called once.
    func start() async throws -> AsyncThrowingStream<JSONRPCMessage, Error>
    /// Send one message. For HTTP this posts the message and feeds whatever
    /// the server answers (JSON or an SSE stream) into the inbound stream
    /// before returning; cancelling the calling task abandons that response.
    func send(_ message: JSONRPCMessage) async throws
    /// Called once `initialize` succeeded, with the negotiated protocol
    /// version. HTTP transports start sending `MCP-Protocol-Version` and open
    /// the server-to-client listening stream.
    func didInitialize(protocolVersion: String) async
    /// Close the connection and release resources (terminate the process,
    /// delete the HTTP session). Idempotent.
    func close() async
    /// Extra context for error messages, such as the tail of a stdio server's
    /// stderr.
    var diagnostics: String? { get }
}

extension MCPTransport {
    public func didInitialize(protocolVersion: String) async {}
    public var diagnostics: String? { nil }
}

/// Builds the transport of a configured server, with the server's auth
/// (HTTP only; nil when it has none).
public typealias MCPTransportFactory = @Sendable (_ config: MCPServerConfig, _ auth: MCPTransportAuth?) throws -> any MCPTransport

public enum MCPTransports {
    /// The default transport for a config: `MCPStdioTransport` for `.stdio`,
    /// `MCPStreamableHTTPTransport` for `.http`.
    public static func make(for config: MCPServerConfig, auth: MCPTransportAuth? = nil) throws -> any MCPTransport {
        switch config.transport {
        case .stdio(let command, let args, let env, let cwd):
            return MCPStdioTransport(command: command, args: args, env: env, cwd: cwd)
        case .http(let url, let headers):
            return MCPStreamableHTTPTransport(
                url: url,
                headers: headers,
                requestTimeoutSeconds: config.toolTimeoutSeconds,
                auth: auth
            )
        }
    }
}
