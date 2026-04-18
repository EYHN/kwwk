import Foundation

/// Regenerates `Sources/KWAI/Resources/models.json` from pi's TypeScript
/// `models.generated.ts`. Usage:
///
///   swift run kw-generate-models \
///       /path/to/pi-mono/packages/ai/src/models.generated.ts \
///       Sources/KWAI/Resources/models.json
///
/// We don't ship the raw TS — we regex-rewrite it into plain JSON so the
/// runtime can decode it with `JSONSerialization` (no JS/Node dependency).
@main
struct GenerateModels {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data(
                "usage: kw-generate-models <models.generated.ts> <output.json>\n".utf8
            ))
            exit(1)
        }
        let inputPath = args[1]
        let outputPath = args[2]

        let raw = try String(contentsOf: URL(fileURLWithPath: inputPath), encoding: .utf8)
        let json = try convert(raw)

        // Round-trip via JSONSerialization so we catch any remaining syntax
        // issues up front and get canonical sorted output.
        guard let data = json.data(using: .utf8) else {
            FileHandle.standardError.write(Data("failed to encode JSON string\n".utf8))
            exit(2)
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            let snippet = String(json.prefix(400))
            FileHandle.standardError.write(Data("JSON parse failed: \(error)\nsnippet:\n\(snippet)\n".utf8))
            exit(3)
        }
        let outputData = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try outputData.write(to: outputURL)

        // Report a coverage summary.
        var perProvider: [(String, Int)] = []
        if let root = obj as? [String: Any] {
            for key in root.keys.sorted() {
                if let inner = root[key] as? [String: Any] {
                    perProvider.append((key, inner.count))
                }
            }
        }
        print("generated \(outputPath) (\(outputData.count) bytes)")
        let width = perProvider.map { $0.0.count }.max() ?? 10
        for (provider, count) in perProvider {
            let pad = String(repeating: " ", count: max(0, width - provider.count))
            print("  \(provider)\(pad)  \(count) models")
        }
    }

    /// Apply the regex sequence that rewrites pi's TypeScript object literal
    /// into plain JSON. Order matters — `satisfies` must be stripped before
    /// we touch trailing commas, otherwise the `,` on that line gets eaten.
    static func convert(_ raw: String) throws -> String {
        var s = raw

        // Strip comments and imports (everything before the first `{`).
        if let range = s.range(of: "export const MODELS = ") {
            s = String(s[range.upperBound...])
        } else if let firstBrace = s.firstIndex(of: "{") {
            s = String(s[firstBrace...])
        }

        // Trim trailing `} as const;` → `}`.
        s = s.replacingOccurrences(of: " as const;", with: "")
        s = s.replacingOccurrences(of: "as const;", with: "")

        // Strip `satisfies Model<"…">` annotations.
        s = s.replacingOccurrences(
            of: #" satisfies Model<".*?">"#,
            with: "",
            options: .regularExpression
        )

        // Quote unquoted object keys (any identifier followed by `:` sitting
        // on its own line after whitespace).
        s = s.replacingOccurrences(
            of: #"(?m)^(\s+)([a-zA-Z_][a-zA-Z0-9_]*):"#,
            with: #"$1"$2":"#,
            options: .regularExpression
        )

        // JSON forbids trailing commas — drop them before `}` or `]`.
        for _ in 0..<4 {  // iterate a few times to catch nested cases
            s = s.replacingOccurrences(
                of: #",(\s*[}\]])"#,
                with: "$1",
                options: .regularExpression
            )
        }

        // Strip any stray leading/trailing whitespace.
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }
}
