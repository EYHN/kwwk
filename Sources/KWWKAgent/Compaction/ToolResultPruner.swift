import Foundation
import KWWKAI

/// Clears old tool results from the summary request's input (never from
/// native compaction, which shares the live prompt's cached prefix). Outside
/// the newest `protectedTokens`, a successful result of at least
/// `minimumCharacters` becomes one line naming the call, its first line and
/// its size. Deterministic, so a retry or resume sends the same bytes.
enum ToolResultPruner {
    static let protectedTokens = 60_000
    static let minimumCharacters = 1_000

    static func prune(_ messages: [Message]) -> [Message] {
        var calls: [String: ToolCall] = [:]
        for case .assistant(let assistant) in messages {
            for case .toolCall(let call) in assistant.content { calls[call.id] = call }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var output = messages
        var tokensAfter = 0
        for index in messages.indices.reversed() {
            defer { tokensAfter += ContextTokenEstimator.estimate(message: messages[index]) }
            guard tokensAfter >= protectedTokens, case .toolResult(var result) = messages[index],
                  !result.isError else { continue }
            let text = result.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined(separator: "\n")
            guard text.count >= minimumCharacters else { continue }
            let arguments = calls[result.toolCallId].flatMap { call in
                (try? encoder.encode(call.arguments)).map { String(decoding: $0, as: UTF8.self) }
            } ?? ""
            let firstLine = text.prefix { !$0.isNewline }
            result.content = [.text(TextContent(text: "[tool result cleared: \(result.toolName)"
                + "(\(arguments.prefix(80))) returned \(text.count) chars; first line: \(firstLine.prefix(100))]"))]
            output[index] = .toolResult(result)
        }
        return output
    }
}
