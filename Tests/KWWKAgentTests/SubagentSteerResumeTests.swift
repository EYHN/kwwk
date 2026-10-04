import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Subagent steer and resume")
struct SubagentSteerResumeTests {
    @Test("limits are unbounded by default")
    func limitsDefaultToUnbounded() throws {
        let limits = SubagentLimits()
        #expect(limits.maxConcurrent == nil)
        #expect(limits.maxConcurrentMutating == nil)
        #expect(limits.maxTotal == nil)
        #expect(limits.maxTurns == nil)
        #expect(limits.timeoutSeconds == nil)

        // Far past the old 4 concurrent / 1 mutating / 64 total defaults.
        let limiter = SubagentLimiter(limits: limits)
        let permits = try (0..<80).map { _ in try limiter.reserve(tools: .standard) }
        #expect(permits.count == 80)
        for permit in permits { permit.release() }

        // An explicit ceiling still holds.
        let bounded = SubagentLimiter(limits: SubagentLimits(maxConcurrent: 2, maxConcurrentMutating: 1))
        let first = try bounded.reserve(tools: .standard)
        #expect(throws: SubagentLimitError.self) { _ = try bounded.reserve(tools: .standard) }
        let reader = try bounded.reserve(tools: .readOnly)
        first.release()
        reader.release()
    }

