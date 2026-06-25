import Foundation

// MARK: - Role & stop reasons

public enum Role: String, Codable, Sendable, Hashable {
    case user
    case assistant
    case toolResult
}

public enum StopReason: String, Codable, Sendable, Hashable {
    case stop
    case length
    case toolUse
    case error
    case aborted
}

// MARK: - Content blocks

public struct TextContent: Codable, Sendable, Hashable {
    public var text: String
    public var textSignature: String?
    public init(text: String, textSignature: String? = nil) {
        self.text = text
        self.textSignature = textSignature
    }
}

public struct ThinkingContent: Codable, Sendable, Hashable {
    public var thinking: String
    public var thinkingSignature: String?
    public var redacted: Bool?
    public init(thinking: String, thinkingSignature: String? = nil, redacted: Bool? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.redacted = redacted
    }
}

public struct ImageContent: Codable, Sendable, Hashable {
    /// Base64-encoded image bytes.
    public var data: String
    public var mimeType: String
    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct ToolCall: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public var thoughtSignature: String?
    public init(id: String, name: String, arguments: JSONValue, thoughtSignature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
    }
}

/// Content blocks allowed in a user message.
public enum UserBlock: Sendable, Hashable, Codable {
    case text(TextContent)
    case image(ImageContent)

    private enum CodingKeys: String, CodingKey { case type }
    private enum BlockType: String, Codable { case text, image }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(BlockType.self, forKey: .type) {
        case .text: self = .text(try TextContent(from: decoder))
        case .image: self = .image(try ImageContent(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode(BlockType.text, forKey: .type)
            try t.encode(to: encoder)
        case .image(let i):
            try c.encode(BlockType.image, forKey: .type)
            try i.encode(to: encoder)
        }
    }
}

/// Content blocks allowed in an assistant message.
public enum AssistantBlock: Sendable, Hashable, Codable {
    case text(TextContent)
    case thinking(ThinkingContent)
    case toolCall(ToolCall)

    private enum CodingKeys: String, CodingKey { case type }
    private enum BlockType: String, Codable { case text, thinking, toolCall }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(BlockType.self, forKey: .type) {
        case .text: self = .text(try TextContent(from: decoder))
        case .thinking: self = .thinking(try ThinkingContent(from: decoder))
        case .toolCall: self = .toolCall(try ToolCall(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode(BlockType.text, forKey: .type)
            try t.encode(to: encoder)
        case .thinking(let th):
            try c.encode(BlockType.thinking, forKey: .type)
            try th.encode(to: encoder)
        case .toolCall(let tc):
            try c.encode(BlockType.toolCall, forKey: .type)
            try tc.encode(to: encoder)
        }
    }
}

/// Content blocks allowed in a toolResult message.
public enum ToolResultBlock: Sendable, Hashable, Codable {
    case text(TextContent)
    case image(ImageContent)

    private enum CodingKeys: String, CodingKey { case type }
    private enum BlockType: String, Codable { case text, image }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(BlockType.self, forKey: .type) {
        case .text: self = .text(try TextContent(from: decoder))
        case .image: self = .image(try ImageContent(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode(BlockType.text, forKey: .type)
            try t.encode(to: encoder)
        case .image(let i):
            try c.encode(BlockType.image, forKey: .type)
            try i.encode(to: encoder)
        }
    }
}

// MARK: - Usage & cost

public struct Cost: Codable, Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var total: Double
    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, total: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }
}

public struct Usage: Codable, Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int
    public var totalTokens: Int
    public var cost: Cost
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0, totalTokens: Int = 0, cost: Cost = .init()) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.totalTokens = totalTokens
        self.cost = cost
    }

    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite, reasoning, totalTokens, cost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        self.output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        self.cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        self.cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        self.reasoning = try c.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
        self.totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        self.cost = try c.decodeIfPresent(Cost.self, forKey: .cost) ?? .init()
    }
}

// MARK: - Messages

public struct UserMessage: Codable, Sendable, Hashable {
    public var role: Role
    public var content: [UserBlock]
    public var timestamp: Int64

    public init(content: [UserBlock], timestamp: Int64 = Timestamp.now()) {
        self.role = .user
        self.content = content
        self.timestamp = timestamp
    }

    /// Convenience: plain string content.
    public init(text: String, timestamp: Int64 = Timestamp.now()) {
        self.role = .user
        self.content = [.text(TextContent(text: text))]
        self.timestamp = timestamp
    }
}

public struct AssistantMessage: Codable, Sendable, Hashable {
    public var role: Role
    public var content: [AssistantBlock]
    public var api: String
    public var provider: String
    public var model: String
    public var responseId: String?
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var timestamp: Int64

    public init(
        content: [AssistantBlock],
        api: String,
        provider: String,
        model: String,
        responseId: String? = nil,
        usage: Usage = .init(),
        stopReason: StopReason = .stop,
        errorMessage: String? = nil,
        timestamp: Int64 = Timestamp.now()
    ) {
        self.role = .assistant
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.responseId = responseId
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}

public struct ToolResultMessage: Codable, Sendable, Hashable {
    public var role: Role
    public var toolCallId: String
    public var toolName: String
    public var content: [ToolResultBlock]
    public var details: JSONValue?
    public var isError: Bool
    public var timestamp: Int64

    public init(
        toolCallId: String,
        toolName: String,
        content: [ToolResultBlock],
        details: JSONValue? = nil,
        isError: Bool = false,
        timestamp: Int64 = Timestamp.now()
    ) {
        self.role = .toolResult
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.isError = isError
        self.timestamp = timestamp
    }
}

/// Discriminated union of all message kinds.
public enum Message: Sendable, Hashable, Codable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    public var role: Role {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .toolResult: return .toolResult
        }
    }

    private enum CodingKeys: String, CodingKey { case role }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Role.self, forKey: .role) {
        case .user: self = .user(try UserMessage(from: decoder))
        case .assistant: self = .assistant(try AssistantMessage(from: decoder))
        case .toolResult: self = .toolResult(try ToolResultMessage(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .user(let m): try m.encode(to: encoder)
        case .assistant(let m): try m.encode(to: encoder)
        case .toolResult(let m): try m.encode(to: encoder)
        }
    }
}

// MARK: - Timestamp helper

public enum Timestamp {
    /// Unix time in milliseconds (matching pi-ai's TS `Date.now()`).
    public static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
