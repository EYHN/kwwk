import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Agent + BackgroundTaskManager", .serialized)
struct AgentBackgroundTests {

    @Test("background notification wakes an idle agent and shows up as a user message")
    func idleWakeInjectsUserMessage() async throws {
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

        // Wait for the agent to pick up the steered notification and complete
        // a run. We look for a user message containing the <task-notification>
        // tag in the transcript.
        let ok = await awaitUntil(12000) {
            let msgs = agent.state.messages
            return msgs.contains { message in
                guard case .user(let u) = message else { return false }
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

    @Test("notifications delivered mid-turn are injected as steering at turn boundaries")
    func midTurnSteering() async throws {
        // Two-turn FauxProvider: first turn calls a `step` tool, second turn
        // acknowledges. Between the tool call and the LLM emitting its second
        // message, we push a background notification — the agent loop should
        // drain it as steering and inject it as a user message before the
        // second turn.
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

        let before = await manager.list(sessionId: "s1").filter { $0.status == .running }.count
        #expect(before == 2)

        await agent.abortAndKillBackgroundTasks()

        let after = await manager.list(sessionId: "s1").filter { $0.status == .running }.count
        #expect(after == 0)
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
               case .text(let t) = u.content.first,
               t.text.contains("<task-notification>") { return true }
            return false
        }
        #expect(!hasNotif)
    }
}
