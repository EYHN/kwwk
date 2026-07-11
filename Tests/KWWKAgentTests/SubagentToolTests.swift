import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Subagent tool")
struct SubagentToolTests {
    @Test("coding agent only exposes agent and history tools when subagents are configured")
    func agentToolIsConditional() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let cwd = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwd) }

        let withoutSubagents = await makeCodingAgent(CodingAgentConfig(
            model: faux.getModel(),
            cwd: cwd.path,
            tools: .readOnly,
            bashEnvironment: [:]
        )).agent
        #expect(!withoutSubagents.state.tools.contains { $0.name == "agent" })
        #expect(!withoutSubagents.state.tools.contains { $0.name == "agent_history" })

        let withSubagents = await makeCodingAgent(CodingAgentConfig(
            model: faux.getModel(),
            cwd: cwd.path,
            tools: .readOnly,
            subagents: [minimalSubagent()],
            bashEnvironment: [:]
        )).agent
        #expect(withSubagents.state.tools.contains { $0.name == "agent" })
        #expect(withSubagents.state.tools.contains { $0.name == "agent_history" })
    }

    @Test("unknown subagent type returns a clear error")
    func unknownSubagentType() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )

        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-1",
                .object([
                    "description": .string("unknown child"),
                    "prompt": .string("do work"),
                    "subagent_type": .string("missing"),
                ]),
                nil,
                nil
            )
        }
    }

    @Test("omitted subagent type is rejected instead of gaining general permissions")
    func omittedSubagentTypeIsRejected() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [
                SubagentDefinition(
                    name: "general",
                    description: "Use for general work.",
                    prompt: "Return the requested answer."
                ),
                minimalSubagent(),
            ],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )

        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-1",
                .object([
                    "description": .string("ambiguous child"),
                    "prompt": .string("answer without a declared capability boundary"),
                ]),
                nil,
                nil
            )
        }
    }

    @Test("definition without tools inherits parent coding tools")
    func omittedToolsInheritsParentTools() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let capture = SubagentContextCapture()
        faux.setResponses([
            .factory { context, _, _, _ in
                await capture.record(
                    messageCount: context.messages.count,
                    toolNames: context.tools?.map(\.name) ?? []
                )
                return subagentYieldMessage("captured wildcard")
            },
        ])
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent(tools: nil)],
            parentModel: faux.getModel(),
            parentTools: .standard,
            bashEnvironment: testBashEnvironment
        )

        _ = try await tool.execute(
            "call-1",
            .object([
                "description": .string("inherited tools"),
                "prompt": .string("inspect tools"),
                "subagent_type": .string("mini"),
            ]),
            nil,
            nil
        )

        let snapshot = await capture.snapshot()
        #expect(snapshot.toolNames.contains("read"))
        #expect(snapshot.toolNames.contains("write"))
        #expect(snapshot.toolNames.contains("edit"))
        #expect(snapshot.toolNames.contains("bash"))
        #expect(snapshot.toolNames.contains("grep"))
        #expect(!snapshot.toolNames.contains("agent"))
    }

    @Test("foreground subagent returns final assistant text")
    func foregroundReturnsText() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(subagentYieldMessage("subagent answer"))])
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )

        let result = try await tool.execute(
            "call-1",
            .object([
                "description": .string("answer task"),
                "prompt": .string("answer from child"),
                "subagent_type": .string("mini"),
            ]),
            nil,
            nil
        )

        #expect(resultText(result).contains("subagent answer"))
        guard case .object(let details) = result.details ?? .null else {
            Issue.record("expected details object")
            return
        }
        if case .string(let status) = details["status"] ?? .null {
            #expect(status == "completed")
        } else {
            Issue.record("expected status detail")
        }
        if case .string(let model) = details["model"] ?? .null {
            #expect(model == faux.getModel().id)
        } else {
            Issue.record("expected inherited model detail")
        }
    }

    @Test("SDK SubagentRunner can run a subagent directly")
    func sdkRunnerForeground() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(subagentYieldMessage("direct subagent answer"))])
        let runner = SubagentRunner(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )

        let result = try await runner.run(type: "mini", prompt: "answer directly")

        #expect(result.text.contains("direct subagent answer"))
        #expect(result.model.id == faux.getModel().id)
        #expect(result.stopReason == .stop)
    }

    @Test("SDK SubagentRunner can start a background subagent")
    func sdkRunnerBackground() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(subagentYieldMessage("direct background answer"))])
        let manager = BackgroundTaskManager()
        let runner = SubagentRunner(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "sdk-parent",
            bashEnvironment: testBashEnvironment
        )

        let started = try await runner.startBackground(
            type: "mini",
            prompt: "answer in background",
            description: "sdk background"
        )

        #expect(started.subagentType == "mini")
        let done = await awaitUntil(12000) {
            let snap = await manager.get(started.taskId)
            return snap?.status != .running
        }
        #expect(done)
        guard done else { return }

        let taskTool = createTaskTool(manager: manager, sessionId: "sdk-parent")
        let waitResult = try await taskTool.execute(
            "wait",
            .object([
                "poll": .array([.string(started.taskId)]),
                "timeout_seconds": .int(1),
            ]),
            nil,
            nil
        )
        #expect(resultText(waitResult).contains("direct background answer"))
        #expect(FileManager.default.fileExists(atPath: started.outputFile.path))
    }

    @Test("foreground subagent emits token progress updates")
    func foregroundEmitsTokenProgress() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        faux.setResponses([.message(subagentYieldMessage("subagent token answer"))])
        let updates = ToolUpdateCapture()
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )

        let result = try await tool.execute(
            "call-1",
            .object([
                "description": .string("token task"),
                "prompt": .string("answer with token accounting"),
                "subagent_type": .string("mini"),
            ]),
            nil,
            { update in
                updates.record(update)
            }
        )

        let displays = updates.uiDisplays()
        #expect(displays.contains { $0.contains("tokens") })
        #expect(detailObject(result, "usage") != nil)
        #expect(detailString(result, "child_session_id") != nil)
    }

    @Test("agent loop forwards subagent lifecycle events and aggregates summary")
    func lifecycleEventsAndRunSummary() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(
                        name: "agent",
                        arguments: .object([
                            "description": .string("delegate child"),
                            "prompt": .string("answer from child"),
                            "subagent_type": .string("mini"),
                        ]),
                        id: "agent-1"
                    ),
                ],
                stopReason: .toolUse
            )),
            .message(subagentYieldMessage("child lifecycle answer")),
            .message(fauxAssistantMessage("parent done")),
        ])

        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            tools: [tool]
        ))
        let capture = SubagentRuntimeCapture()
        _ = agent.subscribe { event, _ in
            switch event {
            case .runtimeEvent(.subagent(let subagent)):
                await capture.append(kind: subagent.kind)
            case .agentEnd(_, let summary):
                await capture.set(summary: summary)
            default:
                break
            }
        }

        try await agent.prompt("delegate")

        let kinds = await capture.kinds()
        #expect(kinds.contains(.started))
        #expect(kinds.contains(.toolUpdate))
        #expect(kinds.contains(.completed))

        guard let summary = await capture.summary() else {
            Issue.record("expected agent summary")
            return
        }
        #expect(summary.subagents.count == 1)
        #expect(summary.subagents.first?.subagentType == "mini")
        #expect(summary.subagents.first?.status == .completed)
        #expect((summary.subagents.first?.usage?.totalTokens ?? 0) > 0)
        #expect((summary.subagents.first?.turns ?? 0) > 0)
        #expect((summary.subagents.first?.durationMs ?? 0) >= 0)
    }

    @Test("failed subagent results keep structured failure details")
    func failedSubagentDetails() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(
                        name: "agent",
                        arguments: .object([
                            "description": .string("failing child"),
                            "prompt": .string("fail from child"),
                            "subagent_type": .string("mini"),
                        ]),
                        id: "agent-1"
                    ),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage(
                "boom",
                stopReason: .error,
                errorMessage: "child blew up"
            )),
            .message(fauxAssistantMessage("parent observed failure")),
        ])

        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            tools: [tool]
        ))
        let capture = SubagentRuntimeCapture()
        _ = agent.subscribe { event, _ in
            switch event {
            case .runtimeEvent(.subagent(let subagent)):
                await capture.append(kind: subagent.kind)
            case .agentEnd(_, let summary):
                await capture.set(summary: summary)
            default:
                break
            }
        }

        try await agent.prompt("delegate")

        let toolResult = agent.state.messages.compactMap { message -> ToolResultMessage? in
            if case .toolResult(let result) = message, result.toolName == "agent" {
                return result
            }
            return nil
        }.first
        guard let toolResult, case .object(let details) = toolResult.details ?? .null else {
            Issue.record("expected structured tool result details")
            return
        }
        #expect(toolResult.isError)
        #expect(details["status"] == .string("failed"))
        #expect(details["subagent_type"] == .string("mini"))
        #expect(details["error_message"] == .string("agent: child blew up"))

        let kinds = await capture.kinds()
        #expect(kinds.contains(.failed))
        let summary = await capture.summary()
        #expect(summary?.subagents.first?.status == .failed)
        #expect(summary?.subagents.first?.errorMessage == "agent: child blew up")
    }

    @Test("fresh subagent does not inherit parent transcript or recursive agent tool")
    func freshContextAndNoRecursiveAgentTool() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let capture = SubagentContextCapture()
        faux.setResponses([
            .factory { context, _, _, _ in
                await capture.record(
                    messageCount: context.messages.count,
                    toolNames: context.tools?.map(\.name) ?? []
                )
                return subagentYieldMessage("captured")
            },
        ])
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent(tools: .standard)],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )

        _ = try await tool.execute(
            "call-1",
            .object([
                "description": .string("inspect child"),
                "prompt": .string("child prompt only"),
                "subagent_type": .string("mini"),
            ]),
            nil,
            nil
        )

        let snapshot = await capture.snapshot()
        #expect(snapshot.messageCount == 1)
        #expect(!snapshot.toolNames.contains("agent"))
        #expect(!snapshot.toolNames.contains("write"))
        #expect(!snapshot.toolNames.contains("edit"))
        #expect(!snapshot.toolNames.contains("bash"))
    }

    @Test("definition model override and tool-call model override precedence")
    func modelOverridePrecedence() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            models: [
                FauxModelDefinition(id: "parent-model"),
                FauxModelDefinition(id: "definition-model"),
                FauxModelDefinition(id: "tool-model"),
            ]
        ))
        defer { faux.unregister() }
        let parent = faux.getModel(id: "parent-model")!
        let definitionModel = faux.getModel(id: "definition-model")!
        let toolModel = faux.getModel(id: "tool-model")!
        faux.setResponses([
            .message(subagentYieldMessage("definition model result")),
            .message(subagentYieldMessage("tool model result")),
        ])
        let definition = minimalSubagent(model: .override(definitionModel))
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [definition],
            parentModel: parent,
            parentTools: .readOnly,
            allowedModelOverrides: [toolModel],
            bashEnvironment: testBashEnvironment
        )

        let definitionResult = try await tool.execute(
            "call-1",
            .object([
                "description": .string("definition model"),
                "prompt": .string("use definition model"),
                "subagent_type": .string("mini"),
            ]),
            nil,
            nil
        )
        #expect(detailString(definitionResult, "model") == "definition-model")

        let toolOverrideResult = try await tool.execute(
            "call-2",
            .object([
                "description": .string("tool model"),
                "prompt": .string("use tool model"),
                "subagent_type": .string("mini"),
                "model": .string("tool-model"),
            ]),
            nil,
            nil
        )
        #expect(detailString(toolOverrideResult, "model") == "tool-model")
    }

    @Test("tool-call model override cannot switch provider through the global catalog")
    func modelOverrideStaysOnParentProvider() async throws {
        guard let foreign = ModelsCatalog.models(for: "openai").first else {
            Issue.record("expected bundled OpenAI catalog models")
            return
        }
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            models: [FauxModelDefinition(id: "parent-model")]
        ))
        defer { faux.unregister() }
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(id: "parent-model")!,
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )

        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "call-cross-provider-model",
                .object([
                    "description": .string("foreign model id"),
                    "prompt": .string("use parent provider"),
                    "subagent_type": .string("mini"),
                    "model": .string(foreign.id),
                ]),
                nil,
                nil
            )
        }
    }

    @Test("public agent tool overload reads live parent agent state")
    func publicOverloadReadsLiveParentState() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            models: [
                FauxModelDefinition(id: "initial-parent"),
                FauxModelDefinition(id: "live-parent"),
            ]
        ))
        defer { faux.unregister() }
        let parentAgent = Agent(initialState: AgentInitialState(
            model: faux.getModel(id: "initial-parent")!
        ))
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentAgent: parentAgent,
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )
        parentAgent.state.model = faux.getModel(id: "live-parent")!
        faux.setResponses([.message(subagentYieldMessage("live model result"))])

        let result = try await tool.execute(
            "call-1",
            .object([
                "description": .string("live parent"),
                "prompt": .string("use live parent model"),
                "subagent_type": .string("mini"),
            ]),
            nil,
            nil
        )

        #expect(detailString(result, "model") == "live-parent")
    }

    @Test("background subagent writes output and can be read with task poll")
    func backgroundSubagent() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(subagentYieldMessage("background subagent answer"))])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "s1",
            bashEnvironment: testBashEnvironment
        )

        let result = try await tool.execute(
            "call-1",
            .object([
                "description": .string("background child"),
                "prompt": .string("run in background"),
                "subagent_type": .string("mini"),
                "run_in_background": .bool(true),
            ]),
            nil,
            nil
        )
        guard let taskId = detailString(result, "task_id") else {
            Issue.record("expected task_id detail")
            return
        }
        #expect(resultText(result).contains("agent_history(task_id: \"\(taskId)\")"))
        #expect(resultText(result).contains("poll only when otherwise blocked"))

        let done = await awaitUntil(12000) {
            let snap = await manager.get(taskId)
            return snap?.status != .running
        }
        #expect(done)
        guard done else { return }
        let snap = await manager.get(taskId)
        #expect(snap?.status == .completed)
        let contents = snap?.outputFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        #expect(contents.contains("background subagent answer"))

        let taskTool = createTaskTool(manager: manager, sessionId: "s1")
        let waitResult = try await taskTool.execute(
            "wait-1",
            .object([
                "poll": .array([.string(taskId)]),
                "timeout_seconds": .int(1),
            ]),
            nil,
            nil
        )
        #expect(resultText(waitResult).contains("background subagent answer"))
    }

    @Test("background progress is visible through task list before completion")
    func backgroundProgressIsVisibleWhileRunning() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokensPerSecond: 50,
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        let finalAnswer = "background progress final " + String(repeating: "x", count: 48)
        let bashSecret = "BASH_COMMAND_SECRET_MUST_NOT_APPEAR"
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "bash",
                    arguments: .object([
                        "command": .string("AWS_SECRET_ACCESS_KEY=\(bashSecret) sleep 1"),
                        "description": .string("Pause briefly"),
                    ]),
                    id: "progress-bash"
                )],
                stopReason: .toolUse
            )),
            .message(subagentYieldMessage(finalAnswer)),
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent(tools: [.bash])],
            parentModel: faux.getModel(),
            parentTools: .standard,
            backgroundManager: manager,
            sessionId: "progress-parent",
            bashEnvironment: testBashEnvironment
        )

        let started = try await tool.execute(
            "progress-background",
            .object([
                "description": .string("report live progress"),
                "prompt": .string("produce the requested answer"),
                "subagent_type": .string("mini"),
                "run_in_background": .bool(true),
            ]),
            nil,
            nil
        )
        guard let taskId = detailString(started, "task_id") else {
            Issue.record("expected task_id detail")
            return
        }

        let progressVisible = await awaitUntil(2_000) {
            guard let snapshot = await manager.get(taskId) else { return false }
            return snapshot.status == .running
                && snapshot.outputTail.contains("tool bash started")
                && snapshot.outputTail.contains("command=AWS_SECRET_ACCESS_KEY=<redacted> sleep 1")
                && snapshot.outputTail.contains("description=Pause briefly")
        }
        #expect(progressVisible)

        let taskTool = createTaskTool(manager: manager, sessionId: "progress-parent")
        let listed = try await taskTool.execute(
            "list-progress",
            .object(["list": .bool(true)]),
            nil,
            nil
        )
        #expect(resultText(listed).contains("output_tail:"))
        #expect(resultText(listed).contains("[progress]"))
        #expect(resultText(listed).contains("tool bash started"))
        guard case .object(let details) = listed.details ?? .null,
              case .array(let tasks) = details["tasks"] ?? .null,
              case .object(let task) = tasks.first ?? .null,
              case .string(let outputTail) = task["output_tail"] ?? .null else {
            Issue.record("expected structured output_tail in task list")
            return
        }
        #expect(outputTail.contains("[progress]"))

        let completed = await awaitUntil(5_000) {
            await manager.get(taskId)?.status == .completed
        }
        #expect(completed)
        let contents = try String(
            contentsOf: outputDir.appendingPathComponent("\(taskId).log"),
            encoding: .utf8
        )
        #expect(contents.contains("[progress]"))
        #expect(contents.contains("[final]\n\(finalAnswer)"))
        #expect(contents.contains("command=AWS_SECRET_ACCESS_KEY=<redacted> sleep 1"))
        #expect(contents.contains("tool bash finished · exit_code=0"))
        #expect(!contents.contains(bashSecret))
        let progressLineCount = contents.split(separator: "\n").filter {
            $0.hasPrefix("[progress]")
        }.count
        #expect(progressLineCount <= 8, "token updates were not throttled: \(progressLineCount)")
        guard let progressRange = contents.range(of: "[progress]"),
              let finalRange = contents.range(of: "[final]") else {
            Issue.record("expected progress and final sections")
            return
        }
        #expect(progressRange.lowerBound < finalRange.lowerBound)
    }

    @Test("background progress excludes thinking and write contents")
    func backgroundProgressDoesNotLeakHiddenOrLargeArguments() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        let cwd = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let manager = BackgroundTaskManager(outputDir: cwd.appendingPathComponent("tasks"))
        let thinkingSecret = "THINKING_SECRET_MUST_NOT_APPEAR"
        let writeSecret = "WRITE_CONTENT_SECRET_MUST_NOT_APPEAR"
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxThinking(thinkingSecret),
                    fauxText("Writing the requested fixture."),
                    fauxToolCall(
                        name: "write",
                        arguments: .object([
                            "path": .string("fixture.txt"),
                            "content": .string(writeSecret),
                        ]),
                        id: "progress-write"
                    ),
                ],
                stopReason: .toolUse
            )),
            .message(subagentYieldMessage("safe final answer")),
        ])
        let tool = createAgentTool(
            cwd: cwd.path,
            subagents: [minimalSubagent(tools: [.write])],
            parentModel: faux.getModel(),
            parentTools: .standard,
            parentFileAccessPolicy: .workspaceOnly,
            backgroundManager: manager,
            sessionId: "redacted-progress-parent",
            bashEnvironment: testBashEnvironment
        )

        let started = try await tool.execute(
            "redacted-progress",
            .object([
                "description": .string("verify progress redaction"),
                "prompt": .string("write the fixture and finish"),
                "subagent_type": .string("mini"),
                "run_in_background": .bool(true),
            ]),
            nil,
            nil
        )
        guard let taskId = detailString(started, "task_id") else {
            Issue.record("expected task_id detail")
            return
        }
        let completed = await awaitUntil(3_000) {
            await manager.get(taskId)?.status == .completed
        }
        #expect(completed)
        guard let outputFile = await manager.get(taskId)?.outputFile else {
            Issue.record("expected output file")
            return
        }
        let contents = try String(contentsOfFile: outputFile, encoding: .utf8)
        #expect(contents.contains("tool write started"))
        #expect(contents.contains("path=fixture.txt"))
        #expect(contents.contains("assistant text (untrusted): Writing the requested fixture."))
        #expect(!contents.contains(thinkingSecret))
        #expect(!contents.contains(writeSecret))
    }

    @Test("subagent internal background tasks use child session and are killed on completion")
    func internalBackgroundTasksAreChildScopedAndClosed() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(
                        name: "bash",
                        arguments: .object([
                            "command": .string("exec sleep 3600"),
                            "description": .string("Sleep inside child"),
                            "run_in_background": .bool(true),
                        ]),
                        id: "bash-child-1"
                    ),
                ],
                stopReason: .toolUse
            )),
            .message(subagentYieldMessage("child finished after starting background work")),
            .message(subagentYieldMessage("child finished after starting background work")),
        ])

        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent(tools: [.bash])],
            parentModel: faux.getModel(),
            parentTools: .standard,
            backgroundManager: manager,
            sessionId: "parent-session",
            bashEnvironment: testBashEnvironment
        )

        let result = try await tool.execute(
            "call-1",
            .object([
                "description": .string("child bash task"),
                "prompt": .string("start the background command and finish"),
                "subagent_type": .string("mini"),
            ]),
            nil,
            nil
        )

        guard let childSessionId = detailString(result, "child_session_id") else {
            Issue.record("expected child_session_id detail")
            return
        }

        let parentTasks = await manager.list(sessionId: "parent-session")
        #expect(parentTasks.isEmpty)

        let childTasks = await manager.list(sessionId: childSessionId)
        #expect(childTasks.count == 1)
        #expect(childTasks.first?.sessionId == childSessionId)
        #expect(childTasks.first?.status == .killed)
        #expect(await manager.hasNotifications(sessionId: childSessionId) == false)
    }

    @Test("foreground cancellation aborts the child subagent")
    func foregroundCancellationAbortsChild() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokensPerSecond: 1,
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage(String(repeating: "x", count: 200)))])
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )
        let cancellation = CancellationHandle()

        let task = Task {
            try await tool.execute(
                "call-1",
                .object([
                    "description": .string("cancel child"),
                    "prompt": .string("produce a slow answer"),
                    "subagent_type": .string("mini"),
                ]),
                cancellation,
                nil
            )
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        cancellation.cancel(reason: "test")

        await #expect(throws: Error.self) {
            _ = try await task.value
        }
    }

    @Test("foreground cancellation closes the child provider session")
    func foregroundCancellationClosesChildProviderSession() async throws {
        let api = "subagent-cancel-\(UUID().uuidString)"
        let sourceId = "subagent-cancel-source-\(UUID().uuidString)"
        let provider = CancellationLifecycleProvider(api: api)
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        defer { Task { await APIRegistry.shared.unregisterSource(sourceId) } }

        let parentSessionId = "parent-\(UUID().uuidString)"
        let model = Model(
            id: "cancel-model",
            api: api,
            provider: "test-provider"
        )
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [minimalSubagent()],
            parentModel: model,
            parentTools: .readOnly,
            sessionId: parentSessionId,
            bashEnvironment: testBashEnvironment
        )
        let cancellation = CancellationHandle()

        let task = Task {
            try await tool.execute(
                "call-1",
                .object([
                    "description": .string("cancel child"),
                    "prompt": .string("wait until cancelled"),
                    "subagent_type": .string("mini"),
                ]),
                cancellation,
                nil
            )
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        cancellation.cancel(reason: "test")

        await #expect(throws: Error.self) {
            _ = try await task.value
        }

        let prefix = "\(parentSessionId):subagent:mini:"
        let closed = await awaitUntil(2_000) {
            provider.closedSessions.contains { $0.hasPrefix(prefix) }
        }
        #expect(closed)
    }
}

