import Foundation
import KWWKAI

/// How the tools of an MCP server reach the model.
///
/// - `direct`: declared to the model like any built-in tool.
/// - `deferred`: registered but not declared until a tool-search step loads
///   them (default).
/// - `hidden`: never exposed; `MCPManager.tools()` leaves them out.
public enum MCPToolExposure: String, Sendable, Hashable, Codable, CaseIterable {
    case direct
    case deferred
    case hidden

    /// Parse a config value. pi's `codemode` / `codemode-deferred` exposures
    /// have no kwwk equivalent and are read as `deferred`, so pi configs can be
    /// copied over unchanged.
    public init?(configValue: String) {
        switch configValue {
        case "direct": self = .direct
        case "deferred", "codemode", "codemode-deferred": self = .deferred
        case "hidden": self = .hidden
        default: return nil
        }
    }
}

/// How kwwk talks to an MCP server.
public enum MCPTransportConfig: Sendable, Hashable {
    /// Spawn `command` with `args` and speak newline-delimited JSON-RPC over
    /// its stdin/stdout. `env` is added to the inherited environment. A
    /// relative `cwd` resolves against the session working directory.
    case stdio(command: String, args: [String] = [], env: [String: String] = [:], cwd: String? = nil)
    /// Streamable HTTP transport (MCP 2025-03-26+).
    case http(url: URL, headers: [String: String] = [:])
}

/// One configured MCP server.
public struct MCPServerConfig: Sendable, Hashable {
    /// Server name: letters, digits, `_` and `-`.
    public var name: String
    public var transport: MCPTransportConfig
    /// Disabled servers stay listed (status `.disabled`) but never connect.
    public var enabled: Bool
    /// Default exposure of the server's tools.
    public var exposure: MCPToolExposure
    /// Per-tool overrides of `exposure`. Keys are tool names as the server
    /// offers them, or patterns where `*` matches any run of characters. An
    /// exact name wins over patterns; among patterns the lexicographically
    /// first matching key wins (JSON object order is not preserved).
    public var toolExposure: [String: MCPToolExposure]
    /// What the server offers, in a sentence. Used for the system-prompt
    /// summary before the server's own instructions are known.
    public var description: String?
    /// Bound on connecting (spawn + `initialize` + first `tools/list`).
    public var startupTimeoutSeconds: Double?
    /// Per-request timeout of tool calls and other requests.
    public var toolTimeoutSeconds: Double?
    /// Config file that defined the entry, when loaded from disk.
    public var source: String?

    public init(
        name: String,
        transport: MCPTransportConfig,
        enabled: Bool = true,
        exposure: MCPToolExposure = .deferred,
        toolExposure: [String: MCPToolExposure] = [:],
        description: String? = nil,
        startupTimeoutSeconds: Double? = nil,
        toolTimeoutSeconds: Double? = nil,
        source: String? = nil
    ) {
        self.name = name
        self.transport = transport
        self.enabled = enabled
        self.exposure = exposure
        self.toolExposure = toolExposure
        self.description = description
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.source = source
    }

    /// Effective exposure of one tool: its exact `toolExposure` entry, else
    /// the first matching `*` pattern (in sorted key order), else `exposure`.
    public func exposure(forTool toolName: String) -> MCPToolExposure {
        if let exact = toolExposure[toolName] { return exact }
        for pattern in toolExposure.keys.sorted() where pattern.contains("*") {
            if MCPGlob.matches(pattern: pattern, value: toolName), let value = toolExposure[pattern] {
                return value
            }
        }
        return exposure
    }
}

/// Minimal `*`-only glob matching used for `toolExposure` patterns.
enum MCPGlob {
    static func matches(pattern: String, value: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == value }
        var rest = Substring(value)
        guard let first = parts.first, rest.hasPrefix(first) else { return false }
        rest = rest.dropFirst(first.count)
        let last = parts[parts.count - 1]
        for middle in parts.dropFirst().dropLast() where !middle.isEmpty {
            guard let range = rest.range(of: middle) else { return false }
            rest = rest[range.upperBound...]
        }
        return rest.count >= last.count && rest.hasSuffix(last)
    }
}

/// Result of reading the user and project `mcp.json` files.
public struct MCPConfigLoadResult: Sendable {
    /// Valid servers, user entries first (in sorted name order), then servers
    /// only the project defines. Disabled servers are included.
    public var servers: [MCPServerConfig]
    /// Problems with individual files or entries. Invalid entries are skipped.
    public var warnings: [String]
    /// Config files that were read.
    public var files: [String]

    public init(servers: [MCPServerConfig] = [], warnings: [String] = [], files: [String] = []) {
        self.servers = servers
        self.warnings = warnings
        self.files = files
    }
}

