import Foundation
import KWWKAI

public struct LSToolOptions: Sendable {
    public var operations: LSOperations
    public init(
        operations: LSOperations = LocalLSOperations()
    ) {
        self.operations = operations
    }
}

public struct LocalLSOperations: LSOperations {
    public init() {}

    public func list(path: String) async throws -> [LSEntry] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw CodingToolError.fileNotFound(path)
        }
        let names = try fm.contentsOfDirectory(atPath: path).sorted()
        var out: [LSEntry] = []
        for name in names {
            let full = (path as NSString).appendingPathComponent(name)
            var entryIsDir: ObjCBool = false
            let exists = fm.fileExists(atPath: full, isDirectory: &entryIsDir)
            if !exists { continue }
            let attrs = try fm.attributesOfItem(atPath: full)
            let size = (attrs[.size] as? Int64) ?? 0
            let type = (attrs[.type] as? FileAttributeType) ?? .typeRegular
            let kind: LSEntry.Kind
            switch type {
            case .typeDirectory: kind = .directory
            case .typeSymbolicLink: kind = .symlink
            default: kind = .file
            }
            out.append(LSEntry(name: name, kind: kind, size: size))
        }
        return out
    }
}

public func createLSTool(cwd: String, options: LSToolOptions = .init()) -> AgentTool {
    let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "path": ["type": "string"],
            "limit": ["type": "number"],
        ],
    ]
    let ops = options.operations
    return AgentTool(
        name: "ls",
        label: "ls",
        description: "List the contents of a directory.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            let path: String
            if case .object(let obj) = args, case .string(let p) = obj["path"] ?? .null {
                path = PathUtils.resolveToCwd(p, cwd: cwd)
            } else {
                path = cwd
            }
            let limit: Int? = {
                if case .object(let obj) = args {
                    if case .int(let v) = obj["limit"] ?? .null { return v }
                    if case .double(let v) = obj["limit"] ?? .null { return Int(v) }
                }
                return nil
            }()

            var entries = try await ops.list(path: path)
            if let limit { entries = Array(entries.prefix(limit)) }
            let lines = entries.map { entry -> String in
                switch entry.kind {
                case .directory: return "\(entry.name)/"
                case .symlink: return "\(entry.name)@"
                case .file: return "\(entry.name)"
                }
            }
            return AgentToolResult(
                content: [.text(TextContent(text: lines.joined(separator: "\n")))],
                details: .object([
                    "entries": .array(entries.map { e in
                        .object([
                            "name": .string(e.name),
                            "kind": .string(kindName(e.kind)),
                            "size": .int(Int(e.size)),
                        ])
                    })
                ])
            )
        }
    )
}

private func kindName(_ kind: LSEntry.Kind) -> String {
    switch kind {
    case .file: return "file"
    case .directory: return "directory"
    case .symlink: return "symlink"
    }
}