private func minimalSubagent(
    tools: CodingTools? = nil,
    model: SubagentModel = .inherit
) -> SubagentDefinition {
    SubagentDefinition(
        name: "mini",
        description: "Use for test subagent work.",
        prompt: "Return the requested test answer. Do not edit files.",
        tools: tools,
        model: model
    )
}

private func subagentYieldMessage(
    _ result: String,
    status: String = "complete",
    id: String = UUID().uuidString
) -> AssistantMessage {
    fauxAssistantMessage(
        blocks: [fauxToolCall(
            name: "subagent_yield",
            arguments: .object([
                "status": .string(status),
                "result": .string(result),
            ]),
            id: id
        )],
        stopReason: .toolUse
    )
}

private func resultText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined()
}

private func detailString(_ result: AgentToolResult, _ key: String) -> String? {
    guard case .object(let details) = result.details ?? .null,
          case .string(let value) = details[key] ?? .null else {
        return nil
    }
    return value
}

private func detailObject(_ result: AgentToolResult, _ key: String) -> [String: JSONValue]? {
    guard case .object(let details) = result.details ?? .null,
          case .object(let value) = details[key] ?? .null else {
        return nil
    }
    return value
}

private actor SubagentContextCapture {
    private var messageCount: Int = -1
    private var toolNames: [String] = []

    func record(messageCount: Int, toolNames: [String]) {
        self.messageCount = messageCount
        self.toolNames = toolNames
    }

    func snapshot() -> (messageCount: Int, toolNames: [String]) {
        (messageCount, toolNames)
    }
}

