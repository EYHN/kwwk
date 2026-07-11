import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Subagent production hardening")
struct SubagentHardeningTests {
    @Test("abandoning an unlaunched reservation releases queued or immediate capacity")
    func abandoningPrelaunchReservationReleasesCapacity() throws {
        let immediateLimiter = SubagentLimiter(limits: SubagentLimits(
            maxConcurrent: 1,
            maxTotal: 2
        ))
        let immediate = try immediateLimiter.enqueue(tools: .readOnly)
        immediate.abandon()
        let replacement = try immediateLimiter.reserve(tools: .readOnly)
        replacement.release()

        let queuedLimiter = SubagentLimiter(limits: SubagentLimits(
            maxConcurrent: 1,
            maxTotal: 3
        ))
        let active = try queuedLimiter.reserve(tools: .readOnly)
        let queued = try queuedLimiter.enqueue(tools: .readOnly)
        queued.abandon()
        active.release()
        let afterQueuedCancellation = try queuedLimiter.reserve(tools: .readOnly)
        afterQueuedCancellation.release()
    }

    @Test("direct agent-tool execution rejects malformed optional arguments")
    func malformedOptionalArguments() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let tool = makeTool(model: faux.getModel())
        let malformed: [(String, JSONValue)] = [
            ("subagent_type", .bool(true)),
            ("model", .int(42)),
            ("run_in_background", .string("yes")),
            ("subagent_type", .null),
            ("unknown_key", .bool(true)),
        ]

