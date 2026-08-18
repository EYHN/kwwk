import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// `maxTaskTimeoutSeconds`: the runtime-wide ceiling on how long one `bash`
/// or `agent` call may keep the model waiting. It beats the model's own
/// `timeout` and its `run_in_background: false`; work that outlives it is
/// moved to the background when a manager is attached.
@Suite("maxTaskTimeoutSeconds wait cap")
struct MaxTaskTimeoutTests {
    // MARK: - bash

    @Test("bash: cap lowers the schema maximum and the default")
    func bashSchemaReflectsCap() {
        let tool = createBashTool(cwd: "/", options: BashToolOptions(
            environment: testBashEnvironment,
            defaultTimeoutSeconds: 120,
            maxTimeoutSeconds: 600,
            manager: BackgroundTaskManager(outputDir: makeTempDir()),
            maxTaskTimeoutSeconds: 45
        ))
        guard case .object(let schema) = tool.parameters,
              case .object(let props) = schema["properties"] ?? .null,
              case .object(let timeout) = props["timeout"] ?? .null else {
            Issue.record("expected timeout schema")
            return
        }
        #expect(timeout["maximum"] == .int(45))
        if case .string(let text) = timeout["description"] ?? .null {
            #expect(text.contains("Default 45, max 45"))
        } else {
            Issue.record("expected timeout description")
        }
        #expect(tool.description.contains("45s"))
    }

    @Test("bash: cap without a manager leaves the schema at the cap too")
    func bashSchemaWithoutManager() {
        let options = BashToolOptions(
            environment: testBashEnvironment,
            defaultTimeoutSeconds: 10,
            maxTimeoutSeconds: 600,
            maxTaskTimeoutSeconds: 45
        )
        #expect(options.effectiveMaxTimeoutSeconds == 45)
        #expect(options.effectiveDefaultTimeoutSeconds == 10)
        let uncapped = BashToolOptions(environment: testBashEnvironment)
        #expect(uncapped.effectiveMaxTimeoutSeconds == 600)
        #expect(uncapped.effectiveDefaultTimeoutSeconds == 120)
    }

