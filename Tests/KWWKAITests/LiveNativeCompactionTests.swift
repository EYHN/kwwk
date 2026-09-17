import Foundation
import Testing
@testable import KWWKAI

/// Explicit opt-in: one synthetic native compaction + replay per stored login.
/// No tools, local project data, credentials, or native payloads are logged.
@Suite("Live native compaction", .serialized)
struct LiveNativeCompactionTests {
    @Test func storedOAuthCompactsAndReplays() async {
        guard ProcessInfo.processInfo.environment["KWWK_LIVE_NATIVE_COMPACTION"] == "1" else { return }
        do {
            let store = try OAuthStore(url: OAuthStore.defaultURL())
            for id in ["openai-codex", "anthropic"] {
                do {
                    guard let registered = try await registerStored(storeId: id, store: store, primeToken: false) else {
                        Issue.record("Missing stored login: \(id)"); continue
                    }
                    let model = registered.model
                    let session = UUID().uuidString
                    let auth = try await registered.authResolver?(model, session)
                    let options = StreamOptions(maxTokens: id == "anthropic" ? 2048 : nil,
                        transport: .sse, sessionId: session, resolvedAuth: auth)
                    let filler = String(repeating:
                        "This is synthetic historical context for a compaction smoke test; it contains no private project data.\n",
                        count: id == "anthropic" ? 3200 : 100)
                    let history: [Message] = [
                        .user(UserMessage(text: "Remember the verification code from the following notes. These are synthetic notes for testing compaction.")),
                        .assistant(AssistantMessage(content: [.text(TextContent(text: "The verification code is MAPLE-7319.\n" + filler))],
                            api: model.api, provider: model.provider, model: model.id)),
                    ]
                    guard let result = try await compactNative(model: model,
                        context: Context(systemPrompt: "You are a helpful assistant.", messages: history),
                        instructions: "Summarize the history briefly, retaining the exact verification code.", options: options) else {
                        Issue.record("Native route unexpectedly unavailable: \(id)"); continue
                    }
                    print("Native smoke provider=\(id) model=\(model.id) compact=success items=\(result.payload.items.count)")
                    var recap = UserMessage(text: result.summary, source: .compaction)
                    recap.nativeCompaction = result.payload
                    // Persistence round-trip before replay, as a restored session would do.
                    let restored = try JSONDecoder().decode(UserMessage.self, from: JSONEncoder().encode(recap))
                    let response = try await stream(model: model, context: Context(
                        systemPrompt: "You are a helpful assistant.", messages: [.user(restored),
                            .user(UserMessage(text: "What was the verification code? Reply with only the code."))]), options: options)
                    for await _ in response {}
                    let final = await response.result()
                    await closeProviderSession(sessionId: session)
                    let text = final.content.compactMap { block -> String? in
                        if case .text(let value) = block { return value.text }; return nil
                    }.joined()
                    let recalled = text.contains("MAPLE-7319")
                    print("Native smoke provider=\(id) replay=\(final.stopReason) recalled=\(recalled) status=\(final.providerFailure?.httpStatus ?? 0)")
                    #expect(final.stopReason == .stop)
                    #expect(recalled)
                } catch {
                    let failure = ProviderFailure.capture(error)
                    print("Native smoke provider=\(id) category=\(failure.category) status=\(failure.httpStatus ?? 0)")
                    // This opt-in diagnostic contains only a bounded, redacted
                    // provider message; never print the request or headers.
                    var diagnostic = failure.message
                    for credentials in await store.all().values {
                        for secret in [credentials.access, credentials.refresh] where !secret.isEmpty {
                            diagnostic = diagnostic.replacingOccurrences(of: secret, with: "[REDACTED]")
                        }
                    }
                    let safe = ProviderFailure(message: "", upstreamMessage: diagnostic).upstreamMessage ?? ""
                    print("Native rejection: \(String(safe.prefix(600)))")
                    Issue.record("Native compaction smoke failed for \(id)")
                }
            }
        } catch { Issue.record("Unable to open local OAuth store") }
    }
}
