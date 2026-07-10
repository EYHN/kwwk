import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("Cursor inline exec capabilities")
struct CursorExecCapabilityTests {
    @Test("read-only agents reject native write and delete without changing files")
    func readOnlyRejectsFileMutation() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let dir = makeTempDir("cursor-read-only")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writeTarget = dir.appendingPathComponent("created.txt")
        let deleteTarget = dir.appendingPathComponent("keep.txt")
        try write("keep", to: deleteTarget)

        let calls = [
            ToolCall(
                id: "cursor-write",
                name: "write",
                arguments: [
                    "path": .string(writeTarget.path),
                    "content": .string("must not be written"),
                ],
                cursorExecResolved: true
            ),
            ToolCall(
                id: "cursor-delete",
                name: "delete",
                arguments: ["path": .string(deleteTarget.path)],
                cursorExecResolved: true
            ),
        ]
        let agent = makeCursorExecAgent(
            model: faux.getModel(),
            cwd: dir.path,
            tools: buildCodingToolList(
                cwd: dir.path,
                selected: .readOnly,
                backgroundManager: nil,
                sessionId: nil,
                bashEnvironment: testBashEnvironment,
                bashShellPath: "/bin/sh"
            ),
            calls: calls
        )

        try await agent.prompt("inspect only")

