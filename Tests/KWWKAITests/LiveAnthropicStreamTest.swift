import Foundation
import Testing
@testable import KWWKAI

/// Live smoke test — hits real `api.anthropic.com` using a key read from
/// `~/.kwwk/oauth.json` and prints each streamed event with a monotonic
/// millisecond timestamp so we can see tokens arriving incrementally.
///
/// Gated behind the `KWWK_LIVE_ANTHROPIC=1` env var so normal test runs
/// don't hit the network. Burns a few tokens per invocation.
@Suite("Live Anthropic stream")
struct LiveAnthropicStreamTests {

    @Test("streams tokens incrementally, thinking blocks appear over time")
    func liveStream() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_LIVE_ANTHROPIC"] == "1" else {
            print("[skipped] set KWWK_LIVE_ANTHROPIC=1 to run")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let oauthURL = home.appendingPathComponent(".kwwk/oauth.json")
        let data = try Data(contentsOf: oauthURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let entry = json["anthropic-api-key"] as? [String: Any],
              let apiKey = entry["access"] as? String,
              !apiKey.isEmpty
        else {
            Issue.record("no anthropic-api-key in ~/.kwwk/oauth.json")
            return
        }

        let provider = AnthropicProvider(defaultAPIKey: apiKey)
        let model = Model(
            id: "claude-sonnet-4-5-20250929",
            name: "claude-sonnet-4-5",
            api: "anthropic-messages",
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com",
            reasoning: true,
            input: [.text],
            contextWindow: 200_000,
            maxTokens: 4096
        )
        let ctx = Context(messages: [
            .user(UserMessage(text: "Write one paragraph (around 120 words) about why cats like cardboard boxes."))
        ])
        // Thinking off for this one — long plain text response is what we
        // want to observe for token-level streaming granularity.
        let options = StreamOptions()

        let startNs = DispatchTime.now().uptimeNanoseconds
        func stamp() -> String {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            return String(format: "%6.1fms", ms)
        }

        print("\n=== live stream start ===")
        let stream = provider.stream(model: model, context: ctx, options: options)
        var deltaCount = 0
        var thinkingDeltaCount = 0
        var textCharsSoFar = 0
        for await event in stream {
            switch event {
            case .start:
                print("[\(stamp())] start")
            case .textStart:
                print("[\(stamp())] text_start")
            case .textDelta(_, let delta, _):
                deltaCount += 1
                textCharsSoFar += delta.count
                // Print every delta so we see granularity.
                print("[\(stamp())] text_delta (+\(delta.count) char, total \(textCharsSoFar)) \(quote(delta))")
            case .textEnd:
                print("[\(stamp())] text_end")
            case .thinkingStart:
                print("[\(stamp())] thinking_start")
            case .thinkingDelta(_, let delta, _):
                thinkingDeltaCount += 1
                let preview = String(delta.prefix(60))
                    .replacingOccurrences(of: "\n", with: "\\n")
                print("[\(stamp())] thinking_delta (+\(delta.count) char) \(quote(preview))")
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
        print("=== live stream end ===")
        print("stop_reason=\(final.stopReason) text_deltas=\(deltaCount) thinking_deltas=\(thinkingDeltaCount) chars=\(textCharsSoFar)")
        print("final.text:")
        for block in final.content {
            if case .text(let t) = block {
                for line in t.text.components(separatedBy: "\n") {
                    print("  | \(line)")
                }
            }
            if case .thinking(let th) = block {
                print("  [thinking]")
                for line in th.thinking.components(separatedBy: "\n") {
                    print("  ~ \(line)")
                }
            }
        }

        // Core assertion: streaming actually streams. If all text arrived
        // in a single delta we have a batching bug; expect at least 3
        // text deltas for a count-to-10 prompt.
        #expect(deltaCount >= 3, "expected multiple text deltas; got \(deltaCount). Provider may be batching.")
    }

    private func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