        for (key, value) in malformed {
            await #expect(throws: Error.self) {
                _ = try await tool.execute(
                    "bad-\(key)",
                    .object([
                        "description": .string("validate input"),
                        "prompt": .string("must not launch"),
                        key: value,
                    ]),
                    nil,
                    nil
                )
            }
        }
        #expect(faux.state.callCount == 0)
    }

    @Test("invalid and ambiguous subagent registries fail closed")
    func invalidRegistries() {
        let valid = hardeningDefinition(name: "explore")
        #expect(throws: Error.self) {
            try validateSubagentDefinitions([hardeningDefinition(name: " bad")])
        }
        #expect(throws: Error.self) {
            try validateSubagentDefinitions([valid, hardeningDefinition(name: "explore")])
        }
        #expect(throws: Error.self) {
            try validateSubagentDefinitions([
                hardeningDefinition(name: "Explore"),
                hardeningDefinition(name: "explore"),
            ])
        }
    }

    @Test("invalid background model override fails before task registration")
    func invalidBackgroundModelFailsFast() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [hardeningDefinition(name: "mini")],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "model-fail-fast",
            bashEnvironment: testBashEnvironment
        )
        await #expect(throws: Error.self) {
            _ = try await tool.execute(
                "invalid-background-model",
                .object([
                    "description": .string("invalid model"),
                    "prompt": .string("must not start"),
                    "subagent_type": .string("mini"),
                    "model": .string("not-allowed"),
                    "run_in_background": .bool(true),
                ]),
                nil,
                nil
            )
        }
        #expect(await manager.list(sessionId: "model-fail-fast").isEmpty)
        #expect(faux.state.callCount == 0)
    }

    @Test("parent maxTurns is a child ceiling with structured failure kind")
    func parentMaxTurnsCeiling() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let cwd = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let file = cwd.appendingPathComponent("value.txt")
        try "value".write(to: file, atomically: true, encoding: .utf8)
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "read",
                    arguments: .object(["path": .string(file.path)]),
                    id: "read-once"
                )],
                stopReason: .toolUse
            )),
        ])
        let tool = createAgentTool(
            cwd: cwd.path,
            subagents: [hardeningDefinition(name: "mini", tools: .readOnly)],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            parentMaxTurns: 1,
            limits: SubagentLimits(maxTurns: 8, timeoutSeconds: 10),
            bashEnvironment: testBashEnvironment
        )

        do {
            _ = try await executeMini(tool, callId: "max-turns")
            Issue.record("expected max-turn failure")
        } catch let error as StructuredToolExecutionError {
            guard case .object(let details) = error.details ?? .null else {
                Issue.record("expected structured details")
                return
            }
            #expect(details["failure_kind"] == .string("max_turns"))
        }
    }

    @Test("subagent reserves its final capped turn for text synthesis")
    func finalCappedTurnSynthesizesText() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let cwd = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let file = cwd.appendingPathComponent("evidence.txt")
        try "evidence".write(to: file, atomically: true, encoding: .utf8)
        let requests = FinalTurnRequestCapture()
        faux.setResponses([
            .factory { context, options, _, _ in
                await requests.append(context: context, options: options)
                return fauxAssistantMessage(
                    blocks: [fauxToolCall(
                        name: "read",
                        arguments: .object(["path": .string(file.path)]),
                        id: "collect-evidence"
                    )],
                    stopReason: .toolUse
                )
            },
            .factory { context, options, _, _ in
                await requests.append(context: context, options: options)
                return hardeningYieldMessage("synthesized from gathered evidence")
            },
        ])
        let tool = createAgentTool(
            cwd: cwd.path,
            subagents: [hardeningDefinition(name: "mini", tools: .readOnly)],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            parentThinkingBudgets: ThinkingBudgets(high: 4_096),
            limits: SubagentLimits(maxTurns: 2, timeoutSeconds: 10),
            bashEnvironment: testBashEnvironment
        )

        let result = try await executeMini(tool, callId: "final-synthesis")
        #expect(hardeningResultText(result).contains("synthesized from gathered evidence"))
        let snapshots = await requests.values()
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.toolNames.contains("read") == true)
        #expect(snapshots.first?.thinkingBudgets != nil)
        #expect(snapshots.last?.toolNames == ["subagent_yield"])
        #expect(snapshots.last?.toolChoice == ToolChoice.tool(name: "subagent_yield"))
        #expect(snapshots.last?.reasoning == nil)
        #expect(snapshots.last?.thinkingBudgets == nil)
        #expect(snapshots.last?.systemPrompt.contains("final permitted turn") == true)
    }

    @Test("one-turn subagent uses its only turn for synthesis")
    func oneTurnSubagentSynthesizes() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let requests = FinalTurnRequestCapture()
        faux.setResponses([
            .factory { context, options, _, _ in
                await requests.append(context: context, options: options)
                return hardeningYieldMessage("one-turn answer")
            },
        ])
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [hardeningDefinition(name: "mini", tools: .readOnly)],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            limits: SubagentLimits(maxTurns: 1, timeoutSeconds: 10),
            bashEnvironment: testBashEnvironment
        )

        let result = try await executeMini(tool, callId: "one-turn-synthesis")
        #expect(hardeningResultText(result).contains("one-turn answer"))
        let snapshot = await requests.values().first
        #expect(snapshot?.toolNames == ["subagent_yield"])
        #expect(snapshot?.toolChoice == ToolChoice.tool(name: "subagent_yield"))
    }

    @Test("tool calls hallucinated on the reserved final turn are never executed")
    func finalTurnHallucinatedToolCallFailsClosed() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let cwd = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let target = cwd.appendingPathComponent("must-not-exist.txt")
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxText("partial evidence must survive the terminal failure"),
                    fauxToolCall(
                        name: "write",
                        arguments: .object([
                            "path": .string(target.path),
                            "content": .string("forbidden final-turn side effect"),
                        ]),
                        id: "forbidden-final-write"
                    ),
                ],
                stopReason: .toolUse
            )),
        ])
        let tool = createAgentTool(
            cwd: cwd.path,
            subagents: [hardeningDefinition(name: "mini", tools: [.write])],
            parentModel: faux.getModel(),
            parentTools: .standard,
            limits: SubagentLimits(maxTurns: 1, timeoutSeconds: 10),
            bashEnvironment: testBashEnvironment
        )

        do {
            _ = try await executeMini(tool, callId: "final-tool-fail-closed")
            Issue.record("expected max-turn failure")
        } catch let error as StructuredToolExecutionError {
            guard case .object(let details) = error.details ?? .null else {
                Issue.record("expected structured details")
                return
            }
            #expect(details["failure_kind"] == .string("max_turns"))
            #expect(details["turns"] == .int(1))
            #expect(details["usage"] != nil)
            #expect(details["cost"] != nil)
            #expect(details["duration_ms"] != nil)
            #expect(details["partial_output"] == .string(
                "partial evidence must survive the terminal failure"
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("parent security hooks are inherited by child tools")
    func parentHookInheritance() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let cwd = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let file = cwd.appendingPathComponent("secret.txt")
        try "secret".write(to: file, atomically: true, encoding: .utf8)
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "read",
                    arguments: .object(["path": .string(file.path)]),
                    id: "child-read"
                )],
                stopReason: .toolUse
            )),
            .message(hardeningYieldMessage("read was blocked")),
        ])
        let calls = HookCallCounter()
        let parent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                tools: [createReadTool(cwd: cwd.path)]
            ),
            beforeToolCall: { context, _ in
                guard context.toolCall.name == "read" else { return nil }
                await calls.increment()
                return BeforeToolCallResult(block: true, reason: "parent policy denied read")
            }
        ))
        let tool = createAgentTool(
            cwd: cwd.path,
            subagents: [hardeningDefinition(name: "mini", tools: .readOnly)],
            parentAgent: parent,
            parentTools: .readOnly,
            bashEnvironment: testBashEnvironment
        )

        let result = try await executeMini(tool, callId: "hook")
        #expect(hardeningResultText(result).contains("read was blocked"))
        #expect(await calls.value() == 1)
    }

    @Test("test-runner Bash policy is revalidated after parent hook rewrites")
    func testRunnerPolicyAfterHookRewrite() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let cwd = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let sentinel = cwd.appendingPathComponent("sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "bash",
                    arguments: .object(["command": .string("swift test")]),
                    id: "rewritten-bash"
                )],
                stopReason: .toolUse
            )),
            .message(hardeningYieldMessage("destructive rewrite was rejected")),
        ])

        let parent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                tools: [createBashTool(cwd: cwd.path, options: BashToolOptions(
                    environment: testBashEnvironment
                ))]
            ),
            cwd: cwd.path,
            beforeToolCall: { context, _ in
                guard context.toolCall.name == "bash" else { return nil }
                return BeforeToolCallResult(modifiedArgs: .object([
                    "command": .string("rm -rf .build/debug/*.build; swift test"),
                ]))
            }
        ))
        let tool = createAgentTool(
            cwd: cwd.path,
            subagents: [SubagentDefinition(
                name: "test-runner",
                description: "Run tests without modifying source files.",
                prompt: "Run focused tests and report the result.",
                tools: [.bash],
                bashCommandPolicy: .buildAndTestOnly
            )],
            parentAgent: parent,
            parentTools: [.bash],
            bashEnvironment: testBashEnvironment
        )

        let result = try await tool.execute(
            "test-runner-policy",
            .object([
                "description": .string("verify hook boundary"),
                "prompt": .string("run the focused test without modifying files"),
                "subagent_type": .string("test-runner"),
            ]),
            nil,
            nil
        )

        #expect(hardeningResultText(result).contains("destructive rewrite was rejected"))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve-me")
    }

    @Test("child inherits trusted project context and skill metadata, not skill bodies")
    func projectContextInheritance() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let capture = PromptCapture()
        faux.setResponses([
            .factory { context, _, _, _ in
                await capture.set(context.systemPrompt ?? "")
                return hardeningYieldMessage("context captured")
            },
        ])
        let skill = Skill(
            name: "safe-review",
            description: "Review the workspace safely.",
            path: "/tmp/safe-review/SKILL.md",
            body: "SECRET SKILL BODY"
        )
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [hardeningDefinition(name: "mini")],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            projectContextFiles: [("AGENTS.md", "PROJECT POLICY SENTINEL")],
            availableSkills: [skill],
            bashEnvironment: testBashEnvironment
        )

        _ = try await executeMini(tool, callId: "context")
        let prompt = await capture.value()
        #expect(prompt.contains("PROJECT POLICY SENTINEL"))
        #expect(prompt.contains("safe-review"))
        #expect(prompt.contains("Review the workspace safely."))
        #expect(!prompt.contains("SECRET SKILL BODY"))
        #expect(prompt.contains("Instruction priority is:"))
        #expect(prompt.contains("call `subagent_yield` exactly once"))
    }

    @Test("parent workspace roots cap a parentAgent child's requested cwd")
    func parentToolCwdCapsChildWorkspace() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let parentRoot = makeTempDir()
        let nestedRoot = parentRoot.appendingPathComponent("nested", isDirectory: true)
        let foreignRoot = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: parentRoot)
            try? FileManager.default.removeItem(at: foreignRoot)
        }
        try FileManager.default.createDirectory(
            at: nestedRoot,
            withIntermediateDirectories: true
        )
        let nestedFile = nestedRoot.appendingPathComponent("inside.txt")
        let foreignFile = foreignRoot.appendingPathComponent("outside.txt")
        try Data("inside".utf8).write(to: nestedFile)
        try Data("outside".utf8).write(to: foreignFile)
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "read",
                    arguments: ["path": .string(foreignFile.path)],
                    id: "foreign-read"
                )],
                stopReason: .toolUse
            )),
            .message(hardeningYieldMessage("foreign child finished")),
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "read",
                    arguments: ["path": .string(nestedFile.path)],
                    id: "nested-read"
                )],
                stopReason: .toolUse
            )),
            .message(hardeningYieldMessage("nested child finished")),
        ])

        let reads = HookCallCounter()
        let parent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                tools: [createReadTool(
                    cwd: parentRoot.path,
                    fileAccessPolicy: .workspaceOnly
                )]
            ),
            cwd: parentRoot.path,
            beforeToolCall: { context, _ in
                if context.toolCall.name == "read" { await reads.increment() }
                return nil
            }
        ))
        let foreignChild = createAgentTool(
            cwd: foreignRoot.path,
            subagents: [hardeningDefinition(name: "mini", tools: .readOnly)],
            parentAgent: parent,
            parentTools: .readOnly,
            parentFileAccessPolicy: .workspaceOnly,
            bashEnvironment: testBashEnvironment
        )
        let nestedChild = createAgentTool(
            cwd: nestedRoot.path,
            subagents: [hardeningDefinition(name: "mini", tools: .readOnly)],
            parentAgent: parent,
            parentTools: .readOnly,
            parentFileAccessPolicy: .workspaceOnly,
            bashEnvironment: testBashEnvironment
        )

        _ = try await executeMini(foreignChild, callId: "foreign-child")
        #expect(await reads.value() == 0)
        _ = try await executeMini(nestedChild, callId: "nested-child")
        #expect(await reads.value() == 1)
    }

    @Test("one agent tool enforces total and per-turn launch budgets")
    func launchBudgets() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(hardeningYieldMessage("first child"))])
        let limits = SubagentLimits(
            maxConcurrent: 1,
            maxConcurrentMutating: 1,
            maxTotal: 1,
            maxCallsPerTurn: 3,
            maxTurns: 4,
            timeoutSeconds: 10
        )
        let tool = makeTool(model: faux.getModel(), limits: limits)
        #expect(tool.turnLimitKey == "subagent")
        #expect(tool.maxCallsPerTurn == 3)

        _ = try await executeMini(tool, callId: "first")
        do {
            _ = try await executeMini(tool, callId: "second")
            Issue.record("expected total launch budget failure")
        } catch let error as StructuredToolExecutionError {
            guard case .object(let details) = error.details ?? .null else {
                Issue.record("expected structured details")
                return
            }
            #expect(details["failure_kind"] == .string("total_limit"))
        }
    }

    @Test("active mutating children are fail-fast serialized")
    func mutatingConcurrencyLimit() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokensPerSecond: 1,
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(String(repeating: "x", count: 100))),
        ])
        let limits = SubagentLimits(
            maxConcurrent: 4,
            maxConcurrentMutating: 1,
            maxTotal: 8,
            maxCallsPerTurn: 4,
            maxTurns: 4,
            timeoutSeconds: 10
        )
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [hardeningDefinition(name: "mini", tools: [.bash])],
            parentModel: faux.getModel(),
            parentTools: .standard,
            limits: limits,
            bashEnvironment: testBashEnvironment
        )
        let cancellation = CancellationHandle()
        let first = Task {
            try await tool.execute(
                "mutating-first",
                .object([
                    "description": .string("first mutating child"),
                    "prompt": .string("return a slow answer"),
                    "subagent_type": .string("mini"),
                ]),
                cancellation,
                nil
            )
        }
        let started = await awaitUntil(2_000) { faux.state.callCount == 1 }
        #expect(started)

        do {
            _ = try await executeMini(tool, callId: "mutating-second")
            Issue.record("expected mutating concurrency failure")
        } catch let error as StructuredToolExecutionError {
            guard case .object(let details) = error.details ?? .null else {
                Issue.record("expected structured details")
                cancellation.cancel(reason: "test cleanup")
                _ = try? await first.value
                return
            }
            #expect(details["failure_kind"] == .string("mutating_concurrency_limit"))
        }
        cancellation.cancel(reason: "test cleanup")
        _ = try? await first.value
    }

    @Test("background children queue for capacity, auto-start, and cancel while queued")
    func backgroundCapacityQueue() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokensPerSecond: 20,
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        faux.setResponses([
            .message(hardeningYieldMessage(String(repeating: "x", count: 40))),
            .message(hardeningYieldMessage("second completed")),
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let limits = SubagentLimits(
            maxConcurrent: 1,
            maxConcurrentMutating: 1,
            maxTotal: 4,
            maxCallsPerTurn: 4,
            maxTurns: 4,
            timeoutSeconds: 10
        )
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [hardeningDefinition(name: "mini")],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            limits: limits,
            backgroundManager: manager,
            sessionId: "capacity-parent",
            bashEnvironment: testBashEnvironment
        )

        func launch(_ suffix: String) async throws -> String {
            let result = try await tool.execute(
                "capacity-\(suffix)",
                .object([
                    "description": .string("capacity \(suffix)"),
                    "prompt": .string("finish capacity \(suffix)"),
                    "subagent_type": .string("mini"),
                    "run_in_background": .bool(true),
                ]),
                nil,
                nil
            )
            guard let id = hardeningDetailString(result, "task_id") else {
                throw CodingToolError.invalidArgument("test expected task id")
            }
            return id
        }

        let firstId = try await launch("first")
        #expect(await awaitUntil(2_000) { faux.state.callCount == 1 })
        let secondId = try await launch("second")
        let cancelledId = try await launch("cancelled")

        let secondQueued = await manager.get(secondId)
        #expect(secondQueued?.status == .queued)
        #expect(secondQueued?.runningAt == nil)
        #expect(await manager.get(cancelledId)?.status == .queued)

        let job = createJobTool(manager: manager, sessionId: "capacity-parent")
        let listed = try await job.execute(
            "list-capacity",
            .object(["list": .bool(true)]),
            nil,
            nil
        )
        #expect(hardeningResultText(listed).contains("waiting_for_capacity"))
        _ = try await job.execute(
            "cancel-capacity",
            .object(["cancel": .array([.string(cancelledId)])]),
            nil,
            nil
        )
        #expect(await manager.get(cancelledId)?.status == .killed)

        #expect(await awaitUntil(8_000) {
            let first = await manager.get(firstId)
            let second = await manager.get(secondId)
            return first?.status == .completed && second?.status == .completed
        })
        let secondCompleted = await manager.get(secondId)
        #expect(secondCompleted?.runningAt != nil)
        #expect(faux.state.callCount == 2)
    }

    @Test("foreground child deadline returns a structured timeout")
    func foregroundDeadline() async throws {
        try await withRetries { _ in
            let faux = await registerFauxProvider(RegisterFauxProviderOptions(
                tokensPerSecond: 1,
                tokenSize: FauxTokenSize(min: 1, max: 1)
            ))
            defer { faux.unregister() }
            faux.setResponses([
                .message(fauxAssistantMessage(String(repeating: "x", count: 100))),
            ])
            let tool = makeTool(
                model: faux.getModel(),
                limits: SubagentLimits(maxTurns: 4, timeoutSeconds: 1)
            )
            let startedAt = Date()
            do {
                _ = try await executeMini(tool, callId: "deadline")
                Issue.record("expected deadline failure")
            } catch let error as StructuredToolExecutionError {
                guard case .object(let details) = error.details ?? .null else {
                    Issue.record("expected structured details")
                    return
                }
                #expect(details["failure_kind"] == .string("timeout"))
                #expect(details["capacity_retained_until_runner_exit"] == .bool(true))
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            try retryCheck(elapsed < 2, "deadline returned after \(elapsed)s, expected < 2s")
        }
    }

    @Test("background child deadline is classified by the child before manager watchdog")
    func backgroundDeadlineKeepsTimeoutClassification() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokensPerSecond: 1,
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(String(repeating: "x", count: 100))),
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tool = createAgentTool(
            cwd: FileManager.default.currentDirectoryPath,
            subagents: [hardeningDefinition(name: "mini")],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            limits: SubagentLimits(maxTurns: 4, timeoutSeconds: 1),
            backgroundManager: manager,
            sessionId: "background-deadline-parent",
            bashEnvironment: testBashEnvironment
        )
        let started = try await tool.execute(
            "background-deadline",
            .object([
                "description": .string("background deadline"),
                "prompt": .string("return too slowly"),
                "subagent_type": .string("mini"),
                "run_in_background": .bool(true),
            ]),
            nil,
            nil
        )
        let taskId = try #require(hardeningDetailString(started, "task_id"))

        #expect(await awaitUntil(2_500) {
            await manager.get(taskId)?.status.isTerminal == true
        })
        let terminal = try #require(await manager.get(taskId))
        guard case .object(let details) = terminal.outcome?.details ?? .null else {
            Issue.record("expected structured background outcome")
            return
        }
        #expect(details["failure_kind"] == .string("timeout"))
        #expect(details["capacity_retained_until_runner_exit"] == .bool(true))
        await manager.closeSession(sessionId: "background-deadline-parent")
    }

    @Test("foreground deadline returns even when provider ignores cancellation")
    func nonCooperativeForegroundDeadline() async throws {
        try await withRetries { _ in
            let provider = NonCooperativeSubagentProvider(delaySeconds: 2)
            let sourceId = "non-cooperative-\(UUID().uuidString)"
            await APIRegistry.shared.register(provider, sourceId: sourceId)
            defer { Task { await APIRegistry.shared.unregisterSource(sourceId) } }
            let model = Model(
                id: "non-cooperative-model",
                api: provider.api,
                provider: "non-cooperative"
            )
            let tool = makeTool(
                model: model,
                limits: SubagentLimits(maxTurns: 4, timeoutSeconds: 1)
            )
            let updates = HardeningUpdateCapture()
            let startedAt = Date()
            do {
                _ = try await tool.execute(
                    "non-cooperative-deadline",
                    .object([
                        "description": .string("non-cooperative child"),
                        "prompt": .string("return too late"),
                        "subagent_type": .string("mini"),
                    ]),
                    nil,
                    { updates.append($0) }
                )
                Issue.record("expected deadline failure")
            } catch let error as StructuredToolExecutionError {
                guard case .object(let details) = error.details ?? .null else {
                    Issue.record("expected structured details")
                    return
                }
                #expect(details["failure_kind"] == .string("timeout"))
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            try retryCheck(elapsed < 1.75, "deadline returned after \(elapsed)s, expected < 1.75s")
            try retryCheck(provider.didFinish == false, "provider finished before the deadline returned")
            let updatesAtTimeout = updates.count
            let eventuallyFinished = await awaitUntil(3_000) { provider.didFinish }
            #expect(eventuallyFinished)
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(updates.count == updatesAtTimeout)
        }
    }

    @Test("timed-out non-cooperative child retains physical runner capacity")
    func nonCooperativeTimeoutRetainsCapacity() async throws {
        let provider = NonCooperativeSubagentProvider(delaySeconds: 3)
        let sourceId = "non-cooperative-capacity-\(UUID().uuidString)"
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        defer { Task { await APIRegistry.shared.unregisterSource(sourceId) } }
        let model = Model(
            id: "non-cooperative-capacity-model",
            api: provider.api,
            provider: "non-cooperative-capacity"
        )
        let tool = makeTool(
            model: model,
            limits: SubagentLimits(
                maxConcurrent: 1,
                maxConcurrentMutating: 1,
                maxTotal: 2,
                maxCallsPerTurn: 2,
                maxTurns: 4,
                timeoutSeconds: 1
            )
        )

        _ = try? await executeMini(tool, callId: "zombie-first")
        #expect(provider.callCount == 1)
        #expect(provider.didFinish == false)

        do {
            _ = try await executeMini(tool, callId: "zombie-second")
            Issue.record("expected physical concurrency rejection")
        } catch let error as StructuredToolExecutionError {
            guard case .object(let details) = error.details ?? .null else {
                Issue.record("expected structured concurrency details")
                return
            }
            #expect(details["failure_kind"] == .string("concurrency_limit"))
        }
        #expect(provider.callCount == 1)
        #expect(provider.didFinish == false)

        #expect(await awaitUntil(3_000) { provider.didFinish })
        let third = Task { try? await executeMini(tool, callId: "after-zombie-exit") }
        #expect(await awaitUntil(750) { provider.callCount == 2 })
        _ = await third.value
    }

    @Test("an update callback can synchronously cancel its own subagent")
    func updateCallbackCancellationDoesNotDeadlock() async throws {
        try await withRetries { _ in
            let faux = await registerFauxProvider()
            defer { faux.unregister() }
            faux.setResponses([.message(fauxAssistantMessage("cancel during update"))])
            let tool = makeTool(model: faux.getModel())
            let cancellation = CancellationHandle()
            let callback = HardeningUpdateCanceller(cancellation: cancellation)
            let startedAt = Date()

            do {
                _ = try await tool.execute(
                    "cancel-from-update",
                    .object([
                        "description": .string("cancel from update"),
                        "prompt": .string("emit one update"),
                        "subagent_type": .string("mini"),
                    ]),
                    cancellation,
                    { callback.handle($0) }
                )
                Issue.record("expected cancellation failure")
            } catch let error as StructuredToolExecutionError {
                guard case .object(let details) = error.details ?? .null else {
                    Issue.record("expected structured details")
                    return
                }
                #expect(details["failure_kind"] == .string("aborted"))
            }
            #expect(callback.didCancel)
            let elapsed = Date().timeIntervalSince(startedAt)
            try retryCheck(elapsed < 2, "cancellation returned after \(elapsed)s, expected < 2s")
        }
    }

    @Test("background subagent completion emits unified terminal lifecycle")
    func backgroundTerminalLifecycle() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(hardeningYieldMessage("background complete"))])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let coding = await makeCodingAgent(CodingAgentConfig(
            model: faux.getModel(),
            cwd: FileManager.default.currentDirectoryPath,
            tools: .readOnly,
            backgroundManager: manager,
            subagents: [hardeningDefinition(name: "mini")],
            sessionId: "lifecycle-parent",
            bashEnvironment: testBashEnvironment
        ))
        let capture = BackgroundLifecycleCapture()
        let unsubscribe = coding.agent.subscribe { event, _ in
            if case .runtimeEvent(.subagent(let subagent)) = event,
               subagent.kind == .completed || subagent.kind == .failed {
                await capture.set(subagent)
            }
        }
        defer { unsubscribe() }
        guard let tool = coding.agent.state.tools.first(where: { $0.name == "agent" }) else {
            Issue.record("expected agent tool")
            return
        }

        let started = try await tool.execute(
            "background-lifecycle",
            .object([
                "description": .string("background lifecycle"),
                "prompt": .string("finish in background"),
                "subagent_type": .string("mini"),
                "run_in_background": .bool(true),
            ]),
            nil,
            nil
        )
        let taskId = hardeningDetailString(started, "task_id")
        let childSessionId = hardeningDetailString(started, "child_session_id")
        let delivered = await awaitUntil(3_000) { await capture.value() != nil }
        #expect(delivered)
        let terminal = await capture.value()
        #expect(terminal?.kind == .completed)
        #expect(terminal?.backgroundTaskId == taskId)
        #expect(terminal?.childSessionId == childSessionId)
        #expect(terminal?.usage != nil)
        #expect(terminal?.cost != nil)
        let aggregate = coding.agent.backgroundSubagentRuns()
        #expect(aggregate.count == 1)
        #expect(aggregate.first?.status == .completed)
        #expect(aggregate.first?.backgroundTaskId == taskId)
        await coding.detachBackground?()
        await manager.closeSession(sessionId: "lifecycle-parent")
    }

    @Test("background subagent cancellation emits one correlated failed lifecycle")
    func backgroundCancellationLifecycle() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            tokensPerSecond: 1,
            tokenSize: FauxTokenSize(min: 1, max: 1)
        ))
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(String(repeating: "x", count: 100))),
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let coding = await makeCodingAgent(CodingAgentConfig(
            model: faux.getModel(),
            cwd: FileManager.default.currentDirectoryPath,
            tools: .readOnly,
            backgroundManager: manager,
            subagents: [hardeningDefinition(name: "mini")],
            sessionId: "cancel-parent",
            bashEnvironment: testBashEnvironment
        ))
        let capture = BackgroundLifecycleLog()
        let unsubscribe = coding.agent.subscribe { event, _ in
            if case .runtimeEvent(.subagent(let subagent)) = event,
               subagent.kind == .completed || subagent.kind == .failed {
                await capture.append(subagent)
            }
        }
        defer { unsubscribe() }
        guard let tool = coding.agent.state.tools.first(where: { $0.name == "agent" }) else {
            Issue.record("expected agent tool")
            return
        }
        let started = try await tool.execute(
            "background-cancel",
            .object([
                "description": .string("cancel lifecycle"),
                "prompt": .string("return a slow answer"),
                "subagent_type": .string("mini"),
                "run_in_background": .bool(true),
            ]),
            nil,
            nil
        )
        guard let taskId = hardeningDetailString(started, "task_id"),
              let childSessionId = hardeningDetailString(started, "child_session_id") else {
            Issue.record("expected correlated ids")
            return
        }
        try await manager.kill(taskId)
        let delivered = await awaitUntil(3_000) { await capture.values().count == 1 }
        #expect(delivered)
        let events = await capture.values()
        #expect(events.count == 1)
        #expect(events.first?.kind == .failed)
        #expect(events.first?.backgroundTaskId == taskId)
        #expect(events.first?.childSessionId == childSessionId)
        await coding.detachBackground?()
        await manager.closeSession(sessionId: "cancel-parent")
    }
}

