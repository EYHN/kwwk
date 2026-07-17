import Foundation
import KWWKAI

enum CompactionTranscriptSerializer {
    struct Limits: Sendable, Equatable {
        var messageTextBytes: Int
        var thinkingBytes: Int
        var toolArgumentBytes: Int
        var toolResultBytes: Int
        var toolDetailsBytes: Int

        init(
            messageTextBytes: Int = 12_000,
            thinkingBytes: Int = 8_000,
            toolArgumentBytes: Int = 4_000,
            toolResultBytes: Int = 4_000,
            toolDetailsBytes: Int = 2_000
        ) {
            self.messageTextBytes = messageTextBytes
            self.thinkingBytes = thinkingBytes
            self.toolArgumentBytes = toolArgumentBytes
            self.toolResultBytes = toolResultBytes
            self.toolDetailsBytes = toolDetailsBytes
        }
    }

    static func serialize(
        _ messages: [Message],
        startingAt baseIndex: Int = 0,
        limits: Limits = .init(),
        maxTokens: Int? = nil
    ) -> String {
        let records = messages.enumerated().map { offset, message in
            record(
                for: message,
                index: baseIndex + offset,
                limits: limits
            )
        }
        let serialized = records.compactMap { record in
            guard let data = try? encoder().encode(record) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        guard let maxTokens,
              ContextTokenEstimator.estimate(text: serialized) > maxTokens else {
            return serialized
        }
        return globallyBounded(
            serialized,
            records: records,
            maxTokens: max(1, maxTokens)
        )
    }

    private static func globallyBounded(
        _ serialized: String,
        records: [TranscriptRecord],
        maxTokens: Int
    ) -> String {
        let originalTokens = ContextTokenEstimator.estimate(text: serialized)
        let outline = records.compactMap { record -> String? in
            guard let data = try? encoder().encode(record.semanticOutline),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        }.joined(separator: "\n")

        // Preserve the identity and outcome of every record whenever that
        // semantic outline fits. The remaining budget is spent on a head/tail
        // preview of the detailed JSONL instead of replacing the whole group
        // with one opaque elision record.
        if !outline.isEmpty,
           ContextTokenEstimator.estimate(text: outline) <= maxTokens {
            var lowerBound = 0
            var upperBound = serialized.utf8.count
            var best = outline
            while lowerBound <= upperBound {
                let candidateLimit = lowerBound + (upperBound - lowerBound) / 2
                let preview = bounded(serialized, byteLimit: candidateLimit)
                let elision = encodedElision(
                    recordCount: records.count,
                    originalTokens: originalTokens,
                    preview: preview
                )
                let candidate = outline + "\n" + elision
                if ContextTokenEstimator.estimate(text: candidate) <= maxTokens {
                    best = candidate
                    lowerBound = candidateLimit + 1
                } else {
                    upperBound = candidateLimit - 1
                }
            }
            return best
        }

        var lowerBound = 0
        var upperBound = serialized.utf8.count
        var best = encodedElision(
            recordCount: records.count,
            originalTokens: originalTokens,
            preview: nil
        )

        if ContextTokenEstimator.estimate(text: best) > maxTokens {
            let minimal = #"{"role":"transcriptElision"}"#
            return ContextTokenEstimator.estimate(text: minimal) <= maxTokens ? minimal : "{}"
        }

        while lowerBound <= upperBound {
            let candidateLimit = lowerBound + (upperBound - lowerBound) / 2
            let preview = bounded(serialized, byteLimit: candidateLimit)
            let candidate = encodedElision(
                recordCount: records.count,
                originalTokens: originalTokens,
                preview: preview
            )
            if ContextTokenEstimator.estimate(text: candidate) <= maxTokens {
                best = candidate
                lowerBound = candidateLimit + 1
            } else {
                upperBound = candidateLimit - 1
            }
        }
        return best
    }

    private static func encodedElision(
        recordCount: Int,
        originalTokens: Int,
        preview: String?
    ) -> String {
        let record = TranscriptElisionRecord(
            omittedRecords: recordCount,
            originalEstimatedTokens: originalTokens,
            headAndTailPreview: preview
        )
        guard let data = try? encoder().encode(record),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"role":"transcriptElision"}"#
        }
        return text
    }

    private static func record(
        for message: Message,
        index: Int,
        limits: Limits
    ) -> TranscriptRecord {
        switch message {
        case .user(let user):
            let text = user.content.compactMap { block -> String? in
                if case .text(let text) = block {
                    return bounded(text.text, byteLimit: limits.messageTextBytes)
                }
                return nil
            }
            let images = user.content.compactMap { block -> ImageRecord? in
                guard case .image(let image) = block else { return nil }
                return ImageRecord(mimeType: image.mimeType, encodedBytes: image.data.utf8.count)
            }
            return TranscriptRecord(
                index: index,
                role: "user",
                text: text.nilIfEmpty,
                images: images.nilIfEmpty
            )

        case .assistant(let assistant):
            var text: [String] = []
            var thinking: [String] = []
            var calls: [ToolCallRecord] = []
            for block in assistant.content {
                switch block {
                case .text(let content):
                    if !content.text.isEmpty {
                        text.append(bounded(content.text, byteLimit: limits.messageTextBytes))
                    }
                case .thinking(let content):
                    if !content.thinking.isEmpty {
                        thinking.append(bounded(content.thinking, byteLimit: limits.thinkingBytes))
                    }
                case .toolCall(let call):
                    calls.append(ToolCallRecord(
                        id: call.id,
                        name: call.name,
                        argumentsJSON: boundedJSON(call.arguments, byteLimit: limits.toolArgumentBytes)
                    ))
                }
            }
            return TranscriptRecord(
                index: index,
                role: "assistant",
                text: text.nilIfEmpty,
                thinking: thinking.nilIfEmpty,
                toolCalls: calls.nilIfEmpty,
                stopReason: assistant.stopReason.rawValue,
                errorMessage: assistant.errorMessage
            )

        case .toolResult(let result):
            let text = result.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined(separator: "\n")
            let images = result.content.compactMap { block -> ImageRecord? in
                guard case .image(let image) = block else { return nil }
                return ImageRecord(mimeType: image.mimeType, encodedBytes: image.data.utf8.count)
            }
            return TranscriptRecord(
                index: index,
                role: "toolResult",
                text: text.isEmpty ? nil : [bounded(text, byteLimit: limits.toolResultBytes)],
                images: images.nilIfEmpty,
                toolCallId: result.toolCallId,
                toolName: result.toolName,
                isError: result.isError,
                detailsJSON: result.details.map {
                    boundedJSON(modelFacingJSON($0), byteLimit: limits.toolDetailsBytes)
                }
            )
        }
    }

    static func bounded(_ text: String, byteLimit: Int) -> String {
        guard byteLimit >= 0, text.utf8.count > byteLimit else { return text }
        guard byteLimit > 0 else {
            return "[content elided; original UTF-8 bytes: \(text.utf8.count)]"
        }

        let originalBytes = text.utf8.count
        let marker = "\n... [middle elided; original UTF-8 bytes: \(originalBytes)] ...\n"
        let payloadBudget = max(0, byteLimit - marker.utf8.count)
        let headBudget = payloadBudget / 2
        let tailBudget = payloadBudget - headBudget
        let head = prefix(text, fittingUTF8Bytes: headBudget)
        let tail = suffix(text, fittingUTF8Bytes: tailBudget)
        return head + marker + tail
    }

    private static func boundedJSON(_ value: JSONValue, byteLimit: Int) -> String {
        guard let data = try? encoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return bounded(text, byteLimit: byteLimit)
    }

    private static func prefix(_ text: String, fittingUTF8Bytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            let bytes = text[index..<next].utf8.count
            if used + bytes > limit { break }
            used += bytes
            end = next
        }
        return String(text[..<end])
    }

    private static func suffix(_ text: String, fittingUTF8Bytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        var used = 0
        var start = text.endIndex
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let bytes = text[previous..<index].utf8.count
            if used + bytes > limit { break }
            used += bytes
            start = previous
            index = previous
        }
        return String(text[start...])
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct TranscriptRecord: Encodable {
    let index: Int
    let role: String
    var text: [String]?
    var images: [ImageRecord]?
    var thinking: [String]?
    var toolCalls: [ToolCallRecord]?
    var toolCallId: String?
    var toolName: String?
    var isError: Bool?
    var detailsJSON: String?
    var stopReason: String?
    var errorMessage: String?
    var fieldsElided: Bool?

    init(
        index: Int,
        role: String,
        text: [String]? = nil,
        images: [ImageRecord]? = nil,
        thinking: [String]? = nil,
        toolCalls: [ToolCallRecord]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        isError: Bool? = nil,
        detailsJSON: String? = nil,
        stopReason: String? = nil,
        errorMessage: String? = nil,
        fieldsElided: Bool? = nil
    ) {
        self.index = index
        self.role = role
        self.text = text
        self.images = images
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.isError = isError
        self.detailsJSON = detailsJSON
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.fieldsElided = fieldsElided
    }

    var semanticOutline: TranscriptRecord {
        TranscriptRecord(
            index: index,
            role: role,
            toolCalls: toolCalls?.map(\.semanticOutline),
            toolCallId: toolCallId,
            toolName: toolName,
            isError: isError,
            stopReason: stopReason,
            errorMessage: errorMessage.map {
                CompactionTranscriptSerializer.bounded($0, byteLimit: 256)
            },
            fieldsElided: true
        )
    }
}

private struct TranscriptElisionRecord: Encodable {
    let role = "transcriptElision"
    let omittedRecords: Int
    let originalEstimatedTokens: Int
    let headAndTailPreview: String?
}

private struct ImageRecord: Encodable {
    let mimeType: String
    let encodedBytes: Int
}

private struct ToolCallRecord: Encodable {
    let id: String
    let name: String
    let argumentsJSON: String?

    var semanticOutline: ToolCallRecord {
        ToolCallRecord(id: id, name: name, argumentsJSON: nil)
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
