import Foundation
import KWWKAgent

/// A user-authored prompt-template slash command, discovered from
/// `.kwwk/commands/*.md` (project) and `~/.kwwk/commands/*.md` (user). Mirrors
/// pi's `prompt-templates.ts` + `slash-commands.ts`: the markdown body is the
/// template, optional YAML frontmatter provides a `description`, and invoking
/// the command substitutes the caller's argument string into the body before
/// it's submitted to the LLM as an ordinary prompt.
///
/// Substitution grammar (matches pi):
///   - `$1`, `$2`, … positional args (1-based; missing → empty string)
///   - `$@` / `$ARGUMENTS` all args joined by a single space
///   - `${@:N}` args from the N-th (1-based) to the end, space-joined
///   - `${@:N:L}` up to `L` args starting at the N-th, space-joined
struct PromptTemplateCommand: Equatable {
    let name: String
    let description: String
    /// Raw template body (frontmatter stripped).
    let body: String

    /// Render the template against a raw argument string. The string is split
    /// shell-style (single/double quotes group, whitespace separates) before
    /// substitution.
    func render(args: String) -> String {
        PromptTemplate.substitute(body, args: PromptTemplate.parseArgs(args))
    }
}

/// Pure parsing/substitution helpers, factored out so they're trivially unit
/// testable without touching the filesystem or the MainActor.
enum PromptTemplate {

    /// Split an argument string into tokens, honoring `'`/`"` quoting. Quote
    /// characters group whitespace but are themselves dropped from the token.
    static func parseArgs(_ argsString: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuote: Character? = nil
        var produced = false

        for char in argsString {
            if let q = inQuote {
                if char == q {
                    inQuote = nil
                } else {
                    current.append(char)
                    produced = true
                }
            } else if char == "\"" || char == "'" {
                inQuote = char
                // A bare "" / '' still produces an (empty) token.
                produced = true
            } else if char == " " || char == "\t" {
                if produced {
                    args.append(current)
                    current = ""
                    produced = false
                }
            } else {
                current.append(char)
                produced = true
            }
        }
        if produced { args.append(current) }
        return args
    }

    /// Substitute `$1`/`$@`/`$ARGUMENTS`/`${@:N}`/`${@:N:L}` placeholders.
    static func substitute(_ content: String, args: [String]) -> String {
        var result = content

        // `${@:N}` and `${@:N:L}` — handle the slice form before the bare
        // numeric `$1` form so the `{...}` syntax isn't half-consumed.
        result = replace(in: result, pattern: #"\$\{@:(\d+)(?::(\d+))?\}"#) { groups in
            guard let start1 = Int(groups[1]) else { return "" }
            let start = max(0, start1 - 1)
            if start >= args.count { return "" }
            if groups.count > 2, !groups[2].isEmpty, let len = Int(groups[2]) {
                let end = min(args.count, start + max(0, len))
                return args[start..<end].joined(separator: " ")
            }
            return args[start...].joined(separator: " ")
        }

        // `$1`, `$2`, …
        result = replace(in: result, pattern: #"\$(\d+)"#) { groups in
            guard let n = Int(groups[1]), n >= 1, n <= args.count else { return "" }
            return args[n - 1]
        }

        // `$@` and `$ARGUMENTS` — all args, space-joined.
        let all = args.joined(separator: " ")
        result = result.replacingOccurrences(of: "$ARGUMENTS", with: all)
        result = result.replacingOccurrences(of: "$@", with: all)
        return result
    }

    /// Regex replace where the closure receives capture groups (index 0 is the
    /// whole match). Missing optional groups are passed as empty strings.
    private static func replace(
        in input: String,
        pattern: String,
        _ transform: ([String]) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var out = input
        // Replace right-to-left so earlier ranges stay valid.
        for match in matches.reversed() {
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            let replacement = transform(groups)
            let mutable = out as NSString
            out = mutable.replacingCharacters(in: match.range, with: replacement)
        }
        return out
    }

    // MARK: - Frontmatter

