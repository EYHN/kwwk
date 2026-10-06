import Crypto
import Foundation
import KWWKAgent
import KWWKAI

/// Naming of MCP tools as agent tools: `mcp__<server>__<tool>`.
public enum MCPToolNaming {
    /// Provider tool names are limited to 64 characters.
    public static let maxLength = 64

    /// Replace every character outside `[A-Za-z0-9_]` with `_`.
    public static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95
            return ok ? Character(scalar) : "_"
        })
    }

    /// The sanitized name before any hash suffix.
    public static func baseName(server: String, tool: String) -> String {
        sanitize("mcp__\(server)__\(tool)")
    }

    /// First 8 hex digits of `sha256("<server>\0<tool>")`.
    public static func hashSuffix(server: String, tool: String) -> String {
        let digest = SHA256.hash(data: Data("\(server)\u{0}\(tool)".utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Name with an 8-hex hash suffix, shortened to `maxLength`.
    public static func hashedName(server: String, tool: String) -> String {
        let base = baseName(server: server, tool: tool)
        let hash = hashSuffix(server: server, tool: tool)
        return "\(base.prefix(maxLength - hash.count - 1))_\(hash)"
    }

    /// Name of one tool: the base name, or the hashed name when it is too
    /// long or `isTaken` reports it is used by another tool.
    public static func toolName(
        server: String,
        tool: String,
        isTaken: (String) -> Bool = { _ in false }
    ) -> String {
        let base = baseName(server: server, tool: tool)
        if base.count <= maxLength && !isTaken(base) { return base }
        return hashedName(server: server, tool: tool)
    }

    /// Assign names to a set of `(server, tool)` pairs at once. Tools whose
    /// base names collide all get a hash suffix, so the result does not depend
    /// on the order servers connect in. Returned in input order.
    public static func assignNames(_ tools: [(server: String, tool: String)]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in tools {
            counts[baseName(server: entry.server, tool: entry.tool), default: 0] += 1
        }
        var used: Set<String> = []
        return tools.map { entry in
            let base = baseName(server: entry.server, tool: entry.tool)
            var name = (base.count <= maxLength && counts[base] == 1)
                ? base
                : hashedName(server: entry.server, tool: entry.tool)
            // Identical (server, tool) pairs listed twice would still clash.
            var counter = 2
            let original = name
            while used.contains(name) {
                let suffix = "_\(counter)"
                name = String(original.prefix(maxLength - suffix.count)) + suffix
                counter += 1
            }
            used.insert(name)
            return name
        }
    }
}

/// Error thrown for a `tools/call` result with `isError: true`. The agent
/// loop turns thrown errors into error tool results, so the model sees the
/// server's message flagged as an error.
public struct MCPToolCallError: Error, LocalizedError, Sendable {
    public var server: String
    public var tool: String
    public var message: String
    /// The converted result content (text and images).
    public var content: [ToolResultBlock]

    public var errorDescription: String? { message }
}

/// A tool result over the size limit, handed to `MCPResultSpill` whole.
public struct MCPSpilledResult: Sendable {
    public var server: String
    public var tool: String
    /// All text of the result (text blocks, then structured content).
    public var text: String
    /// Images left out of the model-facing result: base64 data and MIME type.
    public var images: [(data: String, mimeType: String)]
}

/// Stores tool results that were too large to show in full and says where.
public protocol MCPResultSpill: Sendable {
    /// Store `result`; return where the model can read it (e.g. a path).
    func spill(_ result: MCPSpilledResult) async throws -> String
}

/// Keeps the binary content of tool results — images, audio, binary
/// resources — as files, so the agent can hand them on (attach, upload, pass
/// to another tool) instead of only looking at them.
public protocol MCPResultFiles: Sendable {
    /// Store `data`; return where the model can read it (e.g. a path).
    func save(_ data: Data, mimeType: String, server: String, tool: String) async throws -> String
}

/// How much of one MCP tool result reaches the model.
public struct MCPResultLimits: Sendable {
    /// Estimated tokens: text counts 4 characters per token, each image
    /// `imageTokens`. Nil means no limit.
    public var maxTokens: Int?
    public var imageTokens: Int
    /// Receives results over the limit; nil drops the rest. Defaults to
    /// ``temporaryDirectory``.
    public var spill: (any MCPResultSpill)?
    /// Receives every image, audio clip and binary resource of a result; the
    /// model is told where each went. Nil keeps images inline only and drops
    /// binary content the model cannot view. Defaults to
    /// ``temporaryDirectory``.
    public var files: (any MCPResultFiles)?

    /// Where results go unless the host chooses: one private directory per
    /// process under the system temp directory, created on the first write
    /// (0700, files 0600), left for the system to clean. A host whose agent
    /// runs its tools elsewhere (another sandbox or machine) must pass a
    /// directory those tools can reach, since the model is given its paths.
    public static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwwk-mcp-\(UUID().uuidString)", isDirectory: true)

    public init(
        maxTokens: Int? = 25_000,
        imageTokens: Int = 1_600,
        spill: (any MCPResultSpill)? = MCPDirectoryResultSpill(directory: MCPResultLimits.temporaryDirectory),
        files: (any MCPResultFiles)? = MCPDirectoryResultFiles(directory: MCPResultLimits.temporaryDirectory)
    ) {
        self.maxTokens = maxTokens
        self.imageTokens = imageTokens
        self.spill = spill
        self.files = files
    }

    public static let `default` = MCPResultLimits()
    public static let unlimited = MCPResultLimits(maxTokens: nil)
}

/// Adapts MCP tools and results to kwwk agent tools.
public enum MCPToolAdapter {
    /// Calls a tool on the server: `(toolName, arguments, cancellation, onProgress)`.
    public typealias Caller = @Sendable (
        _ tool: String,
        _ arguments: JSONValue,
        _ cancellation: CancellationHandle?,
        _ onProgress: (@Sendable (MCPProgress) -> Void)?
    ) async throws -> MCPCallToolResult

    /// Build the agent tool for one MCP tool.
    public static func makeAgentTool(
        server: String,
        tool: MCPTool,
        name: String,
        limits: MCPResultLimits = .default,
        call: @escaping Caller
    ) -> AgentTool {
        let toolName = tool.name
        return AgentTool(
            name: name,
            label: "\(server)/\(tool.name)",
            description: description(server: server, tool: tool),
            parameters: parameters(from: tool.inputSchema)
        ) { _, args, cancellation, onUpdate in
            let progress: (@Sendable (MCPProgress) -> Void)?
            if let onUpdate {
                progress = { update in
                    let total = update.total.map { "/\(format($0))" } ?? ""
                    let text = update.message ?? "Progress \(format(update.progress))\(total)"
                    onUpdate(AgentToolResult(
                        content: [.text(TextContent(text: text))],
                        details: ["server": .string(server), "tool": .string(toolName)]
                    ))
                }
            } else {
                progress = nil
            }
            let result = try await call(toolName, args, cancellation, progress)
            return try await convert(server: server, tool: toolName, result: result, limits: limits)
        }
    }

    /// Model-facing description: the tool's description (else its title, else
    /// a generic line), followed by the server name so tool search can match
    /// on it.
    public static func description(server: String, tool: MCPTool) -> String {
        let base = tool.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if let base, !base.isEmpty {
            text = base
        } else if let title = tool.title, !title.isEmpty {
            text = title
        } else {
            text = "MCP tool \(tool.name)"
        }
        return "\(text)\n\n(MCP server: \(server), tool: \(tool.name))"
    }

    /// Tool parameters must be an object schema with `properties`; MCP
    /// servers may omit `type` or `properties`.
    public static func parameters(from schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema else {
            return ["type": "object", "properties": .object([:])]
        }
        if object["type"] == nil { object["type"] = "object" }
        if object["properties"] == nil { object["properties"] = .object([:]) }
        return .object(object)
    }

    /// Convert a `tools/call` result, saving nothing. Results with `isError`
    /// throw `MCPToolCallError` carrying the server's message.
    public static func convert(server: String, tool: String, result: MCPCallToolResult) throws -> AgentToolResult {
        try finish(server: server, tool: tool, result: result, blocks: modelBlocks(result, saved: [:]))
    }

    /// Convert a `tools/call` result within `limits`: every binary block is
    /// saved through `limits.files` and the model told where; text beyond
    /// the limit is cut and images beyond it are left out, the whole result
    /// going to `limits.spill`.
    public static func convert(
        server: String,
        tool: String,
        result: MCPCallToolResult,
        limits: MCPResultLimits
    ) async throws -> AgentToolResult {
        let saved = await saveFiles(result, server: server, tool: tool, files: limits.files)
        var blocks = modelBlocks(result, saved: saved)
        if let maxTokens = limits.maxTokens, estimatedTokens(blocks, imageTokens: limits.imageTokens) > maxTokens {
            let locations = result.content.indices.compactMap { saved[$0] }
            blocks = await limit(blocks, server: server, tool: tool, maxTokens: maxTokens, limits: limits, saved: locations)
        }
        return try finish(server: server, tool: tool, result: result, blocks: blocks)
    }

    /// The binary payload of a content block: images, audio, and embedded
    /// resources that are not text.
    private static func binary(_ block: MCPContentBlock) -> (data: String, mimeType: String)? {
        switch block {
        case .image(let data, let mimeType), .audio(let data, let mimeType):
            return (data, mimeType)
        case .resource(_, let mimeType, nil, let blob?) where !isTextMimeType(mimeType):
            return (blob, mimeType ?? "application/octet-stream")
        default:
            return nil
        }
    }

    /// Saves every binary block through `files`; returns where each went, by
    /// content index. A block that fails to save is simply not listed.
    private static func saveFiles(
        _ result: MCPCallToolResult,
        server: String,
        tool: String,
        files: (any MCPResultFiles)?
    ) async -> [Int: String] {
        guard let files else { return [:] }
        var saved: [Int: String] = [:]
        for (index, block) in result.content.enumerated() {
            guard let payload = binary(block), let data = Data(base64Encoded: payload.data) else { continue }
            if let location = try? await files.save(data, mimeType: payload.mimeType, server: server, tool: tool) {
                saved[index] = location
            }
        }
        return saved
    }

    private static func modelBlocks(_ result: MCPCallToolResult, saved: [Int: String]) -> [ToolResultBlock] {
        var blocks = result.content.enumerated().flatMap { contentBlocks($1, savedAt: saved[$0]) }
        let hasText = blocks.contains { if case .text = $0 { return true } else { return false } }
        if !hasText, let structured = result.structuredContent {
            blocks.insert(.text(TextContent(text: structured.mcpJSONText(pretty: true))), at: 0)
        }
        return blocks
    }

    private static func finish(
        server: String, tool: String, result: MCPCallToolResult, blocks input: [ToolResultBlock]
    ) throws -> AgentToolResult {
        var blocks = input
        var details: [String: JSONValue] = ["server": .string(server), "tool": .string(tool)]
        if let structured = result.structuredContent { details["structuredContent"] = structured }

        if result.isError {
            let text = blocks.compactMap { block -> String? in
                if case .text(let content) = block { return content.text }
                return nil
            }.joined(separator: "\n")
            let message = text.isEmpty ? "MCP tool \(server)/\(tool) returned an error" : text
            throw MCPToolCallError(server: server, tool: tool, message: message, content: blocks)
        }
        if blocks.isEmpty {
            blocks = [.text(TextContent(text: "(no output)"))]
        }
        return AgentToolResult(content: blocks, details: .object(details))
    }

    static func estimatedTokens(_ blocks: [ToolResultBlock], imageTokens: Int) -> Int {
        blocks.reduce(0) { total, block in
            switch block {
            case .text(let text): return total + (text.text.count + 3) / 4
            case .image: return total + imageTokens
            }
        }
    }

    private static func limit(
        _ blocks: [ToolResultBlock],
        server: String,
        tool: String,
        maxTokens: Int,
        limits: MCPResultLimits,
        saved: [String]
    ) async -> [ToolResultBlock] {
        var budget = maxTokens * 4
        var kept: [ToolResultBlock] = []
        var omittedImages: [(data: String, mimeType: String)] = []
        var allText: [String] = []
        var shownCharacters = 0
        var totalCharacters = 0
        for block in blocks {
            switch block {
            case .text(let content):
                allText.append(content.text)
                totalCharacters += content.text.count
                if budget > 0 {
                    let part = String(content.text.prefix(budget))
                    budget -= part.count
                    shownCharacters += part.count
                    kept.append(.text(TextContent(text: part)))
                }
            case .image(let image):
                if budget >= limits.imageTokens * 4 {
                    budget -= limits.imageTokens * 4
                    kept.append(block)
                } else {
                    omittedImages.append((image.data, image.mimeType))
                }
            }
        }
        var note = "[MCP result over the size limit: showing \(shownCharacters) of \(totalCharacters) characters"
        if !omittedImages.isEmpty { note += ", \(omittedImages.count) image\(omittedImages.count == 1 ? "" : "s") left out" }
        // Images already saved as files need no second copy in the spill;
        // their paths may have been cut with the text, so list them again.
        if let spill = limits.spill,
           let location = try? await spill.spill(MCPSpilledResult(
               server: server, tool: tool, text: allText.joined(separator: "\n\n"),
               images: saved.isEmpty ? omittedImages : []
           )) {
            note += ". The full result is at \(location)"
        }
        if !saved.isEmpty { note += ". Its files are at \(saved.joined(separator: ", "))" }
        note += ".]"
        kept.append(.text(TextContent(text: note)))
        return kept
    }

    /// Model-facing blocks of one MCP content block.
    public static func contentBlocks(_ block: MCPContentBlock) -> [ToolResultBlock] {
        contentBlocks(block, savedAt: nil)
    }

    /// Model-facing blocks of one MCP content block whose binary payload, if
    /// any, was saved at `location`: an image the model can view is shown
    /// and followed by where it was saved; other binary content is replaced
    /// by a line saying what it was and where it went.
    static func contentBlocks(_ block: MCPContentBlock, savedAt location: String?) -> [ToolResultBlock] {
        switch block {
        case .text(let text):
            return [.text(TextContent(text: text))]
        case .image(let data, let mimeType):
            return imageBlocks(data: data, mimeType: mimeType, label: "Image", savedAt: location)
        case .audio(let data, let mimeType):
            return [.text(TextContent(text: "[Audio content (\(mimeType), \(formatSize(byteCount(data))))\(outcome(location))]"))]
        case .resource(let uri, let mimeType, let text, let blob):
            if let text {
                return [.text(TextContent(text: text))]
            }
            if let blob, let mimeType, mimeType.lowercased().hasPrefix("image/"), !isTextMimeType(mimeType) {
                return imageBlocks(data: blob, mimeType: mimeType, label: "Image resource \(uri)", savedAt: location)
            }
            if let blob, let data = Data(base64Encoded: blob), isTextMimeType(mimeType),
               let decoded = String(data: data, encoding: .utf8) {
                return [.text(TextContent(text: decoded))]
            }
            let size = blob.map { ", \(formatSize(byteCount($0)))" } ?? ""
            let saved = location.map { " saved at \($0)" } ?? ""
            return [.text(TextContent(text: "[Binary resource \(uri) (\(mimeType ?? "unknown type")\(size))\(saved)]"))]
        case .resourceLink(let uri, let name, let title, let description, let mimeType):
            var text = "[Resource \(uri)"
            if let label = title ?? name { text += " \"\(label)\"" }
            if let mimeType { text += " (\(mimeType))" }
            if let description, !description.isEmpty { text += ": \(description)" }
            text += "]"
            return [.text(TextContent(text: text))]
        case .unknown(let json):
            return [.text(TextContent(text: json.mcpJSONText()))]
        }
    }

    /// An image the model can view, then where it was saved; one it cannot
    /// (SVG, TIFF…) only as a line.
    private static func imageBlocks(data: String, mimeType: String, label: String, savedAt location: String?) -> [ToolResultBlock] {
        guard isViewableImage(mimeType) else {
            return [.text(TextContent(text: "[\(label) (\(mimeType), \(formatSize(byteCount(data))))\(outcome(location))]"))]
        }
        var blocks: [ToolResultBlock] = [.image(ImageContent(data: data, mimeType: mimeType))]
        if let location {
            blocks.append(.text(TextContent(text: "[\(label) saved at \(location)]")))
        }
        return blocks
    }

    private static func outcome(_ location: String?) -> String {
        location.map { " saved at \($0)" } ?? " omitted"
    }

    private static func byteCount(_ base64: String) -> Int {
        Data(base64Encoded: base64)?.count ?? base64.count * 3 / 4
    }

    /// Image types every provider accepts inline.
    static func isViewableImage(_ mimeType: String) -> Bool {
        let type = mimeType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        return ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"].contains(type)
    }

    static func isTextMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        let type = mimeType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        return type.hasPrefix("text/") || type == "application/json" || type.hasSuffix("+json") || type.hasSuffix("+xml")
    }

    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

/// Spills oversized tool results into a directory: the text as
/// `<server>-<tool>-<id>.txt`, each left-out image beside it.
public struct MCPDirectoryResultSpill: MCPResultSpill {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func spill(_ result: MCPSpilledResult) async throws -> String {
        // Results may hold private data: a 0700 directory and 0600 files.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let stem = "\(MCPToolNaming.sanitize(result.server))-\(MCPToolNaming.sanitize(result.tool))-\(UUID().uuidString.prefix(8))"
        let textURL = directory.appendingPathComponent("\(stem).txt")
        try Self.writePrivate(Data(result.text.utf8), to: textURL)
        var paths = [textURL.path]
        for (index, image) in result.images.enumerated() {
            guard let data = Data(base64Encoded: image.data) else { continue }
            let ext = image.mimeType.split(separator: "/").last.map(String.init) ?? "bin"
            let imageURL = directory.appendingPathComponent("\(stem)-\(index + 1).\(MCPToolNaming.sanitize(ext))")
            try Self.writePrivate(data, to: imageURL)
            paths.append(imageURL.path)
        }
        return paths.joined(separator: ", ")
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: url.path)
        else { throw MCPError.protocolError("Could not write \(url.path)") }
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}

/// Saves binary result content into a directory as
/// `<server>-<tool>-<sha256 prefix>.<ext>`, so the same bytes from the same
/// tool land in one file however often they come back.
public struct MCPDirectoryResultFiles: MCPResultFiles {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ data: Data, mimeType: String, server: String, tool: String) async throws -> String {
        // Results may hold private data: a 0700 directory and 0600 files.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = "\(MCPToolNaming.sanitize(server))-\(MCPToolNaming.sanitize(tool))-\(digest).\(Self.fileExtension(for: mimeType))"
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Written aside and moved in, so a reader never sees half a file.
            let partial = directory.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8))")
            guard FileManager.default.createFile(atPath: partial.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw MCPError.protocolError("Could not write \(partial.path)")
            }
            do {
                try FileManager.default.moveItem(at: partial, to: url)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                // Another call saved the same bytes first.
                if !FileManager.default.fileExists(atPath: url.path) { throw error }
            }
        }
        return url.path
    }

    /// The usual extension for a MIME type: its subtype, with the common
    /// spellings normalized; `bin` when there is nothing usable.
    static func fileExtension(for mimeType: String) -> String {
        let type = mimeType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        let known: [String: String] = [
            "image/jpeg": "jpg", "image/jpg": "jpg", "image/svg+xml": "svg", "image/x-icon": "ico",
            "image/vnd.microsoft.icon": "ico", "audio/mpeg": "mp3", "audio/x-wav": "wav", "audio/wave": "wav",
            "audio/mp4": "m4a", "application/octet-stream": "bin", "application/zip": "zip",
            "application/gzip": "gz", "text/plain": "txt",
        ]
        if let ext = known[type] { return ext }
        guard let subtype = type.split(separator: "/").last.map(String.init) else { return "bin" }
        let base = subtype.split(separator: "+").first.map(String.init) ?? subtype
        let ext = MCPToolNaming.sanitize(base.hasPrefix("x-") ? String(base.dropFirst(2)) : base)
        return ext.isEmpty || ext.count > 10 ? "bin" : ext
    }
}
