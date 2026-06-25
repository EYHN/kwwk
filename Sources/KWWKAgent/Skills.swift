import Foundation

/// A discovered skill: a `SKILL.md` (or root-level `.md`) file with YAML-ish
/// frontmatter exposing a `name` and `description`. The full `body` is loaded
/// up front but is only injected into the model context on demand — the
/// `<available_skills>` block exposes name+description only (progressive
/// disclosure); the model reads the skill file via the read tool when a task
/// matches.
///
/// Mirrors pi's `Skill` type (packages/agent/src/harness/skills.ts +
/// packages/coding-agent/src/core/skills.ts).
public struct Skill: Sendable, Equatable {
    /// Skill identifier. Defaults to the parent directory name when the
    /// frontmatter omits `name`.
    public var name: String
    /// One-line description used for progressive disclosure.
    public var description: String
    /// Absolute path to the `SKILL.md` file.
    public var path: String
    /// Markdown body after the frontmatter block.
    public var body: String
    /// When true the skill is hidden from `<available_skills>` and can only be
    /// invoked explicitly (e.g. via a `/skill:<name>` hook).
    public var disableModelInvocation: Bool

    public init(
        name: String,
        description: String,
        path: String,
        body: String,
        disableModelInvocation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.path = path
        self.body = body
        self.disableModelInvocation = disableModelInvocation
    }
}

/// A non-fatal warning emitted while loading skills (missing description,
/// invalid name, parse failure, …). Loading never throws; bad skills are
/// skipped and surfaced here.
public struct SkillDiagnostic: Sendable, Equatable {
    public enum Code: String, Sendable {
        case readFailed = "read_failed"
        case parseFailed = "parse_failed"
        case invalidMetadata = "invalid_metadata"
    }
    public var code: Code
    public var message: String
    public var path: String

    public init(code: Code, message: String, path: String) {
        self.code = code
        self.message = message
        self.path = path
    }
}

/// Minimal gitignore-style matcher: ordered rules, last match wins, `!`
/// negation, dir-only patterns end in `/`. Ports pi's use of the `ignore` npm
/// package over the subset of patterns skill authors actually use
/// (`name`, `dir/`, `*.ext`, `**/x`, `!negate`). A `final class` so the same
/// instance threads through recursion exactly like pi's shared matcher object.
final class IgnoreMatcher {
    private struct Rule {
        let regex: NSRegularExpression
        let negated: Bool
        let dirOnly: Bool
    }
    private var rules: [Rule] = []

    /// Add raw gitignore patterns (already prefix-adjusted). Each becomes one
    /// ordered rule; invalid patterns are skipped.
    func add(_ patterns: [String]) {
        for raw in patterns {
            var pattern = raw
            var negated = false
            if pattern.hasPrefix("!") {
                negated = true
                pattern.removeFirst()
            }
            var dirOnly = false
            if pattern.hasSuffix("/") {
                dirOnly = true
                pattern.removeLast()
            }
            guard !pattern.isEmpty else { continue }
            guard let regex = IgnoreMatcher.compile(pattern) else { continue }
            rules.append(Rule(regex: regex, negated: negated, dirOnly: dirOnly))
        }
    }

    /// Whether `relPath` (POSIX, relative to the root dir) is ignored. Dir
    /// queries pass a trailing `/`. Later rules override earlier ones.
    func ignores(_ relPath: String) -> Bool {
        let isDir = relPath.hasSuffix("/")
        let path = isDir ? String(relPath.dropLast()) : relPath
        var matched = false
        for rule in rules {
            // A dir-only rule matches the directory itself and everything under
            // it. For a non-dir query, test the path's ancestor segments too so
            // a re-included directory (`!keep/`) also re-includes its contents
            // (gitignore parity).
            let target: String
            if rule.dirOnly {
                if isDir {
                    target = path
                } else if let slash = path.lastIndex(of: "/") {
                    target = String(path[..<slash])     // parent dir of a file
                } else {
                    continue                              // top-level file, no dir match
                }
            } else {
                target = path
            }
            let ns = target as NSString
            if rule.regex.firstMatch(in: target, range: NSRange(location: 0, length: ns.length)) != nil {
                matched = !rule.negated
            }
        }
        return matched
    }

