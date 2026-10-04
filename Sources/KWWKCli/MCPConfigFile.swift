import Foundation
import KWWKAI
import KWWKMCP

/// One server from an `mcp.json` file.
struct MCPConfigEntry: Sendable {
    var server: MCPServerConfig
    /// What the server offers, for the system prompt.
    var description: String?
}

/// Reads the TUI's MCP configuration: `~/.kwwk/mcp.json` and, when the
/// project is trusted, `<cwd>/.kwwk/mcp.json`.
///
/// Both use the `mcpServers` shape shared with other MCP clients, plus
/// kwwk's `exposure`, `toolExposure`, `description`, `enabled`,
/// `startupTimeout` and `toolTimeout` (seconds). A project entry replaces a
/// user entry of the same name. `${VAR}` / `${VAR:-default}` expand from the
/// environment and a leading `~/` from the home directory; a relative stdio
/// `cwd` resolves against the session directory.
enum MCPConfigFile {
    struct Loaded {
        var entries: [MCPConfigEntry] = []
        var warnings: [String] = []
    }

    static func load(
        cwd: String,
        homeDirectory: String,
        trustProject: Bool,
        environment: [String: String]
    ) -> Loaded {
        func resolved(_ base: String) -> String {
            URL(fileURLWithPath: base).appendingPathComponent(".kwwk/mcp.json").resolvingSymlinksInPath().path
        }
        let userPath = resolved(homeDirectory)
        let projectPath = resolved(cwd)
        var paths = [userPath]
        var loaded = Loaded()
        if projectPath != userPath {
            if trustProject {
                paths.append(projectPath)
            } else if FileManager.default.fileExists(atPath: projectPath) {
                loaded.warnings.append(
                    "ignored \(projectPath); set \(MCPRuntime.allowProjectServersVariable)=1 to trust this project's MCP servers"
                )
            }
        }
        var byName: [String: MCPConfigEntry] = [:]
        var order: [String] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            do {
                let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                guard case .object(let root) = document, case .object(let servers)? = root["mcpServers"] else {
                    loaded.warnings.append("\(path): expected an object with an \"mcpServers\" object")
                    continue
                }
                for name in servers.keys.sorted() {
                    do {
                        var expander = Expander(home: homeDirectory, environment: environment)
                        guard let entry = try parse(
                            name: name, raw: servers[name] ?? .null, cwd: cwd, expander: &expander
                        ) else {
                            byName[name] = nil
                            continue
                        }
                        loaded.warnings += expander.warnings.map { "\(path): \($0)" }
                        if byName[name] == nil { order.append(name) }
                        byName[name] = entry
                    } catch {
                        loaded.warnings.append("\(path): server \"\(name)\": \(describe(error))")
                    }
                }
            } catch {
                loaded.warnings.append("\(path): \(describe(error))")
            }
        }
        loaded.entries = order.compactMap { byName[$0] }
        return loaded
    }

    // MARK: - Parsing

    struct ConfigError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Parse one entry; nil for `"enabled": false`.
    private static func parse(
        name: String, raw: JSONValue, cwd sessionDirectory: String, expander: inout Expander
    ) throws -> MCPConfigEntry? {
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-"
        }) else {
            throw ConfigError(message: "invalid name (use letters, digits, \"_\" and \"-\")")
        }
        guard case .object(let fields) = raw else { throw ConfigError(message: "must be an object") }
        if case .bool(false)? = fields["enabled"] { return nil }

        let type = try string(fields["type"], "type")
        let transport: MCPTransportConfig
        switch (type, fields["url"], fields["command"]) {
        case (nil, .string(let rawURL)?, _), ("http", .string(let rawURL)?, _), ("streamable-http", .string(let rawURL)?, _):
            guard let url = URL(string: expander.expand(rawURL, field: "url")),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw ConfigError(message: "url must be an http or https URL")
            }
            transport = .http(url: url, headers: try strings(fields["headers"], "headers").mapValues {
                expander.expand($0, field: "headers")
            })
        case (nil, _, .string(let command)?), ("stdio", _, .string(let command)?):
            let args = try stringArray(fields["args"], "args").map { expander.expandPath($0, field: "args") }
            let env = try strings(fields["env"], "env").mapValues { expander.expand($0, field: "env") }
            let cwd = try string(fields["cwd"], "cwd").map { expander.expandPath($0, field: "cwd") }
            transport = .stdio(
                command: expander.expandPath(command, field: "command"),
                args: args,
                env: env,
                cwd: cwd.map {
                    $0.hasPrefix("/") ? $0 : URL(fileURLWithPath: sessionDirectory).appendingPathComponent($0).path
                }
            )
        case ("sse", _, _):
            throw ConfigError(message: "the legacy SSE transport is not supported; use the streamable HTTP URL")
        default:
            throw ConfigError(message: "needs either \"command\" (stdio) or \"url\" (streamable HTTP)")
        }

        var server = MCPServerConfig(name: name, transport: transport)
        if let exposure = try string(fields["exposure"], "exposure") {
            server.exposure = try parseExposure(exposure)
        }
        if case .object(let map)? = fields["toolExposure"] {
            server.toolExposure = try map.mapValues { value in
                guard case .string(let text) = value else { throw ConfigError(message: "toolExposure values must be strings") }
                return try parseExposure(text)
            }
        }
        if let seconds = try seconds(fields, "startupTimeout") { server.startupTimeoutSeconds = seconds }
        if let seconds = try seconds(fields, "toolTimeout") ?? seconds(fields, "timeout") { server.toolTimeoutSeconds = seconds }
        return MCPConfigEntry(server: server, description: try string(fields["description"], "description"))
    }

    /// pi's `direct`, `codemode` and `codemode-deferred` read as `deferred`,
    /// so pi configs can be copied over unchanged.
    private static func parseExposure(_ value: String) throws -> MCPToolExposure {
        switch value {
        case "deferred", "direct", "codemode", "codemode-deferred": return .deferred
        case "hidden": return .hidden
        default: throw ConfigError(message: "exposure must be \"deferred\" or \"hidden\"")
        }
    }

    private static func string(_ value: JSONValue?, _ field: String) throws -> String? {
        switch value {
        case nil, .null?: return nil
        case .string(let text)?: return text
        default: throw ConfigError(message: "\(field) must be a string")
        }
    }

    private static func stringArray(_ value: JSONValue?, _ field: String) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let items) = value else { throw ConfigError(message: "\(field) must be an array of strings") }
        return try items.map { item in
            guard case .string(let text) = item else { throw ConfigError(message: "\(field) must be an array of strings") }
            return text
        }
    }

    private static func strings(_ value: JSONValue?, _ field: String) throws -> [String: String] {
        guard let value else { return [:] }
        guard case .object(let map) = value else { throw ConfigError(message: "\(field) must map names to strings") }
        return try map.mapValues { item in
            guard case .string(let text) = item else { throw ConfigError(message: "\(field) must map names to strings") }
            return text
        }
    }

    private static func seconds(_ fields: [String: JSONValue], _ field: String) throws -> Double? {
        let value: Double
        switch fields[field] {
        case nil: return nil
        case .int(let int)?: value = Double(int)
        case .double(let double)?: value = double
        default: value = 0
        }
        guard value > 0 else { throw ConfigError(message: "\(field) must be a positive number of seconds") }
        return value
    }

    private static func describe(_ error: Error) -> String {
        if error is DecodingError { return "invalid JSON" }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// Expands `${VAR}` and `${VAR:-default}` references, and `~/` in paths.
struct Expander {
    let home: String
    let environment: [String: String]
    private(set) var warnings: [String] = []

    /// Unset variables without a default expand to "" and add a warning.
    mutating func expand(_ value: String, field: String) -> String {
        var output = ""
        var rest = Substring(value)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            output += rest[..<open.lowerBound]
            let inner = rest[open.upperBound..<close]
            let parts = inner.components(separatedBy: ":-")
            let name = parts[0]
            let fallback = parts.count > 1 ? parts.dropFirst().joined(separator: ":-") : nil
            if let resolved = environment[name], !(fallback != nil && resolved.isEmpty) {
                output += resolved
            } else if let fallback {
                output += fallback
            } else {
                let warning = "\(field) references unset environment variable \(name)"
                if !warnings.contains(warning) { warnings.append(warning) }
            }
            rest = rest[rest.index(after: close)...]
        }
        return output + rest
    }

    mutating func expandPath(_ value: String, field: String) -> String {
        let expanded = expand(value, field: field)
        if expanded == "~" { return home }
        if expanded.hasPrefix("~/") { return home + expanded.dropFirst(1) }
        return expanded
    }
}
