import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// The `agent` tool's optional `thinking_level`: omitted inherits the
/// parent's level, a named level applies to that child only.
@Suite("Subagent thinking level")
struct SubagentThinkingLevelTests {
    @Test("thinking_level is an optional enum on the agent tool")
    func schemaExposesOptionalThinkingLevel() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let tool = makeTool(faux: faux)
        guard case .object(let schema) = tool.parameters,
              case .object(let properties) = schema["properties"] ?? .null,
              case .object(let thinking) = properties["thinking_level"] ?? .null,
              case .array(let values) = thinking["enum"] ?? .null,
              case .array(let required) = schema["required"] ?? .null else {
            Issue.record("agent schema has no thinking_level enum")
            return
        }
        #expect(values == ["off", "minimal", "low", "medium", "high", "xhigh", "max"].map { .string($0) })
        #expect(!required.contains(.string("thinking_level")))
    }

    @Test("omitted, blank or inherit thinking_level uses the parent's level")
    func omittedInheritsParent() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            models: [FauxModelDefinition(id: "parent-model", reasoning: true)]
        ))
        defer { faux.unregister() }
        let seen = ReasoningLog()
        faux.setResponses(Array(repeating: seen.yieldStep(), count: 4))
        let tool = makeTool(faux: faux, parentThinkingLevel: .high)

        for (index, value) in [nil, "", "  ", "inherit"].enumerated() {
            _ = try await tool.execute("call-\(index)", args(thinkingLevel: value), nil, nil)
        }

        #expect(seen.levels == [.high, .high, .high, .high])
    }

    @Test("a named thinking_level overrides the parent's level for that child")
    func namedLevelOverridesParent() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            models: [FauxModelDefinition(id: "parent-model", reasoning: true)]
        ))
        defer { faux.unregister() }
        let seen = ReasoningLog()
        faux.setResponses(Array(repeating: seen.yieldStep(), count: 3))
        let tool = makeTool(faux: faux, parentThinkingLevel: .medium)

        for (index, value) in ["low", " XHIGH ", "off"].enumerated() {
            _ = try await tool.execute("call-\(index)", args(thinkingLevel: value), nil, nil)
        }

        #expect(seen.levels == [.low, .xhigh, nil])
    }

    @Test("an unknown thinking_level is rejected before the child starts")
    func unknownLevelIsRejected() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let tool = makeTool(faux: faux)

        await #expect(throws: Error.self) {
            _ = try await tool.execute("call-bad", args(thinkingLevel: "extreme"), nil, nil)
        }
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-number",
                .object([
                    "description": .string("bad level"),
                    "prompt": .string("answer"),
                    "subagent_type": .string("mini"),
                    "thinking_level": .int(3),
                ]),
                nil,
                nil
            )
        }
        #expect(faux.state.callCount == 0)
    }

    @Test("agent_send resumes a child at the thinking_level it was launched with")
    func resumeKeepsOverride() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            models: [FauxModelDefinition(id: "parent-model", reasoning: true)]
        ))
        defer { faux.unregister() }
        let seen = ReasoningLog()
        faux.setResponses(Array(repeating: seen.yieldStep(), count: 2))
        // The toolset's parent runs with thinking off, so `.minimal` on the
        // resumed run can only come from the launch's override.
        let tools = createSubagentToolset(
            cwd: FileManager.default.currentDirectoryPath,
            model: faux.getModel(id: "parent-model")!,
            childTools: .readOnly,
            subagents: [thinkingSubagent()],
            sessionId: "thinking-resume-parent",
            bashEnvironment: testBashEnvironment
        ).tools
        guard let agent = tools.first(where: { $0.name == "agent" }),
              let send = tools.first(where: { $0.name == "agent_send" }) else {
            Issue.record("expected agent and agent_send tools")
            return
        }

        var launch = args(thinkingLevel: "minimal")
        if case .object(var object) = launch {
            object["name"] = .string("quick")
            launch = .object(object)
        }
        _ = try await agent.execute("call-launch", launch, nil, nil)
        _ = try await send.execute(
            "call-send",
            .object(["agent_id": .string("quick"), "message": .string("again")]),
            nil,
            nil
        )

        #expect(seen.levels == [.minimal, .minimal])
    }
}

private final class ReasoningLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ReasoningLevel?] = []

    var levels: [ReasoningLevel?] { lock.withLock { stored } }

    func yieldStep() -> FauxResponseStep {
        .factory { [self] _, options, _, _ in
            lock.withLock { stored.append(options?.reasoning) }
            return fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "subagent_yield",
                    arguments: .object([
                        "status": .string("complete"),
                        "result": .string("done"),
                    ]),
                    id: UUID().uuidString
                )],
                stopReason: .toolUse
            )
        }
    }
}

private func thinkingSubagent() -> SubagentDefinition {
    SubagentDefinition(
        name: "mini",
        description: "Use for test subagent work.",
        prompt: "Return the requested test answer. Do not edit files."
    )
}

private func makeTool(
    faux: FauxProviderRegistration,
    parentThinkingLevel: ThinkingLevel = .off
) -> AgentTool {
    createAgentTool(
        cwd: FileManager.default.currentDirectoryPath,
        subagents: [thinkingSubagent()],
        parentModel: faux.getModel(id: faux.models[0].id)!,
        parentTools: .readOnly,
        parentThinkingLevel: parentThinkingLevel,
        bashEnvironment: testBashEnvironment
    )
}

private func args(thinkingLevel: String?) -> JSONValue {
    var object: [String: JSONValue] = [
        "description": .string("thinking level"),
        "prompt": .string("answer"),
        "subagent_type": .string("mini"),
    ]
    if let thinkingLevel { object["thinking_level"] = .string(thinkingLevel) }
    return .object(object)
}
