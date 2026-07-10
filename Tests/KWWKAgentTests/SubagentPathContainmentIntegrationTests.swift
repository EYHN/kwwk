import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Subagent path containment integration")
struct SubagentPathContainmentIntegrationTests {
    @Test("child read rejects traversal and an escaping workspace symlink, then summarizes")
    func childRejectsTraversalAndSymlinkEscape() async throws {
        let fixture = try SubagentPathFixture()
        defer { fixture.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let capture = ChildToolResultCapture()
        let finalAnswer = "Both attempted reads were denied by the workspace boundary."

        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(
                        name: "read",
                        arguments: .object([
                            "path": .string("../outside/secret.txt"),
                        ]),
                        id: "read-dotdot-outside"
                    ),
                    fauxToolCall(
                        name: "read",
                        arguments: .object([
                            "path": .string("escape/secret.txt"),
                        ]),
                        id: "read-symlink-outside"
                    ),
                ],
                stopReason: .toolUse
            )),
            .factory { context, _, _, _ in
                await capture.record(context.messages)
                return containmentYieldMessage(finalAnswer)
            },
        ])

        let result = try await makeContainmentAgentTool(
            fixture: fixture,
            model: faux.getModel(),
            childPolicy: nil
        ).execute(
            "path-containment",
            subagentInvocationArguments,
            nil,
            nil
        )

        #expect(agentResultText(result).contains(finalAnswer))
        #expect(agentResultStatus(result) == "completed")
        let results = await capture.snapshot()
        #expect(results.count == 2)
        expectDeniedRead(results["read-dotdot-outside"])
        expectDeniedRead(results["read-symlink-outside"])
    }

    @Test("child definition cannot relax a workspace-only parent policy")
    func childCannotRelaxParentPolicy() async throws {
        let fixture = try SubagentPathFixture()
        defer { fixture.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let capture = ChildToolResultCapture()
        let finalAnswer = "The parent workspace policy still denied the read."

        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(
                        name: "read",
                        arguments: .object([
                            "path": .string(fixture.secret.path),
                        ]),
                        id: "read-after-policy-relaxation"
                    ),
                ],
                stopReason: .toolUse
            )),
            .factory { context, _, _, _ in
                await capture.record(context.messages)
                return containmentYieldMessage(finalAnswer)
            },
        ])

        let result = try await makeContainmentAgentTool(
            fixture: fixture,
            model: faux.getModel(),
            childPolicy: .unrestricted
        ).execute(
            "policy-narrowing",
            subagentInvocationArguments,
            nil,
            nil
        )

        #expect(agentResultText(result).contains(finalAnswer))
        #expect(agentResultStatus(result) == "completed")
        let results = await capture.snapshot()
        #expect(results.count == 1)
        expectDeniedRead(results["read-after-policy-relaxation"])
    }
}

private func containmentYieldMessage(_ result: String) -> AssistantMessage {
    fauxAssistantMessage(
        blocks: [fauxToolCall(
            name: "subagent_yield",
            arguments: .object([
                "status": .string("complete"),
                "result": .string(result),
            ]),
            id: UUID().uuidString
        )],
        stopReason: .toolUse
    )
}

private struct SubagentPathFixture {
    let container: URL
    let workspace: URL
    let outside: URL
    let secret: URL

    init() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-subagent-path-\(UUID().uuidString)", isDirectory: true)
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let secret = outside.appendingPathComponent("secret.txt")
        try Data("outside secret sentinel".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("escape", isDirectory: true),
            withDestinationURL: outside
        )

        self.container = container
        self.workspace = workspace
        self.outside = outside
        self.secret = secret
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}

private struct CapturedChildToolResult: Sendable {
    var isError: Bool
    var text: String
}

private actor ChildToolResultCapture {
    private var results: [String: CapturedChildToolResult] = [:]

    func record(_ messages: [Message]) {
        for message in messages {
            guard case .toolResult(let result) = message else { continue }
            let text = result.content.compactMap { block -> String? in
                if case .text(let content) = block { return content.text }
                return nil
            }.joined(separator: "\n")
            results[result.toolCallId] = CapturedChildToolResult(
                isError: result.isError,
                text: text
            )
        }
    }

    func snapshot() -> [String: CapturedChildToolResult] {
        results
    }
}

private let subagentInvocationArguments: JSONValue = .object([
    "description": .string("check path containment"),
    "prompt": .string("Attempt the requested reads, then summarize whether they succeeded."),
    "subagent_type": .string("reader"),
])

private func makeContainmentAgentTool(
    fixture: SubagentPathFixture,
    model: Model,
    childPolicy: FileAccessPolicy?
) -> AgentTool {
    createAgentTool(
        cwd: fixture.workspace.path,
        subagents: [
            SubagentDefinition(
                name: "reader",
                description: "Tests child path authorization.",
                prompt: "Use the read tool as requested, then report the observed result.",
                tools: .readOnly,
                fileAccessPolicy: childPolicy
            ),
        ],
        parentModel: model,
        parentTools: .readOnly,
        parentFileAccessPolicy: .workspaceOnly,
        limits: SubagentLimits(maxTurns: 4, timeoutSeconds: 10),
        bashEnvironment: testBashEnvironment
    )
}

private func expectDeniedRead(_ result: CapturedChildToolResult?) {
    guard let result else {
        Issue.record("expected child read tool result")
        return
    }
    #expect(result.isError)
    #expect(result.text.contains("Access denied"))
    #expect(result.text.contains("outside secret sentinel") == false)
}

private func agentResultText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block -> String? in
        if case .text(let content) = block { return content.text }
        return nil
    }.joined(separator: "\n")
}

private func agentResultStatus(_ result: AgentToolResult) -> String? {
    guard case .object(let details) = result.details ?? .null,
          case .string(let status) = details["status"] ?? .null else {
        return nil
    }
    return status
}
