import Foundation
import KWWKAI

/// Which tool results `ToolResultPruner` may clear.
public struct ToolResultPrunePolicy: Sendable, Equatable {
    /// Results within this many estimated tokens of the end of the messages
    /// are kept verbatim.
    public var protectRecentTokens: Int
    /// Results whose text is shorter than this are kept: the placeholder
    /// would save little.
    public var minimumCharacters: Int
    /// Tools whose results are always kept: a person's messages and a
    /// subagent's report are conversation, not reproducible output.
    public var exemptTools: Set<String>

    public init(
        protectRecentTokens: Int = 60_000,
        minimumCharacters: Int = 1_000,
        exemptTools: Set<String> = ["agent", "bot_read_message"]
    ) {
        self.protectRecentTokens = protectRecentTokens
        self.minimumCharacters = minimumCharacters
        self.exemptTools = exemptTools
    }
}

/// Replaces old tool results with a one-line placeholder naming the call,
/// its key argument, the first line and the original size. Pure: the same
/// messages and policy always give byte-identical output, so a pruned
/// transcript is stable across retries and resumes.
///
/// Kept: error results, exempt tools, `read`s of skill documents, results
/// already pruned, and every result within the protected recent window.
public enum ToolResultPruner {
    public static let placeholderPrefix = "[tool result cleared to save context"

    public struct Report: Sendable, Equatable {
        public var prunedCount = 0
        /// Characters of tool-result text removed, net of placeholders.
        public var savedCharacters = 0
    }

    public static func prune(
        _ messages: [Message],
        policy: ToolResultPrunePolicy = .init()
    ) -> (messages: [Message], report: Report) {
        var report = Report()
        var calls: [String: ToolCall] = [:]
        for case .assistant(let assistant) in messages {
            for case .toolCall(let call) in assistant.content { calls[call.id] = call }
        }
        var output = messages
        var tokensAfter = 0
        for index in messages.indices.reversed() {
            defer { tokensAfter += ContextTokenEstimator.estimate(message: messages[index]) }
            guard tokensAfter >= policy.protectRecentTokens,
                  case .toolResult(var result) = messages[index],
                  !result.isError,
                  !policy.exemptTools.contains(result.toolName) else { continue }
            let text = result.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined(separator: "\n")
            guard text.count >= policy.minimumCharacters,
                  !text.hasPrefix(placeholderPrefix) else { continue }
            let call = calls[result.toolCallId]
            if result.toolName == "read", let path = call.flatMap({ stringArgument($0, "path") }),
               path.hasSuffix("SKILL.md") { continue }
            let line = placeholder(toolName: result.toolName, call: call, text: text)
            var rebuilt: [ToolResultBlock] = [.text(TextContent(text: line))]
            for block in result.content {
                if case .image = block { rebuilt.append(block) }
            }
            result.content = rebuilt
            output[index] = .toolResult(result)
            report.prunedCount += 1
            report.savedCharacters += text.count - line.count
        }
        return (output, report)
    }

    static func placeholder(toolName: String, call: ToolCall?, text: String) -> String {
        let argument = call.flatMap(keyArgument).map { "(\(clipped($0, 80)))" } ?? ""
        let firstLine = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return "\(placeholderPrefix) — \(toolName)\(argument) returned \(text.count) chars; "
            + "first line: \"\(clipped(firstLine, 100))\". Re-run the tool if you need it.]"
    }

    private static let keyArgumentNames = [
        "command", "path", "file_path", "pattern", "url", "query", "task_id", "id",
    ]

    private static func keyArgument(_ call: ToolCall) -> String? {
        for name in keyArgumentNames {
            if let value = stringArgument(call, name), !value.isEmpty { return value }
        }
        guard case .object(let arguments) = call.arguments else { return nil }
        for key in arguments.keys.sorted() {
            if case .string(let value)? = arguments[key], !value.isEmpty { return value }
        }
        return nil
    }

    private static func stringArgument(_ call: ToolCall, _ name: String) -> String? {
        guard case .object(let arguments) = call.arguments,
              case .string(let value)? = arguments[name] else { return nil }
        return value
    }

    /// One line, at most `limit` characters, with an ellipsis when cut.
    private static func clipped(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}