        #expect(!FileManager.default.fileExists(atPath: writeTarget.path))
        #expect(try String(contentsOf: deleteTarget, encoding: .utf8) == "keep")
        for id in ["cursor-write", "cursor-delete"] {
            let result = cursorToolResult(in: agent.state.messages, id: id)
            #expect(result?.isError == true)
            #expect(cursorResultText(result).contains("not allowed"))
        }
    }

    @Test("standard agents keep registered write and native delete with hooks")
    func standardAllowsFileMutation() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let dir = makeTempDir("cursor-standard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writeTarget = dir.appendingPathComponent("created.txt")
        let deleteTarget = dir.appendingPathComponent("remove.txt")
        try write("remove", to: deleteTarget)

        let calls = [
            ToolCall(
                id: "cursor-write",
                name: "write",
                arguments: [
                    "path": .string(writeTarget.path),
                    "content": .string("original"),
                ],
                cursorExecResolved: true
            ),
            ToolCall(
                id: "cursor-delete",
                name: "delete",
                arguments: ["path": .string(deleteTarget.path)],
                cursorExecResolved: true
            ),
        ]
        let agent = makeCursorExecAgent(
            model: faux.getModel(),
            cwd: dir.path,
            tools: buildCodingToolList(
                cwd: dir.path,
                selected: .standard,
                backgroundManager: nil,
                sessionId: nil,
                bashEnvironment: testBashEnvironment,
                bashShellPath: "/bin/sh"
            ),
            calls: calls,
            beforeToolCall: { context, _ in
                guard context.toolCall.name == "write" else { return nil }
                return BeforeToolCallResult(modifiedArgs: [
                    "path": .string(writeTarget.path),
                    "content": .string("rewritten by before hook"),
                ])
            },
            afterToolCall: { context, _ in
                guard context.toolCall.name == "write" else { return nil }
                return AfterToolCallResult(
                    content: [.text(TextContent(text: "rewritten by after hook"))]
                )
            }
        )

        try await agent.prompt("mutate files")

        #expect(
            try String(contentsOf: writeTarget, encoding: .utf8)
                == "rewritten by before hook"
        )
        #expect(!FileManager.default.fileExists(atPath: deleteTarget.path))

        let writeResult = cursorToolResult(in: agent.state.messages, id: "cursor-write")
        #expect(writeResult?.isError == false)
        #expect(cursorResultText(writeResult) == "rewritten by after hook")
        #expect(cursorToolResult(in: agent.state.messages, id: "cursor-delete")?.isError == false)
    }

    @Test("Cursor write and native delete reject hook rewrites with invalid types")
    func cursorRewritesAreRevalidated() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let dir = makeTempDir("cursor-invalid-rewrite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writeTarget = dir.appendingPathComponent("must-not-exist.txt")
        let deleteTarget = dir.appendingPathComponent("must-remain.txt")
        try write("keep", to: deleteTarget)
        let calls = [
            ToolCall(
                id: "cursor-invalid-write",
                name: "write",
                arguments: [
                    "path": .string(writeTarget.path),
                    "content": .string("valid before rewrite"),
                ],
                cursorExecResolved: true
            ),
            ToolCall(
                id: "cursor-invalid-delete",
                name: "delete",
                arguments: ["path": .string(deleteTarget.path)],
                cursorExecResolved: true
            ),
        ]
        let agent = makeCursorExecAgent(
            model: faux.getModel(),
            cwd: dir.path,
            tools: buildCodingToolList(
                cwd: dir.path,
                selected: .standard,
                backgroundManager: nil,
                sessionId: nil,
                bashEnvironment: testBashEnvironment,
                bashShellPath: "/bin/sh"
            ),
            calls: calls,
            beforeToolCall: { context, _ in
                switch context.toolCall.name {
                case "write":
                    return BeforeToolCallResult(modifiedArgs: [
                        "path": .string(writeTarget.path),
                        "content": .bool(true),
                    ])
                case "delete":
                    return BeforeToolCallResult(modifiedArgs: ["path": .bool(true)])
                default:
                    return nil
                }
            }
        )

        try await agent.prompt("reject invalid rewrites")

        #expect(!FileManager.default.fileExists(atPath: writeTarget.path))
        #expect(try String(contentsOf: deleteTarget, encoding: .utf8) == "keep")
        let writeResult = cursorToolResult(in: agent.state.messages, id: "cursor-invalid-write")
        let deleteResult = cursorToolResult(in: agent.state.messages, id: "cursor-invalid-delete")
        #expect(writeResult?.isError == true)
        #expect(deleteResult?.isError == true)
        #expect(cursorResultText(writeResult).contains("$.content: expected string, got boolean"))
        #expect(cursorResultText(deleteResult).contains("$.path: expected string, got boolean"))
    }

    @Test("Cursor write and native delete honor workspace path containment")
    func cursorFilePolicyContainment() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let workspace = makeTempDir("cursor-workspace-policy")
        let outside = makeTempDir("cursor-workspace-outside")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        let writeTarget = outside.appendingPathComponent("must-not-write.txt")
        let deleteTarget = outside.appendingPathComponent("must-not-delete.txt")
        try write("keep", to: deleteTarget)
        let calls = [
            ToolCall(
                id: "cursor-policy-write",
                name: "write",
                arguments: [
                    "path": .string(writeTarget.path),
                    "content": .string("blocked"),
                ],
                cursorExecResolved: true
            ),
            ToolCall(
                id: "cursor-policy-delete",
                name: "delete",
                arguments: ["path": .string(deleteTarget.path)],
                cursorExecResolved: true
            ),
        ]
        let agent = makeCursorExecAgent(
            model: faux.getModel(),
            cwd: workspace.path,
            tools: buildCodingToolList(
                cwd: workspace.path,
                selected: .standard,
                backgroundManager: nil,
                sessionId: nil,
                fileAccessPolicy: .workspaceOnly,
                bashEnvironment: testBashEnvironment,
                bashShellPath: "/bin/sh"
            ),
            calls: calls
        )

        try await agent.prompt("try outside workspace")

        #expect(!FileManager.default.fileExists(atPath: writeTarget.path))
        #expect(try String(contentsOf: deleteTarget, encoding: .utf8) == "keep")
        for id in ["cursor-policy-write", "cursor-policy-delete"] {
            let result = cursorToolResult(in: agent.state.messages, id: id)
            #expect(result?.isError == true)
            #expect(cursorResultText(result).contains("outside the allowed roots"))
        }
    }

    @Test("custom tool named write does not grant Cursor native delete capability")
    func customWriteNameDoesNotGrantDelete() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let dir = makeTempDir("cursor-custom-write")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("keep.txt")
        try write("keep", to: target)
        let customWrite = AgentTool(
            name: "write",
            label: "custom write",
            description: "A custom tool that happens to share the name.",
            parameters: .object(["type": .string("object")]),
            execute: { _, _, _, _ in
                AgentToolResult(content: [.text(TextContent(text: "custom"))])
            }
        )
        let agent = makeCursorExecAgent(
            model: faux.getModel(),
            cwd: dir.path,
            tools: [customWrite],
            calls: [ToolCall(
                id: "cursor-custom-delete",
                name: "delete",
                arguments: ["path": .string(target.path)],
                cursorExecResolved: true
            )]
        )

        try await agent.prompt("do not grant built-in capability by name")

        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        let result = cursorToolResult(in: agent.state.messages, id: "cursor-custom-delete")
        #expect(result?.isError == true)
        #expect(cursorResultText(result).contains("not allowed"))
    }

    @Test("Cursor duplicate tool-call ids execute at most once")
    func duplicateCursorIdsDoNotRepeatSideEffects() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let counter = CursorExecCounter()
        let tool = AgentTool(
            name: "count",
            label: "count",
            description: "Record one side effect.",
            parameters: .object(["type": .string("object")]),
            execute: { _, _, _, _ in
                await counter.increment()
                return AgentToolResult(content: [.text(TextContent(text: "counted"))])
            }
        )
        let duplicateCalls = (0..<2).map { _ in
            ToolCall(
                id: "cursor-duplicate",
                name: "count",
                arguments: [:],
                cursorExecResolved: true
            )
        }
        let agent = makeCursorExecAgent(
            model: faux.getModel(),
            cwd: FileManager.default.currentDirectoryPath,
            tools: [tool],
            calls: duplicateCalls
        )

        try await agent.prompt("emit duplicate ids")

        #expect(await counter.value() == 1)
        let results = agent.state.messages.compactMap { message -> ToolResultMessage? in
            guard case .toolResult(let result) = message,
                  result.toolCallId == "cursor-duplicate" else { return nil }
            return result
        }
        #expect(results.count == 2)
        #expect(results.filter { $0.isError }.count == 1)
        #expect(results.contains { result in
            guard case .object(let details) = result.details ?? .null else { return false }
            return details["error"] == .string("duplicate_tool_call_id")
        })
    }

    @Test("Cursor inline exec cannot accept the terminal completion tool")
    func cursorInlineTerminalToolIsRejected() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let terminalCounter = CursorExecCounter()
        let siblingCounter = CursorExecCounter()
        let terminal = AgentTool(
            name: "finish",
            label: "finish",
            description: "Terminal completion signal.",
            parameters: .object(["type": .string("object")]),
            execute: { _, _, _, _ in
                await terminalCounter.increment()
                return AgentToolResult(content: [.text(TextContent(text: "accepted"))])
            }
        )
        let sibling = AgentTool(
            name: "count",
            label: "count",
            description: "A sibling side effect.",
            parameters: .object(["type": .string("object")]),
            execute: { _, _, _, _ in
                await siblingCounter.increment()
                return AgentToolResult(content: [.text(TextContent(text: "counted"))])
            }
        )
        let calls = [
            ToolCall(
                id: "cursor-inline-terminal",
                name: "finish",
                arguments: [:],
                cursorExecResolved: true
            ),
            ToolCall(
                id: "cursor-inline-sibling",
                name: "count",
                arguments: [:],
                cursorExecResolved: true
            ),
        ]
        let agent = makeCursorExecAgent(
            model: faux.getModel(),
            cwd: FileManager.default.currentDirectoryPath,
            tools: [terminal, sibling],
            calls: calls,
            terminalToolName: "finish"
        )

        try await agent.prompt("try inline terminal completion")

        #expect(await terminalCounter.value() == 0)
        #expect(await siblingCounter.value() == 1)
        let terminalResult = cursorToolResult(
            in: agent.state.messages,
            id: "cursor-inline-terminal"
        )
        #expect(terminalResult?.isError == true)
        #expect(cursorResultText(terminalResult).contains("must be the only tool call"))
    }
}

