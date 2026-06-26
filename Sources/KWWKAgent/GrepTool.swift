import Foundation
import KWWKAI

public struct GrepToolOptions: Sendable {
    public var operations: GrepOperations
    public init(
        operations: GrepOperations = LocalGrepOperations()
    ) {
        self.operations = operations
    }
}

public struct LocalGrepOperations: GrepOperations {
    public init() {}

    public func grep(params: GrepParams) async throws -> [GrepMatch] {
        let pattern: NSRegularExpression
        do {
            let patternString = params.literal
                ? NSRegularExpression.escapedPattern(for: params.pattern)
                : params.pattern
            var options: NSRegularExpression.Options = []
            if params.ignoreCase { options.insert(.caseInsensitive) }
            pattern = try NSRegularExpression(pattern: patternString, options: options)
        } catch {
            throw CodingToolError.invalidArgument("grep: invalid pattern — \(error)")
        }

        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: params.path)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: params.path, isDirectory: &isDirectory) else {
            throw CodingToolError.fileNotFound(params.path)
        }

        var results: [GrepMatch] = []
        let files = isDirectory.boolValue
            ? collectFiles(at: rootURL)
            : [rootURL]

        let limit = params.limit ?? Truncate.grepDefaultLimit
        let maxLineChars = Truncate.grepMaxLineLength
        let maxTotalBytes = Truncate.grepMaxTotalBytes
        var totalBytes = 0

        outer: for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let ns = line as NSString
                if pattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                    let truncated = Truncate.truncateLine(line, maxChars: maxLineChars)
                    let match = GrepMatch(
                        file: fileURL.path,
                        line: i + 1,
                        text: truncated.text
                    )
                    let entryBytes = "\(match.file):\(match.line):\(match.text)\n".utf8.count
                    if totalBytes + entryBytes > maxTotalBytes && !results.isEmpty {
                        // Mark the last result so the caller knows we
                        // stopped because of the byte budget.
                        results.append(GrepMatch(
                            file: "",
                            line: 0,
                            text: "[truncated: total output exceeded \(Truncate.formatSize(maxTotalBytes))]"
                        ))
                        break outer
                    }
                    totalBytes += entryBytes
                    results.append(match)
                    if results.count >= limit { break outer }
                }
            }
        }
        return results
    }

    private func collectFiles(at rootURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true {
                out.append(url)
            }
        }
        return out
    }
}

public func createGrepTool(cwd: String, options: GrepToolOptions = .init()) -> AgentTool {
    let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "pattern": ["type": "string"],
            "path": ["type": "string"],
            "glob": ["type": "string"],
            "ignoreCase": ["type": "boolean"],
            "literal": ["type": "boolean"],
            "context": ["type": "number"],
            "limit": ["type": "number"],
        ],
        "required": ["pattern"],
    ]
    let ops = options.operations
    let defaultLimit = Truncate.grepDefaultLimit
    let maxLineChars = Truncate.grepMaxLineLength
    let maxTotalBytes = Truncate.grepMaxTotalBytes
    return AgentTool(
        name: "grep",
        label: "grep",
        description: """
        Search file contents for a regex pattern. Results are capped to avoid flooding the context window:
          - Default \(defaultLimit) matches (override with `limit`)
          - Single lines truncated to \(maxLineChars) chars
          - Total output capped at ~\(Truncate.formatSize(maxTotalBytes))
        Use a tighter `limit` or a more specific pattern when searching large codebases.
        """,
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let pattern) = obj["pattern"] ?? .null else {
                throw CodingToolError.invalidArgument("grep: `pattern` is required")
            }
            let path: String
            if case .string(let p) = obj["path"] ?? .null {
                path = PathUtils.resolveToCwd(p, cwd: cwd)
            }
            else { path = cwd }

            let ignoreCase: Bool = {
                if case .bool(let v) = obj["ignoreCase"] ?? .null { return v }
                return false
            }()
            let literal: Bool = {
                if case .bool(let v) = obj["literal"] ?? .null { return v }
                return false
            }()
            let limit: Int? = {
                if case .int(let v) = obj["limit"] ?? .null { return v }
                if case .double(let v) = obj["limit"] ?? .null { return Int(v) }
                return nil
            }()

            let matches = try await ops.grep(params: GrepParams(
                pattern: pattern,
                path: path,
                ignoreCase: ignoreCase,
                literal: literal,
                limit: limit
            ))

            // Detect the sentinel we inject when the byte budget is hit.
            let byteTruncated = matches.last?.text.hasPrefix("[truncated: total output exceeded") == true
            let effectiveMatches = byteTruncated ? Array(matches.dropLast()) : matches

            if effectiveMatches.isEmpty {
                return AgentToolResult(
                    content: [.text(TextContent(text: "No matches found for \(pattern)"))],
                    details: .object(["matches": .array([])])
                )
            }

            var lines = effectiveMatches.map { "\($0.file):\($0.line):\($0.text)" }
            if byteTruncated {
                lines.append("[truncated: total output exceeded \(Truncate.formatSize(maxTotalBytes))]")
            }
            let body = lines.joined(separator: "\n")

            let encoded: [JSONValue] = effectiveMatches.map { m in
                .object([
                    "file": .string(m.file),
                    "line": .int(m.line),
                    "text": .string(m.text),
                ])
            }

            var details: [String: JSONValue] = [
                "matches": .array(encoded),
                "totalMatches": .int(effectiveMatches.count),
                "truncated": .bool(byteTruncated || effectiveMatches.count >= (limit ?? defaultLimit)),
            ]
            if byteTruncated {
                details["truncatedBy"] = .string("bytes")
            } else if effectiveMatches.count >= (limit ?? defaultLimit) {
                details["truncatedBy"] = .string("limit")
            }

            return AgentToolResult(
                content: [.text(TextContent(text: body))],
                details: .object(details)
            )
        }
    )
}
