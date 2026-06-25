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

public enum Skills {
    private static let maxNameLength = 64
    private static let maxDescriptionLength = 1024

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
            let result = loadFromDirectory(dir, includeRootFiles: true)
            for skill in result.skills where seenNames.insert(skill.name).inserted {
                skills.append(skill)
            }
            diagnostics.append(contentsOf: result.diagnostics)
        }
        return (skills, diagnostics)
    }

    private static func loadFromDirectory(
        _ dir: String,
        includeRootFiles: Bool
    ) -> (skills: [Skill], diagnostics: [SkillDiagnostic]) {
        var skills: [Skill] = []
        var diagnostics: [SkillDiagnostic] = []
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(atPath: dir).sorted() else {
            return (skills, diagnostics)
        }

        // A directory containing SKILL.md is itself a skill; don't descend further.
        if entries.contains("SKILL.md") {
            let full = (dir as NSString).appendingPathComponent("SKILL.md")
            let r = loadFromFile(full)
            if let s = r.skill { skills.append(s) }
            diagnostics.append(contentsOf: r.diagnostics)
            return (skills, diagnostics)
        }

        for entry in entries {
            if entry.hasPrefix(".") || entry == "node_modules" { continue }
            let full = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let r = loadFromDirectory(full, includeRootFiles: false)
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
