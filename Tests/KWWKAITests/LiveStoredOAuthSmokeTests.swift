import Foundation
import Testing
@testable import KWWKAI

/// Explicit opt-in only. No tools, project context, raw events, or credentials
/// are printed. Uses the same refresh/registration path as the CLI.
@Suite("Stored OAuth smoke", .serialized)
struct LiveStoredOAuthSmokeTests {
    @Test func storedLoginsComplete() async {
        guard ProcessInfo.processInfo.environment["KWWK_LIVE_STORED_OAUTH"] == "1" else { return }
        do {
            let store = try OAuthStore(url: OAuthStore.defaultURL())
            for id in ["openai-codex", "anthropic"] {
                guard let registered = try await registerStored(storeId: id, store: store, primeToken: false) else {
                    Issue.record("Missing stored login: \(id)")
                    continue
                }
                do {
                    let session = UUID().uuidString
                    let auth = try await registered.authResolver?(registered.model, session)
                    let options = StreamOptions(
                        maxTokens: id == "anthropic" ? 128 : nil,
                        transport: .sse, sessionId: session, resolvedAuth: auth)
                    let events = try await stream(model: registered.model, context: Context(
                        systemPrompt: "You are a helpful assistant. Give a brief answer.",
                        messages: [.user(UserMessage(text: "Reply with the word OK."))]), options: options)
                    var deltas = 0
                    for await event in events {
                        if case .textDelta = event { deltas += 1 }
                    }
                    let result = await events.result()
                    await closeProviderSession(sessionId: session)
                    let category = result.providerFailure?.category.rawValue ?? "none"
                    let status = result.providerFailure?.httpStatus.map(String.init) ?? "none"
                    print("OAuth smoke provider=\(id) model=\(registered.model.id) stop=\(result.stopReason) deltas=\(deltas) category=\(category) status=\(status)")
                    #expect(result.stopReason == .stop)
                    #expect(deltas > 0)
                } catch {
                    // Deliberately omit raw errors; OAuth failures can carry secrets.
                    Issue.record("OAuth smoke setup/stream failed for \(id)")
                }
            }
        } catch {
            Issue.record("Unable to open local OAuth store")
        }
    }
}
