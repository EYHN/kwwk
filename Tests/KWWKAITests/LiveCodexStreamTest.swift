import Foundation
import Testing
@testable import KWWKAI

/// Live smoke test against ChatGPT Codex using the OAuth creds in
/// `~/.kwwk/oauth.json`. Prints every event with a monotonic timestamp
/// so we can inspect what the endpoint actually emits for reasoning —
/// specifically whether `[thinking]` blocks arrive at all when
/// `reasoning: {effort}` is requested.
///
/// Gated on `KWWK_LIVE_CODEX=1` so CI never hits the network.
@Suite("Live Codex stream")
struct LiveCodexStreamTests {

    @Test("raw SSE dump — shows exactly what Codex emits")
    func rawSSE() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_LIVE_CODEX_RAW"] == "1" else {
            print("[skipped] set KWWK_LIVE_CODEX_RAW=1 to dump raw SSE")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let oauthURL = home.appendingPathComponent(".kwwk/oauth.json")
        let data = try Data(contentsOf: oauthURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let entry = json["openai-codex"] as? [String: Any] else { return }
        _ = entry

        let store = OAuthStore(url: OAuthStore.defaultURL())
        let manager = OAuthManager(store: store)
        let accessToken = try await manager.apiKey(for: "openai-codex")
        let refreshed = await store.get("openai-codex")
        let accountId: String? = {
            if case .string(let s) = refreshed?.extras["accountId"] ?? .null { return s }
            return nil
        }()

        let client = URLSessionHTTPClient()
        let body: [String: Any] = [
            "model": "gpt-5.4",
            "stream": true,
            "store": false,
            "instructions": "You are helpful.",
            "input": [[
                "role": "user",
                "content": [["type": "input_text", "text": "Multiply these step by step, showing your work: 47 × 38. Then double-check by computing it a different way."]],
            ]],
            "reasoning": ["effort": "medium", "summary": "auto"],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "text/event-stream",
            "authorization": "Bearer \(accessToken)",
            "openai-beta": "responses=experimental",
            "originator": "kwwk",
        ]
        if let accountId { headers["chatgpt-account-id"] = accountId }

        print("\n=== raw SSE ===")
        let (response, stream) = try await client.stream(
            url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            method: "POST",
            headers: headers,
            body: bodyData
        )
        print("status=\(response.statusCode)")
        var buffer = Data()
        for try await byte in stream {
            buffer.append(byte)
        }
        let text = String(data: buffer, encoding: .utf8) ?? "<non-utf8>"
        // Print every event line, truncated to keep output manageable.
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty { continue }
            let trimmed = line.count > 400 ? String(line.prefix(400)) + "…" : line
            print(trimmed)
        }
        print("=== raw SSE end ===")
    }

    @Test("streams and reports reasoning events if the endpoint emits them")
    func liveStream() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_LIVE_CODEX"] == "1" else {
            print("[skipped] set KWWK_LIVE_CODEX=1 to run")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let oauthURL = home.appendingPathComponent(".kwwk/oauth.json")
        let data = try Data(contentsOf: oauthURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let entry = json["openai-codex"] as? [String: Any],
              let refresh = entry["refresh"] as? String, !refresh.isEmpty
        else {
            Issue.record("no openai-codex OAuth in ~/.kwwk/oauth.json")
            return
        }

        // Refresh the access token so we have a fresh one before the
        // stream call. The manager also stashes the `accountId` JWT claim.
        let store = OAuthStore(url: OAuthStore.defaultURL())
        let manager = OAuthManager(store: store)
        let accessToken: String
        do {
            accessToken = try await manager.apiKey(for: "openai-codex")
        } catch {
            Issue.record("codex token refresh failed: \(error)")
            return
        }
        let refreshed = await store.get("openai-codex")
        let accountId: String? = {
            if case .string(let s) = refreshed?.extras["accountId"] ?? .null { return s }
            return nil
        }()

        let provider = ProviderVariants.chatgptCodex(
            accessToken: accessToken,
            accountId: accountId,
            originator: "kwwk"
        )

        let model = Model(
            id: "gpt-5.4",
            name: "gpt-5.4",
            api: "chatgpt-codex",
            provider: "chatgpt-codex",
            baseUrl: "https://chatgpt.com",
            reasoning: true,
            input: [.text, .image],
            contextWindow: 272_000,
            // Codex rejects max_output_tokens — sentinel 0 skips emission.
            maxTokens: 0
        )

        // Codex 400s with "Instructions are required" if systemPrompt is
        // empty, so plug in a minimal one.
        let ctx = Context(
            systemPrompt: "You are a helpful assistant.",
            messages: [
                .user(UserMessage(text: "What's 7 * 9? Think before answering."))
            ]
        )
        let options = StreamOptions(reasoning: .medium)

        let startNs = DispatchTime.now().uptimeNanoseconds
        func stamp() -> String {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            return String(format: "%6.1fms", ms)
        }

        print("\n=== codex live stream start ===")
        let stream = provider.stream(model: model, context: ctx, options: options)
        var textDeltas = 0
        var thinkingDeltas = 0
        var eventTypes: [String] = []
        for await event in stream {
            eventTypes.append(event.type)
            switch event {
            case .start:
                print("[\(stamp())] start")
            case .textStart:
                print("[\(stamp())] text_start")
            case .textDelta(_, let delta, _):
                textDeltas += 1
                let preview = String(delta.prefix(60))
                    .replacingOccurrences(of: "\n", with: "\\n")
                print("[\(stamp())] text_delta (+\(delta.count)ch) \"\(preview)\"")
            case .textEnd:
                print("[\(stamp())] text_end")
            case .thinkingStart:
                print("[\(stamp())] thinking_start")
            case .thinkingDelta(_, let delta, _):
                thinkingDeltas += 1
                let preview = String(delta.prefix(80))
                    .replacingOccurrences(of: "\n", with: "\\n")
                print("[\(stamp())] thinking_delta (+\(delta.count)ch) \"\(preview)\"")
            case .thinkingEnd:
                print("[\(stamp())] thinking_end")
            case .toolCallStart:
                print("[\(stamp())] tool_call_start")
            case .toolCallDelta:
                print("[\(stamp())] tool_call_delta")
            case .toolCallEnd:
                print("[\(stamp())] tool_call_end")
            case .done:
                print("[\(stamp())] done")
            case .error:
                print("[\(stamp())] error")
            }
        }
        let final = await stream.result()
        print("=== codex live stream end ===")
        print("event_types=\(Array(Set(eventTypes)).sorted())")
        print("text_deltas=\(textDeltas) thinking_deltas=\(thinkingDeltas)")
        print("stop_reason=\(final.stopReason)")
        print("final blocks:")
        for (i, block) in final.content.enumerated() {
            switch block {
            case .text(let t):
                print("  [\(i)] text: \(t.text.prefix(200))")
            case .thinking(let th):
                print("  [\(i)] thinking: \(th.thinking.prefix(200))")
            case .toolCall(let tc):
                print("  [\(i)] tool: \(tc.name)")
            }
        }
        if let err = final.errorMessage { print("error: \(err)") }
    }
}
