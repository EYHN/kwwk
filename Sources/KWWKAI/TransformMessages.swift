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
    public static func normalize(_ messages: [Message], model: Model) -> [Message] {
        var result = downgradeUnsupportedImages(messages, model: model)
        result = stripCrossModelThinking(result, model: model)
        result = sanitizeSurrogates(result)
        result = repairToolFlow(result)
        return result
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
            case .assistant:
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
    public static func stripCrossModelThinking(_ messages: [Message], model: Model) -> [Message] {
        messages.map { message in
            guard case .assistant(var a) = message else { return message }
            let isSameModel = a.provider == model.provider && a.api == model.api && a.model == model.id
            if isSameModel { return message }

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
                }
            }
            a.content = newContent
            return .assistant(a)
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
                    case .toolCall:
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

    /// Skip errored/aborted assistant turns and balance tool calls with
    /// results: synthesize placeholder tool results for orphaned tool calls and
    /// drop tool results whose originating tool call was removed.
    public static func repairToolFlow(_ messages: [Message]) -> [Message] {
        var result: [Message] = []
        var pendingToolCalls: [ToolCall] = []
        var existingResultIds = Set<String>()
        // Tool-call ids that survived into `result` (so we can drop orphaned
        // tool results whose assistant turn was skipped).
        var liveToolCallIds = Set<String>()

        func flushSynthetic() {
            guard !pendingToolCalls.isEmpty else { return }
            for tc in pendingToolCalls where !existingResultIds.contains(tc.id) {
                result.append(.toolResult(ToolResultMessage(
                    toolCallId: tc.id,
                    toolName: tc.name,
                    content: [.text(TextContent(text: "No result provided"))],
                    isError: true
                )))
            }
            pendingToolCalls = []
            existingResultIds = []
        }

        for message in messages {
            switch message {
            case .assistant(let a):
                flushSynthetic()
                // (c) Skip incomplete turns that must not be replayed verbatim.
                if a.stopReason == .error || a.stopReason == .aborted {
                    continue
                }
                let toolCalls: [ToolCall] = a.content.compactMap {
                    if case .toolCall(let tc) = $0 { return tc } else { return nil }
                }
                if !toolCalls.isEmpty {
                    pendingToolCalls = toolCalls
                    existingResultIds = []
                    for tc in toolCalls { liveToolCallIds.insert(tc.id) }
                }
                result.append(message)
            case .toolResult(let r):
                // (d) Drop tool results orphaned by a skipped assistant turn.
                if !liveToolCallIds.contains(r.toolCallId) {
                    continue
                }
                existingResultIds.insert(r.toolCallId)
                result.append(message)
            case .user:
                flushSynthetic()
                result.append(message)
            }
        }
        flushSynthetic()
        return result
    }
}
