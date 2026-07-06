import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// Covers the Agent-core review findings: ergonomic steer/followUp overloads
/// and exactly-one-turnStart-per-run.
@Suite("Agent hardening")
struct AgentHardeningTests {

    private actor Counter {
        var count = 0
        func bump() { count += 1 }
    }

    // M15: steer/followUp gained String and UserMessage conveniences so callers
    // don't have to wrap in `.user(...)`.
    @Test("steer/followUp accept String and UserMessage without .user wrapping")
    func steerConveniencesEnqueue() async {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.steer("plain text")
        agent.steer(UserMessage(text: "typed message"))
        #expect(agent.queuedSteeringCount() == 2)

        let queued = agent.queuedSteeringMessages()
        if case .user(let first) = queued.first {
            #expect(first.content.contains { block in
                if case .text(let t) = block { return t.text == "plain text" }
                return false
            })
        } else {
            Issue.record("expected a user message at the front of the steering queue")
        }
    }

    // Finding #8 / L12: run() pre-emits turnStart and previously entered the
    // loop with firstTurn:false, so every run emitted two turnStart events.
    @Test("a single-turn run emits exactly one turnStart")
    func oneTurnStartPerRun() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        let counter = Counter()
        let unsubscribe = agent.subscribe { event, _ in
            if case .turnStart = event { await counter.bump() }
        }
        defer { unsubscribe() }

        try await agent.prompt("hello")
        #expect(await counter.count == 1)
    }
}
