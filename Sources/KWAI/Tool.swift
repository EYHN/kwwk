import Foundation

/// A JSONSchema-shaped parameter descriptor. We represent schemas as JSONValue
/// to stay flexible while matching the wire format that providers expect.
public struct Tool: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Validate raw tool-call arguments against a tool's parameter schema. On
/// validation failure the function throws `JSONSchemaError`.
public func validateToolArguments(tool: Tool, toolCall: ToolCall) throws -> JSONValue {
    try JSONSchema.validate(toolCall.arguments, against: tool.parameters)
    return toolCall.arguments
}
