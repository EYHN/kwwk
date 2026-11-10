import ArgumentParser
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
/// Current pi-mono checkouts must first run `npm run hydrate-model-data` in
/// `packages/ai` to materialize the Git-ignored provider JSON files
/// referenced by the generated TypeScript.
///
/// By default the output is written to:
///
///   Sources/KWWKAI/Resources/models.json
///
/// NOTE: when syncing the model catalogs, also regenerate the Cursor
/// catalog (`swift run kwwk-generate-cursor-models`) — the two bundled
/// files are updated together.
///
@main
struct GenerateModels: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kwwk-generate-models",
        abstract: "Regenerate the bundled model catalog from pi-mono's generated TypeScript catalog.",
        discussion: """
        \(GenerateModelsCore.defaultOverridesPath), read from the working directory, is laid over pi-mono's \
        catalog: kwwk's own corrections, kept across syncs.

        Also run `swift run kwwk-generate-cursor-models` when syncing: the Cursor catalog \
        (cursor-models.json) is regenerated separately.

        Current pi-mono checkouts must first run `npm run hydrate-model-data` in pi-mono's packages/ai \
        to materialize the Git-ignored provider JSON files.
        """
    )

    @Argument(help: ArgumentHelp("pi-mono's packages/ai/src/models.generated.ts.", valueName: "models.generated.ts"))
    var inputPath: String

    @Argument(help: ArgumentHelp("Output path.", valueName: "output.json"))
    var outputPath: String = GenerateModelsCore.defaultOutputPath

    func run() throws {
        // kwwk's own corrections ride every regeneration when the command is
        // run from the repository root, where they live.
        let overridesURL = URL(fileURLWithPath: GenerateModelsCore.defaultOverridesPath)
        let hasOverrides = FileManager.default.fileExists(atPath: overridesURL.path)
        let result = try GenerateModelsCore.generate(
            fromFile: URL(fileURLWithPath: inputPath),
            overridesFile: hasOverrides ? overridesURL : nil
        )
        print(hasOverrides
            ? "applied \(GenerateModelsCore.defaultOverridesPath)"
            : "no \(GenerateModelsCore.defaultOverridesPath) here; pi-mono's catalog as it is")
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.outputData.write(to: outputURL, options: [.atomic])

        Self.printSummary(
            outputPath: outputPath,
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
        let counts = providers.map { (root[$0] as? [String: Any])?.count ?? 0 }
        let totalModels = counts.reduce(0, +)

        print("generated \(outputPath) (\(outputBytes) bytes)")
        print("  providers: \(providers.count)")
        print("  models:    \(totalModels)")

        print("  by provider:")
        let width = providers.map(\.count).max() ?? 0
        for (provider, count) in zip(providers, counts) {
            let pad = String(repeating: " ", count: max(0, width - provider.count))
            print("    \(provider)\(pad)  \(count)")
        }
    }
}
