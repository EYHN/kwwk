import Foundation
import KWWKAI

struct CompactionFileFacts: Sendable, Equatable {
    var readPaths: Set<String> = []
    var modifiedPaths: Set<String> = []

    var isEmpty: Bool {
        readPaths.isEmpty && modifiedPaths.isEmpty
    }
}

enum CompactionFactsExtractor {
    /// Enough room for a substantial working set while keeping repeated
    /// compactions from growing the recap without bound.
    static let maximumRenderedFacts = 256
    static let maximumRenderedBytes = 32 * 1_024

    private static let openTag = "<file-operations>"
    private static let closeTag = "</file-operations>"

    static func extract(from messages: [Message]) -> CompactionFileFacts {
        var facts = CompactionFileFacts()
        var pendingOperations: [String: (name: String, path: String)] = [:]

        for message in messages {
            switch message {
            case .assistant(let assistant):
                for block in assistant.content {
                    guard case .toolCall(let call) = block,
                          let path = pathArgument(from: call.arguments),
                          isTrackedOperation(call.name) else {
                        continue
                    }
                    pendingOperations[call.id] = (call.name.lowercased(), path)
                }

            case .toolResult(let result):
                guard let operation = pendingOperations.removeValue(forKey: result.toolCallId),
                      !result.isError else {
                    continue
                }
                switch operation.name {
                case "read":
                    facts.readPaths.insert(operation.path)
                case "write", "edit":
                    facts.modifiedPaths.insert(operation.path)
                default:
                    break
                }

            case .user:
                continue
            }
        }
        return facts
    }

    private static func isTrackedOperation(_ name: String) -> Bool {
        switch name.lowercased() {
        case "read", "write", "edit": return true
        default: return false
        }
    }

    static func render(
        _ facts: CompactionFileFacts,
        carryingForwardFrom previousSummary: String?,
        maximumFacts: Int = maximumRenderedFacts,
        maximumBytes: Int = maximumRenderedBytes
    ) -> String? {
        let newLines = Set(
            facts.readPaths.map { "<read path=\"\(escapeXML($0))\" />" }
                + facts.modifiedPaths.map { "<modified path=\"\(escapeXML($0))\" />" }
        )
        let carriedLines = existingLines(in: previousSummary).subtracting(newLines)
        let candidates = newLines.sorted() + carriedLines.sorted()
        let lines = boundedLines(
            candidates,
            maximumFacts: max(0, maximumFacts),
            maximumBytes: max(0, maximumBytes)
        )
        guard !lines.isEmpty else { return nil }
        return """
        \(openTag)
        \(lines.joined(separator: "\n"))
        \(closeTag)
        """
    }

    private static func boundedLines(
        _ candidates: [String],
        maximumFacts: Int,
        maximumBytes: Int
    ) -> [String] {
        var lines: [String] = []
        var renderedBytes = openTag.utf8.count + closeTag.utf8.count + 2

        for line in candidates {
            guard lines.count < maximumFacts else { break }
            let separatorBytes = lines.isEmpty ? 0 : 1
            let addedBytes = separatorBytes + line.utf8.count
            guard renderedBytes + addedBytes <= maximumBytes else { continue }
            lines.append(line)
            renderedBytes += addedBytes
        }
        return lines
    }

    private static func pathArgument(from arguments: JSONValue) -> String? {
        guard case .object(let object) = arguments else { return nil }
        for key in ["path", "file_path", "filePath"] {
            if case .string(let path) = object[key] ?? .null, !path.isEmpty {
                return path
            }
        }
        return nil
    }

    private static func existingLines(in previousSummary: String?) -> Set<String> {
        guard let previousSummary,
              let open = previousSummary.range(of: openTag),
              let close = previousSummary.range(
                of: closeTag,
                range: open.upperBound..<previousSummary.endIndex
              ) else {
            return []
        }
        return Set(previousSummary[open.upperBound..<close.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isFactLine))
    }

    private static func isFactLine(_ line: String) -> Bool {
        let hasKnownPrefix = line.hasPrefix("<read path=\"")
            || line.hasPrefix("<modified path=\"")
        return hasKnownPrefix && line.hasSuffix("\" />")
    }

    static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
