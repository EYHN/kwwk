import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("Process-local host message context")
struct HostMessageContextTests {
    @Test("host identity is never encoded, decoded or reflected")
    func opaqueIdentityStaysInMemory() throws {
        var message = UserMessage(text: "visible message")
        message.hostContextID = "private-host-nonce"
        let encoded = try JSONEncoder().encode(message)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private-host-nonce"))
        #expect(!String(reflecting: message).contains("private-host-nonce"))
        #expect(!String(reflecting: Message.user(message)).contains("private-host-nonce"))
        let restored = try JSONDecoder().decode(UserMessage.self, from: encoded)
        #expect(restored.hostContextID == nil)
        #expect(restored.content == message.content)
        #expect(restored != message, "distinct in-memory context must remain distinguishable")
        let supplied = Data(#"{"role":"user","content":[{"type":"text","text":"visible"}],"timestamp":1,"hostContextID":"untrusted"}"#.utf8)
        #expect(try JSONDecoder().decode(UserMessage.self, from: supplied).hostContextID == nil)
    }

    @Test("consumption hook is awaited before the provider, and blocked input never consumes")
    func awaitedConsumption() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let hookEntered = HostContextLatch()
        let releaseHook = HostContextLatch()
        let state = HostContextState()
        faux.setResponses([.factory { _, options, _, _ in
            state.recordCall(options?.sessionId)
            return fauxAssistantMessage("done")
        }])
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            sessionId: "root",
            userMessageConsumed: { session, message in
                hookEntered.open()
                await releaseHook.wait()
                state.consume(session, message)
            },
            autoCompact: nil
        ))
        var message = UserMessage(text: "accepted")
        message.hostContextID = "A"
        let run = Task { try await agent.prompt(message) }
        await hookEntered.wait()
        #expect(state.calls.isEmpty)
        releaseHook.open()
        try await run.value
        #expect(state.calls == ["A"])

        agent.userPromptSubmit = { _, _ in UserPromptSubmitResult(block: true) }
        let consumedBefore = state.consumed
        try await agent.prompt(UserMessage(text: "blocked"))
        #expect(state.consumed == consumedBefore)
    }

    @Test("queued root steering changes the cause only after the current call finishes")
    func queuedRootContext() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let entered = HostContextLatch()
        let release = HostContextLatch()
        let state = HostContextState()
        faux.setResponses([
            .factory { _, options, _, _ in
                state.recordCall(options?.sessionId)
                entered.open()
                await release.wait()
                #expect(state.current(options?.sessionId) == "A")
                return fauxAssistantMessage("first")
            },
            .factory { _, options, _, _ in
                state.recordCall(options?.sessionId)
                return fauxAssistantMessage("second")
            },
        ])
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            sessionId: "root",
            userMessageFactory: hostContextFactory,
            userMessageConsumed: state.consume,
            autoCompact: nil
        ))
        let run = Task {
            try await HostMessageContext.$id.withValue("A") { try await agent.prompt("first") }
        }
        await entered.wait()
        HostMessageContext.$id.withValue("B") { agent.steer("second") }
        #expect(state.current("root") == "A")
        release.open()
        try await run.value
        if agent.hasQueuedMessages() { try await agent.continue() }
        #expect(state.calls == ["A", "B"])
    }

    @Test("running child consumes the context attached by agent_send, then nil clears it")
    func runningChildContext() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let entered = HostContextLatch()
        let release = HostContextLatch()
        let state = HostContextState()
        faux.setResponses([
            .factory { _, options, _, _ in
                state.recordCall(options?.sessionId)
                entered.open()
                await release.wait()
                #expect(state.current(options?.sessionId) == "A")
                return hostYield("first")
            },
            .factory { _, options, _, _ in
                state.recordCall(options?.sessionId)
                return hostYield("second")
            },
            .factory { _, options, _, _ in
                state.recordCall(options?.sessionId)
                return hostYield("unattributed")
            },
        ])
        let toolset = createSubagentToolset(
            cwd: FileManager.default.currentDirectoryPath,
            model: faux.getModel(), childTools: .readOnly,
            subagents: [SubagentDefinition(name: "mini", description: "test", prompt: "yield", tools: .readOnly)],
            sessionId: "parent", bashEnvironment: testBashEnvironment
        )
        let parent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: toolset.tools),
            sessionId: "parent", userMessageFactory: hostContextFactory,
            userMessageConsumed: state.consume,
            wrapToolExecution: { session, tool in
                var wrapped = tool
                wrapped.execute = { id, args, cancellation, update in
                    state.recordTool(session)
                    return try await HostMessageContext.$id.withValue(state.current(session)) {
                        try await tool.execute(id, args, cancellation, update)
                    }
                }
                return wrapped
            },
            autoCompact: nil
        ))
        toolset.attach(to: parent)
        // Direct tool admission establishes the host's explicit scope, just
        // as the real host wrapper does before SDK detached work begins.
        let launchTool = try #require(toolset.tools.first { $0.name == "agent" })
        let sendTool = try #require(toolset.tools.first { $0.name == "agent_send" })
        let run = Task {
            try await HostMessageContext.$id.withValue("A") {
                try await launchTool.execute("launch", .object([
                    "subagent_type": .string("mini"), "description": .string("test"),
                    "prompt": .string("work"),
                ]), nil, nil)
            }
        }
        await entered.wait()
        _ = try await HostMessageContext.$id.withValue("B") {
            try await sendTool.execute("send", .object([
                "agent_id": .string("mini-1"), "message": .string("continue"),
            ]), nil, nil)
        }
        #expect(state.calls == ["A"])
        release.open()
        _ = try await run.value
        _ = try await sendTool.execute("unknown", .object([
            "agent_id": .string("mini-1"), "message": .string("unattributed continuation"),
        ]), nil, nil)
        #expect(state.calls == ["A", "B", "unknown"])
        #expect(state.toolContexts.contains("B"), "child tool wrapper must see consumed B despite Task.detached")
        #expect(state.toolContexts.contains("unknown"))
        #expect(state.toolSessions.allSatisfy { $0 != "parent" })
    }

    @Test("background completion carries its creation context, not a later scope")
    func taskCompletionContext() async throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = BackgroundTaskManager(outputDir: directory)
        let release = HostContextLatch()
        let consumer = BackgroundTaskDeliveryConsumer(sessionId: "root")
        let detach = await manager.registerDeliveryConsumer(consumer)
        defer { Task { await detach() } }
        let task = await HostMessageContext.$id.withValue("private-background-cause") {
            await manager.adopt(spec: BackgroundTaskSpec(kind: "test", label: "finite task"), sessionId: "root") { _ in
                await release.wait()
                return BackgroundTaskOutcome(success: true, summary: "done")
            }
        }
        HostMessageContext.$id.withValue("B") { release.open() }
        #expect(await awaitUntil(5_000) { await manager.get(task.taskId)?.status == .completed })
        let messages = consumer.drainMessages()
        let message = try #require(messages.compactMap { message -> UserMessage? in
            if case .user(let user) = message { return user }; return nil
        }.first)
        #expect(message.hostContextID == "private-background-cause")
        #expect(message.source == .runtime)
        let notices = await manager.drainNotifications(sessionId: "root")
        #expect(notices.first?.hostContextID == "private-background-cause")
        #expect(!String(reflecting: notices).contains("private-background-cause"))
        #expect(!notices.map { $0.messageText() }.joined().contains("private-background-cause"))
    }
    @Test("spawn captures explicit host scope and unscoped tasks remain unknown")
    func spawnedTaskContext() async throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = BackgroundTaskManager(outputDir: directory)
        let scoped = await HostMessageContext.$id.withValue("private-spawn-cause") {
            await manager.spawn(runner: HostContextRunner(), sessionId: "root")
        }
        let unscoped = await manager.spawn(runner: HostContextRunner(), sessionId: "root")
        #expect(await awaitUntil(5_000) {
            let first = await manager.get(scoped.taskId)
            let second = await manager.get(unscoped.taskId)
            return first?.status == .completed && second?.status == .completed
        })
        let notices = await manager.drainNotifications(sessionId: "root")
        #expect(notices.first { $0.taskId == scoped.taskId }?.hostContextID == "private-spawn-cause")
        #expect(notices.first { $0.taskId == unscoped.taskId }?.hostContextID == nil)
        #expect(!String(reflecting: notices).contains("private-spawn-cause"))
    }

}