private actor CursorExecCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

private func makeCursorExecAgent(
    model: Model,
    cwd: String,
    tools: [AgentTool],
    calls: [ToolCall],
    beforeToolCall: BeforeToolCallHook? = nil,
    afterToolCall: AfterToolCallHook? = nil,
    terminalToolName: String? = nil
) -> Agent {
    let streamFn: StreamFn = { model, _, options in
        guard let bridge = options?.cursorExecBridge else {
            throw CursorExecTestError.missingBridge
        }

        let message = AssistantMessage(
            content: calls.map(AssistantBlock.toolCall),
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .stop
        )
        let pair = AssistantMessageStream.makeStream()
        Task {
            pair.continuation.push(.start(partial: message))
            for call in calls {
                _ = await bridge.execute(call)
            }
            pair.continuation.push(.done(reason: .stop, message: message))
            pair.continuation.end(message)
        }
        return pair.stream
    }

    var options = AgentOptions(
        initialState: AgentInitialState(model: model, tools: tools),
        streamFn: streamFn,
        cwd: cwd,
        beforeToolCall: beforeToolCall,
        afterToolCall: afterToolCall
    )
    options.terminalToolName = terminalToolName
    return Agent(options: options)
}

private func cursorToolResult(in messages: [Message], id: String) -> ToolResultMessage? {
    messages.lazy.compactMap { message -> ToolResultMessage? in
        guard case .toolResult(let result) = message, result.toolCallId == id else { return nil }
        return result
    }.first
}

private func cursorResultText(_ result: ToolResultMessage?) -> String {
    result?.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text.text
    }.joined(separator: "\n") ?? ""
}

private enum CursorExecTestError: Error {
    case missingBridge
}
