import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("Headless background policy", .serialized)
struct HeadlessTests {
    @Test("headless forces reusable background-default subagents to foreground")
    func headlessOverridesDefinitionDefault() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage(
            blocks: [fauxToolCall(
                name: "subagent_yield",
                arguments: .object([
                    "status": .string("complete"),
                    "result": .string("foreground child result"),
                ]),
                id: "yield-headless"
            )],
            stopReason: .toolUse
        ))])

        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-headless-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        var definition = SubagentDefinition.general(tools: .readOnly)
        definition.runInBackgroundByDefault = true
        let agent = await makeHeadlessCodingAgent(CodingAgentConfig(
            model: faux.getModel(),
            cwd: cwd.path,
            tools: .readOnly,
            backgroundManager: BackgroundTaskManager(
                outputDir: cwd.appendingPathComponent("background", isDirectory: true)
            ),
            subagents: [definition],
            sessionId: "headless-default",
            autoCompactThreshold: nil,
            bashEnvironment: [:]
        ))

        guard let subagent = agent.state.tools.first(where: { $0.name == "agent" }) else {
            Issue.record("expected subagent tool")
            return
        }
        let result = try await subagent.execute(
            "foreground-default",
            .object([
                "description": .string("check default"),
                "prompt": .string("return a result"),
                "subagent_type": .string("general"),
            ]),
            nil,
            nil
        )
        let rendered = result.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")
        #expect(rendered.contains("foreground child result"))
        #expect(!rendered.contains("requires a BackgroundTaskManager"))
    }

    @Test("headless builder strips background capabilities even from a reusable config")
    func headlessBuilderForbidsBackground() async throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-headless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let manager = BackgroundTaskManager(
            outputDir: cwd.appendingPathComponent("background", isDirectory: true)
        )
        let config = CodingAgentConfig(
            model: headlessTestModel(),
            cwd: cwd.path,
            tools: .standard,
            backgroundManager: manager,
            subagents: [.general()],
            sessionId: "headless-policy",
            autoCompactThreshold: nil,
            bashEnvironment: [:]
        )

        let agent = await makeHeadlessCodingAgent(config)
        let toolNames = Set(agent.state.tools.map(\.name))
        #expect(!toolNames.contains("task"))
        #expect(!toolNames.contains("task_poll"))
        #expect(!toolNames.contains("task_cancel"))
        #expect(!toolNames.contains("task_list"))
        #expect(!toolNames.contains("task_read"))

        guard let bash = agent.state.tools.first(where: { $0.name == "bash" }),
              case .object(let bashSchema) = bash.parameters,
              case .object(let bashProperties) = bashSchema["properties"] ?? .null else {
            Issue.record("expected headless bash schema")
            return
        }
        #expect(bashProperties["run_in_background"] == nil)

        guard let subagent = agent.state.tools.first(where: { $0.name == "agent" }) else {
            Issue.record("expected foreground subagent tool")
            return
        }
        guard case .object(let agentSchema) = subagent.parameters,
              case .object(let agentProperties) = agentSchema["properties"] ?? .null else {
            Issue.record("expected headless subagent schema")
            return
        }
        #expect(agentProperties["run_in_background"] == nil)
        #expect(!subagent.description.contains("run_in_background"))
        do {
            _ = try await subagent.execute(
                "headless-background-attempt",
                .object([
                    "description": .string("background attempt"),
                    "prompt": .string("do work"),
                    "subagent_type": .string("general"),
                    "run_in_background": .bool(true),
                ]),
                nil,
                nil
            )
            Issue.record("headless subagent unexpectedly started in background")
        } catch {
            #expect("\(error)".contains("requires a BackgroundTaskManager"))
        }
        #expect(await manager.list(sessionId: "headless-policy").isEmpty)
    }

    @Test("headless teardown kills any agent-owned background work")
    func headlessCleanupKillsAttachedWork() async {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-headless-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let agent = Agent(
            initialState: AgentInitialState(model: headlessTestModel()),
            sessionId: "headless-cleanup"
        )
        let detach = await agent.attachBackgroundManager(
            manager,
            sessionId: "headless-cleanup"
        )
        let (taskId, _) = await manager.spawn(
            runner: HeadlessNeverRunner(),
            sessionId: "headless-cleanup"
        )

        await cleanupHeadlessAgent(agent)

        #expect(await manager.get(taskId)?.status == .killed)
        await detach()
    }
}

private func headlessTestModel() -> Model {
    Model(
        id: "headless-test-model",
        api: "headless-test-api",
        provider: "headless-test-provider"
    )
}

private struct HeadlessNeverRunner: BackgroundTaskRunner {
    let spec = BackgroundTaskSpec(
        kind: "headless-test",
        label: "never",
        hardTimeoutSeconds: 60
    )

    func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    ) {
        Task.detached {
            while !cancellation.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            onDone(BackgroundTaskOutcome(success: false, summary: "cancelled"))
        }
    }
}
