import Foundation

/// Directory names pruned during recursive tool walks (find, grep). Mirrors
/// pi's fd/ripgrep defaults, which skip VCS metadata and dependency/build
/// trees. `.build` matters especially now that a slashless `find` pattern
/// recurses the whole tree — without it `find "*.swift"` drowns in SwiftPM's
/// vendored checkouts and generated sources.
let ignoredWalkDirectoryNames: Set<String> = [".git", ".hg", ".svn", "node_modules", ".build"]

public enum Glob {

    /// Match a path against a glob pattern supporting `*`, `?`, and `**`.
    public static func matches(path: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: patternToRegex(pattern)) else {
            return false
        }
        return matches(path: path, compiled: regex)
    }

    private static func matches(path: String, compiled: NSRegularExpression) -> Bool {
        let ns = path as NSString
        return compiled.firstMatch(in: path, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Translate a glob pattern into an anchored regex string.
    public static func patternToRegex(_ pattern: String) -> String {
        var out = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            if ch == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    // `**` — match any characters including slashes
                    out += ".*"
                    i = pattern.index(after: next)
                    if i < pattern.endIndex && pattern[i] == "/" {
                        i = pattern.index(after: i)
                    }
                    continue
                }
                out += "[^/]*"
            } else if ch == "?" {
                out += "[^/]"
            } else if "[]().+|^$\\{}".contains(ch) {
                // Escape regex metacharacters (including `[` and `]`) so a glob
                // like `file[1].txt` matches those literal brackets instead of
                // being read as a regex character class.
                out += "\\\(ch)"
            } else {
                out.append(ch)
            }
            i = pattern.index(after: i)
        }
        out += "$"
        return out
    }

    /// Canonicalize a directory path with a real filesystem resolve. The
    /// `FileManager` enumerator yields fully-resolved paths (on macOS a
    /// `/var/…` root surfaces as `/private/var/…` because `/var` is a
    /// firmlink that neither `resolvingSymlinksInPath` nor
    /// `standardizedFileURL` traverse — only `realpath` does). Any walk that
    /// slices enumerated paths relative to its root must measure the prefix
    /// against this canonical form. Returns the input unchanged when it
    /// doesn't resolve (nonexistent path) — the enumerator then yields
    /// nothing anyway.
    public static func canonicalDirectoryPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Walk `root` recursively and return absolute file paths matching `pattern`.
    /// The pattern is compiled once, and well-known VCS/dependency directories
    /// are pruned during the walk.
    ///
    /// Matching mirrors the grep tool's `--glob` semantics (and fd/ripgrep/omp):
    /// a pattern **without** a slash filters on the basename at any depth, so
    /// `*.swift` finds every Swift file in the tree — not just top-level ones.
    /// A pattern **with** a slash matches the path relative to `root`, so
    /// `Sources/*.swift` scopes to that directory and `**/*.swift` recurses
    /// explicitly.
    public static func expand(root: String, pattern: String, limit: Int? = nil) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: patternToRegex(pattern)) else {
            return []
        }
        let matchesRelative = pattern.contains("/")
        let fm = FileManager.default
        // Canonicalize the root before enumerating so the relative-path
        // prefix below strips the right number of leading characters (see
        // `canonicalDirectoryPath`) — otherwise a slash-anchored pattern like
        // `src/*.swift` under a firmlinked root matches nothing.
        let base = canonicalDirectoryPath(root)
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else {
            return []
        }
        var results: [String] = []
        let prefix = base.hasSuffix("/") ? base.count : base.count + 1
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if ignoredWalkDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let candidate: String
            if matchesRelative {
                var relative = url.path
                if relative.count > prefix { relative = String(relative.dropFirst(prefix)) }
                candidate = relative
            } else {
                candidate = url.lastPathComponent
            }
            if matches(path: candidate, compiled: regex) {
                results.append(url.path)
                if let limit, results.count >= limit { break }
            }
        }
        return results
    }
}
