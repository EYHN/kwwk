import Foundation
import Testing
@testable import KWAI

@Suite("Tool argument validation")
struct ValidationTests {
    @Test("validateToolArguments passes through when schema allows it")
    func passthroughValid() throws {
        let tool = Tool(
            name: "echo",
            description: "Echo tool",
            parameters: [
                "type": "object",
                "properties": ["count": ["type": "number"]],
                "required": ["count"],
            ]
        )
        let call = ToolCall(id: "tool-1", name: "echo", arguments: ["count": 42])
        let validated = try validateToolArguments(tool: tool, toolCall: call)
        #expect(validated == .object(["count": 42]))
    }

    @Test("validateToolArguments rejects when required field is missing")
    func missingRequired() {
        let tool = Tool(
            name: "echo",
            description: "Echo tool",
            parameters: [
                "type": "object",
                "properties": ["count": ["type": "number"]],
                "required": ["count"],
            ]
        )
        let call = ToolCall(id: "tool-1", name: "echo", arguments: .object([:]))
        #expect(throws: JSONSchemaError.missingRequired(path: "$", key: "count")) {
            _ = try validateToolArguments(tool: tool, toolCall: call)
        }
    }

    @Test("validateToolArguments rejects when enum value is invalid")
    func enumViolation() {
        let tool = Tool(
            name: "op",
            description: "arith",
            parameters: [
                "type": "object",
                "properties": [
                    "op": ["type": "string", "enum": ["+", "-"]],
                ],
                "required": ["op"],
            ]
        )
        let call = ToolCall(id: "t", name: "op", arguments: ["op": "*"])
        #expect(throws: Error.self) {
            _ = try validateToolArguments(tool: tool, toolCall: call)
        }
    }

    @Test("validateToolArguments validates nested arrays")
    func nestedArrays() throws {
        let tool = Tool(
            name: "b",
            description: "batch",
            parameters: [
                "type": "object",
                "properties": [
                    "items": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["items"],
            ]
        )
        let goodCall = ToolCall(id: "t", name: "b", arguments: ["items": .array([.string("a")])])
        _ = try validateToolArguments(tool: tool, toolCall: goodCall)

        let badCall = ToolCall(id: "t", name: "b", arguments: ["items": .array([.int(1)])])
        #expect(throws: Error.self) {
            _ = try validateToolArguments(tool: tool, toolCall: badCall)
        }
    }
}