/// Reads `~/.kwwk/mcp.json` and `<cwd>/.kwwk/mcp.json`.
///
/// Both files use the `mcpServers` shape shared with other MCP clients:
///
/// ```json
/// {
///   "mcpServers": {
///     "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."] },
///     "docs": { "type": "http", "url": "https://example.com/mcp",
///               "headers": { "Authorization": "Bearer ${DOCS_TOKEN}" } }
///   }
/// }
/// ```
///
/// kwwk adds `enabled`, `exposure`, `toolExposure`, `description`,
/// `startupTimeout` and `toolTimeout` (seconds; pi's `timeout` is accepted as
/// an alias of `toolTimeout`). Project entries replace user entries with the
/// same name. A project entry without `command`, `url` or `type` only overrides
/// `enabled` / `exposure` / `toolExposure` of the user entry and keeps the rest,
/// including credentials. `${VAR}` and `${VAR:-default}` references in
/// `command`, `args`, `env`, `url` and `headers` are expanded from the
/// environment.
public enum MCPConfigLoader {
    public static let fileName = "mcp.json"
    static let overrideKeys: Set<String> = ["enabled", "exposure", "toolExposure"]

    /// Load user and project configuration. Never throws: unreadable files
    /// and invalid entries become warnings.
    public static func load(
        cwd: String,
        homeDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPConfigLoadResult {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let userPath = URL(fileURLWithPath: home).appendingPathComponent(".kwwk").appendingPathComponent(fileName).path
        let projectPath = URL(fileURLWithPath: cwd).appendingPathComponent(".kwwk").appendingPathComponent(fileName).path
        var state = State(environment: environment)
        state.read(path: userPath, scope: .user)
        if URL(fileURLWithPath: projectPath).standardizedFileURL != URL(fileURLWithPath: userPath).standardizedFileURL {
            state.read(path: projectPath, scope: .project)
        }
        return MCPConfigLoadResult(
            servers: state.order.compactMap { state.servers[$0] },
            warnings: state.warnings,
            files: state.files
        )
    }

    /// Parse one `mcpServers` document (already decoded). Exposed for callers
    /// that keep MCP config elsewhere (e.g. inside a settings file).
    public static func parse(
        _ document: JSONValue,
        source: String = "<inline>",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPConfigLoadResult {
        var state = State(environment: environment)
        state.ingest(document: document, path: source, scope: .user)
        return MCPConfigLoadResult(
            servers: state.order.compactMap { state.servers[$0] },
            warnings: state.warnings,
            files: []
        )
    }

    enum Scope { case user, project }

    struct State {
        let environment: [String: String]
        var servers: [String: MCPServerConfig] = [:]
        var order: [String] = []
        var warnings: [String] = []
        var files: [String] = []

        init(environment: [String: String]) {
            self.environment = environment
        }

        mutating func read(path: String, scope: Scope) {
            guard FileManager.default.fileExists(atPath: path) else { return }
            let document: JSONValue
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                document = try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                warnings.append("\(path): \(MCPConfigLoader.describe(error))")
                return
            }
            files.append(path)
            ingest(document: document, path: path, scope: scope)
        }

        mutating func ingest(document: JSONValue, path: String, scope: Scope) {
            guard case .object(let root) = document else {
                warnings.append("\(path): expected an object with an \"mcpServers\" object")
                return
            }
            let rawServers: [String: JSONValue]
            switch root["mcpServers"] {
            case nil: return
            case .object(let object)?: rawServers = object
            default:
                warnings.append("\(path): expected an object with an \"mcpServers\" object")
                return
            }
            for name in rawServers.keys.sorted() {
                guard let raw = rawServers[name] else { continue }
                if scope == .project, case .object(let fields) = raw, MCPConfigLoader.isOverride(fields) {
                    applyOverride(name: name, fields: fields, path: path)
                    continue
                }
                switch MCPConfigLoader.validate(name: name, raw: raw, source: path, environment: environment) {
                case .failure(let error):
                    warnings.append("\(path): \(error.message)")
                case .success(let parsed):
                    if let clash = order.first(where: {
                        $0 != name && MCPToolNaming.sanitize($0) == MCPToolNaming.sanitize(name)
                    }) {
                        warnings.append("\(path): server \"\(name)\" conflicts with \"\(clash)\"")
                        continue
                    }
                    warnings.append(contentsOf: parsed.warnings.map { "\(path): \($0)" })
                    if servers[name] == nil { order.append(name) }
                    servers[name] = parsed.config
                }
            }
        }

        mutating func applyOverride(name: String, fields: [String: JSONValue], path: String) {
            guard var base = servers[name] else {
                warnings.append("\(path): server \"\(name)\" needs \"command\" or \"url\", or a user-level server to override")
                return
            }
            let extra = fields.keys.filter { !MCPConfigLoader.overrideKeys.contains($0) }.sorted()
            guard extra.isEmpty else {
                warnings.append("\(path): server \"\(name)\": an override can only set enabled, exposure, toolExposure")
                return
            }
            do {
                if let enabled = try MCPConfigLoader.parseEnabled(fields["enabled"], name: name) {
                    base.enabled = enabled
                }
                if let exposure = try MCPConfigLoader.parseExposure(fields["exposure"], name: name) {
                    base.exposure = exposure
                }
                if let toolExposure = try MCPConfigLoader.parseToolExposure(fields["toolExposure"], name: name) {
                    base.toolExposure = toolExposure
                }
            } catch let error as MCPConfigError {
                warnings.append("\(path): \(error.message)")
                return
            } catch {
                warnings.append("\(path): \(MCPConfigLoader.describe(error))")
                return
            }
            servers[name] = base
        }
    }

    struct Parsed {
        var config: MCPServerConfig
        var warnings: [String]
    }

    struct MCPConfigError: Error {
        let message: String
    }

    static func isOverride(_ fields: [String: JSONValue]) -> Bool {
        fields["command"] == nil && fields["url"] == nil && fields["type"] == nil
    }

    static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let context): return "invalid JSON (\(context.debugDescription))"
            default: return "invalid JSON"
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    static func isValidServerName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || $0 == "_" || $0 == "-"
        }
    }

    /// Validate one `mcpServers` entry.
    static func validate(
        name: String,
        raw: JSONValue,
        source: String,
        environment: [String: String]
    ) -> Result<Parsed, MCPConfigError> {
        do {
            return .success(try parseEntry(name: name, raw: raw, source: source, environment: environment))
        } catch let error as MCPConfigError {
            return .failure(error)
        } catch {
            return .failure(MCPConfigError(message: "server \"\(name)\": \(describe(error))"))
        }
    }

    private static func parseEntry(
        name: String,
        raw: JSONValue,
        source: String,
        environment: [String: String]
    ) throws -> Parsed {
        guard isValidServerName(name) else {
            throw MCPConfigError(message: "invalid server name \"\(name)\" (use letters, digits, \"_\" and \"-\")")
        }
        guard case .object(let fields) = raw else {
            throw MCPConfigError(message: "server \"\(name)\" must be an object")
        }
        var expander = EnvExpander(environment: environment, server: name)

        let type: String?
        switch fields["type"] {
        case nil: type = nil
        case .string(let value)?: type = value
        default: throw MCPConfigError(message: "server \"\(name)\": type must be a string")
        }
        if type == "sse" {
            throw MCPConfigError(
                message: "server \"\(name)\": legacy SSE transport is not supported; use the streamable HTTP URL"
            )
        }
        if let type, !["stdio", "http", "streamable-http"].contains(type) {
            throw MCPConfigError(
                message: "server \"\(name)\": type must be \"stdio\", \"http\" or \"streamable-http\""
            )
        }

        let transport: MCPTransportConfig
        if case .string(let rawURL)? = fields["url"], type == nil || type == "http" || type == "streamable-http" {
            let expanded = expander.expand(rawURL, field: "url")
            guard let url = URL(string: expanded),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host != nil
            else {
                throw MCPConfigError(message: "server \"\(name)\": url must be an http or https URL")
            }
            let headers = try stringMap(fields["headers"], field: "headers", name: name)
                .mapValues { expander.expand($0, field: "headers") }
            transport = .http(url: url, headers: headers)
        } else if case .string(let command)? = fields["command"], type == nil || type == "stdio" {
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPConfigError(message: "server \"\(name)\": command must not be empty")
            }
            var args: [String] = []
            switch fields["args"] {
            case nil: break
            case .array(let values)?:
                for value in values {
                    guard case .string(let arg) = value else {
                        throw MCPConfigError(message: "server \"\(name)\": args must be an array of strings")
                    }
                    args.append(expander.expand(arg, field: "args"))
                }
            default:
                throw MCPConfigError(message: "server \"\(name)\": args must be an array of strings")
            }
            let env = try stringMap(fields["env"], field: "env", name: name)
                .mapValues { expander.expand($0, field: "env") }
            var cwd: String?
            switch fields["cwd"] {
            case nil: break
            case .string(let value)?: cwd = value
            default: throw MCPConfigError(message: "server \"\(name)\": cwd must be a string")
            }
            transport = .stdio(command: expander.expand(command, field: "command"), args: args, env: env, cwd: cwd)
        } else {
            throw MCPConfigError(
                message: "server \"\(name)\" needs either \"command\" (stdio) or \"url\" (streamable HTTP)"
            )
        }

        var description: String?
        switch fields["description"] {
        case nil: break
        case .string(let value)?: description = value.isEmpty ? nil : value
        default: throw MCPConfigError(message: "server \"\(name)\": description must be a string")
        }

        let config = MCPServerConfig(
            name: name,
            transport: transport,
            enabled: try parseEnabled(fields["enabled"], name: name) ?? true,
            exposure: try parseExposure(fields["exposure"], name: name) ?? .deferred,
            toolExposure: try parseToolExposure(fields["toolExposure"], name: name) ?? [:],
            description: description,
            startupTimeoutSeconds: try parseSeconds(
                fields, keys: ["startupTimeout", "startupTimeoutSeconds"], name: name
            ),
            toolTimeoutSeconds: try parseSeconds(
                fields, keys: ["toolTimeout", "toolTimeoutSeconds", "timeout"], name: name
            ),
            source: source
        )
        return Parsed(config: config, warnings: expander.warnings)
    }

    static func parseEnabled(_ value: JSONValue?, name: String) throws -> Bool? {
        switch value {
        case nil: return nil
        case .bool(let flag)?: return flag
        default: throw MCPConfigError(message: "server \"\(name)\": enabled must be a boolean")
        }
    }

    static let exposureList = "\"direct\", \"deferred\", \"hidden\""

    static func parseExposure(_ value: JSONValue?, name: String) throws -> MCPToolExposure? {
        switch value {
        case nil: return nil
        case .string(let raw)?:
            if let exposure = MCPToolExposure(configValue: raw) { return exposure }
            fallthrough
        default:
            throw MCPConfigError(message: "server \"\(name)\": exposure must be one of \(exposureList)")
        }
    }

    static func parseToolExposure(_ value: JSONValue?, name: String) throws -> [String: MCPToolExposure]? {
        switch value {
        case nil: return nil
        case .object(let entries)?:
            var result: [String: MCPToolExposure] = [:]
            for (tool, raw) in entries {
                guard case .string(let text) = raw, let exposure = MCPToolExposure(configValue: text) else {
                    throw MCPConfigError(
                        message: "server \"\(name)\": toolExposure \"\(tool)\" must be one of \(exposureList)"
                    )
                }
                result[tool] = exposure
            }
            return result
        default:
            throw MCPConfigError(message: "server \"\(name)\": toolExposure must map tool names to exposures")
        }
    }

    /// The first of `keys` present in `fields`, as positive seconds.
    static func parseSeconds(_ fields: [String: JSONValue], keys: [String], name: String) throws -> Double? {
        guard let field = keys.first(where: { fields[$0] != nil }) else { return nil }
        let value = fields[field]
        let seconds: Double
        switch value {
        case nil: return nil
        case .int(let v)?: seconds = Double(v)
        case .double(let v)?: seconds = v
        default: seconds = -1
        }
        guard seconds > 0 else {
            throw MCPConfigError(message: "server \"\(name)\": \(field) must be a positive number of seconds")
        }
        return seconds
    }

    static func stringMap(_ value: JSONValue?, field: String, name: String) throws -> [String: String] {
        switch value {
        case nil: return [:]
        case .object(let entries)?:
            var result: [String: String] = [:]
            for (key, raw) in entries {
                guard case .string(let text) = raw else {
                    throw MCPConfigError(message: "server \"\(name)\": \(field) must map names to strings")
                }
                result[key] = text
            }
            return result
        default:
            throw MCPConfigError(message: "server \"\(name)\": \(field) must map names to strings")
        }
    }
}

