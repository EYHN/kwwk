import Foundation
import KWWKAI
import KWWKMCP

extension KWWK {
    /// `kwwk mcp …`: manage MCP servers without editing `mcp.json` by hand.
    /// Returns the process exit code.
    public static func runMCPCommand(_ arguments: [String]) async -> Int32 {
        await MCPCommand.run(
            arguments,
            cwd: FileManager.default.currentDirectoryPath,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            environment: ProcessInfo.processInfo.environment,
            io: .standard
        )
    }
}

/// Where `kwwk mcp` writes its output.
struct MCPCommandIO: Sendable {
    var out: @Sendable (String) -> Void
    var err: @Sendable (String) -> Void

    static let standard = MCPCommandIO(
        out: { print($0) },
        err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    )
}

/// The servers of one `mcp.json` file, edited in place. Other top-level
/// keys and other servers are kept as they are.
struct MCPConfigEditor {
    let url: URL
    let scope: MCPConfigScope

    func root() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let object) = value else {
            throw MCPConfigFile.ConfigError(message: "\(url.path) is not a JSON object")
        }
        return object
    }

    func servers() throws -> [String: JSONValue] {
        guard case .object(let servers)? = try root()["mcpServers"] else { return [:] }
        return servers
    }

    func set(_ name: String, _ entry: JSONValue) throws {
        var root = try root()
        var servers = try self.servers()
        servers[name] = entry
        root["mcpServers"] = .object(servers)
        try write(root)
    }

    @discardableResult
    func remove(_ name: String) throws -> Bool {
        var root = try root()
        var servers = try self.servers()
        guard servers.removeValue(forKey: name) != nil else { return false }
        root["mcpServers"] = .object(servers)
        try write(root)
        return true
    }

    private func write(_ root: [String: JSONValue]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(root))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        // The user file may hold tokens in headers or env; the project file
        // is meant to be shared.
        if scope == .user {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

enum MCPCommand {
    static let usage = """
    usage: kwwk mcp <command>

      add [options] <name> <url>              add a Streamable HTTP server
      add [options] <name> -- <command> [args...]
                                              add a stdio server
      add-json [--scope <scope>] <name> <json>
                                              add a server from its mcp.json entry
      list                                    list servers and check each one
      get <name>                              show a server's configuration
      remove [--scope <scope>] <name>         remove a server (and its sign-in)
      login [--no-browser] [--callback-port <port>] <name>
                                              sign in to an OAuth server
      logout <name>                           forget a server's sign-in

    add options:
      -t, --transport <stdio|http>   default: http for a URL, else stdio
      -s, --scope <user|project>     user: ~/.kwwk/mcp.json (default)
                                     project: .kwwk/mcp.json in this directory
      -e, --env KEY=value            environment of a stdio server (repeatable)
      -H, --header "Name: value"     header of an HTTP server (repeatable)
      --description <text>           one line telling the model what it offers
      --client-id <id>               pre-registered OAuth client
      --client-secret <secret>
      --client-name <name>           client_name for dynamic registration
      --oauth-scope <scopes>         OAuth scope to request
      --callback-port <port>         fixed OAuth callback port
      --no-oauth                     never use OAuth for this server
    """

    static func run(
        _ arguments: [String],
        cwd: String,
        homeDirectory: String,
        environment: [String: String],
        io: MCPCommandIO
    ) async -> Int32 {
        guard let command = arguments.first else {
            io.out(usage)
            return 0
        }
        let rest = Array(arguments.dropFirst())
        let context = Context(cwd: cwd, homeDirectory: homeDirectory, environment: environment, io: io)
        do {
            switch command {
            case "add": try context.add(rest)
            case "add-json": try context.addJSON(rest)
            case "list": await context.list()
            case "get": try await context.get(rest)
            case "remove", "rm": try await context.remove(rest)
            case "login": try await context.login(rest)
            case "logout": try await context.logout(rest)
            case "-h", "--help", "help": io.out(usage)
            default:
                io.err("kwwk mcp: unknown command '\(command)'\n\n\(usage)")
                return 2
            }
            return 0
        } catch let error as UsageError {
            io.err("kwwk mcp \(command): \(error.message)")
            return 2
        } catch {
            io.err("kwwk mcp \(command): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return 1
        }
    }

    struct UsageError: Error {
        let message: String
    }

    struct Context {
        let cwd: String
        let homeDirectory: String
        let environment: [String: String]
        let io: MCPCommandIO

        func editor(_ scope: MCPConfigScope) -> MCPConfigEditor {
            MCPConfigEditor(url: MCPConfigFile.path(scope: scope, cwd: cwd, homeDirectory: homeDirectory), scope: scope)
        }

        func displayPath(_ scope: MCPConfigScope) -> String {
            let path = editor(scope).url.path
            return path.hasPrefix(homeDirectory + "/") ? "~" + path.dropFirst(homeDirectory.count) : path
        }

        var trustsProject: Bool {
            ["1", "true", "yes"].contains(environment[MCPRuntime.allowProjectServersVariable]?.lowercased() ?? "")
        }

        // MARK: add

        func add(_ arguments: [String]) throws {
            var options = AddOptions()
            var positional: [String] = []
            var command: [String]?
            var index = 0
            func value(_ flag: String) throws -> String {
                index += 1
                guard index < arguments.count else { throw UsageError(message: "\(flag) needs a value") }
                return arguments[index]
            }
            while index < arguments.count {
                var argument = arguments[index]
                var inline: String?
                if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                    inline = String(argument[argument.index(after: equals)...])
                    argument = String(argument[..<equals])
                }
                func next() throws -> String { if let inline { return inline }; return try value(argument) }
                switch argument {
                case "--":
                    command = Array(arguments[(index + 1)...])
                    index = arguments.count
                    continue
                case "-t", "--transport": options.transport = try next()
                case "-s", "--scope": options.scope = try Self.scope(try next())
                case "-e", "--env":
                    let pair = try next()
                    guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                        throw UsageError(message: "--env needs KEY=value, got \(pair)")
                    }
                    options.env[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
                case "-H", "--header":
                    let header = try next()
                    guard let colon = header.firstIndex(of: ":"), colon != header.startIndex else {
                        throw UsageError(message: "--header needs \"Name: value\", got \(header)")
                    }
                    options.headers[String(header[..<colon]).trimmingCharacters(in: .whitespaces)] =
                        String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                case "--description": options.description = try next()
                case "--client-id": options.oauth["clientId"] = .string(try next())
                case "--client-secret": options.oauth["clientSecret"] = .string(try next())
                case "--client-name": options.oauth["clientName"] = .string(try next())
                case "--oauth-scope": options.oauth["scope"] = .string(try next())
                case "--callback-port":
                    guard let port = Int(try next()), (1...65_535).contains(port) else {
                        throw UsageError(message: "--callback-port needs a port number")
                    }
                    options.oauth["callbackPort"] = .int(port)
                case "--no-oauth": options.noOAuth = true
                default:
                    if argument.hasPrefix("-") && argument.count > 1 {
                        throw UsageError(message: "unknown option \(argument)")
                    }
                    positional.append(argument)
                }
                index += 1
            }
            guard let name = positional.first else { throw UsageError(message: "missing server name\n\n\(MCPCommand.usage)") }
            let target = command ?? Array(positional.dropFirst())
            guard !target.isEmpty else { throw UsageError(message: "missing URL or -- command for \(name)") }
            let isURL = target.count == 1 && ["http", "https"].contains(URL(string: target[0])?.scheme?.lowercased() ?? "")
            let transport = options.transport ?? (isURL && command == nil ? "http" : "stdio")

            var entry: [String: JSONValue] = [:]
            switch transport {
            case "http", "streamable-http":
                guard target.count == 1 else { throw UsageError(message: "an HTTP server takes exactly one URL") }
                guard options.env.isEmpty else { throw UsageError(message: "--env applies to stdio servers") }
                entry["type"] = "http"
                entry["url"] = .string(target[0])
                if !options.headers.isEmpty { entry["headers"] = .object(options.headers.mapValues { .string($0) }) }
                if options.noOAuth {
                    guard options.oauth.isEmpty else { throw UsageError(message: "--no-oauth conflicts with OAuth options") }
                    entry["oauth"] = .bool(false)
                } else if !options.oauth.isEmpty {
                    entry["oauth"] = .object(options.oauth)
                }
            case "stdio":
                guard options.headers.isEmpty, options.oauth.isEmpty, !options.noOAuth else {
                    throw UsageError(message: "--header and OAuth options apply to HTTP servers")
                }
                entry["command"] = .string(target[0])
                if target.count > 1 { entry["args"] = .array(target.dropFirst().map { .string($0) }) }
                if !options.env.isEmpty { entry["env"] = .object(options.env.mapValues { .string($0) }) }
            case "sse":
                throw UsageError(message: "the legacy SSE transport is not supported; use the server's Streamable HTTP URL")
            default:
                throw UsageError(message: "--transport must be stdio or http")
            }
            if let description = options.description { entry["description"] = .string(description) }
            try write(name: name, entry: .object(entry), scope: options.scope)
        }

        func addJSON(_ arguments: [String]) throws {
            var scope = MCPConfigScope.user
            var positional: [String] = []
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "-s", "--scope":
                    index += 1
                    guard index < arguments.count else { throw UsageError(message: "--scope needs a value") }
                    scope = try Self.scope(arguments[index])
                default:
                    positional.append(arguments[index])
                }
                index += 1
            }
            guard positional.count == 2 else { throw UsageError(message: "usage: kwwk mcp add-json [--scope <scope>] <name> <json>") }
            let entry: JSONValue
            do {
                entry = try JSONDecoder().decode(JSONValue.self, from: Data(positional[1].utf8))
            } catch {
                throw UsageError(message: "invalid JSON")
            }
            try write(name: positional[0], entry: entry, scope: scope)
        }

        private func write(name: String, entry: JSONValue, scope: MCPConfigScope) throws {
            guard let parsed = try MCPConfigFile.validate(
                name: name, raw: entry, cwd: cwd, homeDirectory: homeDirectory, environment: environment
            ) else {
                throw UsageError(message: "the entry is disabled (\"enabled\": false)")
            }
            let editor = editor(scope)
            guard try editor.servers()[name] == nil else {
                throw UsageError(message: "MCP server \(name) already exists in \(displayPath(scope)); remove it first")
            }
            try editor.set(name, entry)
            let kind: String
            if case .http = parsed.server.transport { kind = "HTTP" } else { kind = "stdio" }
            io.out("Added \(kind) MCP server \(name) to \(scope.rawValue) config (\(displayPath(scope))).")
            if parsed.oauth != nil {
                io.out("If it needs a sign-in, run: kwwk mcp login \(name)")
            }
            if scope == .project && !trustsProject {
                io.out("Project servers load only with \(MCPRuntime.allowProjectServersVariable)=1.")
            }
        }

        static func scope(_ value: String) throws -> MCPConfigScope {
            guard let scope = MCPConfigScope(rawValue: value) else {
                throw UsageError(message: "--scope must be user or project")
            }
            return scope
        }

        // MARK: list / get

        func loaded() -> MCPConfigFile.Loaded {
            MCPConfigFile.load(cwd: cwd, homeDirectory: homeDirectory, trustProject: trustsProject, environment: environment)
        }

        func list() async {
            let loaded = loaded()
            for warning in loaded.warnings { io.err("warning: \(warning)") }
            guard !loaded.entries.isEmpty else {
                io.out("No MCP servers configured. Add one with: kwwk mcp add <name> <url>")
                return
            }
            io.out("Checking MCP server health…\n")
            let runtime = MCPRuntime(cwd: cwd, homeDirectory: homeDirectory, environment: environment)
            if let manager = runtime.manager {
                let wait = loaded.entries.map(\.server.startupTimeoutSeconds).max() ?? 30
                await manager.waitForStartup(timeout: wait)
                let states = Dictionary(
                    await manager.statuses().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
                )
                for entry in loaded.entries {
                    let name = entry.server.name
                    let status = states[name]
                    let health: String
                    switch status?.state {
                    case .connected?: health = "✔ Connected (\(status?.toolCount ?? 0) tools)"
                    case .authorizationRequired?:
                        health = entry.oauth != nil ? "! Needs authentication (kwwk mcp login \(name))" : "! Needs authorization"
                    case .failed(let reason)?, .disconnected(let reason)?:
                        health = "✘ Failed to connect: \(reason.split(whereSeparator: \.isNewline).first ?? "")"
                    case .connecting?: health = "… Still connecting"
                    case .closed?, nil: health = entry.server.exposure == .hidden ? "hidden" : "not started"
                    }
                    io.out("\(name) (\(entry.scope.rawValue)): \(Self.target(entry.server.transport)) - \(health)")
                }
                await runtime.shutdown()
            }
        }

        static func target(_ transport: MCPTransportConfig) -> String {
            switch transport {
            case .http(let url, _): return url.absoluteString + " (HTTP)"
            case .stdio(let command, let args, _, _): return ([command] + args).joined(separator: " ")
            }
        }

        func get(_ arguments: [String]) async throws {
            guard arguments.count == 1, let name = arguments.first else { throw UsageError(message: "usage: kwwk mcp get <name>") }
            var found = false
            for scope in MCPConfigScope.allCases {
                guard let raw = try editor(scope).servers()[name] else { continue }
                found = true
                io.out("\(name):")
                io.out("  Scope: \(scope.rawValue) (\(displayPath(scope)))")
                if scope == .project && !trustsProject {
                    io.out("  Not loaded: set \(MCPRuntime.allowProjectServersVariable)=1 to trust this project's servers")
                }
                let fields = raw.cliObject ?? [:]
                if let url = fields["url"]?.cliString {
                    io.out("  Type: http")
                    io.out("  URL: \(url)")
                    for (header, value) in (fields["headers"]?.cliObject ?? [:]).sorted(by: { $0.key < $1.key }) {
                        io.out("  Header: \(header): \(Self.redacted(header, value.cliString ?? ""))")
                    }
                    if case .bool(false)? = fields["oauth"] {
                        io.out("  OAuth: off")
                    } else if (fields["headers"]?.cliObject ?? [:]).keys.contains(where: { $0.lowercased() == "authorization" }) {
                        io.out("  OAuth: off (sends its own Authorization header)")
                    } else {
                        let record = MCPOAuthFileStore.readRecords(url: MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory))[name]
                        let signedIn = record?.serverURL == url && record?.tokens != nil
                        io.out("  OAuth: on, \(signedIn ? "signed in" : "not signed in (kwwk mcp login \(name))")")
                        for (key, value) in (fields["oauth"]?.cliObject ?? [:]).sorted(by: { $0.key < $1.key }) {
                            let text = value.cliString ?? (value.cliInt.map(String.init) ?? "\(value)")
                            io.out("    \(key): \(Self.redacted(key, text))")
                        }
                    }
                } else if let command = fields["command"]?.cliString {
                    io.out("  Type: stdio")
                    io.out("  Command: \(command)")
                    let args = (fields["args"]?.cliArray ?? []).compactMap(\.cliString)
                    if !args.isEmpty { io.out("  Args: \(args.joined(separator: " "))") }
                    for (key, value) in (fields["env"]?.cliObject ?? [:]).sorted(by: { $0.key < $1.key }) {
                        io.out("  Env: \(key)=\(Self.redacted(key, value.cliString ?? ""))")
                    }
                }
                if let description = fields["description"]?.cliString { io.out("  Description: \(description)") }
                if case .bool(false)? = fields["enabled"] { io.out("  Enabled: no") }
                io.out("  To remove it: kwwk mcp remove \(name) --scope \(scope.rawValue)")
            }
            guard found else { throw UsageError(message: "no MCP server named \(name)") }
        }

        /// Values of secret-looking names are hidden, unless they only
        /// reference an environment variable.
        static func redacted(_ name: String, _ value: String) -> String {
            let lowered = name.lowercased()
            let secret = ["token", "secret", "key", "authorization", "password", "cookie"].contains { lowered.contains($0) }
            guard secret, !value.isEmpty else { return value }
            if value.hasPrefix("${"), value.hasSuffix("}") { return value }
            return "***"
        }

        // MARK: remove

        func remove(_ arguments: [String]) async throws {
            var scope: MCPConfigScope?
            var positional: [String] = []
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "-s", "--scope":
                    index += 1
                    guard index < arguments.count else { throw UsageError(message: "--scope needs a value") }
                    scope = try Self.scope(arguments[index])
                default:
                    positional.append(arguments[index])
                }
                index += 1
            }
            guard positional.count == 1, let name = positional.first else {
                throw UsageError(message: "usage: kwwk mcp remove [--scope <scope>] <name>")
            }
            var removed: [MCPConfigScope] = []
            for candidate in scope.map({ [$0] }) ?? MCPConfigScope.allCases where try editor(candidate).remove(name) {
                removed.append(candidate)
            }
            guard !removed.isEmpty else {
                throw UsageError(message: "no MCP server named \(name)\(scope.map { " in \($0.rawValue) config" } ?? "")")
            }
            for candidate in removed {
                io.out("Removed MCP server \(name) from \(candidate.rawValue) config (\(displayPath(candidate))).")
            }
            try await MCPOAuthFileStore(url: MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory)).remove(server: name)
        }

        // MARK: login / logout

        func login(_ arguments: [String]) async throws {
            var openBrowser = true
            var port: UInt16?
            var positional: [String] = []
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--no-browser": openBrowser = false
                case "--callback-port":
                    index += 1
                    guard index < arguments.count, let value = UInt16(arguments[index]), value > 0 else {
                        throw UsageError(message: "--callback-port needs a port number")
                    }
                    port = value
                default: positional.append(arguments[index])
                }
                index += 1
            }
            guard positional.count == 1, let name = positional.first else {
                throw UsageError(message: "usage: kwwk mcp login [--no-browser] [--callback-port <port>] <name>")
            }
            let (provider, store) = try oauthProvider(name, port: port)
            await store.remember(port: provider.callbackPort, server: name)
            io.out("Signing in to \(name)…")
            try await provider.login(openBrowser: openBrowser)
            io.out("Signed in to \(name).")
        }

        func logout(_ arguments: [String]) async throws {
            guard arguments.count == 1, let name = arguments.first else { throw UsageError(message: "usage: kwwk mcp logout <name>") }
            _ = try oauthProvider(name, port: nil)
            try await MCPOAuthFileStore(url: MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory)).remove(server: name)
            io.out("Signed out of \(name).")
        }

        private func oauthProvider(_ name: String, port: UInt16?) throws -> (CLIMCPOAuthProvider, MCPOAuthFileStore) {
            guard let entry = loaded().entries.first(where: { $0.server.name == name }) else {
                throw UsageError(message: "no MCP server named \(name)")
            }
            guard case .http(let url, _) = entry.server.transport, var settings = entry.oauth else {
                throw UsageError(message: "\(name) does not use OAuth")
            }
            if let port { settings.callbackPort = port }
            let storeURL = MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory)
            let store = MCPOAuthFileStore(url: storeURL)
            let callbackPort = MCPOAuthCLI.callbackPort(
                server: name, serverURL: url, settings: settings, records: MCPOAuthFileStore.readRecords(url: storeURL)
            )
            return (CLIMCPOAuthProvider(server: name, serverURL: url, settings: settings, store: store, callbackPort: callbackPort), store)
        }
    }

    struct AddOptions {
        var transport: String?
        var scope: MCPConfigScope = .user
        var env: [String: String] = [:]
        var headers: [String: String] = [:]
        var description: String?
        var oauth: [String: JSONValue] = [:]
        var noOAuth = false
    }
}

private extension JSONValue {
    var cliObject: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var cliString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var cliArray: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var cliInt: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}