private func hostContextFactory(_ text: String) -> UserMessage {
    var message = UserMessage(text: text)
    message.hostContextID = HostMessageContext.id
    return message
}

private func hostYield(_ text: String) -> AssistantMessage {
    fauxAssistantMessage(blocks: [fauxToolCall(name: "subagent_yield", arguments: .object([
        "status": .string("complete"), "result": .string(text),
    ]), id: UUID().uuidString)], stopReason: .toolUse)
}

private final class HostContextState: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [String: String] = [:]
    private var callValues: [String] = []
    private var consumeValues: [String] = []
    private var tools: [(String, String)] = []
    func consume(_ session: String?, _ message: UserMessage) {
        lock.withLock {
            contexts[session ?? "nil"] = message.hostContextID ?? "unknown"
            consumeValues.append(message.hostContextID ?? "unknown")
        }
    }
    func current(_ session: String?) -> String? {
        lock.withLock { contexts[session ?? "nil"] }
    }
    func recordCall(_ session: String?) {
        lock.withLock { callValues.append(contexts[session ?? "nil"] ?? "unknown") }
    }
    func recordTool(_ session: String?) {
        lock.withLock { tools.append((session ?? "nil", contexts[session ?? "nil"] ?? "unknown")) }
    }
    var calls: [String] { lock.withLock { callValues } }
    var consumed: [String] { lock.withLock { consumeValues } }
    var toolContexts: [String] { lock.withLock { tools.map(\.1) } }
    var toolSessions: [String] { lock.withLock { tools.map(\.0) } }
}

private final class HostContextLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        let pending = lock.withLock { opened = true; defer { waiters.removeAll() }; return waiters }
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
}

private struct HostContextRunner: BackgroundTaskRunner {
    var spec: BackgroundTaskSpec { BackgroundTaskSpec(kind: "test", label: "finite work") }
    func run(taskId: String, outputFile: URL, cancellation: CancellationHandle,
             onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void) {
        onDone(BackgroundTaskOutcome(success: true, summary: "done"))
    }
}
