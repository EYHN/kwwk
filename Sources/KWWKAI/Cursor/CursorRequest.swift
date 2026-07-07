import Foundation
import Crypto

/// Builds the `AgentRunRequest` (wrapped in an `AgentClientMessage`) for a
/// Cursor Run against a seeded blob store. Mirrors oh-my-pi's
/// `buildGrpcRequest`:
///
/// - `rootPromptMessagesJson` carries the system prompt PLUS every prior
///   user/assistant/toolResult message as JSON blobs — Cursor's server builds
///   the actual model prompt from this field (`turns[]` is UI metadata), so
///   omitting history here silently loses all multi-turn context.
/// - `turns[]`, each turn's `user_message`, and its `steps[]` are sha256 blob
///   IDs registered in the blob store and resolved by the server through the
///   KV `get_blob` handshake — never inline message bytes.
/// - The trailing user message drives the turn's `userMessageAction`; when the
///   context ends in assistant/tool-result messages instead, the run resumes
///   the previous turn (`resumeAction`) and the trailing messages stay in
///   history.
enum CursorRequestBuilder {
    static func build(
        model: Model,
        wireModelId: String,
        context: Context,
        conversationId: String,
        blobStore: CursorBlobStore,
        cachedCheckpoint: Data?
    ) -> Data {
        // System prompt blob: `{ "role": "system", "content": … }`, keyed by its
        // sha256 id, referenced from rootPromptMessagesJson.
        let systemContent = context.systemPrompt?.isEmpty == false
            ? context.systemPrompt!
            : "You are a helpful assistant."
        let systemId = storeJSONBlob(["role": "system", "content": systemContent], in: blobStore)

        // Final user message → action; everything before it → history.
        let activeIndex = activeUserMessageIndex(context.messages)

        let turns = buildTurns(context.messages, activeIndex: activeIndex, blobStore: blobStore)
        let rootPromptIds = buildRootPromptIds(
            context.messages, activeIndex: activeIndex, systemId: systemId, blobStore: blobStore
        )

        // Preserve cached non-history checkpoint fields (todos, file states,
        // summary archives, …) only while the system prompt is unchanged.
        let preserved = cachedCheckpoint.flatMap { checkpoint in
            CursorProto.rootPromptIds(ofState: checkpoint).first == systemId ? checkpoint : nil
        }
        let conversationState = CursorProto.encodeConversationState(
            rootPromptIds: rootPromptIds, turns: turns, preserving: preserved
        )

        let action: CursorProto.RunAction
        if let activeIndex, case .user(let active) = context.messages[activeIndex] {
            action = .userMessage(encodeUser(active, messageId: UUID().uuidString))
        } else {
            action = .resume
        }

        return CursorProto.encodeRunRequestMessage(
            conversationState: conversationState,
            action: action,
            modelId: wireModelId,
            modelName: model.name,
            conversationId: conversationId,
            customSystemPrompt: nil
        )
    }

    /// Index of the trailing user message when it carries text or images —
    /// that message becomes the action. `nil` means resume (context ends in
    /// assistant/tool-result messages, or the trailing user message is empty).
    private static func activeUserMessageIndex(_ messages: [Message]) -> Int? {
        guard case .user(let u)? = messages.last else { return nil }
        guard !userText(u).isEmpty || !userImages(u).isEmpty else { return nil }
        return messages.count - 1
    }

    // MARK: - Content extraction

