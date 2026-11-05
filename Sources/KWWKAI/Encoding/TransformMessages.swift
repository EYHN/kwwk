import Crypto
import Foundation

/// Shared message-normalization pre-encode pass.
///
/// Ported from pi's `packages/ai/src/api/transform-messages.ts`. These passes
/// run across every provider before a transcript is encoded into a request
/// body, smoothing over cross-model replay hazards that otherwise produce hard
/// 400s. Each pass is exposed as a pure, independently testable function and
/// composed by ``normalize(_:model:)``.
public enum TransformMessages {
    static let nonVisionUserImagePlaceholder = "(image omitted: model does not support images)"
    static let nonVisionToolImagePlaceholder = "(tool image omitted: model does not support images)"

    /// Run every pass in order and return the normalized transcript.
    ///
    /// Order matters: image downgrade and thinking/text stripping operate on
    /// per-message content first; surrogate sanitization cleans the resulting
    /// text; the error-skip + orphan-synthesis pass then reshapes the message
    /// sequence so tool calls and tool results stay balanced.
    public static func normalize(
        _ messages: [Message],
        model: Model,
        preserveAnthropicFallback: Bool = false
    ) -> [Message] {
        var result = downgradeUnsupportedImages(expandNativeCompaction(messages, model: model), model: model)
        result = stripCrossModelThinking(result, model: model, preserveAnthropicFallback: preserveAnthropicFallback)
        result = fillEmptyToolCallIds(result)
        result = dropUnnamedToolCalls(result)
        result = normalizeToolCallIds(result, model: model)
        result = uniquifyToolCallIds(result, model: model)
        result = sanitizeSurrogates(result)
        result = repairToolFlow(result)
        return result
    }

    /// A foreign provider cannot read Codex's encrypted summary. Restore its
    /// source prefix so normal context management can summarize it for that model.
    public static func expandNativeCompaction(_ messages: [Message], model: Model? = nil) -> [Message] {
        messages.flatMap { message -> [Message] in
            guard case .user(var user) = message, let native = user.nativeCompaction,
                  model.map({ !native.canReplay(with: $0) }) ?? true else { return [message] }
            if let fallback = native.fallbackMessages { return expandNativeCompaction(fallback) }
            if let summary = native.textSummary {
                // The UI recap can be shorter than the provider's full summary.
                user.content = [.text(TextContent(text: summary))] + user.content
            }
            user.nativeCompaction = nil
            return [.user(user)]
        }
    }

    // MARK: - (a) Image downgrade

    /// Replace image blocks with a text placeholder when the model cannot
    /// accept images. Collapses runs of adjacent images into a single
    /// placeholder, matching pi's behavior.
    public static func downgradeUnsupportedImages(_ messages: [Message], model: Model) -> [Message] {
        if model.input.contains(.image) {
            return messages
        }
        return messages.map { message in
            switch message {
            case .user(var u):
                u.content = replaceUserImages(u.content, placeholder: nonVisionUserImagePlaceholder)
                return .user(u)
            case .toolResult(var t):
                t.content = replaceToolImages(t.content, placeholder: nonVisionToolImagePlaceholder)
                return .toolResult(t)
            case .assistant, .system:
                return message
            }
        }
    }

    private static func replaceUserImages(_ content: [UserBlock], placeholder: String) -> [UserBlock] {
        var result: [UserBlock] = []
        var previousWasPlaceholder = false
        for block in content {
            switch block {
            case .image:
                if !previousWasPlaceholder {
                    result.append(.text(TextContent(text: placeholder)))
                }
                previousWasPlaceholder = true
            case .text(let t):
                result.append(.text(t))
                previousWasPlaceholder = t.text == placeholder
            }
        }
        return result
    }

    private static func replaceToolImages(_ content: [ToolResultBlock], placeholder: String) -> [ToolResultBlock] {
        var result: [ToolResultBlock] = []
        var previousWasPlaceholder = false
        for block in content {
            switch block {
            case .image:
                if !previousWasPlaceholder {
                    result.append(.text(TextContent(text: placeholder)))
                }
                previousWasPlaceholder = true
            case .text(let t):
                result.append(.text(t))
                previousWasPlaceholder = t.text == placeholder
            }
        }
        return result
    }

