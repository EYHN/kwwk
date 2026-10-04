import Crypto
import Foundation
import KWWKAgent
import KWWKAI

/// Naming of MCP tools as agent tools: `mcp__<server>__<tool>`.
public enum MCPToolNaming {
    /// Provider tool names are limited to 64 characters.
    public static let maxLength = 64

    /// Replace every character outside `[A-Za-z0-9_]` with `_`.
    public static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95
            return ok ? Character(scalar) : "_"
        })
    }

    /// The sanitized name before any hash suffix.
    public static func baseName(server: String, tool: String) -> String {
        sanitize("mcp__\(server)__\(tool)")
    }

    /// First 8 hex digits of `sha256("<server>\0<tool>")`.
    public static func hashSuffix(server: String, tool: String) -> String {
        let digest = SHA256.hash(data: Data("\(server)\u{0}\(tool)".utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Name with an 8-hex hash suffix, shortened to `maxLength`.
    public static func hashedName(server: String, tool: String) -> String {
        let base = baseName(server: server, tool: tool)
        let hash = hashSuffix(server: server, tool: tool)
        return "\(base.prefix(maxLength - hash.count - 1))_\(hash)"
    }

    /// Name of one tool: the base name, or the hashed name when it is too
    /// long or `isTaken` reports it is used by another tool.
    public static func toolName(
        server: String,
        tool: String,
        isTaken: (String) -> Bool = { _ in false }
    ) -> String {
        let base = baseName(server: server, tool: tool)
        if base.count <= maxLength && !isTaken(base) { return base }
        return hashedName(server: server, tool: tool)
    }

    /// Assign names to a set of `(server, tool)` pairs at once. Tools whose
    /// base names collide all get a hash suffix, so the result does not depend
    /// on the order servers connect in. Returned in input order.
    public static func assignNames(_ tools: [(server: String, tool: String)]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in tools {
            counts[baseName(server: entry.server, tool: entry.tool), default: 0] += 1
        }
        var used: Set<String> = []
        return tools.map { entry in
            let base = baseName(server: entry.server, tool: entry.tool)
            var name = (base.count <= maxLength && counts[base] == 1)
                ? base
                : hashedName(server: entry.server, tool: entry.tool)
            // Identical (server, tool) pairs listed twice would still clash.
            var counter = 2
            let original = name
            while used.contains(name) {
                let suffix = "_\(counter)"
                name = String(original.prefix(maxLength - suffix.count)) + suffix
                counter += 1
            }
            used.insert(name)
            return name
        }
    }
}

/// Error thrown for a `tools/call` result with `isError: true`. The agent
/// loop turns thrown errors into error tool results, so the model sees the
/// server's message flagged as an error.
public struct MCPToolCallError: Error, LocalizedError, Sendable {
    public var server: String
    public var tool: String
    public var message: String
    /// The converted result content (text and images).
    public var content: [ToolResultBlock]

    public var errorDescription: String? { message }
}

/// Adapts MCP tools and results to kwwk agent tools.
public enum MCPToolAdapter {
    /// Calls a tool on the server: `(toolName, arguments, cancellation, onProgress)`.
    public typealias Caller = @Sendable (
        _ tool: String,
        _ arguments: JSONValue,
        _ cancellation: CancellationHandle?,
        _ onProgress: (@Sendable (MCPProgress) -> Void)?
    ) async throws -> MCPCallToolResult

    /// Build the agent tool for one MCP tool.
    public static func makeAgentTool(
        server: String,
        tool: MCPTool,
        name: String,
        call: @escaping Caller
    ) -> AgentTool {
        let toolName = tool.name
        return AgentTool(
            name: name,
            label: "\(server)/\(tool.name)",
            description: description(server: server, tool: tool),
            parameters: parameters(from: tool.inputSchema)
        ) { _, args, cancellation, onUpdate in
            let progress: (@Sendable (MCPProgress) -> Void)?
            if let onUpdate {
                progress = { update in
                    let total = update.total.map { "/\(format($0))" } ?? ""
                    let text = update.message ?? "Progress \(format(update.progress))\(total)"
                    onUpdate(AgentToolResult(
                        content: [.text(TextContent(text: text))],
                        details: ["server": .string(server), "tool": .string(toolName)]
                    ))
                }
            } else {
                progress = nil
            }
            let result = try await call(toolName, args, cancellation, progress)
            return try convert(server: server, tool: toolName, result: result)
        }
    }

    /// Model-facing description: the tool's description (else its title, else
    /// a generic line), followed by the server name so tool search can match
    /// on it.
    public static func description(server: String, tool: MCPTool) -> String {
        let base = tool.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if let base, !base.isEmpty {
            text = base
        } else if let title = tool.title, !title.isEmpty {
            text = title
        } else {
            text = "MCP tool \(tool.name)"
        }
        return "\(text)\n\n(MCP server: \(server), tool: \(tool.name))"
    }

    /// Tool parameters must be an object schema with `properties`; MCP
    /// servers may omit `type` or `properties`.
    public static func parameters(from schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema else {
            return ["type": "object", "properties": .object([:])]
        }
        if object["type"] == nil { object["type"] = "object" }
        if object["properties"] == nil { object["properties"] = .object([:]) }
        return .object(object)
    }

    /// Convert a `tools/call` result. Results with `isError` throw
    /// `MCPToolCallError` carrying the server's message.
    public static func convert(server: String, tool: String, result: MCPCallToolResult) throws -> AgentToolResult {
        var blocks = result.content.flatMap(contentBlocks(_:))
        let hasText = blocks.contains { if case .text = $0 { return true } else { return false } }
        if !hasText, let structured = result.structuredContent {
            blocks.insert(.text(TextContent(text: structured.mcpJSONText(pretty: true))), at: 0)
        }
        var details: [String: JSONValue] = ["server": .string(server), "tool": .string(tool)]
        if let structured = result.structuredContent { details["structuredContent"] = structured }

        if result.isError {
            let text = blocks.compactMap { block -> String? in
                if case .text(let content) = block { return content.text }
                return nil
            }.joined(separator: "\n")
            let message = text.isEmpty ? "MCP tool \(server)/\(tool) returned an error" : text
            throw MCPToolCallError(server: server, tool: tool, message: message, content: blocks)
        }
        if blocks.isEmpty {
            blocks = [.text(TextContent(text: "(no output)"))]
        }
        return AgentToolResult(content: blocks, details: .object(details))
    }

    /// Model-facing blocks of one MCP content block.
    public static func contentBlocks(_ block: MCPContentBlock) -> [ToolResultBlock] {
        switch block {
        case .text(let text):
            return [.text(TextContent(text: text))]
        case .image(let data, let mimeType):
            return [.image(ImageContent(data: data, mimeType: mimeType))]
        case .audio(let data, let mimeType):
            let bytes = Data(base64Encoded: data)?.count ?? data.count * 3 / 4
            return [.text(TextContent(text: "[Audio content (\(mimeType), \(formatSize(bytes))) omitted]"))]
        case .resource(let uri, let mimeType, let text, let blob):
            if let text {
                return [.text(TextContent(text: text))]
            }
            if let blob, let mimeType, mimeType.lowercased().hasPrefix("image/") {
                return [.image(ImageContent(data: blob, mimeType: mimeType))]
            }
            if let blob, let data = Data(base64Encoded: blob), isTextMimeType(mimeType),
               let decoded = String(data: data, encoding: .utf8) {
                return [.text(TextContent(text: decoded))]
            }
            let size = blob.flatMap { Data(base64Encoded: $0)?.count }.map { ", \(formatSize($0))" } ?? ""
            return [.text(TextContent(text: "[Binary resource \(uri) (\(mimeType ?? "unknown type")\(size))]"))]
        case .resourceLink(let uri, let name, let title, let description, let mimeType):
            var text = "[Resource \(uri)"
            if let label = title ?? name { text += " \"\(label)\"" }
            if let mimeType { text += " (\(mimeType))" }
            if let description, !description.isEmpty { text += ": \(description)" }
            text += "]"
            return [.text(TextContent(text: text))]
        case .unknown(let json):
            return [.text(TextContent(text: json.mcpJSONText()))]
        }
    }

    static func isTextMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        let type = mimeType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        return type.hasPrefix("text/") || type == "application/json" || type.hasSuffix("+json") || type.hasSuffix("+xml")
    }

    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
