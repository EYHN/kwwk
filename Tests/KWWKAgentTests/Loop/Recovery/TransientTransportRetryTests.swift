import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

private actor ThrowCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
    func snapshot() -> Int { count }
}

/// FrontierHarness eval: 41 trials ended with `NSURLErrorDomain -1001` while
/// the provider was rate limiting. Each request sat silent past URLSession's
/// 60 s idle timeout, the agent spent its five attempts on that (≈313 s
/// every time), and kwwk exited 1.
@Suite("Agent retries transient transport errors")
struct TransientTransportRetryTests {
    private func succeeding(_ model: Model) -> AssistantMessageStream {
        let pair = AssistantMessageStream.makeStream()
        pair.continuation.end(AssistantMessage(
            content: [.text(TextContent(text: "recovered"))],
            api: model.api,
            provider: model.provider,
            model: model.id
        ))
        return pair.stream
    }

    @Test("thrown timeouts and dropped connections are retried, then the turn succeeds",
          arguments: [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                      NSURLErrorBadServerResponse])
    func recoversFromThrownTransportErrors(code: Int) async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let counter = ThrowCounter()
        let streamFn: StreamFn = { model, _, _ in
            if await counter.next() <= 4 {
                throw NSError(domain: NSURLErrorDomain, code: code)
            }
            return self.succeeding(model)
        }
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            streamFn: streamFn
        ))
        agent.retryBaseDelayMs = 1
        try await agent.prompt("hi")
        #expect(await counter.snapshot() == 5)
        guard case .assistant(let last) = agent.state.messages.last else {
            Issue.record("expected an assistant reply")
            return
        }
        #expect(last.stopReason != .error)
    }

    @Test("timeouts keep a five-attempt budget; other transient errors get eight")
    func budgets() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        for (code, expected) in [(NSURLErrorTimedOut, 5), (NSURLErrorNetworkConnectionLost, 8)] {
            let counter = ThrowCounter()
            let streamFn: StreamFn = { _, _, _ in
                _ = await counter.next()
                throw NSError(domain: NSURLErrorDomain, code: code)
            }
            let agent = Agent(options: AgentOptions(
                initialState: AgentInitialState(model: faux.getModel()),
                streamFn: streamFn
            ))
            agent.retryBaseDelayMs = 1
            _ = try? await agent.prompt("hi")
            #expect(await counter.snapshot() == expected)
        }
    }
}
