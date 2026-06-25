import Foundation
import Testing
@testable import KWWKCli

@Suite("PromptTemplate argument substitution")
struct PromptTemplateSubstitutionTests {

    @Test("positional $1/$2 substitution")
    func positional() {
        let args = PromptTemplate.parseArgs("alpha beta")
        let out = PromptTemplate.substitute("first=$1 second=$2", args: args)
        #expect(out == "first=alpha second=beta")
    }

    @Test("missing positional arg becomes empty string")
    func missingPositional() {
        let args = PromptTemplate.parseArgs("only")
        let out = PromptTemplate.substitute("a=$1 b=$2", args: args)
        #expect(out == "a=only b=")
    }

    @Test("$@ and $ARGUMENTS expand to all args space-joined")
    func allArgs() {
        let args = PromptTemplate.parseArgs("one two three")
        #expect(PromptTemplate.substitute("[$@]", args: args) == "[one two three]")
        #expect(PromptTemplate.substitute("[$ARGUMENTS]", args: args) == "[one two three]")
    }

    @Test("${@:N} slice from N to end")
    func sliceToEnd() {
        let args = PromptTemplate.parseArgs("a b c d")
        let out = PromptTemplate.substitute("rest=${@:2}", args: args)
        #expect(out == "rest=b c d")
    }

    @Test("${@:N:L} slice with length")
    func sliceWithLength() {
        let args = PromptTemplate.parseArgs("a b c d e")
        let out = PromptTemplate.substitute("mid=${@:2:2}", args: args)
        #expect(out == "mid=b c")
    }

    @Test("slice past the end yields empty")
    func sliceOutOfRange() {
        let args = PromptTemplate.parseArgs("a b")
        #expect(PromptTemplate.substitute("x=${@:5}", args: args) == "x=")
    }

    @Test("quoted args group whitespace")
    func quotedArgs() {
        let args = PromptTemplate.parseArgs(#"  "hello world"  'foo bar' baz "#)
        #expect(args == ["hello world", "foo bar", "baz"])
    }

    @Test("end-to-end render via PromptTemplateCommand")
    func renderCommand() {
        let cmd = PromptTemplateCommand(
            name: "review",
            description: "",
            body: "Review $1 and explain: $ARGUMENTS"
        )
        #expect(cmd.render(args: "file.swift carefully now")
            == "Review file.swift and explain: file.swift carefully now")
    }
}

@Suite("PromptTemplate frontmatter + discovery")
struct PromptTemplateDiscoveryTests {

    @Test("frontmatter description is parsed and body stripped")
    func frontmatter() {
        let raw = """
        ---
        description: "Summarize a file"
        argument-hint: <path>
        ---
        Please summarize $1.
        """
        let cmd = PromptTemplate.makeCommand(name: "summarize", rawContent: raw)
        #expect(cmd.description == "Summarize a file")
        #expect(cmd.body == "Please summarize $1.")
    }

    @Test("no frontmatter falls back to first body line as description")
    func noFrontmatter() {
        let cmd = PromptTemplate.makeCommand(
            name: "greet",
            rawContent: "Say hello to $1 warmly.\n\nMore detail."
        )
        #expect(cmd.description == "Say hello to $1 warmly.")
        #expect(cmd.body == "Say hello to $1 warmly.\n\nMore detail.")
    }

    @Test("loads .md files from a directory, skipping non-md")
    func loadFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-cmds-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "Do $1".write(to: dir.appendingPathComponent("alpha.md"),
                          atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("notes.txt"),
                            atomically: true, encoding: .utf8)

        let loaded = CustomSlashCommandLoader.loadFromDirectory(dir.path)
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "alpha")
        #expect(loaded.first?.render(args: "thing") == "Do thing")
    }
}
