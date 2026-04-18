import Foundation

/// Tiny JSONSchema validator covering the subset of the spec actually used by
/// tool parameter schemas: `type`, `properties`, `required`, `items`,
/// `enum`, `anyOf`. Errors are thrown as `JSONSchemaError` so callers can show
/// actionable messages.
public enum JSONSchemaError: Error, Equatable, CustomStringConvertible {
    case typeMismatch(path: String, expected: String, got: String)
    case missingRequired(path: String, key: String)
    case notInEnum(path: String, allowed: [String])
    case noneMatched(path: String)

    public var description: String {
        switch self {
        case .typeMismatch(let p, let e, let g): return "\(p): expected \(e), got \(g)"
        case .missingRequired(let p, let k): return "\(p): missing required property '\(k)'"
        case .notInEnum(let p, let allowed): return "\(p): must be one of \(allowed)"
        case .noneMatched(let p): return "\(p): did not match any variant"
        }
    }
}

public enum JSONSchema {

    /// Validate `value` against the `schema`. Throws on the first violation.
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") throws {
        guard case .object(let s) = schema else { return } // Non-object schema is permissive.

        // anyOf
        if case .array(let variants) = s["anyOf"] ?? .null, !variants.isEmpty {
            var lastError: Error?
            for variant in variants {
                do {
                    try validate(value, against: variant, path: path)
                    return
                } catch {
                    lastError = error
                }
            }
            if lastError != nil {
                throw JSONSchemaError.noneMatched(path: path)
            }
        }

        // enum
        if case .array(let choices) = s["enum"] ?? .null, !choices.isEmpty {
            if !choices.contains(value) {
                let rendered = choices.map { Self.describe($0) }
                throw JSONSchemaError.notInEnum(path: path, allowed: rendered)
            }
        }

        // type
        if case .string(let typeName) = s["type"] ?? .null {
            try validateType(value, typeName: typeName, path: path)
        }

        // object properties + required
        if case .object(let obj) = value {
            if case .array(let required) = s["required"] ?? .null {
                for item in required {
                    if case .string(let key) = item, obj[key] == nil {
                        throw JSONSchemaError.missingRequired(path: path, key: key)
                    }
                }
            }
            if case .object(let props) = s["properties"] ?? .null {
                for (key, sub) in props {
                    if let v = obj[key] {
                        try validate(v, against: sub, path: "\(path).\(key)")
                    }
                }
            }
        }

        // array items
        if case .array(let arr) = value, let itemsSchema = s["items"] {
            for (i, item) in arr.enumerated() {
                try validate(item, against: itemsSchema, path: "\(path)[\(i)]")
            }
        }
    }

    private static func validateType(_ value: JSONValue, typeName: String, path: String) throws {
        let actual = Self.describe(value)
        let ok: Bool
        switch typeName {
        case "string": ok = { if case .string = value { return true } else { return false } }()
        case "integer": ok = { if case .int = value { return true } else { return false } }()
        case "number": ok = { if case .int = value { return true }
                               if case .double = value { return true }
                               return false }()
        case "boolean": ok = { if case .bool = value { return true } else { return false } }()
        case "array": ok = { if case .array = value { return true } else { return false } }()
        case "object": ok = { if case .object = value { return true } else { return false } }()
        case "null": ok = { if case .null = value { return true } else { return false } }()
        default: ok = true
        }
        if !ok {
            throw JSONSchemaError.typeMismatch(path: path, expected: typeName, got: actual)
        }
    }

    public static func describe(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string(let s): return "\"\(s)\""
        case .array: return "array"
        case .object: return "object"
        }
    }
}
