import Foundation
import KWAI
import KWAgent

public struct GrepToolOptions: Sendable {
    public var operations: GrepOperations
    public init(operations: GrepOperations = LocalGrepOperations()) {
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

        for fileURL in files {
            if let data = try? Data(contentsOf: fileURL),
               let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    let ns = line as NSString
                    if pattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                        results.append(GrepMatch(file: fileURL.path, line: i + 1, text: line))
                        if let limit = params.limit, results.count >= limit { return results }
                    }
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
    return AgentTool(
        name: "grep",
        label: "grep",
        description: "Search file contents for a regex pattern.",
        parameters: parameters,
        execute: { _, args, _, _ in
            guard case .object(let obj) = args,
                  case .string(let pattern) = obj["pattern"] ?? .null else {
                throw CodingToolError.invalidArgument("grep: `pattern` is required")
            }
            let path: String
            if case .string(let p) = obj["path"] ?? .null { path = PathUtils.resolveToCwd(p, cwd: cwd) }
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

            if matches.isEmpty {
                return AgentToolResult(
                    content: [.text(TextContent(text: "No matches found for \(pattern)"))],
                    details: .object(["matches": .array([])])
                )
            }
            let lines = matches.map { "\($0.file):\($0.line):\($0.text)" }
            let body = lines.joined(separator: "\n")
            let encoded: [JSONValue] = matches.map { m in
                .object([
                    "file": .string(m.file),
                    "line": .int(m.line),
                    "text": .string(m.text),
                ])
            }
            return AgentToolResult(
                content: [.text(TextContent(text: body))],
                details: .object(["matches": .array(encoded)])
            )
        }
    )
}
