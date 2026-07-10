import Foundation
import KWWKAI

public struct FindToolOptions: Sendable {
    public var operations: FindOperations
    public init(
        operations: FindOperations = LocalFindOperations()
    ) {
        self.operations = operations
    }
}

public struct LocalFindOperations: FindOperations {
    public init() {}

    public func find(pattern: String, cwd: String, limit: Int?) async throws -> [String] {
        Glob.expand(root: cwd, pattern: pattern, limit: limit)
    }
}

public func createFindTool(
    cwd: String,
    options: FindToolOptions = .init(),
    fileAccessPolicy: FileAccessPolicy = .unrestricted
) -> AgentTool {
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
    var tool = AgentTool(
        name: "find",
        label: "find",
        description: """
        Find files matching a glob pattern. A pattern without a slash matches the file \
        name at any depth, so `*.swift` finds every Swift file in the tree. Use a slash \
        to scope it: `Sources/*.swift` matches only that directory's top level, and \
        `Sources/**/*.swift` recurses under it.
        """,
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let pattern) = obj["pattern"] ?? .null else {
                throw CodingToolError.invalidArgument("find: `pattern` is required")
            }
            let rawRoot: String
            if case .string(let p) = obj["path"] ?? .null {
                rawRoot = p
            } else {
                rawRoot = "."
            }
            // Authorize the traversal root before handing it to the recursive
            // operation. This is canonical containment, not an OS sandbox.
            let root = try PathUtils.resolveForAccess(
                rawRoot,
                cwd: cwd,
                policy: fileAccessPolicy,
                intent: .read
            )
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
    tool.fileAccessPolicy = fileAccessPolicy
    tool.fileAccessCwd = cwd
    tool.codingToolCapabilities = .find
    return tool
}
