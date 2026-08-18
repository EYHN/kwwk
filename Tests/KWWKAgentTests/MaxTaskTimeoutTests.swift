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

    @Test("bash: the cap folds into the soft-timeout bounds and the schema")
    func bashSchemaReflectsCap() throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let tools = buildCodingToolList(
            cwd: "/",
            selected: [.bash],
            backgroundManager: BackgroundTaskManager(outputDir: outputDir),
            sessionId: "s",
            bashDefaultTimeoutSeconds: 120,
            bashMaxTimeoutSeconds: 600,
            maxTaskTimeoutSeconds: 45,
            bashEnvironment: testBashEnvironment
        )
        let tool = try #require(tools.first { $0.name == "bash" })
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
        #expect(tool.description.contains("longer than 45s"))
    }

    @Test("bash: without a cap the configured bounds stand")
    func bashBoundsWithoutCap() throws {
        let tools = buildCodingToolList(
            cwd: "/",
            selected: [.bash],
            backgroundManager: nil,
            sessionId: "s",
            bashDefaultTimeoutSeconds: 10,
            bashMaxTimeoutSeconds: 600,
            bashEnvironment: testBashEnvironment
        )
        let tool = try #require(tools.first { $0.name == "bash" })
        guard case .object(let schema) = tool.parameters,
              case .object(let props) = schema["properties"] ?? .null,
              case .object(let timeout) = props["timeout"] ?? .null else {
            Issue.record("expected timeout schema")
            return
        }
        #expect(timeout["maximum"] == .int(600))
        if case .string(let text) = timeout["description"] ?? .null {
            #expect(text.contains("Default 10, max 600"))
        } else {
            Issue.record("expected timeout description")
        }
    }

    @Test("bash: a model timeout above the cap still flips at the cap")
    func bashModelTimeoutIsOverriddenByCap() async throws {
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let releaseFile = cwdDir.appendingPathComponent("release-cap")
        let tools = buildCodingToolList(
            cwd: cwdDir.path,
            selected: [.bash],
            backgroundManager: manager,
            sessionId: "cap-session",
            bashDefaultTimeoutSeconds: 120,
            bashMaxTimeoutSeconds: 600,
            maxTaskTimeoutSeconds: 1,
            bashEnvironment: testBashEnvironment
        )
        let tool = try #require(tools.first { $0.name == "bash" })
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
        #expect(capped.description.contains("longer than 45s"))
        #expect(capped.description.contains("moved to the background automatically"))
        guard case .object(let schema) = capped.parameters,
              case .object(let props) = schema["properties"] ?? .null,
              case .object(let timeout) = props["timeout"] ?? .null else {
            Issue.record("expected agent timeout schema")
            return
        }
        #expect(timeout["maximum"] == .int(45))
        if case .string(let text) = timeout["description"] ?? .null {
            #expect(text.contains("Default 45, max 45"))
        } else {
            Issue.record("expected timeout description")
        }

        // Without a cap the limits' own foreground bounds stand (bash parity:
        // default 120, max 600).
        let uncapped = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )
        #expect(uncapped.description.contains("at most 600s"))
        guard case .object(let schema2) = uncapped.parameters,
              case .object(let props2) = schema2["properties"] ?? .null,
              case .object(let timeout2) = props2["timeout"] ?? .null else {
            Issue.record("expected agent timeout schema")
            return
        }
        #expect(timeout2["maximum"] == .int(600))
        if case .string(let text) = timeout2["description"] ?? .null {
            #expect(text.contains("Default 120, max 600"))
        } else {
            Issue.record("expected timeout description")
        }
    }

    @Test("agent: the model's own `timeout` is the foreground wait, and the cap bounds it")
    func agentModelTimeoutDrivesTheFlip() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let releaseFile = outputDir.appendingPathComponent("release-child")
        faux.setResponses([
            .factory { _, _, _, _ in
                while !FileManager.default.fileExists(atPath: releaseFile.path) {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                return yieldMessage("late answer")
            },
        ])
        let manager = BackgroundTaskManager(outputDir: outputDir)
        // No runtime cap: a 1s `timeout` from the model flips at 1s.
        let tool = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "parent-timeout",
            bashEnvironment: testBashEnvironment
        )
        let started = Date()
        let result = try await tool.execute(
            "call-timeout",
            .object([
                "description": .string("slow child"),
                "prompt": .string("take your time"),
                "subagent_type": .string("slow"),
                "timeout": .int(1),
            ]),
            nil, nil
        )
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(detail(result, "status") == .string("auto_backgrounded"))
        #expect(detail(result, "softTimeoutSeconds") == .int(1))
        FileManager.default.createFile(atPath: releaseFile.path, contents: Data())
        guard case .string(let taskId) = detail(result, "task_id") ?? .null else {
            Issue.record("expected task_id")
            return
        }
        #expect(await awaitUntil(10_000) {
            await manager.get(taskId)?.status == .completed
        })

        // With a 1s cap, a `timeout` of 300 is lowered to 1, not rejected.
        try? FileManager.default.removeItem(at: releaseFile)
        faux.setResponses([
            .factory { _, _, _, _ in
                while !FileManager.default.fileExists(atPath: releaseFile.path) {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                return yieldMessage("late answer 2")
            },
        ])
        let capped = createAgentTool(
            cwd: outputDir.path,
            subagents: [slowSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "parent-timeout-capped",
            bashEnvironment: testBashEnvironment,
            maxTaskTimeoutSeconds: 1
        )
        let started2 = Date()
        let result2 = try await capped.execute(
            "call-timeout-capped",
            .object([
                "description": .string("slow child"),
                "prompt": .string("take your time"),
                "subagent_type": .string("slow"),
                "timeout": .int(300),
                "run_in_background": .bool(false),
            ]),
            nil, nil
        )
        #expect(Date().timeIntervalSince(started2) < 10)
        #expect(detail(result2, "status") == .string("auto_backgrounded"))
        #expect(detail(result2, "softTimeoutSeconds") == .int(1))
        FileManager.default.createFile(atPath: releaseFile.path, contents: Data())
        guard case .string(let taskId2) = detail(result2, "task_id") ?? .null else {
            Issue.record("expected task_id")
            return
        }
        #expect(await awaitUntil(10_000) {
            await manager.get(taskId2)?.status == .completed
        })
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
        #expect(detail(result, "softTimeoutSeconds") == .int(1))
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
