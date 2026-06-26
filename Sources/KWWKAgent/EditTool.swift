import Foundation
import KWWKAI

public struct EditToolOptions: Sendable {
    public var operations: EditOperations
    public init(
        operations: EditOperations = LocalEditOperations()
    ) {
        self.operations = operations
    }
}

public struct LocalEditOperations: EditOperations {
    public init() {}
    public func readFile(_ absolutePath: String) async throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: absolutePath))
    }
    public func writeFile(_ absolutePath: String, content: Data) async throws {
        try content.write(to: URL(fileURLWithPath: absolutePath), options: .atomic)
    }
}

public func createEditTool(cwd: String, options: EditToolOptions = .init()) -> AgentTool {
    let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "path": ["type": "string"],
            "edits": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "oldText": ["type": "string"],
                        "newText": ["type": "string"],
                    ],
                    "required": ["oldText", "newText"],
                ],
            ],
        ],
        "required": ["path", "edits"],
    ]
    let ops = options.operations
    return AgentTool(
        name: "edit",
        label: "edit",
        description: "Edit a file using exact text replacement. Each oldText must match a unique, non-overlapping region.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let rawPath) = obj["path"] ?? .null else {
                throw CodingToolError.invalidArgument("edit: `path` is required")
            }
            guard case .array(let editArr) = obj["edits"] ?? .null, !editArr.isEmpty else {
                throw CodingToolError.invalidArgument("edit: `edits` must contain at least one replacement")
            }
            var collected: [EditDiff.Edit] = []
            for item in editArr {
                guard case .object(let e) = item,
                      case .string(let old) = e["oldText"] ?? .null,
                      case .string(let new) = e["newText"] ?? .null else {
                    throw CodingToolError.invalidArgument("edit: each item must be {oldText, newText}")
                }
                collected.append(EditDiff.Edit(oldText: old, newText: new))
            }
            let edits = collected

            let absolutePath = PathUtils.resolveToCwd(rawPath, cwd: cwd)
            return try await FileMutationQueue.shared.run(absolutePath) {
                let buffer: Data
                do {
                    buffer = try await ops.readFile(absolutePath)
                } catch {
                    throw CodingToolError.fileNotFound(rawPath)
                }
                guard let raw = String(data: buffer, encoding: .utf8) else {
                    throw CodingToolError.invalidArgument("edit: file is not valid UTF-8")
                }

                let (bom, withoutBOM) = EditDiff.stripBOM(raw)
                let ending = EditDiff.detectLineEnding(withoutBOM)
                let normalized = EditDiff.normalizeToLF(withoutBOM)
                let applied = try EditDiff.applyEdits(to: normalized, edits: edits, path: rawPath)
                try cancellation?.throwIfCancelled()

                let final = bom + EditDiff.restoreLineEndings(applied.newContent, ending: ending)
                try await ops.writeFile(absolutePath, content: Data(final.utf8))

                let diff = EditDiff.generateDiff(old: applied.baseContent, new: applied.newContent)
                return AgentToolResult(
                    content: [.text(TextContent(
                        text: "Successfully replaced \(edits.count) block(s) in \(rawPath)."
                    ))],
                    details: .object(["diff": .string(diff)])
                )
            }
        }
    )
}
