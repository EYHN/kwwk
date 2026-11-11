import Foundation
import KWWKAI

public struct ReadToolOptions: Sendable {
    public var operations: ReadOperations
    public var maxLines: Int
    public var maxBytes: Int

    public init(
        operations: ReadOperations = LocalReadOperations(),
        maxLines: Int = Truncate.defaultMaxLines,
        maxBytes: Int = Truncate.defaultMaxBytes
    ) {
        self.operations = operations
        self.maxLines = maxLines
        self.maxBytes = maxBytes
    }
}

public struct LocalReadOperations: ReadOperations {
    public init() {}

    public func readFile(_ absolutePath: String) async throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: absolutePath))
    }

    public func access(_ absolutePath: String) async throws {
        if !FileManager.default.fileExists(atPath: absolutePath) {
            throw CodingToolError.fileNotFound(absolutePath)
        }
        // A file that exists but cannot be read is a permissions problem, not
        // a wrong path — reporting it as "not found" sends the model into
        // path-variation retries instead of recognizing EACCES.
        if !FileManager.default.isReadableFile(atPath: absolutePath) {
            throw CodingToolError.runtime(
                "file exists but is not readable (permission denied, EACCES): \(absolutePath)"
            )
        }
    }

    public func detectImageMimeType(_ absolutePath: String) async throws -> String? {
        // Read the first 12 bytes for sniffing.
        guard let handle = FileHandle(forReadingAtPath: absolutePath) else { return nil }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 12) ?? Data()
        return PathUtils.detectImageMimeType(from: data)
    }
}

public func createReadTool(
    cwd: String,
    options: ReadToolOptions = .init(),
    fileAccessPolicy: FileAccessPolicy = .unrestricted
) -> AgentTool {
    let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Path (relative or absolute) to the file."],
            "offset": ["type": "number", "description": "Line number to start reading from (1-indexed)."],
            "limit": ["type": "number", "description": "Maximum number of lines to read."],
        ],
        "required": ["path"],
    ]

    let ops = options.operations
    let maxLines = options.maxLines
    let maxBytes = options.maxBytes

    var tool = AgentTool(
        name: "read",
        label: "read",
        description: "Read the contents of a text or image file. Long outputs are truncated — use offset/limit for large files. Images are resized and recompressed before they enter the conversation.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let rawPath) = obj["path"] ?? .null else {
                throw CodingToolError.invalidArgument("read: `path` is required")
            }
            let offset: Int? = {
                if case .int(let v) = obj["offset"] ?? .null { return v }
                if case .double(let v) = obj["offset"] ?? .null { return clampedToolInt(v) }
                return nil
            }()
            let limit: Int? = {
                if case .int(let v) = obj["limit"] ?? .null { return v }
                if case .double(let v) = obj["limit"] ?? .null { return clampedToolInt(v) }
                return nil
            }()

            let absolutePath = try PathUtils.resolveForAccess(
                rawPath,
                cwd: cwd,
                policy: fileAccessPolicy,
                intent: .read
            )
            try await ops.access(absolutePath)

            // Image path.
            if try await ops.detectImageMimeType(absolutePath) != nil {
                let buffer = try await ops.readFile(absolutePath)
                let normalized = try ImageNormalizer.normalize(buffer)
                var note = "Read image file [\(normalized.content.mimeType), \(normalized.width)x\(normalized.height), \(normalized.byteCount) bytes]"
                if let coordinateMappingNote = normalized.coordinateMappingNote {
                    note += "\n\(coordinateMappingNote)"
                }
                return AgentToolResult(
                    content: [
                        .text(TextContent(text: note)),
                        .image(normalized.content),
                    ]
                )
            }

            // Text path.
            let buffer = try await ops.readFile(absolutePath)
            guard let text = String(data: buffer, encoding: .utf8) else {
                throw CodingToolError.invalidArgument("read: file is not valid UTF-8")
            }
            // Total line count via a single newline pass — cheap and
            // allocation-free, unlike materializing every line as a String.
            let totalLines = text.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
            let startLine = (offset.map { $0 > 0 ? $0 - 1 : 0 }) ?? 0
            let startDisplay = startLine + 1
            if startLine >= totalLines {
                throw CodingToolError.offsetOutOfRange(offset: offset ?? 0, totalLines: totalLines)
            }

            // A negative limit selects nothing; a huge one stops at EOF.
            let window = readLineWindow(text, startLine: startLine, limit: limit.map { max(0, $0) })
            let selectedContent = window.content
            let userLimitedLines: Int? = limit == nil ? nil : window.lines

            let trunc = Truncate.truncateHead(
                selectedContent,
                maxLines: maxLines,
                maxBytes: maxBytes
            )
            var outputText: String
            var returnDetails: JSONValue?

            if trunc.firstLineExceedsLimit {
                let firstWindowLineBytes = selectedContent.utf8.prefix { $0 != 0x0A }.count
                let firstLineSize = Truncate.formatSize(firstWindowLineBytes)
                outputText = "[Line \(startDisplay) is \(firstLineSize), exceeds \(Truncate.formatSize(maxBytes)) limit.]"
                returnDetails = encodeTruncation(trunc)
            } else if trunc.truncated {
                let endDisplay = startDisplay + trunc.outputLines - 1
                let nextOffset = endDisplay + 1
                outputText = trunc.content
                if trunc.truncatedBy == "lines" {
                    outputText += "\n\n[Showing lines \(startDisplay)-\(endDisplay) of \(totalLines). Use offset=\(nextOffset) to continue.]"
                } else {
                    outputText += "\n\n[Showing lines \(startDisplay)-\(endDisplay) of \(totalLines) (\(Truncate.formatSize(maxBytes)) limit). Use offset=\(nextOffset) to continue.]"
                }
                returnDetails = encodeTruncation(trunc)
            } else if let ul = userLimitedLines, startLine + ul < totalLines {
                let remaining = totalLines - (startLine + ul)
                let nextOffset = startLine + ul + 1
                outputText = "\(trunc.content)\n\n[\(remaining) more lines in file. Use offset=\(nextOffset) to continue.]"
            } else {
                outputText = trunc.content
            }

            return AgentToolResult(
                content: [.text(TextContent(text: outputText))],
                details: returnDetails
            )
        }
    )
    tool.fileAccessPolicy = fileAccessPolicy
    tool.fileAccessCwd = cwd
    tool.codingToolCapabilities = .read
    return tool
}