    /// Split optional leading YAML frontmatter (a `---` fenced block) from the
    /// markdown body. We only need the `description:` line, so this is a minimal
    /// key/value reader rather than a full YAML parser. Returns the parsed
    /// `description` (if any) and the trimmed body.
    static func splitFrontmatter(_ raw: String) -> (description: String?, body: String) {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.hasPrefix("---") else {
            return (nil, normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Find the closing fence: a line that is exactly `---` after the opener.
        let afterOpener = normalized.dropFirst(3)
        guard let closeRange = afterOpener.range(of: "\n---") else {
            return (nil, normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let yaml = String(afterOpener[afterOpener.startIndex..<closeRange.lowerBound])
        // Body starts after the closing `---` line.
        var body = String(afterOpener[closeRange.upperBound...])
        if body.hasPrefix("---") { body.removeFirst(3) }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        var description: String?
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("description:") else { continue }
            var value = String(trimmed.dropFirst("description:".count))
                .trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }
            description = value
            break
        }
        return (description, body)
    }

    /// Build a `PromptTemplateCommand` from a file's raw content. The command
    /// name is the file's basename without the `.md` extension. When no
    /// frontmatter `description` is present, the first non-empty body line is
    /// used (truncated), matching pi.
    static func makeCommand(name: String, rawContent: String) -> PromptTemplateCommand {
        let (descFromFm, body) = splitFrontmatter(rawContent)
        var description = descFromFm ?? ""
        if description.isEmpty {
            if let first = body.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) {
                description = first.count > 60 ? String(first.prefix(60)) + "..." : first
            }
        }
        return PromptTemplateCommand(name: name, description: description, body: body)
    }
}

/// Filesystem discovery of prompt-template commands.
enum CustomSlashCommandLoader {

    /// Discover commands from project (`<cwd>/.kwwk/commands`) and user
    /// (`~/.kwwk/commands`) directories. Project entries win on name collisions
    /// (loaded last). Non-`.md` files and unreadable files are skipped.
    static func discover(cwd: String) -> [PromptTemplateCommand] {
        var byName: [String: PromptTemplateCommand] = [:]
        // User dir first, project dir second so project overrides user.
        let userDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kwwk/commands")
        let projectDir = (cwd as NSString).appendingPathComponent(".kwwk/commands")
        for dir in [userDir, projectDir] {
            for cmd in loadFromDirectory(dir) {
                byName[cmd.name] = cmd
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// Discover prompt-template commands for `cwd` and register each one on
    /// `registry` as a `SlashCommand`. The handler renders the template against
    /// the invocation args and submits the result to the agent as an ordinary
    /// user prompt. Builtin commands are registered first by the caller, so a
    /// custom command with a builtin's name is skipped to avoid shadowing core
    /// behavior (e.g. a stray `model.md` can't hijack `/model`).
    @MainActor
    @discardableResult
    static func register(
        into registry: SlashCommandRegistry,
        cwd: String,
        commands: [PromptTemplateCommand]? = nil
    ) -> [PromptTemplateCommand] {
        let discovered = commands ?? discover(cwd: cwd)
        var registered: [PromptTemplateCommand] = []
        for cmd in discovered {
            if registry.find(cmd.name) != nil { continue }
            let template = cmd
            registry.register(SlashCommand(
                name: cmd.name,
                description: cmd.description.isEmpty
                    ? "Custom prompt command"
                    : cmd.description,
                handler: { ctx, args in
                    let rendered = template.render(args: args)
                    let agent = ctx.agent
                    Task.detached {
                        try? await agent.prompt(rendered)
                    }
                }
            ))
            registered.append(cmd)
        }
        return registered
    }

    /// Load `.md` prompt templates from a single directory (non-recursive).
    static func loadFromDirectory(_ dir: String) -> [PromptTemplateCommand] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [PromptTemplateCommand] = []
        for entry in entries.sorted() {
            guard entry.lowercased().hasSuffix(".md") else { continue }
            let path = (dir as NSString).appendingPathComponent(entry)
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let name = String(entry.dropLast(3)) // strip ".md"
            guard !name.isEmpty else { continue }
            out.append(PromptTemplate.makeCommand(name: name, rawContent: raw))
        }
        return out
    }
}
