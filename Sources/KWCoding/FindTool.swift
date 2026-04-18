import Foundation
import KWAI
import KWAgent

public struct FindToolOptions: Sendable {
    public var operations: FindOperations
    public init(operations: FindOperations = LocalFindOperations()) {
        self.operations = operations
    }
}

public struct LocalFindOperations: FindOperations {
    public init() {}

    public func find(pattern: String, cwd: String, limit: Int?) async throws -> [String] {
        Glob.expand(root: cwd, pattern: pattern, limit: limit)
    }
}

public func createFindTool(cwd: String, options: FindToolOptions = .init()) -> AgentTool {
    let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "pattern": ["type": "string"],
            "path": ["type": "string"],
            "limit": ["type": "number"],
        ],
        "required": ["pattern"],
    ]
    let ops = options.operations
    return AgentTool(
        name: "find",
        label: "find",
        description: "Find files matching a glob pattern.",
        parameters: parameters,
        execute: { _, args, _, _ in
            guard case .object(let obj) = args,
                  case .string(let pattern) = obj["pattern"] ?? .null else {
                throw CodingToolError.invalidArgument("find: `pattern` is required")
            }
            let root: String = {
                if case .string(let p) = obj["path"] ?? .null { return PathUtils.resolveToCwd(p, cwd: cwd) }
                return cwd
            }()
            let limit: Int? = {
                if case .int(let v) = obj["limit"] ?? .null { return v }
                if case .double(let v) = obj["limit"] ?? .null { return Int(v) }
                return nil
            }()

            let matches = try await ops.find(pattern: pattern, cwd: root, limit: limit)
            if matches.isEmpty {
                return AgentToolResult(
                    content: [.text(TextContent(text: "No files match \(pattern)"))],
                    details: .object(["files": .array([])])
                )
            }
            return AgentToolResult(
                content: [.text(TextContent(text: matches.joined(separator: "\n")))],
                details: .object(["files": .array(matches.map { .string($0) })])
            )
        }
    )
}
