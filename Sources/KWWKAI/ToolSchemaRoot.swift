import Foundation

/// Makes a tool's parameter schema a plain object at its root.
///
/// Anthropic answers 400 "input_schema does not support oneOf, allOf, or
/// anyOf at the top level" to a root union (measured 2026-10-10), and one
/// such tool — zod and pydantic write them for MCP servers — fails every
/// request that offers it. Devin's Claude models answer 502 to the same.
/// A union below the root is accepted and left alone.
///
/// `allOf` branches are merged whole. Of `anyOf` / `oneOf` object branches
/// the properties are merged and only a field every branch requires stays
/// required, so the folded schema accepts whatever any branch did.
enum ToolSchemaRoot {
    static func objectRoot(_ schema: JSONValue) -> JSONValue {
        guard case .object(let root) = schema else { return schema }
        return .object(fold(root, root: root, depth: 0))
    }

    private static let unions = ["anyOf", "oneOf", "allOf"]

    private static func fold(_ schema: [String: JSONValue], root: [String: JSONValue], depth: Int) -> [String: JSONValue] {
        guard unions.contains(where: { schema[$0] != nil }) else { return schema }
        var out = schema
        var properties = schema["properties"]?.objectValue ?? [:]
        var required = schema["required"]?.stringArray ?? []

        for branch in branches(schema["allOf"], root: root, depth: depth) {
            properties.merge(branch["properties"]?.objectValue ?? [:]) { own, _ in own }
            required += branch["required"]?.stringArray ?? []
        }
        let alternatives = branches(schema["anyOf"], root: root, depth: depth)
            + branches(schema["oneOf"], root: root, depth: depth)
        var common: Set<String>?
        for branch in alternatives {
            properties.merge(branch["properties"]?.objectValue ?? [:]) { own, _ in own }
            let needs = Set(branch["required"]?.stringArray ?? [])
            common = common.map { $0.intersection(needs) } ?? needs
        }
        required += (common ?? []).sorted()

        for key in unions { out[key] = nil }
        out["type"] = .string("object")
        out["properties"] = .object(properties)
        var seen = Set<String>()
        let unique = required.filter { seen.insert($0).inserted }
        out["required"] = unique.isEmpty ? nil : .array(unique.map { .string($0) })
        return out
    }

    /// The object branches of a union, local `$ref`s followed and unions
    /// inside them folded first; `depth` bounds unions inside unions.
    private static func branches(_ value: JSONValue?, root: [String: JSONValue], depth: Int) -> [[String: JSONValue]] {
        guard case .array(let list)? = value else { return [] }
        return list.compactMap { item in
            guard var branch = resolve(item.objectValue, root: root) else { return nil }
            if depth < 8 { branch = fold(branch, root: root, depth: depth + 1) }
            guard branch["properties"] != nil || branch["type"] == .string("object") else { return nil }
            return branch
        }
    }

    private static func resolve(_ schema: [String: JSONValue]?, root: [String: JSONValue]) -> [String: JSONValue]? {
        guard let schema, case .string(let ref)? = schema["$ref"] else { return schema }
        for prefix in ["#/$defs/", "#/definitions/"] where ref.hasPrefix(prefix) {
            let holder = String(prefix.dropFirst(2).dropLast())
            return root[holder]?.objectValue?[String(ref.dropFirst(prefix.count))]?.objectValue
        }
        return nil
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringArray: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
}
