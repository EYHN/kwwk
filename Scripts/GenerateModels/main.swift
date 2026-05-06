import Foundation
import KWWKGenerateModelsCore

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
@main
struct GenerateModels {
    static func main() throws {
        do {
            try run()
        } catch GenerateError.help {
            FileHandle.standardOutput.write(Data("\(usage)\n".utf8))
            exit(0)
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
        let result = try GenerateModelsCore.generate(from: raw)
        let outputURL = URL(fileURLWithPath: options.outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.outputData.write(to: outputURL, options: [.atomic])

        printSummary(
            outputPath: options.outputPath,
            outputBytes: result.outputData.count,
            root: result.root
        )
    }

    private static func printSummary(
        outputPath: String,
        outputBytes: Int,
        root: [String: Any]
    ) {
        let providers = root.keys.sorted()
        let totalModels = providers.reduce(0) { total, provider in
            total + ((root[provider] as? [String: Any])?.count ?? 0)
        }

        print("generated \(outputPath) (\(outputBytes) bytes)")
        print("  providers: \(providers.count)")
        print("  models:    \(totalModels)")

        print("  by provider:")
        let width = providers.map(\.count).max() ?? 10
        for provider in providers {
            let count = (root[provider] as? [String: Any])?.count ?? 0
            let pad = String(repeating: " ", count: max(0, width - provider.count))
            print("    \(provider)\(pad)  \(count)")
        }
    }

    static let usage = """
    usage: kwwk-generate-models <models.generated.ts> [output.json]

    arguments:
      models.generated.ts      pi-mono packages/ai/src/models.generated.ts
      output.json              optional output path; defaults to \(GenerateModelsCore.defaultOutputPath)

    options:
      -h, --help               show this help
    """
}

private struct Options {
    var inputPath: String
    var outputPath: String

    static func parse(_ rawArguments: ArraySlice<String>) throws -> Options {
        var positional: [String] = []

        for argument in rawArguments {
            switch argument {
            case "-h", "--help":
                throw GenerateError.help
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
            outputPath: positional.count == 2 ? positional[1] : GenerateModelsCore.defaultOutputPath
        )
    }
}

private enum GenerateError: Error, CustomStringConvertible {
    case help
    case usage(String)

    var description: String {
        switch self {
        case .help:
            return GenerateModels.usage
        case .usage(let text):
            return text
        }
    }
}
