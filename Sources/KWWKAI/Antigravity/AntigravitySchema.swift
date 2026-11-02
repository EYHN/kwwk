import Foundation

/// A tool's JSON schema cut down to what Antigravity's function declarations
/// take: an OpenAPI-style subset with no references, unions or keywords
/// outside it. Ported from magpie's `plainSchema` (gateway/codeassist.go).
///
/// Antigravity refuses the whole request over a keyword it doesn't know
/// (magpie #187), an array with no `items` ("properties[batch].items:
/// missing field", plugins#375), `items` on anything but an array
/// ("field predicate failed: $type == Type.ARRAY"), and a boolean schema.
/// A `$ref` is followed to what it names; a self-reference stops at its
/// target's type. `allOf` becomes one schema with every member's fields. A
/// schema with a shape of its own beside an `anyOf` or `oneOf` keeps it and
/// the union is folded in (Philo's rg tool is an object whose `oneOf` only
/// says which of its fields go together, magpie #4046); a bare union is
/// read as its first member that isn't null, nullable.
enum AntigravitySchema {
    static let emptyObject: JSONValue = .object(["type": "object", "properties": .object([:])])

    /// Keywords the subset keeps as they are.
    private static let kept: Set<String> = [
        "description", "nullable", "required", "pattern", "minimum", "maximum", "minLength", "maxLength",
        "minItems", "maxItems", "minProperties", "maxProperties", "propertyOrdering",
    ]

    static func plain(_ schema: JSONValue) -> JSONValue {
        guard case .object(let root) = schema else { return schema }
        var walker = Walker(root: root)
        return walker.walk(.object(root), depth: 0, path: "") ?? emptyObject
    }

    private struct Walker {
        let root: [String: JSONValue]
        let defs: [String: JSONValue]
        /// The `$ref` chain being walked, a self-reference caught before it
        /// recurses.
        var expanding: Set<String> = []

        init(root: [String: JSONValue]) {
            self.root = root
            var defs: [String: JSONValue] = [:]
            for key in ["$defs", "definitions"] {
                if case .object(let holder)? = root[key] { defs.merge(holder) { own, _ in own } }
            }
            self.defs = defs
        }

        /// The schema a local `$ref` names in the root: a JSON pointer ("#",
        /// "#/properties/a/items") or, when it is none, a `$defs` or
        /// `definitions` name.
        func local(_ ref: String) -> JSONValue? {
            if ref == "#" { return .object(root) }
            if ref.hasPrefix("#/") {
                var current: JSONValue = .object(root)
                for token in ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
                    let name = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                    switch current {
                    case .object(let object):
                        guard let next = object[name] else { return byName(ref) }
                        current = next
                    case .array(let items):
                        guard let index = Int(name), items.indices.contains(index) else { return nil }
                        current = items[index]
                    default:
                        return nil
                    }
                }
                return current
            }
            return byName(ref)
        }

        /// The `$defs` or `definitions` entry a ref's last segment names.
        private func byName(_ ref: String) -> JSONValue? {
            defs[String(ref.split(separator: "/").last ?? "")]
        }

        /// A member as its local `$ref` names it, nil when it is no schema.
        func resolve(_ value: JSONValue) -> [String: JSONValue]? {
            guard case .object(let object) = value else { return nil }
            guard case .string(let ref)? = object["$ref"] else { return object }
            if case .object(let target)? = local(ref) { return target }
            return nil
        }

        /// Whether a local `$ref` names the site it sits at or one of its
        /// containers: in a tree, a reference to an ancestor is a
        /// self-reference.
        func selfReference(_ ref: String, path: String) -> Bool {
            guard ref.hasPrefix("#") else { return false }
            let target = String(ref.dropFirst())
            return target.isEmpty || path == target || path.hasPrefix(target + "/")
        }

        /// The type a schema's own shape says, what a self-reference stops at.
        func typeOf(_ object: [String: JSONValue]) -> String {
            if case .string(let type)? = object["type"] { return type }
            if object["properties"] != nil { return "object" }
            if object["items"] != nil { return "array" }
            return "object"
        }

        mutating func walk(_ value: JSONValue, depth: Int, path: String) -> JSONValue? {
            switch value {
            case .bool(let any):
                // A boolean schema: true is any value, the schema {}; false is
                // none, and whoever holds it leaves it out.
                return any ? .object([:]) : nil
            case .array(let items):
                return .array(items.compactMap { walk($0, depth: depth, path: path) })
            case .object(let object):
                return walkObject(object, depth: depth, path: path)
            default:
                return value
            }
        }

