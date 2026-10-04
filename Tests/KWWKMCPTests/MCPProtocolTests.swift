import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI
@testable import KWWKMCP

@Suite("MCP protocol pieces")
struct MCPProtocolTests {
    @Test("JSON-RPC messages round-trip")
    func roundTrip() throws {
        let messages: [JSONRPCMessage] = [
            .request(id: .int(1), method: "tools/list", params: ["cursor": "x"]),
            .request(id: .string("a"), method: "ping", params: nil),
            .notification(method: "notifications/initialized", params: nil),
            .response(id: .int(2), result: ["ok": true]),
            .error(id: .int(3), error: JSONRPCErrorObject(code: -32601, message: "nope")),
        ]
        for message in messages {
            let data = try message.encoded()
            #expect(!data.contains(UInt8(ascii: "\n")))
            let decoded = try JSONRPCMessage.decodeAll(data)
            #expect(decoded == [message])
            #expect(message.json["jsonrpc"] == "2.0")
        }
    }

    @Test("JSON-RPC batches and invalid input")
    func batches() throws {
        let data = Data(#"[{"jsonrpc":"2.0","id":1,"result":{}},{"jsonrpc":"2.0","method":"x"}]"#.utf8)
        let decoded = try JSONRPCMessage.decodeAll(data)
        #expect(decoded == [.response(id: .int(1), result: .object([:])), .notification(method: "x", params: nil)])
        #expect(throws: MCPError.self) { try JSONRPCMessage.decodeAll(Data("nope".utf8)) }
        #expect(throws: MCPError.self) { try JSONRPCMessage.decodeAll(Data(#"{"jsonrpc":"2.0"}"#.utf8)) }
        // A null id on an error response is allowed.
        let error = try JSONRPCMessage.decodeAll(Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad"}}"#.utf8))
        #expect(error == [.error(id: nil, error: JSONRPCErrorObject(code: -32700, message: "bad"))])
    }

    @Test("newline framing splits lines across chunks")
    func framing() {
        var framer = NewlineFramer()
        #expect(framer.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = framer.append(Data("1}\r\n\n  \n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
        #expect(framer.finish().map { String(decoding: $0, as: UTF8.self) } == "{\"c\"")
        #expect(framer.finish() == nil)
    }

    @Test("SSE bodies carry JSON-RPC messages")
    func sse() {
        let body = """
        : keep-alive

        id: 1
        data:

        event: message
        data: {"jsonrpc":"2.0","method":"notifications/progress",
        data: "params":{"progressToken":1,"progress":1}}

        event: other
        data: {"jsonrpc":"2.0","method":"ignored"}

        data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
        """
        let messages = MCPStreamableHTTPTransport.messages(fromSSEBody: body)
        #expect(messages.count == 2)
        if case .notification(let method, _) = messages.first {
            #expect(method == "notifications/progress")
        } else {
            Issue.record("expected a notification")
        }
        #expect(messages.last == .response(id: .int(1), result: ["tools": []]))
    }

    @Test("tool names are sanitized")
    func naming() {
        #expect(MCPToolNaming.toolName(server: "my-server", tool: "get.issue") == "mcp__my_server__get_issue")
        #expect(MCPToolNaming.sanitize("a b-c/ü") == "a_b_c__")
        let long = String(repeating: "x", count: 80)
        let name = MCPToolNaming.toolName(server: "s", tool: long)
        #expect(name.count == 64)
        #expect(name.hasPrefix("mcp__s__xxx"))
        let hash = MCPToolNaming.hashSuffix(server: "s", tool: long)
        #expect(hash.count == 8)
        #expect(hash.allSatisfy { $0.isHexDigit })
        #expect(name.hasSuffix("_" + hash))
        #expect(MCPToolNaming.toolName(server: "s", tool: "t", isTaken: { $0 == "mcp__s__t" }).hasPrefix("mcp__s__t_"))
        // Deterministic.
        #expect(MCPToolNaming.hashedName(server: "s", tool: "t") == MCPToolNaming.hashedName(server: "s", tool: "t"))
    }

    @Test("colliding tool names all get hash suffixes")
    func collisions() {
        let names = MCPToolNaming.assignNames([
            ("srv", "a-b"), ("srv", "a_b"), ("srv", "plain"), ("other", "plain"),
        ])
        #expect(names[0] != names[1])
        #expect(names[0].hasPrefix("mcp__srv__a_b_") && names[0].count == "mcp__srv__a_b_".count + 8)
        #expect(names[1].hasPrefix("mcp__srv__a_b_"))
        #expect(names[2] == "mcp__srv__plain")
        #expect(names[3] == "mcp__other__plain")
        // Order independent.
        let reversed = MCPToolNaming.assignNames([("srv", "a_b"), ("srv", "a-b")])
        #expect(reversed == [names[1], names[0]])
        #expect(Set(names).count == names.count)
    }

    @Test("results map to tool result blocks")
    func convert() throws {
        let result = MCPCallToolResult(json: [
            "content": [
                ["type": "text", "text": "hello"],
                ["type": "image", "data": "aGk=", "mimeType": "image/jpeg"],
                ["type": "audio", "data": "aGk=", "mimeType": "audio/wav"],
                ["type": "resource_link", "uri": "file:///a", "name": "a", "description": "the a"],
                ["type": "resource", "resource": ["uri": "file:///b", "mimeType": "application/octet-stream", "blob": "aGk="]],
                ["type": "resource", "resource": ["uri": "file:///c", "mimeType": "application/json", "blob": "e30="]],
            ],
        ])
        let converted = try MCPToolAdapter.convert(server: "s", tool: "t", result: result)
        let texts = converted.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text } else { return nil }
        }
        #expect(texts[0] == "hello")
        #expect(texts[1] == "[Audio content (audio/wav, 2 B) omitted]")
        #expect(texts[2] == "[Resource file:///a \"a\": the a]")
        #expect(texts[3] == "[Binary resource file:///b (application/octet-stream, 2 B)]")
        #expect(texts[4] == "{}")
        #expect(converted.content.contains(.image(ImageContent(data: "aGk=", mimeType: "image/jpeg"))))
        #expect(converted.details?["server"] == "s")
    }

