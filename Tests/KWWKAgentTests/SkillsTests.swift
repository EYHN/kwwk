import Foundation
import Testing
@testable import KWWKAgent

@Suite("Skills")
struct SkillsTests {
    /// Create an isolated temp directory; caller is responsible for nothing —
    /// the OS reclaims temp space, and tests write under a unique subdir.
    private func makeTempDir() -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("kwwk-skills-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("frontmatter parse extracts flat key/value pairs and trims body")
    func frontmatterParse() {
        let content = """
        ---
        name: my-skill
        description: "Does a thing"
        disable-model-invocation: false
        ---

        # Body heading

        Body text.
        """
        let (fm, body) = Skills.parseFrontmatter(content)
        #expect(fm["name"] == "my-skill")
        #expect(fm["description"] == "Does a thing")
        #expect(fm["disable-model-invocation"] == "false")
        #expect(body.hasPrefix("# Body heading"))
        #expect(body.hasSuffix("Body text."))
    }

    @Test("frontmatter parse with no fence returns whole content as body")
    func frontmatterNoFence() {
        let (fm, body) = Skills.parseFrontmatter("just a body\nmore")
        #expect(fm.isEmpty)
        #expect(body == "just a body\nmore")
    }

    @Test("discovery loads a SKILL.md from a skills directory")
    func discoverSkill() {
        let root = makeTempDir()
        let skillDir = (root as NSString).appendingPathComponent("greeter")
        let skillPath = (skillDir as NSString).appendingPathComponent("SKILL.md")
        write("""
        ---
        name: greeter
        description: Greets people warmly
        ---
        Say hello.
        """, to: skillPath)

        let (skills, diagnostics) = Skills.load(directories: [root])
        #expect(skills.count == 1)
        #expect(skills.first?.name == "greeter")
        #expect(skills.first?.description == "Greets people warmly")
        #expect(skills.first?.path == skillPath)
        #expect(skills.first?.body == "Say hello.")
        #expect(diagnostics.isEmpty)
    }

    @Test("name defaults to parent directory when frontmatter omits it")
    func nameDefaultsToParentDir() {
        let root = makeTempDir()
        let skillPath = (((root as NSString).appendingPathComponent("formatter")) as NSString)
            .appendingPathComponent("SKILL.md")
        write("""
        ---
        description: Formats code
        ---
        body
        """, to: skillPath)

        let (skills, _) = Skills.load(directories: [root])
        #expect(skills.first?.name == "formatter")
    }

    @Test("skill missing a description is skipped with a diagnostic")
    func missingDescriptionSkipped() {
        let root = makeTempDir()
        let skillPath = (((root as NSString).appendingPathComponent("broken")) as NSString)
            .appendingPathComponent("SKILL.md")
        write("""
        ---
        name: broken
        ---
        body
        """, to: skillPath)

        let (skills, diagnostics) = Skills.load(directories: [root])
        #expect(skills.isEmpty)
        #expect(diagnostics.contains { $0.code == .invalidMetadata })
    }

    @Test("missing directories are skipped silently")
    func missingDirectorySkipped() {
        let (skills, diagnostics) = Skills.load(directories: ["/no/such/dir/kwwk-test"])
        #expect(skills.isEmpty)
        #expect(diagnostics.isEmpty)
    }

    @Test("available_skills block exposes name and description, not body")
    func availableSkillsBlock() {
        let skills = [
            Skill(name: "greeter", description: "Greets people", path: "/s/greeter/SKILL.md", body: "SECRET BODY"),
            Skill(name: "hidden", description: "Hidden one", path: "/s/hidden/SKILL.md", body: "x", disableModelInvocation: true),
        ]
        let block = Skills.availableSkillsBlock(skills)
        #expect(block.contains("<available_skills>"))
        #expect(block.contains("</available_skills>"))
        #expect(block.contains("<name>greeter</name>"))
        #expect(block.contains("<description>Greets people</description>"))
        #expect(block.contains("<location>/s/greeter/SKILL.md</location>"))
        // Progressive disclosure: body must not appear.
        #expect(!block.contains("SECRET BODY"))
        // disableModelInvocation skills are excluded.
        #expect(!block.contains("hidden"))
    }

    @Test("available_skills block is empty when no visible skills")
    func emptyBlock() {
        #expect(Skills.availableSkillsBlock([]).isEmpty)
        let onlyHidden = [Skill(name: "h", description: "d", path: "/p", body: "b", disableModelInvocation: true)]
        #expect(Skills.availableSkillsBlock(onlyHidden).isEmpty)
    }

    @Test("available_skills XML escapes special characters")
    func xmlEscaping() {
        let skills = [Skill(name: "a-b", description: "uses <tag> & \"quotes\"", path: "/p", body: "")]
        let block = Skills.availableSkillsBlock(skills)
        #expect(block.contains("&lt;tag&gt;"))
        #expect(block.contains("&amp;"))
        #expect(block.contains("&quot;"))
    }

    @Test("system prompt injects available_skills block when skills exist")
    func systemPromptInjection() {
        let prompt = buildSystemPrompt(SystemPromptOptions(
            cwd: "/tmp/project",
            availableSkills: [Skill(name: "greeter", description: "Greets", path: "/s/SKILL.md", body: "b")],
            date: "2024-06-15"
        ))
        #expect(prompt.contains("<available_skills>"))
        #expect(prompt.contains("<name>greeter</name>"))
    }
}