    @Test("agent ids are generated per type, and a chosen name must be unique and well formed")
    func agentIdsAreStableNames() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(steerYield("one")),
            .message(steerYield("two")),
            .message(steerYield("three")),
        ])
        let toolset = steerToolset(model: faux.getModel(), sessionId: "ids-parent")
        let agent = try tool(toolset, "agent")

        let first = try await agent.execute("a1", launchArgs(), nil, nil)
        let second = try await agent.execute("a2", launchArgs(), nil, nil)
        let named = try await agent.execute("a3", launchArgs(name: "login-fix"), nil, nil)
        #expect(steerDetail(first, "agent_id") == "mini-1")
        #expect(steerDetail(second, "agent_id") == "mini-2")
        #expect(steerDetail(named, "agent_id") == "login-fix")
        #expect(steerText(named).contains("Subagent login-fix (mini) completed."))
        #expect(steerText(named).contains("agent_id: login-fix"))

        await #expect(throws: CodingToolError.self) {
            _ = try await agent.execute("dup", launchArgs(name: "LOGIN-FIX"), nil, nil)
        }
        await #expect(throws: CodingToolError.self) {
            _ = try await agent.execute("bad", launchArgs(name: "has space"), nil, nil)
        }
    }

    @Test("agent_send resumes a stopped child from its own transcript")
    func agentSendResumesStoppedChild() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let resumedContext = ContextBox()
        faux.setResponses([
            .message(steerYield("first deliverable")),
            .factory { context, _, _, _ in
                resumedContext.store(context)
                return steerYield("second deliverable")
            },
        ])
        let toolset = steerToolset(model: faux.getModel(), sessionId: "resume-parent")

        let first = try await tool(toolset, "agent").execute("launch", launchArgs(), nil, nil)
        #expect(steerDetail(first, "agent_id") == "mini-1")

        let resumed = try await tool(toolset, "agent_send").execute(
            "follow-up",
            .object([
                "agent_id": .string("mini-1"),
                "message": .string("now do the second part"),
            ]),
            nil,
            nil
        )
        #expect(steerText(resumed).contains("second deliverable"))
        #expect(steerDetail(resumed, "agent_id") == "mini-1")
        #expect(steerDetail(resumed, "status") == "completed")

        // The resumed run saw the first run's prompt and result, then the
        // follow-up under its header.
        let texts = try #require(resumedContext.value).messages.flatMap(messageTexts)
        #expect(texts.contains { $0.contains("do the steer test") })
        #expect(texts.contains { $0.contains("first deliverable") })
        #expect(texts.contains { $0 == subagentFollowUpMessageText("now do the second part") })

        let history = steerText(try await tool(toolset, "agent_history").execute(
            "history",
            .object(["agent_id": .string("mini-1")]),
            nil,
            nil
        ))
        #expect(history.contains("# mini-1 · mini · completed"))
        #expect(history.contains("runs: foreground completed ("))
        #expect(history.contains("→ foreground completed ("))
        #expect(history.contains("run foreground · prompt"))
        #expect(history.contains("run foreground · agent_send\n\nnow do the second part"))
        #expect(history.contains("result · complete\n\nfirst deliverable"))
        #expect(history.contains("result · complete\n\nsecond deliverable"))
    }

    @Test("a resumed background run gets a new task id and task_list names the child")
    func backgroundResumeGetsNewTaskId() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(steerYield("background one")),
            .message(steerYield("background two")),
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let toolset = steerToolset(model: faux.getModel(), sessionId: "bg-parent", manager: manager)

        let started = try await tool(toolset, "agent").execute(
            "bg-launch", launchArgs(background: true), nil, nil
        )
        let firstTask = try #require(steerDetail(started, "task_id"))
        #expect(await manager.get(firstTask)?.spec.hardTimeoutSeconds == 0)
        #expect(await awaitUntil(5_000) { await manager.get(firstTask)?.status == .completed })

        let resumed = try await tool(toolset, "agent_send").execute(
            "bg-follow-up",
            .object([
                "agent_id": .string("mini-1"),
                "message": .string("again"),
                "run_in_background": .bool(true),
            ]),
            nil,
            nil
        )
        let secondTask = try #require(steerDetail(resumed, "task_id"))
        #expect(secondTask != firstTask)
        #expect(steerDetail(resumed, "agent_id") == "mini-1")
        #expect(await awaitUntil(5_000) { await manager.get(secondTask)?.status == .completed })

        let listed = steerText(try await createTaskListTool(manager: manager, sessionId: "bg-parent")
            .execute("list", .object([:]), nil, nil))
        #expect(listed.contains("\(firstTask) [agent mini-1 · mini] completed"))
        #expect(listed.contains("\(secondTask) [agent mini-1 · mini] completed"))
        #expect(!listed.contains("background one"))

        let history = steerText(try await tool(toolset, "agent_history").execute(
            "bg-history",
            .object(["task_id": .string(firstTask)]),
            nil,
            nil
        ))
        #expect(history.contains("runs: \(firstTask) completed ("))
        #expect(history.contains("→ \(secondTask) completed ("))
        #expect(history.contains("run \(secondTask) · agent_send"))
    }

    @Test("agent_send reaches a running child, and a follow-up that lands after its yield reopens the task")
    func agentSendSteersRunningChild() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let entered = Latch()
        let release = Latch()
        let reopenedContext = ContextBox()
        faux.setResponses([
            // The child is mid-step when the parent's message arrives, and
            // yields without having read it.
            .factory { _, _, _, _ in
                entered.open()
                await release.wait()
                return steerYield("answer before the follow-up")
            },
            .factory { context, _, _, _ in
                reopenedContext.store(context)
                return steerYield("answer including the follow-up")
            },
        ])
        let toolset = steerToolset(model: faux.getModel(), sessionId: "steer-parent")
        let agent = try tool(toolset, "agent")
        let launch = Task { try await agent.execute("steer-launch", launchArgs(), nil, nil) }
        await entered.wait()

        let delivered = try await tool(toolset, "agent_send").execute(
            "steer",
            .object([
                "agent_id": .string("mini-1"),
                "message": .string("also cover the edge case"),
            ]),
            nil,
            nil
        )
        #expect(steerDetail(delivered, "status") == "delivered")
        #expect(steerDetail(delivered, "child_status") == "running")
        release.open()

        let result = try await launch.value
        #expect(steerText(result).contains("answer including the follow-up"))
        #expect(!steerText(result).contains("answer before the follow-up"))
        let texts = try #require(reopenedContext.value).messages.flatMap(messageTexts)
        #expect(texts.contains(subagentSteerMessageText("also cover the edge case")))

        let history = steerText(try await tool(toolset, "agent_history").execute(
            "steer-history",
            .object(["agent_id": .string("mini-1")]),
            nil,
            nil
        ))
        #expect(history.contains("user · steer\n\nalso cover the edge case"))
        #expect(history.contains("result · complete\n\nanswer including the follow-up"))
    }

    @Test("agent_send names the known children when the id is unknown")
    func agentSendUnknownId() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(steerYield("done"))])
        let toolset = steerToolset(model: faux.getModel(), sessionId: "unknown-parent")
        _ = try await tool(toolset, "agent").execute("launch", launchArgs(), nil, nil)
        do {
            _ = try await tool(toolset, "agent_send").execute(
                "unknown",
                .object(["agent_id": .string("ghost"), "message": .string("hello")]),
                nil,
                nil
            )
            Issue.record("expected an unknown agent_id to fail")
        } catch {
            #expect(String(describing: error).contains("Known subagents: mini-1"))
        }
    }

    @Test("agent_history shows one line per tool call and returns a call's full arguments and paged result")
    func historyToolCallDetail() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let workspace = makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let lines = (1...300).map { "line \($0)" }.joined(separator: "\n")
        try lines.write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxText("Reading the notes first."),
                    fauxToolCall(
                        name: "read",
                        arguments: .object(["path": .string("notes.txt")]),
                        id: "read-notes"
                    ),
                ],
                stopReason: .toolUse
            )),
            .message(steerYield("The notes have 300 lines.")),
        ])
        let toolset = steerToolset(model: faux.getModel(), sessionId: "detail-parent", cwd: workspace.path)
        _ = try await tool(toolset, "agent").execute("launch", launchArgs(), nil, nil)
        let history = try tool(toolset, "agent_history")

        let transcript = steerText(try await history.execute(
            "transcript", .object(["agent_id": .string("mini-1")]), nil, nil
        ))
        #expect(transcript.contains("## [2] assistant\n\nReading the notes first.\n→ [2.1] read(notes.txt) ⇒ ok · "))
        #expect(transcript.contains("## [4] result · complete\n\nThe notes have 300 lines."))
        #expect(!transcript.contains("line 150"))
        #expect(!transcript.contains("subagent_yield("))

        let detail = steerText(try await history.execute(
            "detail",
            .object(["agent_id": .string("mini-1"), "tool_call": .string("2.1")]),
            nil,
            nil
        ))
        #expect(detail.contains("# mini-1 · [2.1] read · ok"))
        #expect(detail.contains("\"path\" : \"notes.txt\""))
        #expect(detail.contains("## result · lines 1–120 of "))
        #expect(detail.contains("\"tool_call\":\"2.1\",\"offset\":120"))
        #expect(detail.contains("line 100"))
        #expect(!detail.contains("line 150"))

        let nextPage = steerText(try await history.execute(
            "detail-next",
            .object(["agent_id": .string("mini-1"), "tool_call": .string("2.1"), "offset": .int(120)]),
            nil,
            nil
        ))
        #expect(nextPage.contains("## result · lines 121–240 of "))
        #expect(nextPage.contains("line 150"))

        await #expect(throws: CodingToolError.self) {
            _ = try await history.execute(
                "not-a-call",
                .object(["agent_id": .string("mini-1"), "tool_call": .string("1.1")]),
                nil,
                nil
            )
        }
    }
}

