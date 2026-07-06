import Foundation
import KWWKAI

public struct WriteToolOptions: Sendable {
    public var operations: WriteOperations
    public init(
        operations: WriteOperations = LocalWriteOperations()
    ) {
        self.operations = operations
    }
}

public struct LocalWriteOperations: WriteOperations {
    public init() {}

    public func writeFile(_ absolutePath: String, content: Data) async throws {
        // In-place write (open + truncate): when the path is an existing file
        // or symlink, this writes through it and preserves the inode, symlink
        // target, hard links, and permissions rather than replacing them via an
        // atomic rename. Mirrors pi's `fs.writeFile`.
        try PathUtils.writeFileInPlace(absolutePath, data: content)
    }

    public func createParentDirectories(_ absolutePath: String) async throws {
        let parent = (absolutePath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
        }
    }
}

public func createWriteTool(cwd: String, options: WriteToolOptions = .init()) -> AgentTool {
    let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "path": ["type": "string"],
            "content": ["type": "string"],
        ],
        "required": ["path", "content"],
    ]
    let ops = options.operations
    return AgentTool(
        name: "write",
        label: "write",
        description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let rawPath) = obj["path"] ?? .null,
                  case .string(let content) = obj["content"] ?? .null else {
                throw CodingToolError.invalidArgument("write: `path` and `content` are required")
            }

            let absolutePath = PathUtils.resolveToCwd(rawPath, cwd: cwd)
            return try await FileMutationQueue.shared.run(absolutePath) {
                try await ops.createParentDirectories(absolutePath)
                try await ops.writeFile(absolutePath, content: Data(content.utf8))
                return AgentToolResult(
                    content: [.text(TextContent(
                        text: "Successfully wrote \(content.utf8.count) bytes to \(rawPath)"
                    ))]
                )
            }
        }
    )
}
