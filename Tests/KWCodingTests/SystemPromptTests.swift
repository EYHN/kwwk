import Foundation
import Testing
@testable import KWCoding

@Suite("System prompt")
struct SystemPromptTests {
    @Test("default prompt lists tools that have snippets and applies cwd + date")
    func defaultPrompt() {
        let prompt = buildSystemPrompt(SystemPromptOptions(
            cwd: "/tmp/project",
            selectedToolNames: ["read", "bash"],
            toolSnippets: [
                "read": "Read file contents",
                "bash": "Execute shell commands",
            ],
            date: "2024-06-15"
        ))
        #expect(prompt.contains("Available tools:"))
        #expect(prompt.contains("- read: Read file contents"))
        #expect(prompt.contains("- bash: Execute shell commands"))
        #expect(prompt.contains("Current date: 2024-06-15"))
        #expect(prompt.contains("Current working directory: /tmp/project"))
    }

    @Test("omits tools without snippets and falls back to '(none)'")
    func hiddenTools() {
        let prompt = buildSystemPrompt(SystemPromptOptions(
            cwd: "/tmp",
            selectedToolNames: ["read"],
            toolSnippets: [:]
        ))
        #expect(prompt.contains("(none)"))
    }

    @Test("prefers grep/find/ls over bash when all are present")
    func preferenceGuideline() {
        let prompt = buildSystemPrompt(SystemPromptOptions(
            cwd: "/tmp",
            selectedToolNames: ["bash", "grep", "find", "ls", "read", "write", "edit"],
            toolSnippets: DefaultToolSnippets.all
        ))
        #expect(prompt.contains("Prefer grep/find/ls tools over bash for file exploration"))
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
            selectedToolNames: ["read"],
            toolSnippets: ["read": "Read file contents"],
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
