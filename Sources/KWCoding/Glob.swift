import Foundation

public enum Glob {

    /// Match a path against a glob pattern supporting `*`, `?`, and `**`.
    public static func matches(path: String, pattern: String) -> Bool {
        let regex = patternToRegex(pattern)
        return path.range(of: regex, options: .regularExpression) != nil
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
            } else if "().+|^$\\{}".contains(ch) {
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
    public static func expand(root: String, pattern: String, limit: Int? = nil) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var results: [String] = []
        let prefix = root.hasSuffix("/") ? root.count : root.count + 1
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            var relative = url.path
            if relative.count > prefix { relative = String(relative.dropFirst(prefix)) }
            if matches(path: relative, pattern: pattern) {
                results.append(url.path)
                if let limit, results.count >= limit { break }
            }
        }
        return results
    }
}