    /// Translate a gitignore glob into an anchored regex. Supports `*` (not
    /// crossing `/`), `**` (crossing `/`), `?`, leading-`/` anchoring vs.
    /// floating (a pattern without a slash matches at any depth).
    private static func compile(_ pattern: String) -> NSRegularExpression? {
        var p = pattern
        // A leading slash anchors to the root; otherwise the pattern floats.
        let anchored = p.hasPrefix("/")
        if anchored { p.removeFirst() }
        // gitignore: a pattern containing a (non-trailing) slash is anchored to
        // root; a pattern with no slash matches at any depth.
        let hasInnerSlash = p.contains("/")

        var regex = ""
        let chars = Array(p)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    // `**` — match across path separators.
                    // Consume a following `/` so `**/x` also matches `x`.
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        regex += "(?:.*/)?"
                        i += 3
                    } else {
                        regex += ".*"
                        i += 2
                    }
                    continue
                }
                regex += "[^/]*"
                i += 1
            case "?":
                regex += "[^/]"
                i += 1
            default:
                regex += NSRegularExpression.escapedPattern(for: String(c))
                i += 1
            }
        }

        // Build the full anchored pattern.
        let prefix: String
        if anchored || hasInnerSlash {
            prefix = "^"
        } else {
            // Floating: match at any depth.
            prefix = "^(?:.*/)?"
        }
        // Allow matching a directory and everything beneath it.
        let suffix = "(?:/.*)?$"
        return try? NSRegularExpression(pattern: prefix + regex + suffix)
    }

    // MARK: - pi ports

    /// Names of ignore files honored during discovery (pi `IGNORE_FILE_NAMES`).
    static let ignoreFileNames = [".gitignore", ".ignore", ".fdignore"]

    /// Port of pi's `prefixIgnorePattern`: trim, drop comments/empties, handle
    /// `!`/`\!` and `\#`, strip a leading `/`, then prepend `prefix` (the dir's
    /// path relative to the root, with a trailing `/`). Returns nil to drop.
    static func prefixIgnorePattern(_ line: String, prefix: String) -> String? {
        var pattern = line.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty { return nil }
        // Comment unless it starts with `\#`.
        if pattern.hasPrefix("#") { return nil }
        if pattern.hasPrefix("\\#") { pattern.removeFirst() }  // literal '#'

        var negated = false
        if pattern.hasPrefix("!") {
            negated = true
            pattern.removeFirst()
        } else if pattern.hasPrefix("\\!") {
            pattern.removeFirst()                              // literal '!'
        }

        if pattern.hasPrefix("/") { pattern.removeFirst() }    // anchor to dir root

        pattern = prefix + pattern
        return negated ? "!" + pattern : pattern
    }

    /// Read the ignore files in `dir` and add their rules to `matcher`.
    static func addIgnoreRules(into matcher: IgnoreMatcher, dir: String, rootDir: String) {
        let prefix = Skills.ignoreRelativePath(rootDir, dir)
        for name in ignoreFileNames {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let normalized = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let patterns = normalized
                .split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { prefixIgnorePattern(String($0), prefix: prefix) }
            matcher.add(patterns)
        }
    }
}

public enum Skills {
    private static let maxNameLength = 64
    private static let maxDescriptionLength = 1024

    /// Path of `path` relative to `root`, with a trailing `/` for non-root dirs.
    /// Ports pi's `relativeEnvPath` (equal → "", has-prefix → suffix+"/",
    /// else strip leading "/"). Returns "" for the root itself.
    static func ignoreRelativePath(_ root: String, _ path: String) -> String {
        if path == root { return "" }
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(rootWithSlash) {
            return String(path.dropFirst(rootWithSlash.count)) + "/"
        }
        var p = path
        if p.hasPrefix("/") { p.removeFirst() }
        return p + "/"
    }

