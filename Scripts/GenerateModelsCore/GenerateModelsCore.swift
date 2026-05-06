import Foundation

public enum GenerateModelsCore {
    public static let defaultOutputPath = "Sources/KWWKAI/Resources/models.json"
    public static let defaultExcludedProviders: Set<String> = [
        "google-antigravity",
        "google-gemini-cli",
    ]

    public static func generate(
        from raw: String,
        excluding excludedProviders: Set<String> = defaultExcludedProviders
    ) throws -> ModelGenerationResult {
        let json = try convert(raw)

        guard let data = json.data(using: .utf8) else {
            throw GenerateModelsCoreError.conversion("failed to encode converted JSON")
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            let snippet = String(json.prefix(500))
            throw GenerateModelsCoreError.conversion("JSON parse failed: \(error)\nsnippet:\n\(snippet)")
        }
        guard var root = parsed as? [String: Any] else {
            throw GenerateModelsCoreError.conversion("top-level catalog is not an object")
        }

        var dropped: [DroppedProvider] = []
        for provider in excludedProviders.sorted() {
            if let models = root.removeValue(forKey: provider) as? [String: Any] {
                dropped.append(DroppedProvider(provider: provider, count: models.count))
            }
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        return ModelGenerationResult(outputData: outputData, root: root, dropped: dropped)
    }

    public static func convert(_ raw: String) throws -> String {
        var text = raw

        if let range = text.range(of: "export const MODELS = ") {
            text = String(text[range.upperBound...])
        } else if let firstBrace = text.firstIndex(of: "{") {
            text = String(text[firstBrace...])
        } else {
            throw GenerateModelsCoreError.conversion("could not find MODELS object")
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
}

public struct ModelGenerationResult {
    public let outputData: Data
    public let root: [String: Any]
    public let dropped: [DroppedProvider]
}

public struct DroppedProvider: Equatable {
    public let provider: String
    public let count: Int

    public init(provider: String, count: Int) {
        self.provider = provider
        self.count = count
    }
}

public enum GenerateModelsCoreError: Error, CustomStringConvertible {
    case conversion(String)

    public var description: String {
        switch self {
        case .conversion(let text):
            return text
        }
    }
}
