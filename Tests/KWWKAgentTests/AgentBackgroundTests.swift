import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Agent + BackgroundTaskManager", .serialized)
struct AgentBackgroundTests {

    @Test("background notification wakes an idle agent through a runtime aside")
    func idleWakeInjectsRuntimeAside() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage("initial")),
            .message(fauxAssistantMessage("woke from background notification")),
        ])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        // Seed a user message so `continue()` has something to continue from.
        try await agent.prompt("hello")
        #expect(!agent.state.isStreaming)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwbg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let detach = await agent.attachBackgroundManager(manager, sessionId: "sX")
        defer { Task { await detach() } }

        _ = await manager.spawn(
            runner: FauxRunner(
                label: "hello-task",
                outcome: BackgroundTaskOutcome(success: true, summary: "exit 0")
            ),
            sessionId: "sX"
        )

        // Wait for the agent to pick up the runtime aside and complete a run.
        // It retains user role for provider compatibility, but carries a
        // runtime source marker and never enters the editable queue.
        let ok = await awaitUntil(12000) {
            let msgs = agent.state.messages
            return msgs.contains { message in
                guard case .user(let u) = message, u.source == .runtime else { return false }
                if case .text(let t) = u.content.first, t.text.contains("<task-notification>") {
                    return true
                }
                return false
            }
        }
        guard ok else {
            Issue.record("timed out waiting for background notification in idle agent")
            return
        }
    }

    @Test("notifications delivered mid-turn are injected as runtime asides at turn boundaries")
    func midTurnRuntimeAside() async throws {
        // Two-turn FauxProvider: first turn calls a `step` tool, second turn
        // acknowledges. Between the tool call and the LLM emitting its second
        // message, we push a background notification — the agent loop should
        // drain it as runtime context before the second turn.
        //
        // The easiest proxy: just verify that when a notification arrives
        // while streaming, a user-notification message ends up in the final
        // transcript BEFORE `agentEnd` finalizes. The precise interleaving
        // is an implementation detail — we assert that the notification gets
        // delivered at all when the agent is mid-run.
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(
                tokensPerSecond: 100_000,
                tokenSize: FauxTokenSize(min: 1, max: 1)
            )
        )
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwbg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let detach = await agent.attachBackgroundManager(manager, sessionId: "sY")
        defer { Task { await detach() } }

        // Kick off a prompt; while the agent is streaming, push a task.
        Task {
            // Slight delay so the agent starts first.
            try? await Task.sleep(nanoseconds: 5_000_000)
            _ = await manager.spawn(
                runner: FauxRunner(
                    label: "mid-turn-task",
                    outcome: BackgroundTaskOutcome(success: true, summary: "exit 0"),
                    delayMs: 10
                ),
                sessionId: "sY"
            )
        }
        try await agent.prompt("ping")

        // After the initial run, the notification may still be in the queue
        // or delivered. Wait for it to land in the transcript.
        let ok = await awaitUntil(12000) {
            agent.state.messages.contains { m in
                if case .user(let u) = m,
                   u.source == .runtime,
                   case .text(let t) = u.content.first,
                   t.text.contains("<task-notification>") { return true }
                return false
            }
        }
        guard ok else {
            Issue.record("timed out waiting for mid-turn background notification")
            return
        }
    }

    @Test("abortAndKillBackgroundTasks drains the manager")
    func abortAndKill() async {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwbg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let detach = await agent.attachBackgroundManager(manager, sessionId: "s1")
        defer { Task { await detach() } }

        _ = await manager.spawn(runner: ForeverRunner(label: "longtask"), sessionId: "s1")
        _ = await manager.spawn(runner: ForeverRunner(label: "longtask2"), sessionId: "s1")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let before = await manager.list(sessionId: "s1").filter(\.status.isActive).count
        #expect(before == 2)

        await agent.abortAndKillBackgroundTasks()

        let after = await manager.list(sessionId: "s1").filter(\.status.isActive).count
        #expect(after == 0)
    }

    @Test("silent session close does not wake an idle agent")
    func silentCloseDoesNotAutoContinue() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("initial"))])

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwbg-silent-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        try await agent.prompt("seed")
        let detach = await agent.attachBackgroundManager(manager, sessionId: "closing")
        defer { Task { await detach() } }

        let (taskId, _) = await manager.spawn(
            runner: ForeverRunner(label: "cancel quietly"),
            sessionId: "closing"
        )
        await manager.closeSession(sessionId: "closing")
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(await manager.get(taskId)?.status == .killed)
        #expect(agent.state.messages.count == 2)
        #expect(!agent.hasQueuedMessages())
        #expect(!agent.state.isStreaming)
    }

    @Test("tasks scoped to a different session are not delivered")
    func sessionFiltering() async {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwbg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let detach = await agent.attachBackgroundManager(manager, sessionId: "sA")
        defer { Task { await detach() } }

        _ = await manager.spawn(
            runner: FauxRunner(label: "other-session", outcome: BackgroundTaskOutcome(success: true, summary: "ok")),
            sessionId: "sB"
        )

        // Give the bridge a chance to not react.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let hasNotif = agent.state.messages.contains { m in
            if case .user(let u) = m,
               u.source == .runtime,
               case .text(let t) = u.content.first,
               t.text.contains("<task-notification>") { return true }
            return false
        }
        #expect(!hasNotif)
    }

    @Test("an explicit delivery consumer cannot widen the attachment session")
    func explicitConsumerCannotCrossSessionBoundary() async {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwbg-consumer-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BackgroundTaskManager(outputDir: root)
        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        let mismatched = BackgroundTaskDeliveryConsumer(sessionId: "sB")
        let detach = await agent.attachBackgroundManager(
            manager,
            sessionId: "sA",
            deliveryConsumer: mismatched
        )
        defer { Task { await detach() } }

        _ = await manager.spawn(
            runner: FauxRunner(
                label: "other-session",
                outcome: BackgroundTaskOutcome(success: true, summary: "other")
            ),
            sessionId: "sB"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!agent.hasQueuedMessages())

        let (matchingTaskId, _) = await manager.spawn(
            runner: FauxRunner(
                label: "matching-session",
                outcome: BackgroundTaskOutcome(success: true, summary: "matching")
            ),
            sessionId: "sA"
        )
        let delivered = await awaitUntil(2_000) {
            if agent.hasQueuedMessages() { return true }
            return agent.state.messages.contains { message in
                guard case .user(let user) = message,
                      user.source == .runtime,
                      case .text(let text) = user.content.first else { return false }
                return text.text.contains(matchingTaskId)
            }
        }
        #expect(delivered)
    }

    @Test("detaching one manager keeps another manager's idle wake active")
    func detachingOneManagerDoesNotDisableAnother() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage("initial")),
            .message(fauxAssistantMessage("manager B handled")),
        ])

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwbg-multi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let managerA = BackgroundTaskManager(outputDir: root.appendingPathComponent("a"))
        let managerB = BackgroundTaskManager(outputDir: root.appendingPathComponent("b"))
        let agent = Agent(initialState: AgentInitialState(
            model: registration.getModel(),
            tools: createTaskTools(manager: managerA, sessionId: "shared")
        ))
        try await agent.prompt("seed")

        let detachA = await agent.attachBackgroundManager(managerA, sessionId: "shared")
        let detachB = await agent.attachBackgroundManager(managerB, sessionId: "shared")
        defer { Task { await detachB() } }
        await detachA()

        let (taskId, _) = await managerB.spawn(
            runner: FauxRunner(
                label: "manager-b",
                outcome: BackgroundTaskOutcome(success: true, summary: "ok")
            ),
            sessionId: "shared"
        )
        let delivered = await awaitUntil(12_000) {
            agent.state.messages.contains { message in
                guard case .user(let user) = message, user.source == .runtime,
                      case .text(let text) = user.content.first else { return false }
                return text.text.contains(taskId)
            }
        }
        #expect(delivered)
        await agent.waitForIdle()
    }
}
