import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

private let idleSeedMessages: [Message] = [
    .user(UserMessage(content: [.text(TextContent(text: "please add feature X"))])),
    .assistant(fauxAssistantMessage("working on it")),
    .user(UserMessage(content: [.text(TextContent(text: "any update?"))])),
    .assistant(fauxAssistantMessage("step 1 done, moving on")),
    .user(UserMessage(content: [.text(TextContent(text: "great, keep going"))])),
    .assistant(fauxAssistantMessage("step 2 done")),
]

/// Any non-empty transcript is "above" this threshold.
private let alwaysAbove = AgentIdleCompactThreshold.ratio(0.000_001)

private final class IdleEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _types: [String] = []
    func append(_ type: String) { lock.withLock { _types.append(type) } }
    var compactionEvents: [String] {
        lock.withLock { _types.filter { $0 == "compact_start" || $0 == "compact_end" } }
    }
}

private func isCompacted(_ agent: Agent) -> Bool {
    guard case .user(let recap) = agent.state.messages.first else { return false }
    return recap.content.contains { block in
        if case .text(let text) = block { return text.text.contains("<previous-session-summary>") }
        return false
    }
}

@Suite("Agent idle compaction", .serialized)
struct AgentIdleCompactionTests {

    @Test("compacts after the idle delay and reports through compact events")
    func compactsAfterDelay() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("Compressed recap: X then Y."))])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), messages: idleSeedMessages),
            idleCompact: AgentIdleCompactOptions(threshold: alwaysAbove, delay: 0.05)
        ))
        defer { agent.retire() }
        let log = IdleEventLog()
        _ = agent.subscribe { event, _ in log.append(event.type) }
        agent.noteIdleActivity()

        #expect(await awaitUntil(5000) { isCompacted(agent) })
        #expect(await awaitUntil(5000) { log.compactionEvents == ["compact_start", "compact_end"] })
        #expect(agent.state.messages.suffix(2) == idleSeedMessages.suffix(2))
    }

    @Test("off by default, and skipped below the threshold")
    func skipsWhenOffOrSmall() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let off = Agent(initialState: AgentInitialState(model: faux.getModel(), messages: idleSeedMessages))
        #expect(off.idleCompact == nil)
        #expect(await off.compactIfIdle() == nil)
        #expect(!off.idleCompactionTimer.isArmed)

        let small = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), messages: idleSeedMessages),
            idleCompact: AgentIdleCompactOptions(threshold: .ratio(0.5), delay: 3600)
        ))
        defer { small.retire() }
        #expect(await small.compactIfIdle() == nil)
        #expect(small.state.messages == idleSeedMessages)
    }

    @Test("an absolute token threshold ignores the window size")
    func tokenThreshold() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("Compressed recap: X then Y."))])

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), messages: idleSeedMessages),
            idleCompact: AgentIdleCompactOptions(threshold: .tokens(1_000_000), delay: 3600)
        ))
        defer { agent.retire() }
        #expect(await agent.compactIfIdle() == nil)

        // Same measure the agent uses: the full prompt, not just messages.
        let snapshot = agent.state.snapshotModelContext()
        let tokens = AgentContextCompactor.currentUsage(
            context: snapshot.context, model: snapshot.model
        ).tokens
        #expect(tokens > 1)
        agent.idleCompact = AgentIdleCompactOptions(threshold: .tokens(tokens + 1), delay: 3600)
        #expect(await agent.compactIfIdle() == nil)
        #expect(!AgentIdleCompactThreshold.tokens(0).isReached(by: .init(tokens: 10, window: 100)))

        agent.idleCompact = AgentIdleCompactOptions(threshold: .tokens(tokens), delay: 3600)
        guard case .compacted = await agent.compactIfIdle() else {
            Issue.record("expected compaction at the exact token threshold")
            return
        }
    }

    @Test("activity pushes the deadline back; a run and retire() cancel it")
    func activityAndCancellation() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), messages: idleSeedMessages),
            idleCompact: AgentIdleCompactOptions(threshold: alwaysAbove, delay: 0.4)
        ))
        // Keep poking for well over one delay: nothing may fire meanwhile.
        for _ in 0..<12 {
            agent.noteIdleActivity()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(agent.state.messages == idleSeedMessages)
        #expect(agent.idleCompactionTimer.isArmed)

        agent.idleCompact = nil
        #expect(!agent.idleCompactionTimer.isArmed)

        agent.idleCompact = AgentIdleCompactOptions(threshold: alwaysAbove, delay: 3600)
        #expect(agent.idleCompactionTimer.isArmed)
        agent.retire()
        #expect(!agent.idleCompactionTimer.isArmed)
    }

    @Test("the host veto and queued work both skip the compaction")
    func vetoAndQueuedWork() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), messages: idleSeedMessages),
            idleCompact: AgentIdleCompactOptions(threshold: alwaysAbove, delay: 3600, canCompact: { false })
        ))
        defer { agent.retire() }
        #expect(await agent.compactIfIdle() == nil)

        agent.idleCompact = AgentIdleCompactOptions(threshold: alwaysAbove, delay: 3600)
        agent.steer(.user(UserMessage(content: [.text(TextContent(text: "queued"))])))
        #expect(await agent.compactIfIdle() == nil)
        #expect(agent.state.messages == idleSeedMessages)
    }

    @Test("an agent waiting on a background task is not idle")
    func waitingOnBackgroundTask() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("Compressed recap: X then Y."))])

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwidle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), messages: idleSeedMessages),
            sessionId: "idle-session",
            autoCompact: AgentAutoCompactOptions(backgroundManager: manager),
            idleCompact: AgentIdleCompactOptions(threshold: alwaysAbove, delay: 3600)
        ))
        defer { agent.retire() }

        let (taskId, _) = await manager.spawn(runner: ForeverRunner(), sessionId: "idle-session")
        #expect(await agent.compactIfIdle() == nil)
        #expect(agent.state.messages == idleSeedMessages)

        try? await manager.kill(taskId)
        #expect(await awaitUntil(5000) {
            await manager.activeTaskIds(sessionId: "idle-session").isEmpty
        })
        guard case .compacted = await agent.compactIfIdle() else {
            Issue.record("expected compaction once the background task ended")
            return
        }
        #expect(isCompacted(agent))
    }

    @Test("a failed idle compaction is not retried until the transcript changes")
    func failureIsNotRetried() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        // No queued summary response: every summary attempt fails.

        let config = AgentContextCompactionConfig(
            maxSummaryAttempts: 1,
            summaryRetryPolicy: ProviderRetryPolicy(maxAttempts: 1)
        )
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), messages: idleSeedMessages),
            autoCompact: AgentAutoCompactOptions(config: config),
            idleCompact: AgentIdleCompactOptions(threshold: alwaysAbove, delay: 0.05)
        ))
        defer { agent.retire() }
        let log = IdleEventLog()
        _ = agent.subscribe { event, _ in log.append(event.type) }
        agent.noteIdleActivity()

        #expect(await awaitUntil(5000) { log.compactionEvents.count == 2 })
        // The failed attempt's own maintenance window re-armed the timer.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(log.compactionEvents == ["compact_start", "compact_end"])
        #expect(agent.state.messages == idleSeedMessages)
    }
}