private func hardeningDefinition(
    name: String,
    tools: CodingTools? = nil
) -> SubagentDefinition {
    SubagentDefinition(
        name: name,
        description: "Hardening test subagent.",
        prompt: "Complete the test task.",
        tools: tools
    )
}

private func hardeningYieldMessage(
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

private func makeTool(
    model: Model,
    limits: SubagentLimits = .init()
) -> AgentTool {
    createAgentTool(
        cwd: FileManager.default.currentDirectoryPath,
        subagents: [hardeningDefinition(name: "mini")],
        parentModel: model,
        parentTools: .readOnly,
        limits: limits,
        bashEnvironment: testBashEnvironment
    )
}

private func executeMini(_ tool: AgentTool, callId: String) async throws -> AgentToolResult {
    try await tool.execute(
        callId,
        .object([
            "description": .string("hardening test"),
            "prompt": .string("complete the hardening test"),
            "subagent_type": .string("mini"),
        ]),
        nil,
        nil
    )
}

private func hardeningResultText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined()
}

private func hardeningDetailString(_ result: AgentToolResult, _ key: String) -> String? {
    guard case .object(let details) = result.details ?? .null,
          case .string(let value) = details[key] ?? .null else {
        return nil
    }
    return value
}

private actor HookCallCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private actor PromptCapture {
    private var prompt = ""
    func set(_ value: String) { prompt = value }
    func value() -> String { prompt }
}