    private static func userText(_ u: UserMessage) -> String {
        u.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func userImages(_ u: UserMessage) -> [ImageContent] {
        u.content.compactMap { block -> ImageContent? in
            if case .image(let i) = block { return i }
            return nil
        }
    }

    private static func assistantText(_ a: AssistantMessage) -> String {
        a.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined(separator: "\n")
    }

    private static func toolResultText(_ tr: ToolResultMessage) -> String {
        tr.content.compactMap { block -> String? in
            switch block {
            case .text(let t): return t.text
            case .image(let i): return "[\(i.mimeType) image]"
            }
        }.joined(separator: "\n")
    }

    private static func encodeUser(_ u: UserMessage, messageId: String) -> Data {
        CursorProto.encodeUserMessage(
            text: userText(u),
            messageId: messageId,
            images: userImages(u).compactMap { image in
                guard let data = Data(base64Encoded: image.data) else { return nil }
                return CursorProto.UserImage(
                    uuid: deterministicUuid("img:\(image.data.prefix(64)):\(image.mimeType)"),
                    mimeType: image.mimeType,
                    data: data
                )
            }
        )
    }

    // MARK: - History builders

    /// `rootPromptMessagesJson` blob IDs: the system prompt followed by one
    /// JSON blob per prior message in Cursor's Vercel-AI-SDK-shaped format.
    /// The active user message is excluded — it rides in the action.
    private static func buildRootPromptIds(
        _ messages: [Message], activeIndex: Int?, systemId: Data, blobStore: CursorBlobStore
    ) -> [Data] {
        var ids: [Data] = [systemId]
        for (i, message) in messages.enumerated() {
            if i == activeIndex { break }
            switch message {
            case .user(let u):
                var parts: [[String: Any]] = []
                let text = userText(u)
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                for image in userImages(u) {
                    parts.append(["type": "image", "image": image.data, "mediaType": image.mimeType])
                }
                if parts.isEmpty { continue }
                ids.append(storeJSONBlob(["role": "user", "content": parts], in: blobStore))
            case .assistant(let a):
                let text = assistantText(a)
                if text.isEmpty { continue }
                ids.append(storeJSONBlob(
                    ["role": "assistant", "content": [["type": "text", "text": text]]],
                    in: blobStore
                ))
            case .toolResult(let tr):
                let text = toolResultText(tr)
                if text.isEmpty { continue }
                let prefix = tr.isError ? "[Tool Error]" : "[Tool Result]"
                ids.append(storeJSONBlob(
                    ["role": "user", "content": [["type": "text", "text": "\(prefix)\n\(text)"]]],
                    in: blobStore
                ))
            }
        }
        return ids
    }

    /// Serialize prior messages into `ConversationTurnStructure` blob IDs. Each
    /// turn is a user message followed by the assistant's steps (assistant text
    /// and tool results, folded into assistant-message steps). Message ids are
    /// deterministic so unchanged history re-encodes to identical blob IDs and
    /// stays cached server-side.
    private static func buildTurns(
        _ messages: [Message], activeIndex: Int?, blobStore: CursorBlobStore
    ) -> [Data] {
        var turns: [Data] = []
        var i = 0
        while i < messages.count {
            guard case .user(let u) = messages[i] else { i += 1; continue }
            if i == activeIndex { break }

            let text = userText(u)
            let images = userImages(u)
            if text.isEmpty && images.isEmpty { i += 1; continue }
            let contentKey = "\(text)|\(images.map { "\($0.mimeType):\($0.data.prefix(64))" }.joined())"
            let userMessage = encodeUser(
                u, messageId: deterministicUuid("u:\(turns.count):\(contentKey)")
            )
            let userMessageId = blobStore.store(userMessage)

            var stepIds: [Data] = []
            i += 1
            while i < messages.count {
                if case .user = messages[i] { break }
                switch messages[i] {
                case .assistant(let a):
                    let t = assistantText(a)
                    if !t.isEmpty {
                        stepIds.append(blobStore.store(CursorProto.encodeAssistantStep(text: t)))
                    }
                case .toolResult(let tr):
                    let t = toolResultText(tr)
                    if !t.isEmpty {
                        let prefix = tr.isError ? "[Tool Error]" : "[Tool Result]"
                        stepIds.append(blobStore.store(
                            CursorProto.encodeAssistantStep(text: "\(prefix)\n\(t)")
                        ))
                    }
                case .user:
                    break
                }
                i += 1
            }
            turns.append(blobStore.store(
                CursorProto.encodeAgentTurn(userMessage: userMessageId, steps: stepIds)
            ))
        }
        return turns
    }

    // MARK: - Blob helpers

    private static func storeJSONBlob(_ object: [String: Any], in blobStore: CursorBlobStore) -> Data {
        // Sorted keys keep blob bytes (and thus blob IDs) stable across
        // requests so the server-side blob cache can hit.
        let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return blobStore.store(json)
    }

    /// A stable UUID-formatted string derived from `seed`, so re-encoding
    /// unchanged history produces byte-identical blobs.
    static func deterministicUuid(_ seed: String) -> String {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        func hex(_ range: Range<Int>) -> String {
            digest[range].map { String(format: "%02x", $0) }.joined()
        }
        return "\(hex(0..<4))-\(hex(4..<6))-\(hex(6..<8))-\(hex(8..<10))-\(hex(10..<16))"
    }
}
