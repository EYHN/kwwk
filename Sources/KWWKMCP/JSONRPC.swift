import Foundation
import KWWKAI

/// JSON-RPC 2.0 request id.
public enum JSONRPCID: Sendable, Hashable, CustomStringConvertible {
    case int(Int)
    case string(String)

    public var json: JSONValue {
        switch self {
        case .int(let value): return .int(value)
        case .string(let value): return .string(value)
        }
    }

    init?(json: JSONValue?) {
        switch json {
        case .int(let value)?: self = .int(value)
        case .string(let value)?: self = .string(value)
        case .double(let value)? where value.rounded() == value && abs(value) < 1e15: self = .int(Int(value))
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// JSON-RPC 2.0 error object.
public struct JSONRPCErrorObject: Sendable, Hashable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    var json: JSONValue {
        var object: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }
}

/// One JSON-RPC 2.0 message as exchanged with an MCP server.
public enum JSONRPCMessage: Sendable, Hashable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONRPCID, result: JSONValue)
    case error(id: JSONRPCID?, error: JSONRPCErrorObject)

    /// Decode one message object.
    public init(json: JSONValue) throws {
        guard case .object(let object) = json else {
            throw MCPError.protocolError("JSON-RPC message must be an object")
        }
        if case .string(let method)? = object["method"] {
            let params = object["params"]
            if let rawID = object["id"], rawID != .null {
                guard let id = JSONRPCID(json: rawID) else {
                    throw MCPError.protocolError("invalid JSON-RPC id")
                }
                self = .request(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
            return
        }
        if let rawError = object["error"] {
            guard case .object(let errorObject) = rawError else {
                throw MCPError.protocolError("JSON-RPC error must be an object")
            }
            let code: Int
            switch errorObject["code"] {
            case .int(let value)?: code = value
            case .double(let value)?: code = Int(value)
            default: code = JSONRPCErrorObject.internalError
            }
            var message = "Unknown error"
            if case .string(let text)? = errorObject["message"] { message = text }
            self = .error(
                id: JSONRPCID(json: object["id"]),
                error: JSONRPCErrorObject(code: code, message: message, data: errorObject["data"])
            )
            return
        }
        if object.keys.contains("result") {
            guard let id = JSONRPCID(json: object["id"]) else {
                throw MCPError.protocolError("JSON-RPC response without id")
            }
            self = .response(id: id, result: object["result"] ?? .null)
            return
        }
        throw MCPError.protocolError("unrecognized JSON-RPC message")
    }

    /// The message as a JSON object, including `"jsonrpc": "2.0"`.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id.json
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .response(let id, let result):
            object["id"] = id.json
            object["result"] = result
        case .error(let id, let error):
            object["id"] = id?.json ?? .null
            object["error"] = error.json
        }
        return .object(object)
    }

    /// Compact JSON encoding without newlines, suitable for newline-delimited
    /// framing and HTTP bodies.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(json)
    }

    /// Decode a body that holds one message or a JSON-RPC batch array.
    public static func decodeAll(_ data: Data) throws -> [JSONRPCMessage] {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw MCPError.protocolError("invalid JSON: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        if case .array(let items) = value {
            return try items.map { try JSONRPCMessage(json: $0) }
        }
        return [try JSONRPCMessage(json: value)]
    }
}

/// Splits a byte stream into newline-delimited lines (MCP stdio framing).
/// Blank lines are skipped; a trailing `\r` is removed.
public struct NewlineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Append bytes and return every complete line.
    public mutating func append(_ data: Data) -> [Data] {
        // Only the new bytes can hold a newline: scanning just them keeps a
        // large message arriving in many chunks linear.
        guard data.contains(UInt8(ascii: "\n")) else {
            buffer.append(data)
            return []
        }
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[start..<newline]
            start = buffer.index(after: newline)
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) {
                lines.append(Data(line))
            }
        }
        buffer = Data(buffer[start...])
        return lines
    }

    /// Return the unterminated remainder, if any.
    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        let trimmed = buffer.filter { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") && $0 != UInt8(ascii: "\r") }
        return trimmed.isEmpty ? nil : buffer
    }
}

/// Errors raised by the MCP client and transports.
public enum MCPError: Error, LocalizedError, Sendable, Equatable {
    /// The server answered with a JSON-RPC error.
    case server(code: Int, message: String, data: JSONValue?)
    /// The server sent something that is not valid MCP / JSON-RPC.
    case protocolError(String)
    /// A request did not complete in time.
    case timeout(method: String, seconds: Double)
    /// The connection closed. `details` carries e.g. the stderr tail.
    case connectionClosed(details: String?)
    /// The client is not connected (never connected, or closed).
    case notConnected
    /// The HTTP server answered with a non-success status.
    case http(status: Int, body: String)
    /// The HTTP server no longer knows the session (HTTP 404 with a session id).
    case sessionExpired
    /// The transport cannot be used on this platform.
    case unsupportedTransport(String)
    /// Spawning the stdio server failed.
    case spawnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .server(let code, let message, _):
            return "MCP error \(code): \(message)"
        case .protocolError(let message):
            return "MCP protocol error: \(message)"
        case .timeout(let method, let seconds):
            return "MCP request \(method) timed out after \(Self.formatSeconds(seconds))"
        case .connectionClosed(let details):
            if let details, !details.isEmpty { return "MCP connection closed\n\(details)" }
            return "MCP connection closed"
        case .notConnected:
            return "MCP client is not connected"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "MCP HTTP error \(status)" : "MCP HTTP error \(status): \(trimmed)"
        case .sessionExpired:
            return "MCP session expired"
        case .unsupportedTransport(let message):
            return message
        case .spawnFailed(let message):
            return "Failed to start MCP server: \(message)"
        }
    }

    static func formatSeconds(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
    }
}
