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
}