private final class ToolUpdateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [AgentToolResult] = []

    func record(_ update: AgentToolResult) {
        lock.withLock { updates.append(update) }
    }

    func uiDisplays() -> [String] {
        lock.withLock { updates.flatMap { $0.uiDisplay ?? [] } }
    }
}

private final class CancellationLifecycleProvider: APIProvider, APIProviderSessionLifecycle, @unchecked Sendable {
    let api: String
    private let lock = NSLock()
    private var sessions: [String] = []

    init(api: String) {
        self.api = api
    }

    var closedSessions: [String] {
        lock.withLock { sessions }
    }

    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let stream = AssistantMessageStream()
        Task.detached { [api] in
            while options?.cancellation?.isCancelled != true {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let aborted = AssistantMessage(
                content: [],
                api: api,
                provider: model.provider,
                model: model.id,
                stopReason: .aborted,
                errorMessage: "Request was aborted"
            )
            stream.push(.error(reason: .aborted, error: aborted))
            stream.end(aborted)
        }
        return stream
    }

    func closeSession(sessionId: String) async {
        lock.withLock { sessions.append(sessionId) }
    }
}

private actor SubagentRuntimeCapture {
    private var observedKinds: [SubagentLifecycleKind] = []
    private var observedSummary: AgentRunSummary?

    func append(kind: SubagentLifecycleKind) {
        observedKinds.append(kind)
    }

    func set(summary: AgentRunSummary) {
        observedSummary = summary
    }

    func kinds() -> [SubagentLifecycleKind] {
        observedKinds
    }

    func summary() -> AgentRunSummary? {
        observedSummary
    }
}
