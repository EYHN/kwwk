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
            ? collectFiles(at: rootURL, glob: params.glob)
            : [rootURL]

        let limit = params.limit ?? Truncate.grepDefaultLimit
        let maxLineChars = Truncate.grepMaxLineLength
        let maxTotalBytes = Truncate.grepMaxTotalBytes
        let context = max(0, params.context)
        var totalBytes = 0

        outer: for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            // Skip files that look binary (ripgrep, which pi shells out to,
            // does the same by ignoring files with NUL bytes).
            if looksBinary(data) { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let ns = line as NSString
                guard pattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil else { continue }
                let match = makeMatch(
                    file: fileURL.path,
                    lines: lines,
                    index: i,
                    context: context,
                    maxLineChars: maxLineChars
                )
                let entryBytes = blockBytes(match)
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
        return results
    }

    private func makeMatch(
        file: String,
        lines: [String],
        index i: Int,
        context: Int,
        maxLineChars: Int
    ) -> GrepMatch {
        let text = Truncate.truncateLine(lines[i], maxChars: maxLineChars).text
        var before: [GrepContextLine] = []
        var after: [GrepContextLine] = []
        if context > 0 {
            for j in max(0, i - context)..<i {
                before.append(GrepContextLine(line: j + 1, text: Truncate.truncateLine(lines[j], maxChars: maxLineChars).text))
            }
            let end = min(lines.count - 1, i + context)
            if i < end {
                for j in (i + 1)...end {
                    after.append(GrepContextLine(line: j + 1, text: Truncate.truncateLine(lines[j], maxChars: maxLineChars).text))
                }
            }
        }
        return GrepMatch(file: file, line: i + 1, text: text, before: before, after: after)
    }

    private func blockBytes(_ m: GrepMatch) -> Int {
        var total = "\(m.file):\(m.line):\(m.text)\n".utf8.count
        for c in m.before { total += "\(m.file)-\(c.line)-\(c.text)\n".utf8.count }
        for c in m.after { total += "\(m.file)-\(c.line)-\(c.text)\n".utf8.count }
        return total
    }

    private func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    private func collectFiles(at rootURL: URL, glob: String?) -> [URL] {
        let fm = FileManager.default
        // Canonicalize the root before enumerating so a slash-anchored glob's
        // relative-path prefix strips the right number of leading characters
        // (see `Glob.canonicalDirectoryPath` — the enumerator yields
        // firmlink-resolved paths that `standardizedFileURL` doesn't produce).
        let rootPath = Glob.canonicalDirectoryPath(rootURL.path)
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else {
            return []
        }
        // Compile the glob regex once, up front, rather than per visited file.
        // A glob without a slash filters on the basename at any depth (ripgrep's
        // `--glob '*.ts'` semantics); one with a slash matches the path relative
        // to the search root.
        let globRegex = glob.flatMap { try? NSRegularExpression(pattern: Glob.patternToRegex($0)) }
        let globMatchesRelative = glob?.contains("/") ?? false
        var out: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                // Prune VCS metadata and dependency trees during traversal.
                if ignoredWalkDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if let globRegex {
                let candidate = globMatchesRelative
                    ? relativePath(of: url.path, under: rootPath)
                    : url.lastPathComponent
                let ns = candidate as NSString
                if globRegex.firstMatch(in: candidate, options: [], range: NSRange(location: 0, length: ns.length)) == nil {
                    continue
                }
            }
            out.append(url)
        }
        return out
    }

    private func relativePath(of path: String, under root: String) -> String {
        let prefix = root.hasSuffix("/") ? root.count : root.count + 1
        return path.count > prefix ? String(path.dropFirst(prefix)) : path
    }
}

public func createGrepTool(
    cwd: String,
    options: GrepToolOptions = .init(),
    fileAccessPolicy: FileAccessPolicy = .unrestricted
) -> AgentTool {
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
    var tool = AgentTool(
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
            let rawPath: String
            if case .string(let p) = obj["path"] ?? .null {
                rawPath = p.isEmpty ? "." : p
            } else {
                rawPath = "."
            }
            // Recursive local operations receive a canonical, authorized root.
            // The policy is a path boundary, not an OS-level TOCTOU defense.
            let path = try PathUtils.resolveForAccess(
                rawPath,
                cwd: cwd,
                policy: fileAccessPolicy,
                intent: .read
            )

            let glob: String? = {
                if case .string(let g) = obj["glob"] ?? .null {
                    let trimmed = g.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
            }()
            let ignoreCase: Bool = {
                if case .bool(let v) = obj["ignoreCase"] ?? .null { return v }
                return false
            }()
            let literal: Bool = {
                if case .bool(let v) = obj["literal"] ?? .null { return v }
                return false
            }()
            let context: Int = {
                if case .int(let v) = obj["context"] ?? .null { return max(0, v) }
                if case .double(let v) = obj["context"] ?? .null { return max(0, Int(v)) }
                return 0
            }()
            let limit: Int? = {
                if case .int(let v) = obj["limit"] ?? .null { return v }
                if case .double(let v) = obj["limit"] ?? .null { return Int(v) }
                return nil
            }()

            let matches = try await ops.grep(params: GrepParams(
                pattern: pattern,
                path: path,
                glob: glob,
                ignoreCase: ignoreCase,
                literal: literal,
                context: context,
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

            var lines: [String] = []
            for m in effectiveMatches {
                for c in m.before { lines.append("\(m.file)-\(c.line)-\(c.text)") }
                lines.append("\(m.file):\(m.line):\(m.text)")
                for c in m.after { lines.append("\(m.file)-\(c.line)-\(c.text)") }
            }
            if byteTruncated {
                lines.append("[truncated: total output exceeded \(Truncate.formatSize(maxTotalBytes))]")
            }
            let body = lines.joined(separator: "\n")

            let encoded: [JSONValue] = effectiveMatches.map { m in
                var obj: [String: JSONValue] = [
                    "file": .string(m.file),
                    "line": .int(m.line),
                    "text": .string(m.text),
                ]
                if !m.before.isEmpty {
                    obj["before"] = .array(m.before.map { .object(["line": .int($0.line), "text": .string($0.text)]) })
                }
                if !m.after.isEmpty {
                    obj["after"] = .array(m.after.map { .object(["line": .int($0.line), "text": .string($0.text)]) })
                }
                return .object(obj)
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
    tool.fileAccessPolicy = fileAccessPolicy
    tool.fileAccessCwd = cwd
    tool.codingToolCapabilities = .grep
    return tool
}
