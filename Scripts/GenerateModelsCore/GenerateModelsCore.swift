import Foundation

public enum GenerateModelsCore {
    public static let defaultOutputPath = "Sources/KWWKAI/Resources/models.json"

    /// What kwwk knows better than pi-mono, kept beside the generator so a
    /// regeneration carries it instead of losing it.
    public static let defaultOverridesPath = "Scripts/models.overrides.json"

    public static func generate(fromFile inputURL: URL, overridesFile: URL? = nil) throws -> ModelGenerationResult {
        let raw = try String(contentsOf: inputURL, encoding: .utf8)
        let overrides = try overridesFile.map { try Data(contentsOf: $0) }
        return try generate(
            from: raw,
            resolvingImportsRelativeTo: inputURL.deletingLastPathComponent(),
            overrides: overrides
        )
    }

    public static func generate(from raw: String, overrides: Data? = nil) throws -> ModelGenerationResult {
        try generate(from: raw, resolvingImportsRelativeTo: nil, overrides: overrides)
    }

    /// Lays `overrides` over pi-mono's catalog:
    ///
    ///     {"<provider>": {"<model id>": {"contextWindow": 264000, "compat": {"x": true}}}}
    ///
    /// An object merges into the one under it, key by key; any other value
    /// replaces; `null` takes the key — or the model, or the provider — out.
    /// An object marked `"$replace": true` stands in whole for the one under
    /// it instead, its nulls kept as values (a `thinkingLevelMap` that turns a
    /// level off). A key beginning with `$` is a note to the reader and is
    /// dropped.
    static func applying(overrides: Data, to root: [String: Any]) throws -> [String: Any] {
        guard let patch = try JSONSerialization.jsonObject(with: overrides) as? [String: Any] else {
            throw GenerateModelsCoreError.conversion("overrides are not a JSON object")
        }
        return merge(patch, into: root)
    }

    private static func merge(_ patch: [String: Any], into base: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in patch where !key.hasPrefix("$") {
            if value is NSNull {
                out[key] = nil
            } else if let object = value as? [String: Any], object["$replace"] as? Bool == true {
                out[key] = object.filter { !$0.key.hasPrefix("$") }
            } else if let object = value as? [String: Any] {
                out[key] = merge(object, into: out[key] as? [String: Any] ?? [:])
            } else {
                out[key] = value
            }
        }
        return out
    }

    private static func generate(
        from raw: String,
        resolvingImportsRelativeTo baseURL: URL?,
        overrides: Data?
    ) throws -> ModelGenerationResult {
        let expanded = try inlineImportedModelObjects(in: raw, baseURL: baseURL)
        let json = try convert(expanded)
        let data = Data(json.utf8)

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
        let overlaid = try overrides.map { try applying(overrides: $0, to: parsedRoot) } ?? parsedRoot
        let root = overlaid.mapValues(normalizeJSONNumbers)

        let outputData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        return ModelGenerationResult(outputData: outputData, root: root)
    }

