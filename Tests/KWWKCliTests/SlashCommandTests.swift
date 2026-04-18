import Foundation
import Testing
@testable import KWWKCli

@Suite("SlashInput.parse")
struct SlashInputParseTests {

    @Test("plain text is a prompt")
    func plainPrompt() {
        #expect(SlashInput.parse("hello world") == .prompt(text: "hello world"))
    }

    @Test("leading slash + name only")
    func commandNoArgs() {
        #expect(SlashInput.parse("/model") == .command(name: "model", args: ""))
    }

    @Test("leading slash + name + args")
    func commandWithArgs() {
        #expect(SlashInput.parse("/model gpt-5.4") == .command(name: "model", args: "gpt-5.4"))
    }

    @Test("args preserve internal whitespace verbatim")
    func commandArgsKeepSpacing() {
        let parsed = SlashInput.parse("/foo  arg1   arg2")
        #expect(parsed == .command(name: "foo", args: " arg1   arg2"))
    }

    @Test("leading whitespace before the slash is tolerated")
    func tolerantLeadingSpace() {
        #expect(SlashInput.parse("   /model") == .command(name: "model", args: ""))
    }

    @Test("bare slash falls back to prompt")
    func bareSlashIsPrompt() {
        #expect(SlashInput.parse("/") == .prompt(text: "/"))
        #expect(SlashInput.parse("/   ") == .prompt(text: "/   "))
    }

    @Test("slash that isn't in first position is just text")
    func middleSlashIsPrompt() {
        #expect(SlashInput.parse("a/b") == .prompt(text: "a/b"))
    }
}