        private mutating func walkObject(_ object: [String: JSONValue], depth: Int, path: String) -> JSONValue? {
            if depth > 32 { return .object(["type": "object"]) }
            if case .string(let ref)? = object["$ref"] {
                guard let target = local(ref) else { return .object(["type": "object"]) }
                if expanding.contains(ref) || selfReference(ref, path: path) {
                    if case .object(let targetObject) = target {
                        return .object(["type": .string(typeOf(targetObject))])
                    }
                    return .object(["type": "object"])
                }
                expanding.insert(ref)
                defer { expanding.remove(ref) }
                return walk(target, depth: depth + 1, path: ref.hasPrefix("#") ? String(ref.dropFirst()) : path)
            }
            if case .array(let members)? = object["allOf"] {
                // One schema with all the members' fields, and every field one
                // of them requires.
                var merged = object
                merged["allOf"] = nil
                var required = names(object["required"])
                for member in members {
                    // A member's required is read before it is walked: walked
                    // alone, a member that only requires has no properties to
                    // keep its names for.
                    required += names(resolve(member)?["required"])
                    guard case .object(let walked)? = walk(member, depth: depth + 1, path: path + "/allOf") else { continue }
                    for (key, value) in walked where key != "required" {
                        if key == "properties", case .object(let more) = value {
                            var properties = merged["properties"]?.objectValue ?? [:]
                            properties.merge(more) { _, new in new }
                            merged["properties"] = .object(properties)
                        } else if merged[key] == nil {
                            merged[key] = value
                        }
                    }
                }
                if !required.isEmpty { merged["required"] = .array(distinct(required).map { .string($0) }) }
                return walk(.object(merged), depth: depth + 1, path: path)
            }
            if object["anyOf"] != nil || object["oneOf"] != nil {
                if ownShape(object) {
                    return walk(.object(foldUnion(object)), depth: depth + 1, path: path)
                }
                // A union with nothing of its own beside it: the first member
                // that isn't null, nullable.
                for key in ["anyOf", "oneOf"] {
                    guard case .array(let members)? = object[key] else { continue }
                    var pick: JSONValue?
                    var nullable = false
                    for member in members {
                        guard case .object(let branch) = member else { continue }
                        if branch["type"] == .string("null") {
                            nullable = true
                        } else if pick == nil {
                            pick = member
                        }
                    }
                    var out: [String: JSONValue] = [:]
                    if let pick, case .object(let walked)? = walk(pick, depth: depth + 1, path: path + "/" + key) {
                        out = walked
                    }
                    if case .string(let description)? = object["description"], out["description"] == nil {
                        out["description"] = .string(description)
                    }
                    if nullable { out["nullable"] = true }
                    if out["type"] == nil { out["type"] = "string" }
                    return .object(out)
                }
            }

            var out: [String: JSONValue] = [:]
            for (key, value) in object {
                switch key {
                case _ where kept.contains(key):
                    out[key] = value
                case "exclusiveMinimum", "exclusiveMaximum":
                    // A bound it takes only as inclusive (draft 6 on: a number).
                    let inclusive = key == "exclusiveMinimum" ? "minimum" : "maximum"
                    switch value {
                    case .int, .double:
                        if object[inclusive] == nil { out[inclusive] = value }
                    default:
                        break
                    }
                case "type":
                    if case .array(let types) = value {
                        for type in types {
                            if type == .string("null") {
                                out["nullable"] = true
                            } else if out["type"] == nil {
                                out["type"] = type
                            }
                        }
                        // Google has one type a node: of a list, the one its
                        // items or properties are for.
                        for type in types {
                            if type == .string("array"), object["items"] != nil { out["type"] = type; break }
                            if type == .string("object"), object["properties"] != nil { out["type"] = type; break }
                        }
                    } else {
                        out["type"] = value
                    }
                case "properties":
                    var properties: [String: JSONValue] = [:]
                    if case .object(let members) = value {
                        for (name, member) in members {
                            // A property whose schema is false is one the call
                            // may not have: it is left out, and its name in
                            // required with it.
                            let token = name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                            if let walked = walk(member, depth: depth + 1, path: path + "/properties/" + token) {
                                properties[name] = walked
                            }
                        }
                    }
                    out["properties"] = .object(properties)
                case "items":
                    if let walked = walk(value, depth: depth + 1, path: path + "/items") {
                        out["items"] = walked
                    } else if object["maxItems"] == nil {
                        // items false: an array with nothing in it.
                        out["items"] = .object([:])
                        out["maxItems"] = 0
                    }
                case "enum":
                    // Google takes string enums only.
                    if case .array(let members) = value, members.allSatisfy({ if case .string = $0 { return true }; return false }) {
                        out["enum"] = value
                    }
                default:
                    // A keyword outside the subset (format, default, title,
                    // additionalProperties, const…): Antigravity refuses the
                    // request over any it doesn't know (magpie #187).
                    break
                }
            }
            if case .string(let constant)? = object["const"] { out["enum"] = .array([.string(constant)]) }
            if out["type"] == nil {
                if out["properties"] != nil {
                    out["type"] = "object"
                } else if out["items"] != nil {
                    out["type"] = "array"
                }
            }
            if out["type"] == .string("array"), out["items"] == nil {
                // Google wants items on every array: any item is what JSON
                // Schema means by none.
                out["items"] = .object([:])
            }
            if case .string(let type)? = out["type"] {
                // JSON Schema reads an array's keywords only on an array and
                // an object's only on an object; Google turns the request away
                // over one on another type.
                if type != "array" {
                    for key in ["items", "minItems", "maxItems"] { out[key] = nil }
                }
                if type != "object" {
                    for key in ["properties", "required", "minProperties", "maxProperties", "propertyOrdering"] {
                        out[key] = nil
                    }
                }
            }
            if case .array(let required)? = out["required"] {
                // required names only the properties there are.
                let properties = out["properties"]?.objectValue ?? [:]
                let present = required.filter { if case .string(let name) = $0 { return properties[name] != nil }; return false }
                out["required"] = present.isEmpty ? nil : .array(present)
            }
            return .object(out)
        }

