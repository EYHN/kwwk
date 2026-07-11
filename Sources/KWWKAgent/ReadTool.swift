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
        description: "Read the contents of a text or image file. Long outputs are truncated — use offset/limit for large files. Images are inlined at full size with no downscaling, so a large image spends its full encoded byte count.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let rawPath) = obj["path"] ?? .null else {
                throw CodingToolError.invalidArgument("read: `path` is required")
            }
            let offset: Int? = {
                if case .int(let v) = obj["offset"] ?? .null { return v }
                if case .double(let v) = obj["offset"] ?? .null { return Int(v) }
                return nil
            }()
            let limit: Int? = {
                if case .int(let v) = obj["limit"] ?? .null { return v }
                if case .double(let v) = obj["limit"] ?? .null { return Int(v) }
                return nil
            }()

            let absolutePath = try PathUtils.resolveForAccess(
                rawPath,
                cwd: cwd,
                policy: fileAccessPolicy,
                intent: .read
            )
            try await ops.access(absolutePath)

            // Image path. The image is base64-inlined as-is: there is no
            // resizing or downscaling, so a large image contributes its full
            // encoded byte count to the request.
            if let mimeType = try await ops.detectImageMimeType(absolutePath) {
                let buffer = try await ops.readFile(absolutePath)
                let base64 = buffer.base64EncodedString()
                let note = "Read image file [\(mimeType)]"
                return AgentToolResult(
                    content: [
                        .text(TextContent(text: note)),
                        .image(ImageContent(data: base64, mimeType: mimeType)),
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
            let startLine = (offset.map { max(0, $0 - 1) }) ?? 0
            let startDisplay = startLine + 1
            if startLine >= totalLines {
                throw CodingToolError.offsetOutOfRange(offset: offset ?? 0, totalLines: totalLines)
            }

            var userLimitedLines: Int?
            let selectedContent: String
            if let limit {
                // Only split up to the requested window instead of every line
                // in the file: `maxSplits` stops scanning past the window and
                // keeps the remainder as one unsplit chunk, which we drop.
                let needed = startLine + limit
                let head = text.split(separator: "\n", maxSplits: needed, omittingEmptySubsequences: false)
                let windowEnd = min(needed, head.count)
                selectedContent = head[startLine..<windowEnd].joined(separator: "\n")
                userLimitedLines = windowEnd - startLine
            } else {
                // No limit: everything from the offset to EOF is needed anyway.
                let allLines = text.components(separatedBy: "\n")
                selectedContent = allLines[startLine...].joined(separator: "\n")
            }

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
