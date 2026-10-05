import Foundation
import KWWKAI
import KWWKMCP

/// Where an MCP server is configured.
enum MCPConfigScope: String, CaseIterable, Sendable {
    /// `~/.kwwk/mcp.json`: every project.
    case user
    /// `<cwd>/.kwwk/mcp.json`: this project, shareable through version
    /// control; read only with `KWWK_ALLOW_PROJECT_MCP=1`.
    case project
}

/// One server from an `mcp.json` file.
struct MCPConfigEntry: Sendable {
    var server: MCPServerConfig
    /// What the server offers, for the system prompt.
    var description: String? { server.description }
    /// OAuth settings of an HTTP server; nil when it does not use OAuth.
    var oauth: MCPOAuthSettings?
    /// The file it came from.
    var scope: MCPConfigScope = .user
}

/// Reads the TUI's MCP configuration: `~/.kwwk/mcp.json` and, when the
/// project is trusted, `<cwd>/.kwwk/mcp.json`.
///
/// Both use the `mcpServers` shape shared with other MCP clients, plus
/// kwwk's `exposure`, `toolExposure`, `description`, `enabled`,
/// `startupTimeout`, `toolTimeout` and `toolMaxTotalTimeout` (seconds), and
/// for HTTP servers `oauth`: `false`, or an object with `clientName`,
/// `scope`, `clientId`, `clientSecret`, `clientMetadataUrl` and
/// `callbackPort`. HTTP servers use OAuth unless `oauth` is `false` or
/// `headers` set `Authorization`. A project entry replaces a
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
        var scopes = [userPath: MCPConfigScope.user]
        var loaded = Loaded()
        if projectPath != userPath {
            if trustProject {
                paths.append(projectPath)
                scopes[projectPath] = .project
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
                        guard var entry = try parse(
                            name: name, raw: servers[name] ?? .null, cwd: cwd, expander: &expander
                        ) else {
                            byName[name] = nil
                            continue
                        }
                        entry.scope = scopes[path] ?? .user
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

    /// Parse one entry as `load` would, for `kwwk mcp add` to check a server
    /// before writing it. Nil for `"enabled": false`.
    static func validate(
        name: String,
        raw: JSONValue,
        cwd: String,
        homeDirectory: String,
        environment: [String: String]
    ) throws -> MCPConfigEntry? {
        var expander = Expander(home: homeDirectory, environment: environment)
        return try parse(name: name, raw: raw, cwd: cwd, expander: &expander)
    }

    /// The config file of a scope.
    static func path(scope: MCPConfigScope, cwd: String, homeDirectory: String) -> URL {
        let base = scope == .user ? homeDirectory : cwd
        return URL(fileURLWithPath: base).appendingPathComponent(".kwwk/mcp.json")
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
        if let seconds = try seconds(fields, "toolMaxTotalTimeout") { server.toolMaxTotalTimeoutSeconds = seconds }
        server.description = try string(fields["description"], "description")
        var oauth: MCPOAuthSettings?
        if case .http(_, let headers) = transport {
            oauth = try parseOAuth(fields["oauth"], headers: headers, expander: &expander)
        }
        return MCPConfigEntry(server: server, oauth: oauth)
    }

    /// OAuth settings of an HTTP server, or nil when it opts out.
    private static func parseOAuth(
        _ value: JSONValue?, headers: [String: String], expander: inout Expander
    ) throws -> MCPOAuthSettings? {
        switch value {
        case .bool(false)?:
            return nil
        case nil, .null?, .bool(true)?:
            let sendsAuthorization = headers.keys.contains { $0.lowercased() == "authorization" }
            return sendsAuthorization ? nil : MCPOAuthSettings()
        case .object(let fields)?:
            var settings = MCPOAuthSettings()
            if let name = try string(fields["clientName"], "oauth.clientName") { settings.clientName = name }
            settings.scope = try string(fields["scope"], "oauth.scope")
            settings.clientID = try string(fields["clientId"], "oauth.clientId").map { expander.expand($0, field: "oauth.clientId") }
            settings.clientSecret = try string(fields["clientSecret"], "oauth.clientSecret").map {
                expander.expand($0, field: "oauth.clientSecret")
            }
            if let raw = try string(fields["clientMetadataUrl"], "oauth.clientMetadataUrl") {
                guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
                    throw ConfigError(message: "oauth.clientMetadataUrl must be an https URL")
                }
                settings.clientMetadataURL = url
            }
            switch fields["callbackPort"] {
            case nil, .null?: break
            case .int(let port)? where (1...65_535).contains(port): settings.callbackPort = UInt16(port)
            default: throw ConfigError(message: "oauth.callbackPort must be a port number")
            }
            return settings
        default:
            throw ConfigError(message: "oauth must be false or an object")
        }
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
