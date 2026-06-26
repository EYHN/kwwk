import Foundation

/// Mistral provider (`mistral-conversations` API). Mistral's `/v1/chat/completions`
/// endpoint is OpenAI-chat-compatible, so we delegate request encoding and SSE
/// parsing to `OpenAICompletionsProvider`. The one hard requirement Mistral adds
/// is that every tool-call id be exactly 9 alphanumeric characters and that the
/// assistant `tool_call.id` match the corresponding `tool_result.tool_call_id`.
/// We normalize ids consistently across the whole transcript before encoding.
///
/// Reasoning: Mistral's REST chat endpoint does not accept `reasoning_effort`
/// (magistral models reason automatically), so the hint is stripped before
/// delegating to avoid hard 400s.
public final class MistralConversationsProvider: APIProvider, @unchecked Sendable {
    public let api: String
    private let inner: OpenAICompletionsProvider

    public init(
        api: String = "mistral-conversations",
        client: HTTPClient = URLSessionHTTPClient(),
        defaultAPIKey: String? = nil
    ) {
        self.api = api
        self.inner = OpenAICompletionsProvider(
            api: api,
            client: client,
            defaultBaseURL: URL(string: "https://api.mistral.ai")!,
            defaultAPIKey: defaultAPIKey
        )
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        var newContext = context
        newContext.messages = Self.normalizeToolIds(context.messages)
        var opts = options
        opts?.reasoning = nil
        return inner.stream(model: model, context: newContext, options: opts)
    }

    // MARK: - Tool-call id normalization

    static let toolCallIdLength = 9

    /// Rewrite every tool-call id (and matching tool-result id) to a 9-char
    /// alphanumeric value, keeping the same original id mapped to the same
    /// candidate so call/result pairs stay linked.
    static func normalizeToolIds(_ messages: [Message]) -> [Message] {
        var idMap: [String: String] = [:]
        var used: Set<String> = []

        func mapId(_ id: String) -> String {
            if let existing = idMap[id] { return existing }
            var attempt = 0
            while true {
                let candidate = derive(id, attempt: attempt)
                if !used.contains(candidate) {
                    idMap[id] = candidate
                    used.insert(candidate)
                    return candidate
                }
                attempt += 1
            }
        }

        return messages.map { message in
            switch message {
            case .assistant(var a):
                a.content = a.content.map { block in
                    if case .toolCall(var tc) = block {
                        tc.id = mapId(tc.id)
                        return .toolCall(tc)
                    }
                    return block
                }
                return .assistant(a)
            case .toolResult(var tr):
                tr.toolCallId = mapId(tr.toolCallId)
                return .toolResult(tr)
            case .user:
                return message
            }
        }
    }

    /// Ported from pi `deriveMistralToolCallId`: keep an already-valid 9-char
    /// alphanumeric id as-is; otherwise hash a (seed[:attempt]) to 9 chars.
    static func derive(_ id: String, attempt: Int) -> String {
        // ASCII alphanumerics only, matching pi's `[^a-zA-Z0-9]` strip — Swift's
        // `isLetter`/`isNumber` would keep Unicode letters/digits that Mistral
        // rejects in a tool-call id.
        let normalized = String(id.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        if attempt == 0, normalized.count == toolCallIdLength { return normalized }
        let seedBase = normalized.isEmpty ? id : normalized
        let seed = attempt == 0 ? seedBase : "\(seedBase):\(attempt)"
        return shortHash(seed)
    }

    /// Deterministic 9-char alphanumeric hash (FNV-1a 64-bit, base36-ish).
    static func shortHash(_ s: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        var v = h
        var out = ""
        for _ in 0..<toolCallIdLength {
            out.append(alphabet[Int(v % 36)])
            v = (v / 36) ^ (v &<< 7)   // remix so trailing chars don't collapse to 0
        }
        return out
    }
}
