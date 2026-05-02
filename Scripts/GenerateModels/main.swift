import Foundation

/// Regenerates KWWK's bundled model catalog from pi-mono's generated
/// TypeScript catalog.
///
/// Usage:
///
///   swift run kwwk-generate-models \
///       /path/to/pi-mono/packages/ai/src/models.generated.ts
///
/// By default the output is written to:
///
///   Sources/KWWKAI/Resources/models.json
///
/// The Google Gemini CLI and Antigravity providers are intentionally omitted
/// because KWWK does not ship those upstream subscription/OAuth surfaces.
@main
struct GenerateModels {
    static let defaultOutputPath = "Sources/KWWKAI/Resources/models.json"
    static let defaultExcludedProviders: Set<String> = [
        "google-antigravity",
        "google-gemini-cli",
    ]

    static func main() throws {
        do {
            try run()
        } catch GenerateError.usage(let text) {
            FileHandle.standardError.write(Data("\(text)\n\n\(usage)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("kwwk-generate-models: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let options = try Options.parse(CommandLine.arguments.dropFirst())
        let raw = try String(contentsOf: URL(fileURLWithPath: options.inputPath), encoding: .utf8)
        let json = try convert(raw)

        guard let data = json.data(using: .utf8) else {
            throw GenerateError.conversion("failed to encode converted JSON")
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            let snippet = String(json.prefix(500))
            throw GenerateError.conversion("JSON parse failed: \(error)\nsnippet:\n\(snippet)")
        }
        guard var root = parsed as? [String: Any] else {
            throw GenerateError.conversion("top-level catalog is not an object")
        }

        var dropped: [(String, Int)] = []
        for provider in options.excludedProviders.sorted() {
            if let models = root.removeValue(forKey: provider) as? [String: Any] {
                dropped.append((provider, models.count))
            }
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        let outputURL = URL(fileURLWithPath: options.outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try outputData.write(to: outputURL)

        printSummary(outputPath: options.outputPath, outputBytes: outputData.count, root: root, dropped: dropped)
    }

    static func convert(_ raw: String) throws -> String {
        var text = raw

        if let range = text.range(of: "export const MODELS = ") {
            text = String(text[range.upperBound...])
        } else if let firstBrace = text.firstIndex(of: "{") {
            text = String(text[firstBrace...])
        } else {
            throw GenerateError.conversion("could not find MODELS object")
        }

        text = text.replacingOccurrences(of: #"(?m)^\s*//.*\n"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: " as const;", with: "")
        text = text.replacingOccurrences(of: "as const;", with: "")
        text = text.replacingOccurrences(
            of: #" satisfies Model<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?m)^(\s+)([A-Za-z_][A-Za-z0-9_]*):"#,
            with: #"$1"$2":"#,
            options: .regularExpression
        )

        for _ in 0..<6 {
            text = text.replacingOccurrences(
                of: #",(\s*[}\]])"#,
                with: "$1",
                options: .regularExpression
            )
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func printSummary(
        outputPath: String,
        outputBytes: Int,
        root: [String: Any],
        dropped: [(String, Int)]
    ) {
        let providers = root.keys.sorted()
        let totalModels = providers.reduce(0) { total, provider in
            total + ((root[provider] as? [String: Any])?.count ?? 0)
        }

        print("generated \(outputPath) (\(outputBytes) bytes)")
        print("  providers: \(providers.count)")
        print("  models:    \(totalModels)")

        if !dropped.isEmpty {
            print("  dropped:")
            for (provider, count) in dropped {
                print("    \(provider): \(count) models")
            }
        }

        print("  by provider:")
        let width = providers.map(\.count).max() ?? 10
        for provider in providers {
            let count = (root[provider] as? [String: Any])?.count ?? 0
            let pad = String(repeating: " ", count: max(0, width - provider.count))
            print("    \(provider)\(pad)  \(count)")
        }
    }

    static let usage = """
    usage: kwwk-generate-models <models.generated.ts> [output.json] [--include-google-cli]

    arguments:
      models.generated.ts      pi-mono packages/ai/src/models.generated.ts
      output.json              optional output path; defaults to \(defaultOutputPath)

    options:
      --include-google-cli     keep google-gemini-cli and google-antigravity entries
      -h, --help               show this help
    """
}

private struct Options {
    var inputPath: String
    var outputPath: String
    var excludedProviders: Set<String>

    static func parse(_ rawArguments: ArraySlice<String>) throws -> Options {
        var positional: [String] = []
        var excluded = GenerateModels.defaultExcludedProviders

        for argument in rawArguments {
            switch argument {
            case "-h", "--help":
                throw GenerateError.usage(GenerateModels.usage)
            case "--include-google-cli":
                excluded.remove("google-antigravity")
                excluded.remove("google-gemini-cli")
            default:
                if argument.hasPrefix("-") {
                    throw GenerateError.usage("unknown option: \(argument)")
                }
                positional.append(argument)
            }
        }

        guard positional.count == 1 || positional.count == 2 else {
            throw GenerateError.usage("expected input path and optional output path")
        }

        return Options(
            inputPath: positional[0],
            outputPath: positional.count == 2 ? positional[1] : GenerateModels.defaultOutputPath,
            excludedProviders: excluded
        )
    }
}

private enum GenerateError: Error, CustomStringConvertible {
    case usage(String)
    case conversion(String)

    var description: String {
        switch self {
        case .usage(let text), .conversion(let text):
            return text
        }
    }
}
