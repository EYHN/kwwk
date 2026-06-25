import Foundation
import Testing
@testable import KWWKAI

@Suite("TransformMessages")
struct TransformMessagesTests {

    // MARK: - Helpers

    private func textModel(id: String = "m-1", provider: String = "p", api: String = "a") -> Model {
        Model(id: id, api: api, provider: provider, input: [.text])
    }

    private func visionModel(id: String = "m-1", provider: String = "p", api: String = "a") -> Model {
        Model(id: id, api: api, provider: provider, input: [.text, .image])
    }

    private func assistant(
        _ content: [AssistantBlock],
        provider: String = "p",
        api: String = "a",
        model: String = "m-1",
        stopReason: StopReason = .stop
    ) -> Message {
        .assistant(AssistantMessage(
            content: content, api: api, provider: provider, model: model, stopReason: stopReason
        ))
    }

    private func text(_ m: Message) -> [String] {
        switch m {
        case .user(let u):
            return u.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }
        case .assistant(let a):
            return a.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }
        case .toolResult(let r):
            return r.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }
        }
    }

    // MARK: - (a) Image downgrade

    @Test("non-vision model replaces user image with placeholder")
    func downgradeUserImage() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [.user(UserMessage(content: [.text(TextContent(text: "look")), .image(img)]))]
        let out = TransformMessages.downgradeUnsupportedImages(msgs, model: textModel())
        #expect(text(out[0]) == ["look", TransformMessages.nonVisionUserImagePlaceholder])
    }

    @Test("vision model leaves images untouched")
    func visionKeepsImages() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [.user(UserMessage(content: [.image(img)]))]
        let out = TransformMessages.downgradeUnsupportedImages(msgs, model: visionModel())
        #expect(out == msgs)
    }

    @Test("adjacent images collapse to a single placeholder")
    func collapseAdjacentImages() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [.user(UserMessage(content: [.image(img), .image(img), .text(TextContent(text: "x"))]))]
        let out = TransformMessages.downgradeUnsupportedImages(msgs, model: textModel())
        #expect(text(out[0]) == [TransformMessages.nonVisionUserImagePlaceholder, "x"])
    }

    @Test("non-vision model replaces tool-result image")
    func downgradeToolImage() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [.toolResult(ToolResultMessage(
            toolCallId: "c1", toolName: "shot", content: [.image(img)]
        ))]
        let out = TransformMessages.downgradeUnsupportedImages(msgs, model: textModel())
        #expect(text(out[0]) == [TransformMessages.nonVisionToolImagePlaceholder])
    }

    // MARK: - (b) Thinking strip

    @Test("same model keeps thinking blocks and signatures")
    func sameModelKeepsThinking() {
        let msgs: [Message] = [assistant([
            .thinking(ThinkingContent(thinking: "", thinkingSignature: "sig")),
            .text(TextContent(text: "hi")),
        ])]
        let out = TransformMessages.stripCrossModelThinking(msgs, model: textModel())
        #expect(out == msgs)
    }

    @Test("cross model downgrades non-empty thinking to text")
    func crossModelThinkingToText() {
        let msgs: [Message] = [assistant([
            .thinking(ThinkingContent(thinking: "reasoning")),
            .text(TextContent(text: "answer")),
        ], model: "other")]
        let out = TransformMessages.stripCrossModelThinking(msgs, model: textModel())
        #expect(text(out[0]) == ["reasoning", "answer"])
    }

    @Test("cross model drops redacted and empty thinking")
    func crossModelDropsRedactedAndEmpty() {
        let msgs: [Message] = [assistant([
            .thinking(ThinkingContent(thinking: "secret", redacted: true)),
            .thinking(ThinkingContent(thinking: "   ")),
            .text(TextContent(text: "answer")),
        ], model: "other")]
        let out = TransformMessages.stripCrossModelThinking(msgs, model: textModel())
        #expect(text(out[0]) == ["answer"])
        guard case .assistant(let a) = out[0] else { Issue.record("expected assistant"); return }
        #expect(a.content.count == 1)
    }

    @Test("cross model strips thought signature from tool calls")
    func crossModelStripsThoughtSignature() {
        let msgs: [Message] = [assistant([
            .toolCall(ToolCall(id: "c1", name: "f", arguments: .null, thoughtSignature: "ts")),
        ], model: "other", stopReason: .toolUse)]
        let out = TransformMessages.stripCrossModelThinking(msgs, model: textModel())
        guard case .assistant(let a) = out[0], case .toolCall(let tc) = a.content[0] else {
            Issue.record("expected tool call"); return
        }
        #expect(tc.thoughtSignature == nil)
    }

    // MARK: - (c) Error-turn skip

    @Test("errored assistant turn is skipped")
    func skipErroredTurn() {
        let msgs: [Message] = [
            .user(UserMessage(text: "hi")),
            assistant([.text(TextContent(text: "partial"))], stopReason: .error),
            .user(UserMessage(text: "retry")),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.role == .user })
    }

    @Test("aborted assistant turn is skipped")
    func skipAbortedTurn() {
        let msgs: [Message] = [assistant([.text(TextContent(text: "x"))], stopReason: .aborted)]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.isEmpty)
    }

    // MARK: - (d) Orphan tool calls / results

    @Test("orphaned tool call gets synthetic error result")
    func synthesizeOrphanResult() {
        let msgs: [Message] = [assistant([
            .toolCall(ToolCall(id: "c1", name: "f", arguments: .null)),
        ], stopReason: .toolUse)]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.count == 2)
        guard case .toolResult(let r) = out[1] else { Issue.record("expected synthetic result"); return }
        #expect(r.toolCallId == "c1")
        #expect(r.isError)
        #expect(text(out[1]) == ["No result provided"])
    }

    @Test("matched tool call and result are preserved without synthesis")
    func matchedToolResultPreserved() {
        let msgs: [Message] = [
            assistant([.toolCall(ToolCall(id: "c1", name: "f", arguments: .null))], stopReason: .toolUse),
            .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "f", content: [.text(TextContent(text: "ok"))])),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.count == 2)
        guard case .toolResult(let r) = out[1] else { Issue.record("expected result"); return }
        #expect(r.toolCallId == "c1")
        #expect(!r.isError)
    }

    @Test("tool result orphaned by skipped errored turn is dropped")
    func dropOrphanedToolResult() {
        let msgs: [Message] = [
            assistant([.toolCall(ToolCall(id: "c1", name: "f", arguments: .null))], stopReason: .error),
            .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "f", content: [.text(TextContent(text: "ok"))])),
            .user(UserMessage(text: "next")),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.count == 1)
        #expect(out[0].role == .user)
    }

    // MARK: - (e) Surrogate sanitization

    // Note: Swift `String`/`Unicode.Scalar` cannot natively hold a lone
    // UTF-16 surrogate (the scalar initializer returns nil for 0xD800-0xDFFF),
    // so by the time text reaches us it is already surrogate-free. The
    // sanitizer is a defensive guard that must round-trip valid text and
    // preserve valid (paired) astral characters untouched.

    @Test("clean text is returned unchanged")
    func sanitizeCleanText() {
        let s = "hello \u{1F600} world"
        #expect(TransformMessages.sanitize(s) == s)
    }

    @Test("astral characters survive sanitization")
    func sanitizeAstral() {
        // U+1F600 decomposes into a UTF-16 surrogate pair; it must be preserved.
        let s = "emoji: \u{1F600}\u{1F4A9}"
        #expect(TransformMessages.sanitize(s) == s)
    }

    @Test("sanitize pass preserves valid text inside messages")
    func sanitizeAcrossMessages() {
        let msgs: [Message] = [
            .user(UserMessage(text: "café \u{1F600}")),
            assistant([.text(TextContent(text: "naïve"))]),
        ]
        let out = TransformMessages.sanitizeSurrogates(msgs)
        #expect(text(out[0]) == ["café \u{1F600}"])
        #expect(text(out[1]) == ["naïve"])
    }

    // MARK: - Composition

    @Test("normalize composes passes: skip error then synthesize orphan")
    func normalizeComposition() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [
            .user(UserMessage(content: [.text(TextContent(text: "go")), .image(img)])),
            assistant([.text(TextContent(text: "bad"))], stopReason: .error),
            assistant([.toolCall(ToolCall(id: "c1", name: "f", arguments: .null))], stopReason: .toolUse),
        ]
        let out = TransformMessages.normalize(msgs, model: textModel())
        // user image downgraded
        #expect(text(out[0]) == ["go", TransformMessages.nonVisionUserImagePlaceholder])
        // errored turn skipped, tool-call turn kept, synthetic result appended
        #expect(out.count == 3)
        #expect(out[1].role == .assistant)
        guard case .toolResult(let r) = out[2] else { Issue.record("expected synthetic result"); return }
        #expect(r.isError)
    }
}
