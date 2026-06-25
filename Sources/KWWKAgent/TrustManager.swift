import Foundation

/// Project-trust gate, mirroring pi's `trust-manager.ts` / `project-trust.ts`.
///
/// A project directory is "trusted" once the user has opted in to loading its
/// project-local configuration (`.kwwk/commands`, custom prompts, etc.). The
/// decision is persisted in `~/.kwwk/trust.json`, a flat map of
/// `absolute-dir → bool`. A directory inherits the decision of the nearest
/// ancestor that has an explicit entry, so trusting a parent folder once trusts
/// every project beneath it.
///
/// This type only exposes the storage + check API. UI wiring (prompting the
/// user the first time an untrusted project is opened) is left to the CLI as a
/// follow-up — see `TrustManager.requiresPrompt(for:)` for the predicate a host
/// would use to decide whether to ask.
public final class TrustManager {
    /// Location of the JSON store. Defaults to `~/.kwwk/trust.json`.
    public let storeURL: URL

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let home: URL = {
                #if targetEnvironment(macCatalyst) || os(iOS)
                return URL(fileURLWithPath: NSHomeDirectory())
                #else
                return FileManager.default.homeDirectoryForCurrentUser
                #endif
            }()
            self.storeURL = home
                .appendingPathComponent(".kwwk")
                .appendingPathComponent("trust.json")
        }
    }

    // MARK: - Public API

    /// Whether `cwd` (or one of its ancestors) is explicitly trusted. A `false`
    /// stored decision short-circuits the ancestor walk and is reported as
    /// untrusted. Unknown directories (no entry anywhere up the chain) are
    /// untrusted.
    public func isTrusted(_ cwd: String) -> Bool {
        nearestDecision(for: cwd) == true
    }

    /// The nearest explicit decision for `cwd`, or `nil` when no ancestor has an
    /// entry. Distinguishes "explicitly untrusted" (`false`) from "never
    /// decided" (`nil`) so a host can decide whether to prompt.
    public func decision(_ cwd: String) -> Bool? {
        nearestDecision(for: cwd)
    }

    /// Persist `cwd` as trusted.
    public func trust(_ cwd: String) {
        set(cwd, decision: true)
    }

    /// Persist `cwd` as explicitly untrusted.
    public func distrust(_ cwd: String) {
        set(cwd, decision: false)
    }

    /// Remove any explicit decision for `cwd` (it reverts to inheriting from an
    /// ancestor, or to untrusted).
    public func forget(_ cwd: String) {
        var data = read()
        data.removeValue(forKey: TrustManager.normalize(cwd))
        write(data)
    }

    /// Set (or clear, when `decision == nil`) the stored decision for `cwd`.
    public func set(_ cwd: String, decision: Bool?) {
        var data = read()
        let key = TrustManager.normalize(cwd)
        if let decision {
            data[key] = decision
        } else {
            data.removeValue(forKey: key)
        }
        write(data)
    }

    /// Predicate a UI host can use to decide whether to prompt the user on
    /// session start: true when there is no decision anywhere up the chain *and*
    /// the project carries trust-requiring resources. Hosts that don't want to
    /// scan resources can just check `decision(cwd) == nil`.
    public func requiresPrompt(for cwd: String) -> Bool {
        decision(cwd) == nil && TrustManager.hasTrustRequiringResources(cwd)
    }

    // MARK: - Resource detection

    /// Project-local config entries (relative to `cwd/.kwwk`) whose presence
    /// means we'd be loading project-supplied behavior and therefore should be
    /// gated by trust. Mirrors pi's `TRUST_REQUIRING_PROJECT_CONFIG_RESOURCES`.
    static let trustRequiringConfigEntries = [
        "commands",
        "settings.json",
        "subagents",
        "prompts",
        "SYSTEM.md",
        "APPEND_SYSTEM.md",
    ]

    /// True when `cwd` has project-local resources that warrant a trust gate.
    public static func hasTrustRequiringResources(_ cwd: String) -> Bool {
        let fm = FileManager.default
        let configDir = (normalize(cwd) as NSString).appendingPathComponent(".kwwk")
        for entry in trustRequiringConfigEntries {
            let path = (configDir as NSString).appendingPathComponent(entry)
            if fm.fileExists(atPath: path) { return true }
        }
        return false
    }

    // MARK: - Storage

    private func read() -> [String: Bool] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        // The on-disk shape is `{ "/abs/path": true|false }`. `null` values
        // (pi writes them transiently) are treated as "no decision" → dropped.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: Bool] = [:]
        for (key, value) in raw {
            if let b = value as? Bool { out[key] = b }
        }
        return out
    }

    private func write(_ data: [String: Bool]) {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        // Stable, sorted output so the file diffs cleanly across writes.
        let sortedPairs = data.sorted { $0.key < $1.key }
        var ordered: [(String, Bool)] = []
        for (k, v) in sortedPairs { ordered.append((k, v)) }
        let json = "{\n" + ordered.map { "  \(Self.encode($0.0)): \($0.1)" }
            .joined(separator: ",\n") + (ordered.isEmpty ? "" : "\n") + "}\n"
        try? json.data(using: .utf8)?.write(to: storeURL, options: .atomic)
    }

    private static func encode(_ s: String) -> String {
        let data = try? JSONEncoder().encode(s)
        if let data, let str = String(data: data, encoding: .utf8) { return str }
        return "\"\(s)\""
    }

    // MARK: - Lookup helpers

    /// Walk from `cwd` up to the filesystem root, returning the decision of the
    /// nearest directory with an explicit entry.
    private func nearestDecision(for cwd: String) -> Bool? {
        let data = read()
        var current = TrustManager.normalize(cwd)
        while true {
            if let value = data[current] { return value }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    /// Canonicalize a directory path: expand `~`, make absolute, drop a trailing
    /// slash. Symlinks are resolved when the path exists so two spellings of the
    /// same dir collapse to one key.
    static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("~") {
            p = NSHomeDirectory() + p.dropFirst()
        }
        if !(p as NSString).isAbsolutePath {
            let cwd = FileManager.default.currentDirectoryPath
            p = (cwd as NSString).appendingPathComponent(p)
        }
        p = (p as NSString).standardizingPath
        // standardizingPath resolves `~`, `.`, `..` and a trailing slash; resolve
        // symlinks too when the target exists.
        let resolved = (p as NSString).resolvingSymlinksInPath
        return resolved
    }
}