/// Lines `startLine ..< startLine + limit` (to EOF when `limit` is nil),
/// joined by their own "\n" and the number of lines taken. `startLine`
/// must be below the file's line count.
///
/// Lines are cut on the "\n" byte, exactly as `totalLines` counts them, and
/// a "\r" before it stays with its line. Swift's Character view reads "\r\n"
/// as one grapheme, so `String.split(separator: "\n")` finds no break at all
/// in a CRLF file: the window came back as one piece while `totalLines`
/// counted every line, and slicing it at the offset trapped (SIGILL).
func readLineWindow(_ text: String, startLine: Int, limit: Int?) -> (content: String, lines: Int) {
    let utf8 = text.utf8
    var begin = utf8.startIndex
    for _ in 0..<startLine {
        guard let newline = utf8[begin...].firstIndex(of: 0x0A) else { break }
        begin = utf8.index(after: newline)
    }
    var end = utf8.endIndex
    var lines = 0
    if let limit {
        end = begin
        var cursor = begin
        while lines < limit {
            lines += 1
            guard let newline = utf8[cursor...].firstIndex(of: 0x0A) else {
                end = utf8.endIndex
                break
            }
            end = newline
            cursor = utf8.index(after: newline)
        }
    }
    return (String(decoding: utf8[begin..<end], as: UTF8.self), lines)
}

private func encodeTruncation(_ t: Truncate.Result) -> JSONValue {
    var obj: [String: JSONValue] = [
        "truncated": .bool(t.truncated),
        "totalLines": .int(t.totalLines),
        "outputLines": .int(t.outputLines),
        "maxLines": .int(t.maxLines),
        "maxBytes": .int(t.maxBytes),
        "firstLineExceedsLimit": .bool(t.firstLineExceedsLimit),
    ]
    if let by = t.truncatedBy { obj["truncatedBy"] = .string(by) }
    return .object(["truncation": .object(obj)])
}
