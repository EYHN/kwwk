import Foundation
import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Context window awareness")
struct ContextWindowAwarenessTests {
    @Test("a plan refusal stating a smaller window compacts against it and retries")
    func planRefusalLowersWindowAndRecovers() async throws {
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            provider: "plan-refusal-\(UUID().uuidString)",
            models: [FauxModelDefinition(id: "k3", contextWindow: 1_048_576)]
        ))
        defer { faux.unregister() }
        let model = faux.getModel()
        defer { ContextWindows.shared.reset(model) }
        let router = WindowStreamRouter(refuseFirstMainRequest: true)
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(systemPrompt: "main-system", model: model, messages: history(model: model, characters: 400)),
            streamFn: router.streamFn()
        ))

        try await agent.prompt("continue after the refusal")

        let snapshot = await router.snapshot()
        #expect(model.effectiveContextWindow == 8_192)
        #expect(snapshot.mainRequests == 2)
        #expect(snapshot.summaryCalls >= 1)
        #expect(snapshot.lastMainText.contains("<previous-session-summary>"))
        #expect(snapshot.lastMainText.contains("continue after the refusal"))
        #expect(AgentContextCompactor.currentUsage(messages: agent.state.messages, model: model).window == 8_192)
        #expect(!agent.state.messages.contains { message in
            if case .assistant(let assistant) = message { return assistant.stopReason == .error }
            return false
        })
    }

    @Test("a discovered account window makes preflight compact before the catalog figure would")
    func discoveredWindowDrivesPreflight() async throws {
        let provider = "discovery-\(UUID().uuidString)"
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(
            provider: provider,
            models: [FauxModelDefinition(id: "k3", contextWindow: 1_048_576)]
        ))
        defer { faux.unregister() }
        let model = faux.getModel()
        let lookups = LookupLog()
        ContextWindows.shared.setDiscovery({ discovered, auth in
            await lookups.record(model: discovered.id, token: auth?.token)
            return 8_192
        }, forProvider: provider)
        defer {
            ContextWindows.shared.setDiscovery(nil, forProvider: provider)
            ContextWindows.shared.reset(model)
        }
        let router = WindowStreamRouter(refuseFirstMainRequest: false)
        // ~6k tokens of history: 0.6 % of the catalog window, ~75 % of the account's.
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(systemPrompt: "main-system", model: model, messages: history(model: model, characters: 6_000)),
            streamFn: router.streamFn(),
            autoCompact: AgentAutoCompactOptions(threshold: 0.5, config: AgentContextCompactionConfig(minMessages: 1)),
            authResolver: { _, _ in ResolvedProviderAuth(token: "account-token", scheme: .bearer) }
        ))

        try await agent.prompt("next request")
        try await agent.prompt("one more")

        let snapshot = await router.snapshot()
        #expect(model.effectiveContextWindow == 8_192)
        #expect(snapshot.summaryCalls >= 1)
        #expect(snapshot.lastMainText.contains("<previous-session-summary>"))
        // Cached for the refresh interval: one lookup across both prompts.
        #expect(await lookups.entries == [LookupLog.Entry(model: "k3", token: "account-token")])
    }

    private func history(model: Model, characters: Int) -> [Message] {
        let filler = String(repeating: "history words ", count: max(1, characters / 14))
        return [
            .user(UserMessage(text: "old request \(filler)")),
            .assistant(AssistantMessage(content: [.text(TextContent(text: "old response \(filler)"))], api: model.api, provider: model.provider, model: model.id)),
            .user(UserMessage(text: "newer request \(filler)")),
            .assistant(AssistantMessage(content: [.text(TextContent(text: "newer response \(filler)"))], api: model.api, provider: model.provider, model: model.id)),
        ]
    }
}

private actor LookupLog {
    struct Entry: Equatable { let model: String; let token: String? }
    private(set) var entries: [Entry] = []
    func record(model: String, token: String?) { entries.append(Entry(model: model, token: token)) }
}

private actor WindowStreamRouter {
    private let refuseFirstMainRequest: Bool
    private var summaryCalls = 0
    private var mainRequests = 0
    private var lastMainText = ""

    init(refuseFirstMainRequest: Bool) {
        self.refuseFirstMainRequest = refuseFirstMainRequest
    }

    nonisolated func streamFn() -> StreamFn {
        { model, context, _ in
            let message = await self.response(model: model, context: context)
            let pair = AssistantMessageStream.makeStream()
            pair.continuation.end(message)
            return pair.stream
        }
    }

    func response(model: Model, context: Context) -> AssistantMessage {
        if context.systemPrompt?.contains("durable working-state summary") == true ||
            context.systemPrompt?.contains("evicted prefix") == true {
            summaryCalls += 1
            return AssistantMessage(
                content: [.text(TextContent(text: "## Goal\nRecovered summary \(summaryCalls)"))],
                api: model.api, provider: model.provider, model: model.id
            )
        }
        mainRequests += 1
        lastMainText = context.messages.map(text).joined(separator: "\n")
        if refuseFirstMainRequest, mainRequests == 1 {
            let refusal = #"{"error":{"type":"authentication_error","message":"Your current plan supports only k3 up to 8K context. 1M context is available on higher-tier Kimi Code plans."},"type":"error"}"#
            return AssistantMessage(
                content: [],
                api: model.api, provider: model.provider, model: model.id,
                stopReason: .error,
                errorMessage: refusal,
                failure: ProviderFailure(message: refusal, httpStatus: 401)
            )
        }
        return AssistantMessage(
            content: [.text(TextContent(text: "provider success"))],
            api: model.api, provider: model.provider, model: model.id
        )
    }

    func snapshot() -> (summaryCalls: Int, mainRequests: Int, lastMainText: String) {
        (summaryCalls, mainRequests, lastMainText)
    }
}

private func text(_ message: Message) -> String {
    switch message {
    case .user(let user):
        return user.content.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text.text
        }.joined(separator: "\n")
    case .assistant(let assistant):
        return assistant.content.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text.text
        }.joined(separator: "\n")
    default:
        return ""
    }
}
