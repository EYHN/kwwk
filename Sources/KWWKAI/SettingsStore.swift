import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Resolves a single configuration string that may be a literal, an
/// environment-variable template, or a `!`-prefixed shell command. Ported from
/// pi's `coding-agent/src/core/resolve-config-value.ts`.
///
/// Resolution rules (matching pi):
/// - A value beginning with `!` runs the remainder as a shell command and uses
///   its trimmed stdout. (empty stdout → nil).
/// - Otherwise the value is a template: `$NAME` or `${NAME}` interpolate the
///   named environment variable. A missing variable makes the whole template
///   resolve to nil.
/// - `$$` escapes a literal `$` and `$!` escapes a literal `!` in templates.
public enum ConfigValue {
    public typealias Env = [String: String]

    private enum Part: Equatable {
        case literal(String)
        case env(String)
    }

    private enum Reference: Equatable {
        case command(String)   // includes the leading "!"
        case template([Part])
    }

    private static func isEnvNameStart(_ c: Character) -> Bool {
        c == "_" || c.isLetter && c.isASCII
    }

    private static func isEnvNameChar(_ c: Character) -> Bool {
        isEnvNameStart(c) || (c.isNumber && c.isASCII)
    }

    private static func isValidEnvName(_ name: Substring) -> Bool {
        guard let first = name.first, isEnvNameStart(first) else { return false }
        return name.dropFirst().allSatisfy(isEnvNameChar)
    }

    private static func appendLiteral(_ parts: inout [Part], _ value: String) {
        guard !value.isEmpty else { return }
        if case .literal(let previous)? = parts.last {
            parts[parts.count - 1] = .literal(previous + value)
        } else {
            parts.append(.literal(value))
        }
    }

    private static func parseTemplate(_ config: String) -> [Part] {
        var parts: [Part] = []
        let chars = Array(config)
        var i = 0
        while i < chars.count {
            // Find next '$'.
            guard let dollar = chars[i...].firstIndex(of: "$") else {
                appendLiteral(&parts, String(chars[i...]))
                break
            }
            appendLiteral(&parts, String(chars[i..<dollar]))
            let next = dollar + 1 < chars.count ? chars[dollar + 1] : nil

            if next == "$" || next == "!" {
                appendLiteral(&parts, String(next!))
                i = dollar + 2
                continue
            }

            if next == "{" {
                if let close = chars[(dollar + 2)...].firstIndex(of: "}") {
                    let name = String(chars[(dollar + 2)..<close])
                    if isValidEnvName(Substring(name)) {
                        parts.append(.env(name))
                    } else {
                        appendLiteral(&parts, String(chars[dollar...close]))
                    }
                    i = close + 1
                    continue
                }
                // No closing brace: literal '$'.
                appendLiteral(&parts, "$")
                i = dollar + 1
                continue
            }

            // Bare `$NAME` form.
            if let n = next, isEnvNameStart(n) {
                var j = dollar + 1
                while j < chars.count && isEnvNameChar(chars[j]) { j += 1 }
                parts.append(.env(String(chars[(dollar + 1)..<j])))
                i = j
                continue
            }

            appendLiteral(&parts, "$")
            i = dollar + 1
        }
        return parts
    }

    private static func parseReference(_ config: String) -> Reference {
        if config.hasPrefix("!") { return .command(config) }
        return .template(parseTemplate(config))
    }

    private static func resolveEnv(_ name: String, _ env: Env) -> String? {
        if let v = env[name], !v.isEmpty { return v }
        return nil
    }

    private static func resolveTemplate(_ parts: [Part], _ env: Env) -> String? {
        var out = ""
        for part in parts {
            switch part {
            case .literal(let s):
                out += s
            case .env(let name):
                guard let v = resolveEnv(name, env) else { return nil }
                out += v
            }
        }
        return out
    }

    /// Whether `config` is a `!shell-command` reference.
    public static func isCommand(_ config: String) -> Bool {
        if case .command = parseReference(config) { return true }
        return false
    }