    @Test("structured content without text becomes JSON text")
    func structured() throws {
        let result = MCPCallToolResult(json: ["content": [], "structuredContent": ["sum": 3]])
        let converted = try MCPToolAdapter.convert(server: "s", tool: "t", result: result)
        guard case .text(let text)? = converted.content.first else {
            Issue.record("expected text")
            return
        }
        #expect(text.text.contains("\"sum\" : 3"))
        #expect(converted.details?["structuredContent"] == ["sum": 3])
    }

    @Test("isError results throw with the server message")
    func isError() {
        let result = MCPCallToolResult(content: [.text("boom")], isError: true)
        #expect(throws: MCPToolCallError.self) {
            try MCPToolAdapter.convert(server: "s", tool: "t", result: result)
        }
        do {
            _ = try MCPToolAdapter.convert(server: "s", tool: "t", result: MCPCallToolResult(content: [], isError: true))
        } catch {
            #expect(error.localizedDescription == "MCP tool s/t returned an error")
        }
    }

    @Test("parameters and descriptions")
    func adapterShape() {
        #expect(MCPToolAdapter.parameters(from: ["properties": ["a": ["type": "string"]]])
            == ["type": "object", "properties": ["a": ["type": "string"]]])
        #expect(MCPToolAdapter.parameters(from: .null) == ["type": "object", "properties": .object([:])])
        let described = MCPToolAdapter.description(server: "gh", tool: MCPTool(name: "x", title: "Title"))
        #expect(described.hasPrefix("Title"))
        #expect(described.contains("MCP server: gh"))
    }
}
