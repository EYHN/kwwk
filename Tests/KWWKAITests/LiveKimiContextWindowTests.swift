import Foundation
import Testing
@testable import KWWKAI

/// Explicit opt-in only: `KWWK_LIVE_KIMI_CONTEXT=1 swift test --filter
/// LiveKimiContextWindowTests`. Uses the stored Kimi For Coding login through
/// the CLI's registration path. The over-window request is refused before any
/// generation; nothing secret is printed.
@Suite("Kimi context window (live)", .serialized)
struct LiveKimiContextWindowTests {
    @Test func accountWindowIsDiscoveredAndRefusalsAreOverflows() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_LIVE_KIMI_CONTEXT"] == "1" else { return }
        let store = try OAuthStore(url: OAuthStore.defaultURL())
        let registered = try #require(try await registerStored(
            storeId: "kimi-coding", store: store, modelOverride: "k3", primeToken: false
        ))
        let model = registered.model
        let resolver = try #require(registered.authResolver)
        let windows = ContextWindows()

        await windows.refreshIfNeeded(model: model) { try await resolver(model, nil) }
        let discovered = windows.effectiveWindow(for: model)
        print("Kimi live: catalog=\(model.contextWindow) discovered=\(discovered)")
        #expect(discovered < model.contextWindow)

        // Comfortably past the discovered window, so the plan refuses it.
        let words = (0..<(discovered / 2)).map { "w\($0 % 997)" }.joined(separator: " ")
        let session = UUID().uuidString
        let events = try await stream(model: model, context: Context(
            systemPrompt: "Reply with OK.",
            messages: [.user(UserMessage(text: words))]
        ), options: StreamOptions(maxTokens: 64, transport: .sse, sessionId: session,
                                  resolvedAuth: try await resolver(model, session)))
        for await _ in events {}
        let result = await events.result()
        await closeProviderSession(sessionId: session)
        let failure = try #require(result.providerFailure)
        print("Kimi live: status=\(failure.httpStatus.map(String.init) ?? "none") category=\(failure.category.rawValue) limit=\(failure.reportedContextLimit.map(String.init) ?? "none")")
        #expect(failure.category == .contextOverflow)
        #expect(failure.reportedContextLimit == discovered)
    }
}
