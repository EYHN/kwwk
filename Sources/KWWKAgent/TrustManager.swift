import Foundation

/// Project-trust gate, mirroring pi's `trust-manager.ts` / `project-trust.ts`.
///
/// A project directory is "trusted" once the user has opted in to loading its
/// project-local configuration (`.kwwk/commands`, custom prompts, etc.). The
/// decision can be persisted in a JSON file, a flat map of `absolute-dir →
/// bool`. `TrustManager()` is disabled/empty and does not touch disk; the CLI
/// opts into `~/.kwwk/trust.json` via `defaultStoreURL()`.
///
/// This type only exposes the storage + check API. UI wiring (prompting the
/// user the first time an untrusted project is opened) is left to the CLI as a
/// follow-up — see `TrustManager.requiresPrompt(for:)` for the predicate a host
/// would use to decide whether to ask.
/// Error surfaced when the trust store on disk is present but unreadable as a
/// valid `{ "<path>": true|false|null }` map. Mirrors pi's `readTrustFile`
/// throw behavior: a malformed store must NOT be silently treated as empty,
/// because that would drop every previously-saved decision and re-prompt the
/// user (and risk clobbering the file on the next write).
public enum TrustStoreError: Error, Equatable {
    case malformed(path: String, message: String)
}

public final class TrustManager {
    /// Location of the JSON store when persistence is enabled.
    public let storeURL: URL
    public let isPersistent: Bool

    /// The error from the most recent load, if the store was malformed. The
    /// convenience (non-throwing) API fails safe and records the error here so
    /// a CLI host can surface a one-line warning instead of silently behaving
    /// as untrusted.
    public private(set) var lastLoadError: TrustStoreError?

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
            self.isPersistent = true
        } else {
            self.storeURL = URL(fileURLWithPath: "/dev/null")
            self.isPersistent = false
        }
    }

    /// CLI-compatible trust store path: `~/.kwwk/trust.json`.
    public static func defaultStoreURL() -> URL {
        let home: URL = {
            #if targetEnvironment(macCatalyst) || os(iOS)
            return URL(fileURLWithPath: NSHomeDirectory())
            #else
            return FileManager.default.homeDirectoryForCurrentUser
            #endif
        }()
        return home
            .appendingPathComponent(".kwwk")
            .appendingPathComponent("trust.json")
    }

    // MARK: - Public API

    /// Whether `cwd` (or one of its ancestors) is explicitly trusted. A `false`
    /// stored decision short-circuits the ancestor walk and is reported as
    /// untrusted. Unknown directories (no entry anywhere up the chain) are
    /// untrusted.
    public func isTrusted(_ cwd: String) -> Bool {
        decision(cwd) == true
    }

    /// The nearest explicit decision for `cwd`, or `nil` when no ancestor has an
    /// entry. Distinguishes "explicitly untrusted" (`false`) from "never
    /// decided" (`nil`) so a host can decide whether to prompt. Fails safe: a
    /// malformed store returns `nil` (re-prompt) and records `lastLoadError`,
    /// never silently auto-trusts.
    public func decision(_ cwd: String) -> Bool? {
        (try? decisionChecked(cwd)) ?? nil
    }

    /// The nearest explicit decision for `cwd`, surfacing a malformed store as a
    /// thrown `TrustStoreError` (so saved decisions are never silently dropped).
    public func decisionChecked(_ cwd: String) throws -> Bool? {
        let data = try readChecked()
        return nearest(in: data, for: cwd)
    }

    /// Persist `cwd` as trusted.
    public func trust(_ cwd: String) {
        try? set(cwd, decision: true)
    }

    /// Persist `cwd` as explicitly untrusted.
    public func distrust(_ cwd: String) {
        try? set(cwd, decision: false)
    }

    /// Persist `cwd` as trusted, surfacing a malformed-store error (the write is
    /// refused so the corrupt file is never clobbered). pi parity.
    public func trustChecked(_ cwd: String) throws {
        try set(cwd, decision: true)
    }

    /// Remove any explicit decision for `cwd` (it reverts to inheriting from an
    /// ancestor, or to untrusted).
    public func forget(_ cwd: String) {
        try? mutate { $0.removeValue(forKey: TrustManager.normalize(cwd)) }
    }

    /// Set (or clear, when `decision == nil`) the stored decision for `cwd`.
    /// Reads-before-write through the checked loader so a malformed file is not
    /// overwritten (mirrors pi); throws `TrustStoreError` in that case.
    public func set(_ cwd: String, decision: Bool?) throws {
        let key = TrustManager.normalize(cwd)
        try mutate { data in
            if let decision {
                data[key] = decision
            } else {
                data.removeValue(forKey: key)
            }
        }
    }

    /// Read-modify-write helper. Reads through the checked loader (so a corrupt
    /// store throws and is never clobbered), applies `f`, then writes.
    private func mutate(_ f: (inout [String: Bool]) -> Void) throws {
        var data = try readChecked()
        f(&data)
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

    /// Read the store, distinguishing "missing" (→ empty, ok) from "malformed"
    /// (→ throws `TrustStoreError`). Mirrors pi's `readTrustFile`: a corrupt file
    /// must not collapse to `{}`. Records `lastLoadError` as a side-effect so the
    /// non-throwing API can surface it.
    private func readChecked() throws -> [String: Bool] {
        guard isPersistent else {
            lastLoadError = nil
            return [:]
        }
        // Missing / unreadable file → empty, ok (matches pi missing→{}).
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            lastLoadError = nil
            return [:]
        }
        guard let data = try? Data(contentsOf: storeURL) else {
            lastLoadError = nil
            return [:]
        }
        func fail(_ message: String) -> TrustStoreError {
            let err = TrustStoreError.malformed(path: storeURL.path, message: message)
            lastLoadError = err
            return err
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw fail("invalid JSON")
        }
        // Arrays / scalars are not a valid store shape.
        guard let raw = obj as? [String: Any] else {
            throw fail("expected an object")
        }
        var out: [String: Bool] = [:]
        for (key, value) in raw {
            if let b = value as? Bool {
                out[key] = b
            } else if value is NSNull {
                continue                       // pi allows null (= no decision)
            } else {
                throw fail("value for \"\(key)\" must be true, false, or null")
            }
        }
        lastLoadError = nil
        return out
    }

    private func write(_ data: [String: Bool]) {
        guard isPersistent else { return }
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

    /// Walk from `cwd` up to the filesystem root within `data`, returning the
    /// decision of the nearest directory with an explicit entry.
    private func nearest(in data: [String: Bool], for cwd: String) -> Bool? {
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
