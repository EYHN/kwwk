import Foundation

public struct SystemPromptOptions: Sendable {
    public var cwd: String
    public var customPrompt: String?
    public var promptGuidelines: [String]
    public var appendSystemPrompt: String?
    public var contextFiles: [(path: String, content: String)]
    public var skills: [String]
    public var date: String?

    public init(
        cwd: String,
        customPrompt: String? = nil,
        promptGuidelines: [String] = [],
        appendSystemPrompt: String? = nil,
        contextFiles: [(path: String, content: String)] = [],
        skills: [String] = [],
        date: String? = nil
    ) {
        self.cwd = cwd
        self.customPrompt = customPrompt
        self.promptGuidelines = promptGuidelines
        self.appendSystemPrompt = appendSystemPrompt
        self.contextFiles = contextFiles
        self.skills = skills
        self.date = date
    }
}

public func buildSystemPrompt(_ options: SystemPromptOptions) -> String {
    var guidelines: [String] = []
    var seenGuidelines: Set<String> = []
    func add(_ g: String) {
        let trimmed = g.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seenGuidelines.contains(trimmed) else { return }
        seenGuidelines.insert(trimmed)
        guidelines.append(trimmed)
    }

    for g in options.promptGuidelines { add(g) }
    add("Be concise in your responses")
    add("Show file paths clearly when working with files")

    let date: String = options.date ?? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        return df.string(from: Date())
    }()
    let normalizedCwd = options.cwd.replacingOccurrences(of: "\\", with: "/")
    let appendSection = options.appendSystemPrompt.flatMap {
        $0.isEmpty ? nil : "\n\n\($0)"
    } ?? ""

    if let custom = options.customPrompt {
        var prompt = custom + appendSection
        if !options.contextFiles.isEmpty {
            prompt += "\n\n# Project Context\n\nProject-specific instructions and guidelines:\n\n"
            for file in options.contextFiles {
                prompt += "## \(file.path)\n\n\(file.content)\n\n"
            }
        }
        if !options.skills.isEmpty {
            prompt += formatSkills(options.skills)
        }
        prompt += "\nCurrent date: \(date)\nCurrent working directory: \(normalizedCwd)"
        return prompt
    }

    let guidelinesText = guidelines.map { "- \($0)" }.joined(separator: "\n")
    var prompt = """
    You are an expert coding assistant operating inside kwwk, a coding agent harness. Help users by reading files, running commands, editing code, and writing new files.

    Guidelines:
    \(guidelinesText)
    """
    prompt += appendSection
    if !options.contextFiles.isEmpty {
        prompt += "\n\n# Project Context\n\nProject-specific instructions and guidelines:\n\n"
        for file in options.contextFiles {
            prompt += "## \(file.path)\n\n\(file.content)\n\n"
        }
    }
    if !options.skills.isEmpty {
        prompt += formatSkills(options.skills)
    }
    prompt += "\nCurrent date: \(date)\nCurrent working directory: \(normalizedCwd)"
    return prompt
}

private func formatSkills(_ skills: [String]) -> String {
    if skills.isEmpty { return "" }
    var out = "\n\n# Skills\n\n"
    for skill in skills { out += "- \(skill)\n" }
    return out
}