    /// The environment-variable names referenced by `config`, in order, deduped.
    public static func envVarNames(_ config: String) -> [String] {
        guard case .template(let parts) = parseReference(config) else { return [] }
        var names: [String] = []
        for case .env(let name) in parts where !names.contains(name) { names.append(name) }
        return names
    }

    /// Resolve `config` to its concrete value. Returns nil when an env var is
    /// missing or a shell command fails / produces empty output.
    public static func resolve(
        _ config: String,
        env: Env = ProcessInfo.processInfo.environment
    ) -> String? {
        switch parseReference(config) {
        case .command(let command):
            return runCommand(String(command.dropFirst()))
        case .template(let parts):
            return resolveTemplate(parts, env)
        }
    }

    /// Run `command` via the user's shell, returning trimmed stdout (nil on
    /// failure, non-zero exit, or empty output). Mirrors pi's 10s timeout.
    static func runCommand(_ command: String, timeoutSeconds: TimeInterval = 10) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-config-shell-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            // SIGKILL directly — SIGTERM can be ignored by a busy loop, and a
            // slow SIGTERM→SIGKILL escalation leaves the detached `waitUntilExit`
            // thread blocked, which under parallel test execution starves the
            // global queue and stalls unrelated work. SIGKILL reaps promptly.
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 2)
            return nil
        }
        try? outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }
}

/// Which configuration scope a settings file belongs to.
public enum SettingsScope: String, Sendable, Equatable {
    case global
    case project
}

/// Recorded (not swallowed) error from loading a malformed settings file.
/// Mirrors pi's `globalSettingsLoadError` / `projectSettingsLoadError`: a
/// malformed file is treated as empty for the merge, but the error is surfaced
/// so a host can warn — and a future writer can refuse to overwrite that scope.
public struct SettingsLoadError: Error, Sendable, Equatable {
    public let scope: SettingsScope
    public let path: String
    public let message: String

    public init(scope: SettingsScope, path: String, message: String) {
        self.scope = scope
        self.path = path
        self.message = message
    }
}

/// Loads and deep-merges kwwk settings from a global and a project file. Ported
/// from pi's `settings-manager.ts`: the global `~/.kwwk/settings.json` is the
/// base, and a project `./.kwwk/settings.json` is layered on top (project wins).
public struct SettingsStore: Sendable {
    /// Directory name used for both the global (`~/.kwwk`) and project
    /// (`./.kwwk`) config locations.
    public static let configDirName = ".kwwk"
    public static let settingsFileName = "settings.json"

    /// The deep-merged settings (project over global).
    public let merged: Settings
    /// The global settings as loaded (empty defaults when absent).
    public let global: Settings
    /// The project settings as loaded (empty defaults when absent).
    public let project: Settings
    /// Whether the project scope was trusted at load time. When false, the
    /// project file is not read at all (pi parity) and `project == .empty`.
    public let projectTrusted: Bool
    /// Errors recorded while loading malformed files. Empty on a clean load.
    /// A future settings writer MUST check this before overwriting a scope:
    /// refuse to write `project` when `loadErrors.contains { $0.scope == .project }`
    /// (mirrors pi's `saveProjectSettings` guard), and likewise for `global`.
    public let loadErrors: [SettingsLoadError]

    public init(
        merged: Settings,
        global: Settings,
        project: Settings,
        projectTrusted: Bool = true,
        loadErrors: [SettingsLoadError] = []
    ) {
        self.merged = merged
        self.global = global
        self.project = project
        self.projectTrusted = projectTrusted
        self.loadErrors = loadErrors
    }

    /// Default global settings path: `~/.kwwk/settings.json`.
    public static func defaultGlobalPath() -> URL {
        homeDirectory()
            .appendingPathComponent(configDirName, isDirectory: true)
            .appendingPathComponent(settingsFileName)
    }

    /// Project settings path for `cwd`: `<cwd>/.kwwk/settings.json`.
    public static func projectPath(cwd: URL) -> URL {
        cwd.appendingPathComponent(configDirName, isDirectory: true)
            .appendingPathComponent(settingsFileName)
    }

