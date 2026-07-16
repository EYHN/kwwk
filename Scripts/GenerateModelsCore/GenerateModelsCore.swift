import Foundation

public enum GenerateModelsCore {
    public static let defaultOutputPath = "Sources/KWWKAI/Resources/models.json"

    public static func generate(fromFile inputURL: URL) throws -> ModelGenerationResult {
        let raw = try String(contentsOf: inputURL, encoding: .utf8)
        return try generate(from: raw, resolvingImportsRelativeTo: inputURL.deletingLastPathComponent())
    }

    public static func generate(from raw: String) throws -> ModelGenerationResult {
        try generate(from: raw, resolvingImportsRelativeTo: nil)
    }

    private static func generate(from raw: String, resolvingImportsRelativeTo baseURL: URL?) throws -> ModelGenerationResult {
        let expanded = try inlineImportedModelObjects(in: raw, baseURL: baseURL)
        let json = try convert(expanded)

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
        guard let parsedRoot = parsed as? [String: Any] else {
            throw GenerateModelsCoreError.conversion("top-level catalog is not an object")
        }
        let root = normalizeCatalog(parsedRoot)

        let outputData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        return ModelGenerationResult(outputData: outputData, root: root)
    }

    /// OMP's catalog is now stored as sparse JSON model specs. Translate the
    /// pieces whose runtime representation differs from KWWK's bundled schema.
    private static func normalizeCatalog(_ root: [String: Any]) -> [String: Any] {
        let excludedProviders = ["cursor", "google-antigravity", "google-gemini-cli"]
        var normalized = root.filter { !excludedProviders.contains($0.key) }

        for (provider, value) in normalized {
            guard let models = value as? [String: Any] else { continue }
            normalized[provider] = models.mapValues { value in
                guard var model = value as? [String: Any],
                      let thinking = model.removeValue(forKey: "thinking") as? [String: Any]
                else { return value }

                if model["thinkingLevelMap"] == nil,
                   let efforts = thinking["efforts"] as? [String],
                   !efforts.isEmpty {
                    let effortMap = thinking["effortMap"] as? [String: String] ?? [:]
                    let supported = Set(efforts)
                    let levels = ["minimal", "low", "medium", "high", "xhigh", "max"]
                    var levelMap: [String: Any] = [:]
                    for level in levels {
                        levelMap[level] = supported.contains(level)
                            ? (effortMap[level] ?? level)
                            : NSNull()
                    }
                    if let off = effortMap["off"] { levelMap["off"] = off }
                    model["thinkingLevelMap"] = levelMap
                }

                if thinking["mode"] as? String == "anthropic-adaptive" {
                    var compat = model["compat"] as? [String: Any] ?? [:]
                    compat["forceAdaptiveThinking"] = true
                    model["compat"] = compat
                }

                return model
            }
        }
        return normalized
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

    private static func inlineImportedModelObjects(in raw: String, baseURL: URL?) throws -> String {
        guard let baseURL else { return raw }

        let imports = importedModelConstants(in: raw)
        guard !imports.isEmpty else { return raw }

        let providerReferences = providerConstantReferences(in: raw)
        guard !providerReferences.isEmpty else { return raw }

        var lines = ["export const MODELS = {"]
        for reference in providerReferences {
            guard let importPath = imports[reference.constant] else {
                throw GenerateModelsCoreError.conversion(
                    "missing import for provider constant \(reference.constant)"
                )
            }

            let importedURL = URL(fileURLWithPath: importPath, relativeTo: baseURL).standardizedFileURL
            let importedRaw = try String(contentsOf: importedURL, encoding: .utf8)
            let object = try objectLiteral(named: reference.constant, in: importedRaw)
            lines.append(#""\#(reference.provider)": \#(object),"#)
        }
        lines.append("} as const;")
        return lines.joined(separator: "\n")
    }

    private static func importedModelConstants(in raw: String) -> [String: String] {
        let pattern = #"(?m)^\s*import\s+\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\s+from\s+"([^"]+)";"#
        let matches = regexMatches(pattern, in: raw)

        var imports: [String: String] = [:]
        for match in matches {
            guard match.count == 2 else { continue }
            imports[match[0]] = match[1]
        }
        return imports
    }

    private static func providerConstantReferences(in raw: String) -> [(provider: String, constant: String)] {
        guard let modelsObject = try? objectLiteral(named: "MODELS", in: raw) else { return [] }

        let pattern = #"(?m)^\s*"([^"]+)"\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*$"#
        let matches = regexMatches(pattern, in: modelsObject)
        return matches.compactMap { match in
            guard match.count == 2 else { return nil }
            return (provider: match[0], constant: match[1])
        }
    }

    private static func objectLiteral(named constant: String, in raw: String) throws -> String {
        let marker = "export const \(constant) ="
        guard let markerRange = raw.range(of: marker) else {
            throw GenerateModelsCoreError.conversion("could not find exported constant \(constant)")
        }
        guard let start = raw[markerRange.upperBound...].firstIndex(of: "{") else {
            throw GenerateModelsCoreError.conversion("could not find object for exported constant \(constant)")
        }
        let end = try matchingBrace(in: raw, from: start)
        return String(raw[start...end])
    }

    private static func matchingBrace(in text: String, from start: String.Index) throws -> String.Index {
        var depth = 0
        var index = start
        var quote: Character?
        var escaped = false

        while index < text.endIndex {
            let character = text[index]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }

            index = text.index(after: index)
        }

        throw GenerateModelsCoreError.conversion("unterminated object literal")
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return ns.substring(with: range)
            }
        }
    }
}

public struct ModelGenerationResult {
    public let outputData: Data
    public let root: [String: Any]
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
