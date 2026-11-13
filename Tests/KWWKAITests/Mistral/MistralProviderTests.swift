import Foundation
import Testing
@testable import KWWKAI

@Suite("Mistral conversations provider")
struct MistralProviderTests {

    private func isValidMistralId(_ id: String) -> Bool {
        id.count == 9 && id.allSatisfy { $0.isLetter || $0.isNumber }
    }

    @Test("normalizes tool ids to 9 alphanumeric chars, linking call and result")
    func normalizesIds() {
        let original = "toolu_01ABC-xyz/verylongid"
        let messages: [Message] = [
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: original, name: "calc", arguments: .object([:])))],
                api: "mistral-conversations", provider: "mistral", model: "magistral",
                stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(
                toolCallId: original, toolName: "calc",
                content: [.text(TextContent(text: "3"))]
            )),
        ]
        let out = MistralConversationsProvider.normalizeToolIds(messages)

        guard case .assistant(let a) = out[0], case .toolCall(let tc) = a.content[0],
              case .toolResult(let tr) = out[1] else {
            Issue.record("unexpected message shape"); return
        }
        #expect(isValidMistralId(tc.id))
        #expect(tc.id == tr.toolCallId)   // call/result stay linked
        #expect(tc.id != original)
    }

    @Test("keeps an already-valid 9-char alphanumeric id unchanged")
    func keepsValidId() {
        #expect(MistralConversationsProvider.derive("abc123XYZ", attempt: 0) == "abc123XYZ")
    }

    @Test("derive is deterministic and always 9 alphanumeric chars")
    func deriveShape() {
        for s in ["x", "call_99", "толкование", "a/b:c-d.e", ""] {
            let d = MistralConversationsProvider.derive(s, attempt: 0)
            #expect(d.count == 9)
            #expect(d.allSatisfy { $0.isLetter || $0.isNumber })
            #expect(MistralConversationsProvider.derive(s, attempt: 0) == d) // stable
        }
    }

    @Test("distinct original ids that collide get distinct candidates")
    func collisionAvoidance() {
        // Two different originals normalizing to the same 9-char value must not
        // both map to it — the second bumps to attempt+1.
        let a = MistralConversationsProvider.normalizeToolIds([
            .assistant(AssistantMessage(content: [
                .toolCall(ToolCall(id: "dup", name: "t", arguments: .object([:]))),
                .toolCall(ToolCall(id: "dup2", name: "t", arguments: .object([:]))),
            ], api: "mistral-conversations", provider: "mistral", model: "m", stopReason: .toolUse)),
        ])
        guard case .assistant(let msg) = a[0],
              case .toolCall(let c1) = msg.content[0],
              case .toolCall(let c2) = msg.content[1] else { Issue.record("shape"); return }
        #expect(c1.id != c2.id)
    }

    // MARK: - Image limit

    private func image(_ n: Int) -> ImageContent {
        ImageContent(data: "AAAA\(n)", mimeType: "image/png")
    }

    private func imageData(_ messages: [Message]) -> [String] {
        messages.flatMap { message -> [String] in
            switch message {
            case .user(let u):
                return u.content.compactMap { if case .image(let i) = $0 { return i.data }; return nil }
            case .toolResult(let tr):
                return tr.content.compactMap { if case .image(let i) = $0 { return i.data }; return nil }
            default:
                return []
            }
        }
    }

    private func placeholders(_ messages: [Message]) -> Int {
        messages.reduce(0) { count, message in
            switch message {
            case .user(let u):
                return count + u.content.filter {
                    if case .text(let t) = $0 { return t.text == MistralConversationsProvider.imageLeftOutText }
                    return false
                }.count
            case .toolResult(let tr):
                return count + tr.content.filter {
                    if case .text(let t) = $0 { return t.text == MistralConversationsProvider.imageLeftOutText }
                    return false
                }.count
            default:
                return count
            }
        }
    }

    /// n turns that each carry one screenshot, alternating a user message and
    /// a tool result.
    private func shots(_ n: Int) -> [Message] {
        (0..<n).map { i -> Message in
            if i % 2 == 0 {
                return .user(UserMessage(content: [.text(TextContent(text: "shot \(i)")), .image(image(i))]))
            }
            return .toolResult(ToolResultMessage(
                toolCallId: "call\(i)", toolName: "screenshot",
                content: [.text(TextContent(text: "shot \(i)")), .image(image(i))]
            ))
        }
    }

    @Test("past 20 images the oldest are replaced by a short text, ten at a time")
    func keepsNewestTwentyImages() {
        let out = MistralConversationsProvider.limitImages(shots(26))
        #expect(out.count == 26)
        #expect(imageData(out) == (10..<26).map { "AAAA\($0)" })
        #expect(placeholders(out) == 10)
        // every turn's own text stays
        for (i, message) in out.enumerated() {
            let texts: [String]
            switch message {
            case .user(let u): texts = u.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }
            case .toolResult(let tr): texts = tr.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }
            default: texts = []
            }
            #expect(texts.first == "shot \(i)")
        }
    }

    @Test("a transcript of 20 or fewer images comes back unchanged")
    func withinLimitUnchanged() {
        let messages = shots(20)
        #expect(MistralConversationsProvider.limitImages(messages) == messages)
    }

    @Test("tool-result images don't count when the model doesn't take images")
    func toolResultImagesUncountedForTextModel() {
        // 13 user images + 13 tool-result images: only the user ones are sent.
        let messages = shots(26)
        #expect(MistralConversationsProvider.limitImages(messages, countToolResultImages: false) == messages)
    }

    // magpie 01f3349: a conversation reading a screenshot a turn, past 20 of
    // them, missed Mistral's prompt cache every turn as the cut moved by one
    // image each time. Each turn's transcript is the one before with the new
    // turn added, until the cut moves ten images later.
    @Test("past 20 images the prefix changes only every ten new images")
    func limitKeepsPrefix() {
        // one transcript cut at each turn, so a message is the same value
        // in every request it goes in
        let all = shots(60)
        var moved: [Int] = []
        var prev = MistralConversationsProvider.limitImages(Array(all.prefix(20)))
        for n in 21...60 {
            let cur = MistralConversationsProvider.limitImages(Array(all.prefix(n)))
            #expect(imageData(cur).count <= MistralConversationsProvider.maxImages, "\(n) shots")
            if Array(cur.prefix(prev.count)) != prev { moved.append(n) }
            prev = cur
        }
        #expect(moved == [21, 31, 41, 51])
    }

    @Test("the cap reaches the request body Mistral gets")
    func requestBodyCarriesTwentyImages() async throws {
        let client = StubSSEClient(body: CrossProviderSwitchTests.openaiDone)
        let provider = MistralConversationsProvider(client: client, defaultAPIKey: "k")
        let model = Model(
            id: "deepseek-v4-1-flash-1017", api: "mistral-conversations", provider: "mistral",
            baseURL: "https://api.mistral.ai", input: [.text, .image]
        )
        let messages: [Message] = (0..<26).map {
            .user(UserMessage(content: [.text(TextContent(text: "shot \($0)")), .image(image($0))]))
        }
        let stream = provider.stream(model: model, context: Context(messages: messages), options: nil)
        for await _ in stream {}
        let body = try #require(client.lastRequest?.body)
        let text = try #require(String(data: body, encoding: .utf8))
        // JSONSerialization may escape "/", so count the base64 prefix
        #expect(text.components(separatedBy: "base64,AAAA").count - 1 == 16)
        #expect(text.contains("base64,AAAA25\""))
        #expect(text.contains("base64,AAAA10\""))
        #expect(!text.contains("base64,AAAA9\""))
        #expect(text.contains("shot 0"))
        #expect(text.contains(MistralConversationsProvider.imageLeftOutText))
    }
}
