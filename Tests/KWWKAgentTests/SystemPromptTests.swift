import Foundation
import Testing
@testable import KWWKAgent

@Suite("System prompt")
struct SystemPromptTests {
    @Test("default prompt applies identity, guidelines, cwd, and date")
    func defaultPrompt() {
        let prompt = buildSystemPrompt(SystemPromptOptions(
            cwd: "/tmp/project",
            date: "2024-06-15"
        ))
        #expect(prompt.contains("operating inside kwwk"))
        #expect(!prompt.contains("Available tools:"))
        #expect(!prompt.contains("- read: Read file contents"))
        #expect(!prompt.contains("- bash: Execute shell commands"))
        #expect(prompt.contains("Current date: 2024-06-15"))
        #expect(prompt.contains("Current working directory: /tmp/project"))
    }

    @Test("does not render a synthetic tool list")
    func hiddenTools() {
        let prompt = buildSystemPrompt(SystemPromptOptions(cwd: "/tmp"))
        #expect(!prompt.contains("(none)"))
        #expect(!prompt.contains("Available tools:"))
    }

    @Test("customPrompt replaces the default body and keeps metadata")
    func customPrompt() {
        let prompt = buildSystemPrompt(SystemPromptOptions(
            cwd: "/a",
            customPrompt: "You are a custom assistant.",
            appendSystemPrompt: "Follow extra rules.",
            date: "2024-01-01"
        ))
        #expect(prompt.hasPrefix("You are a custom assistant."))
        #expect(prompt.contains("Follow extra rules."))
        #expect(prompt.contains("Current date: 2024-01-01"))
        #expect(prompt.contains("Current working directory: /a"))
    }

    @Test("context files are injected with their paths as headers")
    func contextFiles() {
        let prompt = buildSystemPrompt(SystemPromptOptions(
            cwd: "/a",
            contextFiles: [
                (path: "CLAUDE.md", content: "be helpful"),
                (path: "AGENTS.md", content: "use tools"),
            ]
        ))
        #expect(prompt.contains("# Project Context"))
        #expect(prompt.contains("## CLAUDE.md"))
        #expect(prompt.contains("be helpful"))
        #expect(prompt.contains("## AGENTS.md"))
    }
}