// MARK: - Helpers

private func steerToolset(
    model: Model,
    sessionId: String,
    manager: BackgroundTaskManager? = nil,
    cwd: String = FileManager.default.currentDirectoryPath
) -> SubagentToolset {
    createSubagentToolset(
        cwd: cwd,
        model: model,
        childTools: .readOnly,
        subagents: [SubagentDefinition(
            name: "mini",
            description: "Steer/resume test child.",
            prompt: "Complete the test and use the required yield tool.",
            tools: .readOnly
        )],
        backgroundManager: manager,
        sessionId: sessionId,
        bashEnvironment: testBashEnvironment
    )
}

private func tool(_ toolset: SubagentToolset, _ name: String) throws -> AgentTool {
    try #require(toolset.tools.first { $0.name == name })
}

private func launchArgs(name: String? = nil, background: Bool = false) -> JSONValue {
    var args: [String: JSONValue] = [
        "description": .string("steer test"),
        "prompt": .string("do the steer test"),
        "subagent_type": .string("mini"),
    ]
    if let name { args["name"] = .string(name) }
    if background { args["run_in_background"] = .bool(true) }
    return .object(args)
}

private func steerYield(_ result: String) -> AssistantMessage {
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

private func steerText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text.text
    }.joined(separator: "\n")
}

private func steerDetail(_ result: AgentToolResult, _ key: String) -> String? {
    guard case .object(let details) = result.details ?? .null,
          case .string(let value) = details[key] ?? .null else {
        return nil
    }
    return value
}

private func messageTexts(_ message: Message) -> [String] {
    switch message {
    case .system:
        return []
    case .user(let user):
        return user.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }
    case .assistant(let assistant):
        return assistant.content.compactMap { block in
            switch block {
            case .text(let text): return text.text
            case .toolCall(let call):
                if case .object(let args) = call.arguments,
                   case .string(let result) = args["result"] ?? .null { return result }
                return nil
            default: return nil
            }
        }
    case .toolResult(let result):
        return result.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }
    }
}

private final class ContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Context?

    func store(_ context: Context) { lock.withLock { stored = context } }
    var value: Context? { lock.withLock { stored } }
}

/// Opens once; every waiter, before or after, then proceeds.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