private struct FinalTurnRequestSnapshot: Sendable {
    let toolNames: [String]
    let toolChoice: ToolChoice?
    let reasoning: ReasoningLevel?
    let thinkingBudgets: ThinkingBudgets?
    let systemPrompt: String
}

private actor FinalTurnRequestCapture {
    private var snapshots: [FinalTurnRequestSnapshot] = []

    func append(context: Context, options: StreamOptions?) {
        snapshots.append(FinalTurnRequestSnapshot(
            toolNames: context.tools?.map(\.name) ?? [],
            toolChoice: options?.toolChoice,
            reasoning: options?.reasoning,
            thinkingBudgets: options?.thinkingBudgets,
            systemPrompt: context.systemPrompt ?? ""
        ))
    }

    func values() -> [FinalTurnRequestSnapshot] { snapshots }
}

private actor BackgroundLifecycleCapture {
    private var event: SubagentLifecycleEvent?
    func set(_ value: SubagentLifecycleEvent) { event = value }
    func value() -> SubagentLifecycleEvent? { event }
}

private actor BackgroundLifecycleLog {
    private var events: [SubagentLifecycleEvent] = []
    func append(_ value: SubagentLifecycleEvent) { events.append(value) }
    func values() -> [SubagentLifecycleEvent] { events }
}

