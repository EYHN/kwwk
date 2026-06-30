import Foundation
import KWWKAI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    public func access(_ absolutePath: String) async throws {
        try checkPOSIXAccess(absolutePath, mode: editAccessExistsMode)

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue {
            throw POSIXError(.EISDIR)
        }

        try checkPOSIXAccess(absolutePath, mode: editAccessReadWriteMode)
    }
}

#if canImport(Darwin) || canImport(Glibc)
private let editAccessExistsMode: Int32 = F_OK
private let editAccessReadWriteMode: Int32 = R_OK | W_OK
#else
private let editAccessExistsMode: Int32 = 0
private let editAccessReadWriteMode: Int32 = 6
#endif

private func checkPOSIXAccess(_ absolutePath: String, mode: Int32) throws {
    #if canImport(Darwin)
    let accessResult = Darwin.access(absolutePath, mode)
    #elseif canImport(Glibc)
    let accessResult = Glibc.access(absolutePath, mode)
    #else
    let accessResult: Int32
    if mode == editAccessExistsMode {
        accessResult = FileManager.default.fileExists(atPath: absolutePath) ? 0 : -1
    } else {
        accessResult = FileManager.default.isReadableFile(atPath: absolutePath)
            && FileManager.default.isWritableFile(atPath: absolutePath) ? 0 : -1
    }
    #endif
    if accessResult != 0 {
        #if canImport(Darwin)
        let errorCode = errno
        #elseif canImport(Glibc)
        let errorCode = errno
        #else
        let errorCode = mode == editAccessExistsMode ? ENOENT : EACCES
        #endif
        throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EACCES)
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
        execute: { _, args, cancellation, onUpdate in
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
                do {
                    try await ops.access(absolutePath)
                } catch {
                    throw CodingToolError.runtime(
                        "Could not edit file: \(rawPath). \(editAccessErrorDescription(error))."
                    )
                }

                let buffer = try await ops.readFile(absolutePath)
                guard let raw = String(data: buffer, encoding: .utf8) else {
                    throw CodingToolError.invalidArgument("edit: file is not valid UTF-8")
                }

                let (bom, withoutBOM) = EditDiff.stripBOM(raw)
                let ending = EditDiff.detectLineEnding(withoutBOM)
                let normalized = EditDiff.normalizeToLF(withoutBOM)
                let applied = try EditDiff.applyEdits(to: normalized, edits: edits, path: rawPath)
                try cancellation?.throwIfCancelled()

                let diffResult = EditDiff.generateDiffString(old: applied.baseContent, new: applied.newContent)
                let patch = EditDiff.generateUnifiedPatch(
                    path: rawPath,
                    old: applied.baseContent,
                    new: applied.newContent
                )
                let details = editDetails(diff: diffResult.diff, patch: patch, firstChangedLine: diffResult.firstChangedLine)
                let display = editDisplayLines(
                    summary: "Previewing \(edits.count) replacement(s) in \(rawPath).",
                    diff: diffResult.diff
                )
                onUpdate?(AgentToolResult(
                    content: [.text(TextContent(text: "Previewing \(edits.count) replacement(s) in \(rawPath)."))],
                    details: details,
                    uiDisplay: display
                ))
                try cancellation?.throwIfCancelled()

                let final = bom + EditDiff.restoreLineEndings(applied.newContent, ending: ending)
                try await ops.writeFile(absolutePath, content: Data(final.utf8))

                let summary = "Successfully replaced \(edits.count) block(s) in \(rawPath)."
                return AgentToolResult(
                    content: [.text(TextContent(
                        text: summary
                    ))],
                    details: details,
                    uiDisplay: editDisplayLines(summary: summary, diff: diffResult.diff)
                )
            }
        }
    )
}

private func editDetails(diff: String, patch: String, firstChangedLine: Int?) -> JSONValue {
    var details: [String: JSONValue] = [
        "diff": .string(diff),
        "patch": .string(patch),
    ]
    if let firstChangedLine {
        details["firstChangedLine"] = .int(firstChangedLine)
    }
    return .object(details)
}

private func editDisplayLines(summary: String, diff: String) -> [String] {
    var lines = [summary]
    if !diff.isEmpty {
        lines.append(contentsOf: diff.components(separatedBy: "\n"))
    }
    return lines
}

private func editAccessErrorDescription(_ error: Error) -> String {
    if let posix = error as? POSIXError {
        return "Error code: \(posixErrorCodeName(posix.code.rawValue))"
    }
    if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
        return description
    }
    return String(describing: error)
}

private func posixErrorCodeName(_ code: Int32) -> String {
    switch code {
    case ENOENT: return "ENOENT"
    case EACCES: return "EACCES"
    case EPERM: return "EPERM"
    case ENOTDIR: return "ENOTDIR"
    case EISDIR: return "EISDIR"
    default: return "POSIX(\(code))"
    }
}