    @Test("bash: a model timeout above the cap still flips at the cap")
    func bashModelTimeoutIsOverriddenByCap() async throws {
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let releaseFile = cwdDir.appendingPathComponent("release-cap")
        let tool = createBashTool(cwd: cwdDir.path, options: BashToolOptions(
            environment: testBashEnvironment,
            defaultTimeoutSeconds: 120,
            maxTimeoutSeconds: 600,
            manager: manager,
            sessionId: "cap-session",
            autoBackgroundOnTimeout: true,
            maxTaskTimeoutSeconds: 1
        ))
        let started = Date()
        let result = try await tool.execute(
            "call-1",
            .object([
                "command": .string("while [ ! -f \(shellQuote(releaseFile.path)) ]; do sleep 0.1; done"),
                "timeout": .int(300),
                "run_in_background": .bool(false),
            ]),
            nil, nil
        )
        // Returned around the 1s cap, not the 300s the model asked for.
        #expect(Date().timeIntervalSince(started) < 10)
        guard case .object(let details) = result.details ?? .null else {
            Issue.record("expected details object")
            return
        }
        #expect(details["status"] == .string("auto_backgrounded"))
        #expect(details["softTimeoutSeconds"] == .int(1))
        guard case .string(let taskId) = details["taskId"] ?? .null else {
            Issue.record("expected taskId")
            return
        }
        #expect(await manager.get(taskId)?.status == .running)
        FileManager.default.createFile(atPath: releaseFile.path, contents: Data())
        #expect(await awaitUntil(10_000) {
            await manager.get(taskId)?.status == .completed
        })
    }

    // MARK: - agent

    @Test("agent: description advertises the wait cap")
    func agentDescriptionMentionsCap() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let capped = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: BackgroundTaskManager(outputDir: outputDir),
            sessionId: "parent",
            bashEnvironment: testBashEnvironment,
            maxTaskTimeoutSeconds: 45
        )
        #expect(capped.description.contains("more than 45s"))
        #expect(capped.description.contains("moved to the background automatically"))
        let uncapped = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )
        #expect(!uncapped.description.contains("more than"))
    }

    @Test("agent: a child that finishes inside the cap returns a normal foreground result")
    func agentFastChildStaysForeground() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(yieldMessage("quick answer"))])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "parent-fast",
            bashEnvironment: testBashEnvironment,
            maxTaskTimeoutSeconds: 30
        )
        let result = try await tool.execute(
            "call-fast",
            .object([
                "description": .string("fast child"),
                "prompt": .string("answer quickly"),
                "subagent_type": .string("slow"),
                "run_in_background": .bool(false),
            ]),
            nil, nil
        )
        #expect(text(of: result).contains("quick answer"))
        #expect(detail(result, "status") == .string("completed"))
        // Nothing was registered with the manager and no stray output file
        // remains from the foreground phase.
        #expect(await manager.list().isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        #expect(leftovers.filter { $0.hasPrefix("fg_") }.isEmpty)
    }

    @Test("agent: a child still running at the cap is moved to the background despite run_in_background=false")
    func agentSlowChildFlipsToBackground() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let releaseFile = outputDir.appendingPathComponent("release-child")
        faux.setResponses([
            .factory { _, _, _, _ in
                // Hold the child's only model turn until the test releases it.
                while !FileManager.default.fileExists(atPath: releaseFile.path) {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                return yieldMessage("late answer")
            },
        ])
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "parent-slow",
            bashEnvironment: testBashEnvironment,
            maxTaskTimeoutSeconds: 1
        )
        let started = Date()
        let result = try await tool.execute(
            "call-slow",
            .object([
                "description": .string("slow child"),
                "prompt": .string("take your time"),
                "subagent_type": .string("slow"),
                "run_in_background": .bool(false),
            ]),
            nil, nil
        )
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(detail(result, "status") == .string("auto_backgrounded"))
        #expect(detail(result, "wait_cap_seconds") == .int(1))
        #expect(detail(result, "subagent_type") == .string("slow"))
        #expect(text(of: result).contains("moved to the background"))
        guard case .string(let taskId) = detail(result, "task_id") ?? .null else {
            Issue.record("expected task_id")
            return
        }
        let events = result.runtimeEvents ?? []
        #expect(events.contains { event in
            if case .subagent(let lifecycle) = event {
                return lifecycle.kind == .backgroundStarted && lifecycle.backgroundTaskId == taskId
            }
            return false
        })

        // Registered as a running agent task under the parent session, and
        // the child is still alive: no completion yet.
        let snapshot = try #require(await manager.get(taskId))
        #expect(snapshot.status == .running)
        #expect(snapshot.spec.kind == "agent")
        #expect(snapshot.sessionId == "parent-slow")
        #expect(await manager.drainNotifications(sessionId: "parent-slow").isEmpty)

        // Release the child: the manager sees it finish and notifies with
        // the same terminal shape a background-started child produces.
        FileManager.default.createFile(atPath: releaseFile.path, contents: Data())
        #expect(await awaitUntil(10_000) {
            await manager.get(taskId)?.status == .completed
        })
        let done = try #require(await manager.get(taskId))
        #expect(done.outcome?.success == true)
        guard case .object(let outcome) = done.outcome?.details ?? .null else {
            Issue.record("expected outcome details")
            return
        }
        #expect(outcome["status"] == .string("completed"))
        #expect(outcome["subagent_type"] == .string("slow"))
        #expect(done.outputTail.contains("[final]"))
        #expect(done.outputTail.contains("late answer"))
        let notifications = await manager.drainNotifications(sessionId: "parent-slow")
        #expect(notifications.map(\.taskId) == [taskId])
    }

    @Test("agent: killing the adopted task cancels the child")
    func agentFlippedChildHonoursManagerKill() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        faux.setResponses([
            .factory { _, _, _, _ in
                // Never answers on its own; only cancellation ends this turn.
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            },
        ])
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "parent-kill",
            bashEnvironment: testBashEnvironment,
            maxTaskTimeoutSeconds: 1
        )
        let result = try await tool.execute(
            "call-kill",
            .object([
                "description": .string("stuck child"),
                "prompt": .string("hang"),
                "subagent_type": .string("slow"),
            ]),
            nil, nil
        )
        guard case .string(let taskId) = detail(result, "task_id") ?? .null else {
            Issue.record("expected task_id")
            return
        }
        try await manager.kill(taskId)
        #expect(await awaitUntil(10_000) {
            let status = await manager.get(taskId)?.status
            return status == .killed || status == .failed
        })
    }

    @Test("agent: without a manager the cap is the child's deadline")
    func agentCapWithoutManagerTimesOut() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .factory { _, _, _, _ in
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            },
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let tool = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            limits: SubagentLimits(timeoutSeconds: 600),
            bashEnvironment: testBashEnvironment,
            maxTaskTimeoutSeconds: 1
        )
        let started = Date()
        do {
            _ = try await tool.execute(
                "call-nomanager",
                .object([
                    "description": .string("stuck child"),
                    "prompt": .string("hang"),
                    "subagent_type": .string("slow"),
                ]),
                nil, nil
            )
            Issue.record("expected the capped child to time out")
        } catch let error as StructuredToolExecutionError {
            #expect(Date().timeIntervalSince(started) < 10)
            guard case .object(let details) = error.details ?? .null else {
                Issue.record("expected structured failure details")
                return
            }
            #expect(details["failure_kind"] == .string("timeout"))
        }
    }
}

private func slowSubagent() -> SubagentDefinition {
    SubagentDefinition(
        name: "slow",
        description: "Exercises the foreground wait cap.",
        prompt: "Answer the task.",
        tools: .readOnly
    )
}

private func yieldMessage(_ result: String) -> AssistantMessage {
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

private func text(of result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined()
}

private func detail(_ result: AgentToolResult, _ key: String) -> JSONValue? {
    guard case .object(let details) = result.details ?? .null else { return nil }
    return details[key]
}
