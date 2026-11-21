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
        `Sources/**/*.swift` recurses under it. Returns up to \(Truncate.findDefaultLimit) paths \
        unless `limit` says otherwise, and at most \(Truncate.formatSize(Truncate.listingMaxBytes)) of text.
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
                rawRoot = p.isEmpty ? "." : p
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
                if case .double(let v) = obj["limit"] ?? .null { return clampedToolInt(v) }
                return nil
            }()

            let cap = limit.map { max(0, $0) } ?? Truncate.findDefaultLimit
            // One past the cap tells whether more matches exist.
            let found = try await ops.find(pattern: pattern, cwd: root, limit: min(cap, Int.max - 1) + 1)
            if found.isEmpty {
                return AgentToolResult(
                    content: [.text(TextContent(text: "No files match \(pattern)"))],
                    details: .object(["files": .array([])])
                )
            }
            let listing = cappedListing(found, limit: cap, explicitLimit: limit != nil)
            return AgentToolResult(
                content: [.text(TextContent(text: listing.text))],
                details: .object(["files": .array(listing.shown.map { .string($0) })])
            )
        }
    )
    tool.fileAccessPolicy = fileAccessPolicy
    tool.fileAccessCwd = cwd
    tool.codingToolCapabilities = .find
    return tool
}

/// The first `limit` entries that fit in `Truncate.listingMaxBytes`, plus a
/// notice when any were left out. Shared by `find` and `ls`.
func cappedListing(
    _ entries: [String],
    limit: Int,
    explicitLimit: Bool
) -> (text: String, shown: [String]) {
    var shown = Array(entries.prefix(limit))
    let byCount = entries.count > shown.count
    let fitting = Truncate.entriesFitting(shown, maxBytes: Truncate.listingMaxBytes)
    let byBytes = fitting < shown.count
    shown = Array(shown.prefix(fitting))
    var text = shown.joined(separator: "\n")
    if byBytes {
        text += "\n\n[truncated: showing the first \(shown.count) entries (\(Truncate.formatSize(Truncate.listingMaxBytes)) limit); narrow the pattern or path to see the rest]"
    } else if byCount {
        let hint = explicitLimit
            ? "pass a larger limit or narrow the pattern or path"
            : "pass limit or narrow the pattern or path"
        text += "\n\n[truncated: showing the first \(shown.count) entries; more exist — \(hint)]"
    }
    return (text, shown)
}