private final class HardeningUpdateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentToolResult] = []
    func append(_ value: AgentToolResult) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
}

private final class HardeningUpdateCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: CancellationHandle
    private var cancelled = false

    init(cancellation: CancellationHandle) {
        self.cancellation = cancellation
    }

    var didCancel: Bool { lock.withLock { cancelled } }

    func handle(_ result: AgentToolResult) {
        guard case .object(let details) = result.details ?? .null,
              details["activity_kind"] != nil else { return }
        let shouldCancel = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        if shouldCancel { cancellation.cancel(reason: "cancelled-from-update") }
    }
}

private final class NonCooperativeSubagentProvider: APIProvider, @unchecked Sendable {
    let api = "non-cooperative-\(UUID().uuidString)"
    private let delayNanoseconds: UInt64
    private let lock = NSLock()
    private var finished = false
    private var calls = 0

    init(delaySeconds: UInt64) {
        delayNanoseconds = delaySeconds * 1_000_000_000
    }

    var didFinish: Bool { lock.withLock { finished } }
    var callCount: Int { lock.withLock { calls } }

    func stream(
        model: Model,
        context _: Context,
        options _: StreamOptions?
    ) -> AssistantMessageStream {
        lock.withLock { calls += 1 }
        let stream = AssistantMessageStream()
        Task.detached { [delayNanoseconds, api, lock] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            let message = AssistantMessage(
                content: [.text(TextContent(text: "late result"))],
                api: api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
            stream.push(.start(partial: message))
            stream.push(.textStart(contentIndex: 0, partial: message))
            stream.push(.textDelta(contentIndex: 0, delta: "late result", partial: message))
            stream.push(.textEnd(contentIndex: 0, content: "late result", partial: message))
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            lock.withLock { self.finished = true }
        }
        return stream
    }
}