    /// Default skill directories, in precedence order: project-local `.kwwk`,
    /// the user-global `~/.kwwk`, and a `.claude/skills` directory if the
    /// project uses one. Missing directories are skipped.
    public static func defaultDirectories(cwd: String) -> [String] {
        let cwdNS = cwd as NSString
        var dirs: [String] = [
            cwdNS.appendingPathComponent(".kwwk/skills"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".kwwk/skills"),
            cwdNS.appendingPathComponent(".claude/skills"),
        ]
        // De-dup while preserving order (e.g. cwd == home edge case).
        var seen: Set<String> = []
        dirs = dirs.filter { seen.insert($0).inserted }
        return dirs
    }

    /// Discover skills from the default directories for `cwd`.
    public static func discover(cwd: String) -> (skills: [Skill], diagnostics: [SkillDiagnostic]) {
        load(directories: defaultDirectories(cwd: cwd))
    }

    /// Load skills from the given directories. Each directory is walked
    /// recursively for `SKILL.md` files; root-level `.md` files are also loaded
    /// as skills. Missing directories are skipped silently. Duplicate skill
    /// names keep the first occurrence (earlier directories win).
    public static func load(directories: [String]) -> (skills: [Skill], diagnostics: [SkillDiagnostic]) {
        var skills: [Skill] = []
        var diagnostics: [SkillDiagnostic] = []
        var seenNames: Set<String> = []
        let fm = FileManager.default

        for dir in directories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            // Fresh matcher per root dir; rootDir == dir so prefixes are
            // relative to each root (pi parity).
            let result = loadFromDirectory(
                dir,
                includeRootFiles: true,
                ignore: IgnoreMatcher(),
                rootDir: dir
            )
            for skill in result.skills where seenNames.insert(skill.name).inserted {
                skills.append(skill)
            }
            diagnostics.append(contentsOf: result.diagnostics)
        }
        return (skills, diagnostics)
    }

    private static func loadFromDirectory(
        _ dir: String,
        includeRootFiles: Bool,
        ignore: IgnoreMatcher,
        rootDir: String
    ) -> (skills: [Skill], diagnostics: [SkillDiagnostic]) {
        var skills: [Skill] = []
        var diagnostics: [SkillDiagnostic] = []
        let fm = FileManager.default

        // Add this dir's ignore files before considering its entries.
        IgnoreMatcher.addIgnoreRules(into: ignore, dir: dir, rootDir: rootDir)

        guard let entries = try? fm.contentsOfDirectory(atPath: dir).sorted() else {
            return (skills, diagnostics)
        }

        // A directory containing a non-ignored SKILL.md is itself a skill; don't
        // descend further. If SKILL.md is ignored, fall through to the general
        // loop (pi parity).
        if entries.contains("SKILL.md") {
            let full = (dir as NSString).appendingPathComponent("SKILL.md")
            let rel = ignoreRelativePath(rootDir, dir) + "SKILL.md"
            if !ignore.ignores(rel) {
                let r = loadFromFile(full)
                if let s = r.skill { skills.append(s) }
                diagnostics.append(contentsOf: r.diagnostics)
                return (skills, diagnostics)
            }
        }

        for entry in entries {
            if entry.hasPrefix(".") || entry == "node_modules" { continue }
            let full = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }

            let baseRel = ignoreRelativePath(rootDir, dir) + entry
            let ignorePath = isDir.boolValue ? baseRel + "/" : baseRel
            if ignore.ignores(ignorePath) { continue }

            if isDir.boolValue {
                let r = loadFromDirectory(
                    full,
                    includeRootFiles: false,
                    ignore: ignore,
                    rootDir: rootDir
                )
                skills.append(contentsOf: r.skills)
                diagnostics.append(contentsOf: r.diagnostics)
            } else if includeRootFiles && entry.hasSuffix(".md") {
                let r = loadFromFile(full)
                if let s = r.skill { skills.append(s) }
                diagnostics.append(contentsOf: r.diagnostics)
            }
        }
        return (skills, diagnostics)
    }

    private static func loadFromFile(
        _ path: String
    ) -> (skill: Skill?, diagnostics: [SkillDiagnostic]) {
        var diagnostics: [SkillDiagnostic] = []
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            diagnostics.append(.init(code: .readFailed, message: "failed to read skill file", path: path))
            return (nil, diagnostics)
        }

        let (frontmatter, body) = parseFrontmatter(raw)
        let parentDirName = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let description = frontmatter["description"]
        let name = frontmatter["name"].flatMap { $0.isEmpty ? nil : $0 } ?? parentDirName

        for error in validateDescription(description) {
            diagnostics.append(.init(code: .invalidMetadata, message: error, path: path))
        }
        for error in validateName(name, parentDirName: parentDirName) {
            diagnostics.append(.init(code: .invalidMetadata, message: error, path: path))
        }

        guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, diagnostics)
        }

        let disable = (frontmatter["disable-model-invocation"]?.lowercased() == "true")
        let skill = Skill(
            name: name,
            description: description,
            path: path,
            body: body,
            disableModelInvocation: disable
        )
        return (skill, diagnostics)
    }

    private static func validateName(_ name: String, parentDirName: String) -> [String] {
        var errors: [String] = []
        if name != parentDirName {
            errors.append("name \"\(name)\" does not match parent directory \"\(parentDirName)\"")
        }
        if name.count > maxNameLength {
            errors.append("name exceeds \(maxNameLength) characters (\(name.count))")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            errors.append("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)")
        }
        if name.hasPrefix("-") || name.hasSuffix("-") {
            errors.append("name must not start or end with a hyphen")
        }
        if name.contains("--") {
            errors.append("name must not contain consecutive hyphens")
        }
        return errors
    }

    private static func validateDescription(_ description: String?) -> [String] {
        guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["description is required"]
        }
        if description.count > maxDescriptionLength {
            return ["description exceeds \(maxDescriptionLength) characters (\(description.count))"]
        }
        return []
    }

    /// Parse a YAML-ish frontmatter block delimited by leading/trailing `---`
    /// lines. Only flat `key: value` pairs are recognized (sufficient for skill
    /// metadata). Returns the parsed pairs and the trimmed body. When no
    /// frontmatter is present the whole content is the body.
    static func parseFrontmatter(_ content: String) -> (frontmatter: [String: String], body: String) {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.hasPrefix("---") else {
            return ([:], normalized)
        }
        // Find the closing "\n---" after the opening fence.
        guard let endRange = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 3)..<normalized.endIndex) else {
            return ([:], normalized)
        }
        let yamlStart = normalized.index(normalized.startIndex, offsetBy: 4)
        let yamlString = String(normalized[yamlStart..<endRange.lowerBound])
        // Body starts after the closing "---" line.
        var bodyStart = endRange.upperBound
        // Skip the rest of the closing fence line.
        if let nl = normalized[bodyStart...].firstIndex(of: "\n") {
            bodyStart = normalized.index(after: nl)
        } else {
            bodyStart = normalized.endIndex
        }
        let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        var frontmatter: [String: String] = [:]
        for rawLine in yamlString.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = unquote(value)
            frontmatter[key] = value
        }
        return (frontmatter, body)
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2 {
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                return String(value.dropFirst().dropLast())
            }
        }
        return value
    }

    /// Build the `<available_skills>` XML block exposing only name +
    /// description + location for each visible skill (progressive disclosure).
    /// Skills with `disableModelInvocation == true` are omitted. Returns an
    /// empty string when there are no visible skills.
    public static func availableSkillsBlock(_ skills: [Skill]) -> String {
        let visible = skills.filter { !$0.disableModelInvocation }
        guard !visible.isEmpty else { return "" }

        var lines: [String] = [
            "The following skills provide specialized instructions for specific tasks.",
            "Read the full skill file when the task matches its description.",
            "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
            "",
            "<available_skills>",
        ]
        for skill in visible {
            lines.append("  <skill>")
            lines.append("    <name>\(escapeXml(skill.name))</name>")
            lines.append("    <description>\(escapeXml(skill.description))</description>")
            lines.append("    <location>\(escapeXml(skill.path))</location>")
            lines.append("  </skill>")
        }
        lines.append("</available_skills>")
        return lines.joined(separator: "\n")
    }

    private static func escapeXml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
