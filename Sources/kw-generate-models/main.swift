import Foundation

@main
struct GenerateModels {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, args[0] != "-h", args[0] != "--help" else {
            FileHandle.standardError.write(Data(
                "usage: kw-generate-models <models.generated.ts-or-url> <output.json>\n".utf8
            ))
            Foundation.exit(args.first == "-h" || args.first == "--help" ? 0 : 2)
        }

        let source = args[0]
        let output = URL(fileURLWithPath: args[1])
        let tsSource = try readSource(source)
        let jsonText = try tsModelsToJSON(tsSource)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(jsonText.utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(decoded)

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: output, options: .atomic)
        try Data("\n".utf8).append(to: output)

        if case let .object(providers) = decoded {
            let counts = providers.mapValues { providerValue -> Int in
                if case let .object(models) = providerValue {
                    return models.count
                }
                return 0
            }
            let total = counts.values.reduce(0, +)
            print("generated \(output.path) (\(data.count + 1) bytes)")
            for provider in counts.keys.sorted() {
                let padded = provider.padding(toLength: 24, withPad: " ", startingAt: 0)
                print("  \(padded) \(counts[provider] ?? 0) models")
            }
            print("  total                    \(total) models")
        }
    }

    private static func readSource(_ value: String) throws -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            guard let url = URL(string: value) else {
                throw GeneratorError.invalidURL(value)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        return try String(contentsOfFile: value, encoding: .utf8)
    }

    private static func tsModelsToJSON(_ source: String) throws -> String {
        guard let startRange = source.range(of: "export const MODELS =") else {
            throw GeneratorError.modelsBlockNotFound
        }
        let afterEquals = source[startRange.upperBound...]
            .drop { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        guard afterEquals.first == "{" else {
            throw GeneratorError.modelsBlockNotFound
        }

        let endMarker = " as const;"
        guard let endRange = source.range(of: endMarker, options: .backwards) else {
            throw GeneratorError.modelsBlockNotFound
        }

        var object = String(afterEquals[..<endRange.lowerBound])
        object = object.replacingOccurrences(
            of: #"\s+satisfies Model<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        object = object.replacingOccurrences(
            of: #"(?m)^(\s*)([A-Za-z_$][A-Za-z0-9_$]*)\s*:"#,
            with: #"$1"$2":"#,
            options: .regularExpression
        )
        object = object.replacingOccurrences(
            of: #",(\s*[}\]])"#,
            with: "$1",
            options: .regularExpression
        )

        return object
    }
}

private enum GeneratorError: Error, CustomStringConvertible {
    case invalidURL(String)
    case modelsBlockNotFound

    var description: String {
        switch self {
        case let .invalidURL(value):
            return "invalid URL: \(value)"
        case .modelsBlockNotFound:
            return "could not find `export const MODELS = ... as const;`"
        }
    }
}

private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