    private static func homeDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Load + deep-merge from explicit file URLs. Missing files yield empty
    /// defaults rather than throwing. A malformed file is treated as empty for
    /// the merge but its error is recorded in `loadErrors` (not silently
    /// dropped). When `projectTrusted` is false the project file is skipped
    /// entirely (pi parity) — `project == .empty` and no error.
    public static func load(
        globalPath: URL,
        projectPath: URL?,
        projectTrusted: Bool = true
    ) -> SettingsStore {
        var loadErrors: [SettingsLoadError] = []

        let (global, globalErr) = loadFileChecked(globalPath, scope: .global)
        if let globalErr { loadErrors.append(globalErr) }

        let project: Settings
        if projectTrusted, let projectPath {
            let (p, projErr) = loadFileChecked(projectPath, scope: .project)
            project = p
            if let projErr { loadErrors.append(projErr) }
        } else {
            project = .empty
        }

        let merged = deepMerge(base: global, overrides: project)
        return SettingsStore(
            merged: merged,
            global: global,
            project: project,
            projectTrusted: projectTrusted,
            loadErrors: loadErrors
        )
    }

    /// Convenience: load from the default `~/.kwwk` global path and the project
    /// `.kwwk` directory under `cwd`.
    public static func load(
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        projectTrusted: Bool = true
    ) -> SettingsStore {
        load(
            globalPath: defaultGlobalPath(),
            projectPath: projectPath(cwd: cwd),
            projectTrusted: projectTrusted
        )
    }

    /// Decode a single settings file. Returns `(.empty, nil)` for a missing or
    /// unreadable file (ok), and `(.empty, error)` for a malformed file — the
    /// missing-vs-malformed distinction pi makes and the old `loadFile` lost.
    static func loadFileChecked(_ url: URL, scope: SettingsScope)
        -> (Settings, SettingsLoadError?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.empty, nil) }
        guard let data = try? Data(contentsOf: url) else { return (.empty, nil) }
        do {
            return (try JSONDecoder().decode(Settings.self, from: data), nil)
        } catch {
            return (.empty, SettingsLoadError(scope: scope, path: url.path, message: "\(error)"))
        }
    }

    /// Decode a single settings file, or nil if missing/unreadable/malformed.
    /// Retained for backward compatibility; prefer `loadFileChecked`.
    static func loadFile(_ url: URL) -> Settings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    // MARK: - Deep merge

    /// Deep-merge two `Settings`. `overrides` (project) wins over `base`
    /// (global): primitives and arrays replace, nested objects in `extra` merge
    /// recursively. Mirrors pi's `deepMergeSettings`.
    public static func deepMerge(base: Settings, overrides: Settings) -> Settings {
        var result = base

        if let v = overrides.defaultProvider { result.defaultProvider = v }
        if let v = overrides.defaultModel { result.defaultModel = v }
        if let v = overrides.defaultThinkingLevel { result.defaultThinkingLevel = v }
        if let v = overrides.theme { result.theme = v }
        if let v = overrides.hideThinkingBlock { result.hideThinkingBlock = v }
        if let v = overrides.quietStartup { result.quietStartup = v }
        if let v = overrides.enableInstallTelemetry { result.enableInstallTelemetry = v }
        if let v = overrides.enableAnalytics { result.enableAnalytics = v }
        if let v = overrides.enabledModels { result.enabledModels = v }

        result.extra = deepMergeObjects(base: base.extra, overrides: overrides.extra)
        return result
    }

    private static func deepMergeObjects(
        base: [String: JSONValue],
        overrides: [String: JSONValue]
    ) -> [String: JSONValue] {
        var result = base
        for (key, overrideValue) in overrides {
            if case .object(let o) = overrideValue,
               case .object(let b)? = base[key] {
                result[key] = .object(deepMergeObjects(base: b, overrides: o))
            } else {
                result[key] = overrideValue
            }
        }
        return result
    }
}
