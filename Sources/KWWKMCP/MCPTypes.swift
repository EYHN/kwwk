import Foundation
import KWWKAI

/// `serverInfo` from the `initialize` result.
public struct MCPServerInfo: Sendable, Hashable {
    public var name: String
    public var version: String?
    public var title: String?

    public init(name: String, version: String? = nil, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }
}

/// A tool as listed by `tools/list`.
public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String?
    /// JSON Schema of the arguments.
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    /// Raw `annotations` (`readOnlyHint`, `destructiveHint`, ...).
    public var annotations: JSONValue?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue = .object(["type": "object"]),
        outputSchema: JSONValue? = nil,
        annotations: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }

    init?(json: JSONValue) {
        guard case .string(let name)? = json["name"] else { return nil }
        self.name = name
        self.title = json["title"]?.mcpString ?? json["annotations"]?["title"]?.mcpString
        self.description = json["description"]?.mcpString
        if case .object? = json["inputSchema"], let schema = json["inputSchema"] {
            self.inputSchema = schema
        } else {
            self.inputSchema = .object(["type": "object"])
        }
        self.outputSchema = json["outputSchema"]
        self.annotations = json["annotations"]
    }

    /// A boolean hint from `annotations`, e.g. `readOnlyHint`.
    public func hint(_ name: String) -> Bool? {
        if case .bool(let value)? = annotations?[name] { return value }
        return nil
    }
}

/// One content block of a `tools/call` result.
public enum MCPContentBlock: Sendable, Hashable {
    case text(String)
    /// Base64 image data.
    case image(data: String, mimeType: String)
    /// Base64 audio data.
    case audio(data: String, mimeType: String)
    /// Embedded resource: `text` or base64 `blob`.
    case resource(uri: String, mimeType: String?, text: String?, blob: String?)
    case resourceLink(uri: String, name: String?, title: String?, description: String?, mimeType: String?)
    /// A block type this client does not know.
    case unknown(JSONValue)

    init(json: JSONValue) {
        let type = json["type"]?.mcpString
        switch type {
        case "text":
            self = .text(json["text"]?.mcpString ?? "")
        case "image":
            self = .image(data: json["data"]?.mcpString ?? "", mimeType: json["mimeType"]?.mcpString ?? "image/png")
        case "audio":
            self = .audio(data: json["data"]?.mcpString ?? "", mimeType: json["mimeType"]?.mcpString ?? "audio/wav")
        case "resource":
            let resource = json["resource"]
            self = .resource(
                uri: resource?["uri"]?.mcpString ?? "",
                mimeType: resource?["mimeType"]?.mcpString,
                text: resource?["text"]?.mcpString,
                blob: resource?["blob"]?.mcpString
            )
        case "resource_link":
            self = .resourceLink(
                uri: json["uri"]?.mcpString ?? "",
                name: json["name"]?.mcpString,
                title: json["title"]?.mcpString,
                description: json["description"]?.mcpString,
                mimeType: json["mimeType"]?.mcpString
            )
        default:
            self = .unknown(json)
        }
    }
}

/// Result of `tools/call`.
public struct MCPCallToolResult: Sendable, Hashable {
    public var content: [MCPContentBlock]
    public var structuredContent: JSONValue?
    public var isError: Bool

    public init(content: [MCPContentBlock], structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    init(json: JSONValue) {
        if case .array(let blocks)? = json["content"] {
            content = blocks.map(MCPContentBlock.init(json:))
        } else {
            content = []
        }
        structuredContent = json["structuredContent"]
        if case .bool(let flag)? = json["isError"] { isError = flag } else { isError = false }
    }
}

/// A `notifications/progress` update for an in-flight request.
public struct MCPProgress: Sendable, Hashable {
    public var progress: Double
    public var total: Double?
    public var message: String?

    public init(progress: Double, total: Double? = nil, message: String? = nil) {
        self.progress = progress
        self.total = total
        self.message = message
    }
}

extension JSONValue {
    var mcpString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var mcpNumber: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// Compact JSON text.
    func mcpJSONText(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.withoutEscapingSlashes, .sortedKeys, .prettyPrinted]
            : [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
