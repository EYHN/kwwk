import Foundation

/// Directory names pruned during recursive tool walks (find, grep). Mirrors
/// pi's fd/ripgrep defaults, which skip VCS metadata and dependency trees.
let ignoredWalkDirectoryNames: Set<String> = [".git", ".hg", ".svn", "node_modules"]

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

    /// Walk `root` recursively and return absolute file paths matching `pattern`.
    /// The pattern is compiled once, and well-known VCS/dependency directories
    /// are pruned during the walk.
    public static func expand(root: String, pattern: String, limit: Int? = nil) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: patternToRegex(pattern)) else {
            return []
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else {
            return []
        }
        var results: [String] = []
        let prefix = root.hasSuffix("/") ? root.count : root.count + 1
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if ignoredWalkDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            var relative = url.path
            if relative.count > prefix { relative = String(relative.dropFirst(prefix)) }
            if matches(path: relative, compiled: regex) {
                results.append(url.path)
                if let limit, results.count >= limit { break }
            }
        }
        return results
    }
}