/// Expands `${VAR}` and `${VAR:-default}` references.
struct EnvExpander {
    let environment: [String: String]
    let server: String
    var warnings: [String] = []

    init(environment: [String: String], server: String) {
        self.environment = environment
        self.server = server
    }

    /// Expand every reference in `value`. Unset variables without a default
    /// expand to the empty string and add a warning.
    mutating func expand(_ value: String, field: String) -> String {
        var missing: [String] = []
        let result = Self.expand(value, environment: environment, missing: &missing)
        for variable in missing {
            let warning = "server \"\(server)\": \(field) references unset environment variable \(variable)"
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        return result
    }

    static func expand(_ value: String, environment: [String: String], missing: inout [String]) -> String {
        guard value.contains("${") else { return value }
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "$",
               value.index(after: index) < value.endIndex,
               value[value.index(after: index)] == "{",
               let close = value[index...].firstIndex(of: "}") {
                let inner = String(value[value.index(index, offsetBy: 2)..<close])
                let name: String
                let fallback: String?
                if let range = inner.range(of: ":-") {
                    name = String(inner[..<range.lowerBound])
                    fallback = String(inner[range.upperBound...])
                } else {
                    name = inner
                    fallback = nil
                }
                if let resolved = environment[name], !(fallback != nil && resolved.isEmpty) {
                    output += resolved
                } else if let fallback {
                    output += fallback
                } else {
                    missing.append(name)
                }
                index = value.index(after: close)
            } else {
                output.append(value[index])
                index = value.index(after: index)
            }
        }
        return output
    }
}