        /// Whether a schema says what it is beside its union: a type that
        /// isn't only null, properties or items.
        private func ownShape(_ object: [String: JSONValue]) -> Bool {
            if object["properties"] != nil || object["items"] != nil { return true }
            switch object["type"] {
            case .string(let type)?: return type != "null"
            case .array(let types)?: return types.contains { $0 != .string("null") }
            default: return false
            }
        }

        /// The schema with its `anyOf` and `oneOf` folded in, for a subset
        /// that has no unions. What it says itself stands. A null branch
        /// makes it nullable. On an object, a field only branches declare
        /// joins its properties, as the first branch to declare it gives it,
        /// and a field every branch that isn't null requires is required.
        private func foldUnion(_ object: [String: JSONValue]) -> [String: JSONValue] {
            var out = object
            out["anyOf"] = nil
            out["oneOf"] = nil
            var isObject = object["type"] == .string("object") || object["properties"] != nil
            if case .array(let types)? = object["type"] { isObject = isObject || types.contains(.string("object")) }
            var properties = object["properties"]?.objectValue ?? [:]
            var common: [String]?
            for key in ["anyOf", "oneOf"] {
                guard case .array(let members)? = object[key] else { continue }
                for member in members {
                    guard let branch = resolve(member) else { continue }
                    if branch["type"] == .string("null") {
                        out["nullable"] = true
                        continue
                    }
                    guard isObject else { continue }
                    for name in (branch["properties"]?.objectValue ?? [:]).keys.sorted() where properties[name] == nil {
                        properties[name] = branch["properties"]?.objectValue?[name]
                    }
                    let required = names(branch["required"])
                    common = common.map { $0.filter(required.contains) } ?? required
                }
            }
            if isObject {
                if !properties.isEmpty { out["properties"] = .object(properties) }
                let required = names(object["required"]) + (common ?? [])
                if !required.isEmpty { out["required"] = .array(distinct(required).map { .string($0) }) }
            }
            return out
        }

        private func names(_ value: JSONValue?) -> [String] {
            guard case .array(let items)? = value else { return [] }
            return items.compactMap { if case .string(let name) = $0 { return name }; return nil }
        }

        private func distinct(_ names: [String]) -> [String] {
            var seen: Set<String> = []
            return names.filter { seen.insert($0).inserted }
        }
    }
}