    // MARK: - (b) Cross-model thinking strip

    /// Strip thinking blocks (and empty thinking signatures) when replaying an
    /// assistant turn to a model that did not produce it.
    ///
    /// - Same model: thinking blocks pass through untouched (signatures are
    ///   needed for replay, even when the thinking text is empty).
    /// - Cross model: redacted thinking is opaque encrypted content and is
    ///   dropped entirely; non-empty thinking is downgraded to plain text;
    ///   empty thinking is dropped.
    public static func stripCrossModelThinking(
        _ messages: [Message],
        model: Model,
        preserveAnthropicFallback: Bool = false
    ) -> [Message] {
        messages.map { message in
            guard case .assistant(var a) = message else { return message }
            let isSameModel = a.provider == model.provider && a.api == model.api
                && (a.responseModel ?? a.model) == model.id
            let preserveFallback = preserveAnthropicFallback && a.provider == model.provider
                && a.api == "anthropic-messages" && model.api == a.api
            if preserveFallback { return message }
            if isSameModel {
                a.content.removeAll { if case .fallback = $0 { return true }; return false }
                return .assistant(a)
            }

            var newContent: [AssistantBlock] = []
            for block in a.content {
                switch block {
                case .thinking(let th):
                    if th.redacted == true {
                        // Drop opaque encrypted reasoning cross-model.
                        continue
                    }
                    let trimmed = th.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        continue
                    }
                    // Downgrade reasoning text to a plain text block.
                    newContent.append(.text(TextContent(text: th.thinking)))
                case .toolCall(let tc):
                    // Thought signatures are model-specific; drop them cross-model.
                    if tc.thoughtSignature != nil {
                        var stripped = tc
                        stripped.thoughtSignature = nil
                        newContent.append(.toolCall(stripped))
                    } else {
                        newContent.append(.toolCall(tc))
                    }
                case .text(let t):
                    newContent.append(.text(t))
                case .fallback: break
                }
            }
            a.content = newContent
            return .assistant(a)
        }
    }

    // MARK: - Tool-call id normalization

    /// Normalize a single foreign tool-call id so any target accepts it,
    /// without ever sending two distinct ids as one:
    /// - Pipe-delimited ids (Responses-API origin) keep only the segment before
    ///   the first `|` (pi's `normalizeToolCallId`); that segment is the call's
    ///   own `call_id`.
    /// - An id of `[a-zA-Z0-9_-]` only, within the target's length, goes as
    ///   it is.
    /// - Any other id (Devin's `Bash:0#…`, Kimi's `functions.read:0`, a
    ///   relay's) is `idMark` and its unpadded base64url, which Anthropic's
    ///   `^[a-zA-Z0-9_-]+$` takes and which maps distinct ids to distinct
    ///   ones. Replacing each bad char with `_` sent `Bash:0#ab` and
    ///   `Bash.0#ab` as the same id, and their results crossed (magpie
    ///   `safeCallID`, #1304). A safe id that already begins with a mark is
    ///   encoded too, so no id can pass for another's rewrite.
    /// - An id still longer than the target allows (40 for `openai` and
    ///   Responses-origin ids, else 64, Bedrock's and Codex's cap) is
    ///   `hashMark` and its SHA-256, cut to the limit, instead of a plain
    ///   prefix, which collapsed ids that differ only past the cut.
    /// The mapping keeps no state, so a call and its result always agree.
    static func normalizeId(_ id: String, model: Model) -> String {
        let callId = id.firstIndex(of: "|").map { String(id[..<$0]) } ?? id
        let limit = id.contains("|") || model.provider == "openai" ? 40 : 64
        let marked = callId.hasPrefix(idMark) || callId.hasPrefix(hashMark)
        if isSafeId(callId), !marked, callId.count <= limit {
            return callId
        }
        if !isSafeId(callId) || marked {
            let encoded = idMark + base64URL(Data(callId.utf8))
            if encoded.count <= limit { return encoded }
        }
        let digest = SHA256.hash(data: Data(callId.utf8)).map { String(format: "%02x", $0) }.joined()
        return hashMark + String(digest.prefix(limit - hashMark.count))
    }

    /// Prefix of a tool-call id `normalizeId` base64url-encoded.
    static let idMark = "kw_"
    /// Prefix of a tool-call id `normalizeId` hashed to fit a length limit.
    static let hashMark = "kwh_"

    /// Whether `id` matches Anthropic's `^[a-zA-Z0-9_-]+$`.
    static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Normalize tool-call ids on cross-model assistant turns and propagate the
    /// rewrite to the corresponding tool-result messages via a shared id map.
    /// Mirrors pi: only cross-model tool calls are rewritten.
    public static func normalizeToolCallIds(_ messages: [Message], model: Model) -> [Message] {
        var idMap: [String: String] = [:]
        return messages.map { message in
            switch message {
            case .assistant(var a):
                let isSameModel = a.provider == model.provider && a.api == model.api && a.model == model.id
                if isSameModel { return message }
                a.content = a.content.map { block in
                    guard case .toolCall(var tc) = block else { return block }
                    let newId = normalizeId(tc.id, model: model)
                    if newId != tc.id {
                        idMap[tc.id] = newId
                        tc.id = newId
                    }
                    return .toolCall(tc)
                }
                return .assistant(a)
            case .toolResult(var t):
                if let mapped = idMap[t.toolCallId] {
                    t.toolCallId = mapped
                }
                return .toolResult(t)
            case .user, .system:
                return message
            }
        }
    }

    /// Gives every replayed tool call an id no other call in the transcript
    /// has, and each of its results the same id. Anthropic refuses a request
    /// in which two `tool_use` blocks share an id, and the stored transcript
    /// would then fail on every later turn. Cursor sends one id on each exec
    /// of a single tool (an edit reads, then writes), so a Cursor turn
    /// replayed to another provider held the same id twice (2026-10-26).
    ///
    /// The first call with an id keeps it; a later one becomes `<id>_<n>`
    /// with the lowest free `n`, or `hashMark` and a SHA-256 when that is not
    /// a safe id within the target's length. The results in a turn's span,
    /// up to the next assistant message, go to that turn's calls with the
    /// id in order, a call of the same tool first. The mapping depends only
    /// on the transcript, so it is the same on every request. Errored and
    /// aborted turns are left out, as ``repairToolFlow(_:)`` drops them.
    public static func uniquifyToolCallIds(_ messages: [Message], model: Model) -> [Message] {
        var taken = Set<String>()
        for case .assistant(let a) in messages {
            for case .toolCall(let tc) in a.content { taken.insert(tc.id) }
        }
        var claimed = Set<String>()
        /// This turn's calls by their id before renaming: the id sent and the
        /// tool, in order, each struck off when a result takes it.
        var span: [String: [(id: String, name: String)]] = [:]
        var renamed = false
        let result = messages.map { message -> Message in
            switch message {
            case .assistant(var a):
                span = [:]
                if a.stopReason == .error || a.stopReason == .aborted { return message }
                var changed = false
                a.content = a.content.map { block in
                    guard case .toolCall(var tc) = block else { return block }
                    let original = tc.id
                    if !claimed.insert(original).inserted {
                        tc.id = freshId(for: original, taken: &taken, model: model)
                        claimed.insert(tc.id)
                        changed = true
                    }
                    span[original, default: []].append((tc.id, tc.name))
                    return .toolCall(tc)
                }
                guard changed else { return message }
                renamed = true
                return .assistant(a)
            case .toolResult(var r):
                guard var calls = span[r.toolCallId], !calls.isEmpty else { return message }
                let match = calls.firstIndex { $0.name == r.toolName } ?? 0
                let id = calls.remove(at: match).id
                span[r.toolCallId] = calls
                guard id != r.toolCallId else { return message }
                r.toolCallId = id
                return .toolResult(r)
            case .user, .system:
                return message
            }
        }
        return renamed ? result : messages
    }

    private static func freshId(for id: String, taken: inout Set<String>, model: Model) -> String {
        let limit = model.provider == "openai" ? 40 : 64
        var n = 2
        while true {
            var candidate = "\(id)_\(n)"
            if !isSafeId(candidate) || candidate.count > limit {
                let digest = SHA256.hash(data: Data("\(id)#\(n)".utf8)).map { String(format: "%02x", $0) }.joined()
                candidate = hashMark + String(digest.prefix(limit - hashMark.count))
            }
            if taken.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    /// Gives each tool call stored with an empty id (a session saved before
    /// the Chat decoder minted one, or any other source that sent none) an
    /// id, and each tool result with an empty id the id of the call it
    /// answers: the first call of the turn still unanswered with the same
    /// tool name, else the first one unanswered. The id goes by the call's
    /// place in the transcript, so it is the same on every request. Calls
    /// that share `""` can't otherwise be told apart, and Anthropic refuses
    /// an empty `tool_use.id` outright.
    public static func fillEmptyToolCallIds(_ messages: [Message]) -> [Message] {
        var pending: [(id: String, name: String)] = []
        return messages.enumerated().map { index, message in
            switch message {
            case .assistant(var a):
                pending = []
                guard a.content.contains(where: { if case .toolCall(let tc) = $0 { return tc.id.isEmpty }; return false })
                else { return message }
                a.content = a.content.enumerated().map { position, block in
                    guard case .toolCall(var tc) = block, tc.id.isEmpty else { return block }
                    tc.id = "call_unnamed_\(index)_\(position)"
                    pending.append((tc.id, tc.name))
                    return .toolCall(tc)
                }
                return .assistant(a)
            case .toolResult(var t):
                guard t.toolCallId.isEmpty, !pending.isEmpty else { return message }
                let match = pending.firstIndex { $0.name == t.toolName } ?? 0
                t.toolCallId = pending.remove(at: match).id
                return .toolResult(t)
            case .user, .system:
                return message
            }
        }
    }

    /// Leaves out each tool call stored with an empty name, and its result.
    /// A Chat relay can send a `tool_calls` fragment that never names its
    /// function (OpenRouter's GLM, 2026-09-07); the call ran as "Tool  not
    /// found" and stayed in the transcript, and every provider that checks
    /// the name refuses it on every later turn (Responses: "Invalid
    /// 'input[33].name': empty string"). A turn left with no content goes
    /// too. Runs after ``fillEmptyToolCallIds(_:)`` so the result is found
    /// by the id its call was given.
    public static func dropUnnamedToolCalls(_ messages: [Message]) -> [Message] {
        var dropped = Set<String>()
        return messages.compactMap { message in
            switch message {
            case .assistant(var a):
                let kept = a.content.filter { block in
                    guard case .toolCall(let tc) = block, tc.name.isEmpty else { return true }
                    dropped.insert(tc.id)
                    return false
                }
                guard kept.count != a.content.count else { return message }
                guard !kept.isEmpty else { return nil }
                a.content = kept
                return .assistant(a)
            case .toolResult(let t):
                return dropped.contains(t.toolCallId) ? nil : message
            case .user, .system:
                return message
            }
        }
    }

    // MARK: - (e) Surrogate sanitization

    /// Replace lone UTF-16 surrogate code units in text blocks with the Unicode
    /// replacement character. Swift `String` cannot natively hold a lone
    /// surrogate, but text decoded from upstream JSON may contain the literal
    /// replacement scalar or escaped sequences; this pass guards against any
    /// remaining unpaired surrogate scalars before encoding.
    public static func sanitizeSurrogates(_ messages: [Message]) -> [Message] {
        messages.map { message in
            switch message {
            case .user(var u):
                u.content = u.content.map { block in
                    if case .text(var t) = block {
                        t.text = sanitize(t.text)
                        return .text(t)
                    }
                    return block
                }
                return .user(u)
            case .assistant(var a):
                a.content = a.content.map { block in
                    switch block {
                    case .text(var t):
                        t.text = sanitize(t.text)
                        return .text(t)
                    case .thinking(var th):
                        th.thinking = sanitize(th.thinking)
                        return .thinking(th)
                    case .toolCall, .fallback:
                        return block
                    }
                }
                return .assistant(a)
            case .toolResult(var r):
                r.content = r.content.map { block in
                    if case .text(var t) = block {
                        t.text = sanitize(t.text)
                        return .text(t)
                    }
                    return block
                }
                return .toolResult(r)
            case .system:
                return message
            }
        }
    }

    /// Replace any lone surrogate scalars with U+FFFD.
    static func sanitize(_ text: String) -> String {
        var changed = false
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if (0xD800...0xDFFF).contains(scalar.value) {
                scalars.append(Unicode.Scalar(0xFFFD)!)
                changed = true
            } else {
                scalars.append(scalar)
            }
        }
        return changed ? String(scalars) : text
    }

    // MARK: - (c)+(d) Error-turn skip & tool-flow repair

    /// Text of the result synthesized for a tool call that has none.
    static let missingToolResultText = "No result provided"

    /// Skip errored/aborted assistant turns and pair every replayed tool call
    /// with exactly one result, right after its assistant turn.
    ///
    /// A tool-calling turn's span runs to the next assistant message. Within
    /// it, the first result for each of the turn's calls is kept and moved up
    /// to sit directly after the turn, ahead of any user or system message
    /// that landed between them (a steer, a tool declaration, a resume after
    /// a restart mid-tool). A call with no result gets a synthetic error
    /// result. Every other tool result is dropped: a second result for the
    /// same call, a result for another turn's call (ids some providers reuse
    /// per turn), one whose turn was skipped as failed, or one cut loose by
    /// compaction. Providers refuse any of these with a 400 (Anthropic,
    /// OpenAI's "tool messages must follow tool_calls", WorkBuddy's 11148
    /// "tool calls and tool results do not match"), and the transcript would
    /// fail the same way on every later turn.
    public static func repairToolFlow(_ messages: [Message]) -> [Message] {
        var result: [Message] = []
        result.reserveCapacity(messages.count)
        var index = messages.startIndex
        while index < messages.endIndex {
            let message = messages[index]
            index += 1
            switch message {
            case .user, .system:
                result.append(message)
            case .toolResult:
                // Outside any live tool-calling turn's span: it answers nothing.
                continue
            case .assistant(let a):
                // (c) Skip incomplete turns that must not be replayed verbatim.
                if a.stopReason == .error || a.stopReason == .aborted { continue }
                result.append(message)
                var seenCallIds = Set<String>()
                let calls: [ToolCall] = a.content.compactMap {
                    guard case .toolCall(let tc) = $0, seenCallIds.insert(tc.id).inserted else { return nil }
                    return tc
                }
                guard !calls.isEmpty else { continue }
                let spanEnd = messages[index...].firstIndex { $0.role == .assistant } ?? messages.endIndex
                var answered = Set<String>()
                var others: [Message] = []
                for later in messages[index..<spanEnd] {
                    guard case .toolResult(let r) = later else {
                        others.append(later)
                        continue
                    }
                    // (d) Keep only the first result for one of this turn's calls.
                    if seenCallIds.contains(r.toolCallId), answered.insert(r.toolCallId).inserted {
                        result.append(later)
                    }
                }
                for tc in calls where !answered.contains(tc.id) {
                    result.append(.toolResult(ToolResultMessage(
                        toolCallId: tc.id,
                        toolName: tc.name,
                        content: [.text(TextContent(text: missingToolResultText))],
                        isError: true
                    )))
                }
                result.append(contentsOf: others)
                index = spanEnd
            }
        }
        return result
    }
}
