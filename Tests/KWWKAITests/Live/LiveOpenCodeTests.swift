import Foundation
import Testing
@testable import KWWKAI

/// Explicit opt-in only: one short request per wire through OpenCode's
/// gateway with a real key, as `registerOpenCode` sends it.
///
///     KWWK_LIVE_OPENCODE=go OPENCODE_API_KEY=oc_sk_… swift test --filter LiveOpenCode
///
/// `KWWK_LIVE_OPENCODE` names the plans to run (`go`, `zen`, or `go,zen`).
/// The key is `OPENCODE_API_KEY`, else the plan's login in
/// `~/.kwwk/oauth.json`. `KWWK_LIVE_OPENCODE_MODELS` (comma-separated) replaces
/// the models tried. Only the plan, model, wire, stop reason, delta count and a
/// failure's category and status are printed: never the key or a body.
@Suite(
    "Live OpenCode",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["KWWK_LIVE_OPENCODE"]?.isEmpty == false)
)
struct LiveOpenCodeTests {
    /// One model per wire the plan serves.
    static let models: [String: [String]] = [
        OpenCodePlan.go.id: ["glm-5.2", "grok-4.7", "claude-haiku-5-5", "gemini-4-argon"],
        OpenCodePlan.zen.id: ["glm-5.3-flash", "gpt-5-nano", "claude-haiku-4-5", "gemini-3.5-flash-lite"],
    ]

    @Test func eachWireAnswers() async {
        let env = ProcessInfo.processInfo.environment
        let plans = (env["KWWK_LIVE_OPENCODE"] ?? "").split(separator: ",").compactMap { name -> OpenCodePlan? in
            switch name.trimmingCharacters(in: .whitespaces) {
            case "go": .go
            case "zen": .zen
            default: nil
            }
        }
        #expect(!plans.isEmpty, "KWWK_LIVE_OPENCODE names go, zen or go,zen")
        for plan in plans {
            guard let key = await Self.key(for: plan, env: env) else {
                Issue.record("No key for \(plan.id): set OPENCODE_API_KEY or log in to it")
                continue
            }
            let ids = env["KWWK_LIVE_OPENCODE_MODELS"].map {
                $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } ?? Self.models[plan.id] ?? []
            for id in ids {
                let registered = await registerOpenCode(plan: plan, apiKey: key, modelOverride: id)
                let session = UUID().uuidString
                do {
                    // the key travels with the resolution, as in a session
                    let auth = try await registered.authResolver?(registered.model, session)
                    let events = try await stream(model: registered.model, context: Context(
                        systemPrompt: "You are a helpful assistant. Give a brief answer.",
                        messages: [.user(UserMessage(text: "Reply with the word OK."))]
                    ), options: StreamOptions(apiKey: auth?.token, sessionId: session, resolvedAuth: auth))
                    var deltas = 0
                    for await event in events {
                        if case .textDelta = event { deltas += 1 }
                    }
                    let result = await events.result()
                    await closeProviderSession(sessionId: session)
                    let category = result.providerFailure?.category.rawValue ?? "none"
                    let status = result.providerFailure?.httpStatus.map(String.init) ?? "none"
                    print("OpenCode live plan=\(plan.id) model=\(id) wire=\(registered.model.api) stop=\(result.stopReason) deltas=\(deltas) category=\(category) status=\(status)")
                    #expect(result.stopReason == .stop || result.stopReason == .length, "\(plan.id) \(id)")
                    #expect(deltas > 0, "\(plan.id) \(id)")
                } catch {
                    // Deliberately omit the raw error: a provider's can echo what it was sent.
                    Issue.record("OpenCode live request failed for \(plan.id) \(id)")
                }
            }
            await APIRegistry.shared.unregisterScope(plan.id)
        }
    }

    private static func key(for plan: OpenCodePlan, env: [String: String]) async -> String? {
        if let key = env["OPENCODE_API_KEY"], !key.isEmpty { return key }
        guard let store = try? OAuthStore(url: OAuthStore.defaultURL()) else { return nil }
        return await store.get(plan.id)?.access
    }
}