    /// JSONSerialization may expand ordinary decimal prices such as `0.33`
    /// into binary floating-point artifacts such as `0.33000000000000002`
    /// when re-encoding an `NSNumber`. Preserve the concise decimal spelling
    /// from pi-mono so regeneration does not create semantic no-op churn.
    private static func normalizeJSONNumbers(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValues(normalizeJSONNumbers)
        }
        if let array = value as? [Any] {
            return array.map(normalizeJSONNumbers)
        }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "d" || type == "f" {
                return NSDecimalNumber(string: number.stringValue)
            }
        }
        return value
    }

    public static func convert(_ raw: String) throws -> String {
        var text = raw

        if text.range(of: "export const MODELS") != nil {
            text = try objectLiteral(named: "MODELS", in: text)
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
            let object = try providerModelsObject(
                named: reference.constant,
                in: importedRaw,
                sourceURL: importedURL
            )
            lines.append(#""\#(reference.provider)": \#(object),"#)
        }
        lines.append("} as const;")
        return lines.joined(separator: "\n")
    }

    /// pi-mono provider catalogs were originally emitted as inline TypeScript
    /// object literals. Newer generated catalogs import their values from a
    /// sibling JSON file and retain only a type map in the `.models.ts` file.
    /// Prefer the inline object for backwards compatibility, otherwise resolve
    /// the exported identifier to its JSON import and inline that JSON object.
    private static func providerModelsObject(
        named constant: String,
        in raw: String,
        sourceURL: URL
    ) throws -> String {
        let marker = "export const \(constant)"
        guard let markerRange = raw.range(of: marker) else {
            throw GenerateModelsCoreError.conversion("could not find exported constant \(constant)")
        }
        guard let assignment = assignmentOperator(
            in: raw,
            after: markerRange.upperBound
        ) else {
            throw GenerateModelsCoreError.conversion("could not find assignment for exported constant \(constant)")
        }

        let expression = raw[raw.index(after: assignment)...]
            .drop(while: { $0.isWhitespace })
        guard let first = expression.first else {
            throw GenerateModelsCoreError.conversion("missing value for exported constant \(constant)")
        }

        if first == "{" {
            let end = try matchingBrace(in: raw, from: expression.startIndex)
            return String(raw[expression.startIndex...end])
        }

        let expressionText = String(expression)
        let directImport = regexMatches(#"^([A-Za-z_][A-Za-z0-9_]*)\s+as\b"#, in: expressionText)
            .first?.first
        // `flattenModelCatalog` keys groups by model id; the newer
        // `flattenChatModelCatalog` keys them as `<type>:<id>` alongside image
        // and classifier entries, and only chat models belong in the catalog.
        let flattenMatch = regexMatches(
            #"^flatten(Chat)?ModelCatalog\(\s*"[^"]+"\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)"#,
            in: expressionText
        ).first
        let flattenedImport = flattenMatch?.last
        let chatOnly = flattenMatch?.count == 2
        guard let importedName = directImport ?? flattenedImport else {
            throw GenerateModelsCoreError.conversion(
                "unsupported value for exported constant \(constant)"
            )
        }

        let jsonImports = importedJSONValues(in: raw)
        guard let importPath = jsonImports[importedName] else {
            throw GenerateModelsCoreError.conversion(
                "missing JSON import for provider constant \(constant)"
            )
        }

        let jsonURL = URL(
            fileURLWithPath: importPath,
            relativeTo: sourceURL.deletingLastPathComponent()
        ).standardizedFileURL
        let json: String
        do {
            json = try String(contentsOf: jsonURL, encoding: .utf8)
        } catch {
            throw GenerateModelsCoreError.conversion(
                "could not read provider JSON for \(constant) at \(jsonURL.path); "
                    + "run `npm run hydrate-model-data` in pi-mono's packages/ai first: \(error)"
            )
        }

        let data = Data(json.utf8)
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GenerateModelsCoreError.conversion(
                "invalid provider JSON for \(constant): \(error)"
            )
        }
        guard let object = parsed as? [String: Any] else {
            throw GenerateModelsCoreError.conversion(
                "provider JSON for \(constant) is not an object"
            )
        }
        if flattenedImport != nil {
            var models: [String: Any] = [:]
            for (groupName, value) in object {
                guard let group = value as? [String: Any] else {
                    throw GenerateModelsCoreError.conversion(
                        "provider JSON group \(groupName) for \(constant) is not an object"
                    )
                }
                for (key, value) in group {
                    var model = value
                    var modelId = key
                    if chatOnly {
                        guard var object = value as? [String: Any],
                              object["type"] as? String == "chat",
                              let id = object["id"] as? String else { continue }
                        object.removeValue(forKey: "type")
                        model = object
                        modelId = id
                    }
                    guard models[modelId] == nil else {
                        throw GenerateModelsCoreError.conversion(
                            "duplicate model \(modelId) while flattening provider JSON for \(constant)"
                        )
                    }
                    models[modelId] = model
                }
            }
            let flattened = try JSONSerialization.data(withJSONObject: models, options: [.sortedKeys])
            return String(decoding: flattened, as: UTF8.self)
        }
        return json
    }

    private static func importedModelConstants(in raw: String) -> [String: String] {
        let pattern = #"(?m)^\s*import\s+\{([^}]*)\}\s+from\s+"([^"]+)";"#
        let matches = regexMatches(pattern, in: raw)

        var imports: [String: String] = [:]
        for match in matches {
            for name in match[0].split(separator: ",") {
                let constant = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !constant.isEmpty, !constant.hasPrefix("type ") else { continue }
                imports[constant] = match[1]
            }
        }
        return imports
    }

    private static func importedJSONValues(in raw: String) -> [String: String] {
        let pattern = #"(?m)^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)\s+from\s+"([^"]+\.json)""#
        let matches = regexMatches(pattern, in: raw)

        var imports: [String: String] = [:]
        for match in matches {
            imports[match[0]] = match[1]
        }
        return imports
    }

    private static func providerConstantReferences(in raw: String) -> [(provider: String, constant: String)] {
        guard let modelsObject = try? objectLiteral(named: "MODELS", in: raw) else { return [] }

        let pattern = #"(?m)^\s*"([^"]+)"\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*$"#
        let matches = regexMatches(pattern, in: modelsObject)
        return matches.map { (provider: $0[0], constant: $0[1]) }
    }

    private static func objectLiteral(named constant: String, in raw: String) throws -> String {
        let marker = "export const \(constant)"
        guard let markerRange = raw.range(of: marker) else {
            throw GenerateModelsCoreError.conversion("could not find exported constant \(constant)")
        }
        guard let assignment = assignmentOperator(
            in: raw,
            after: markerRange.upperBound
        ) else {
            throw GenerateModelsCoreError.conversion("could not find assignment for exported constant \(constant)")
        }
        guard let start = raw[raw.index(after: assignment)...].firstIndex(of: "{") else {
            throw GenerateModelsCoreError.conversion("could not find object for exported constant \(constant)")
        }
        let end = try matchingBrace(in: raw, from: start)
        return String(raw[start...end])
    }

    /// Finds the declaration's assignment operator while skipping balanced
    /// delimiters in an optional TypeScript type annotation.
    private static func assignmentOperator(
        in text: String,
        after start: String.Index
    ) -> String.Index? {
        var index = start
        var delimiterStack: [Character] = []
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
            } else if character == "{" || character == "[" || character == "(" {
                delimiterStack.append(character)
            } else if character == "}" || character == "]" || character == ")" {
                _ = delimiterStack.popLast()
            } else if character == "=" && delimiterStack.isEmpty {
                return index
            } else if character == ";" && delimiterStack.isEmpty {
                return nil
            }

            index = text.index(after: index)
        }

        return nil
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
