import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
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

    @Test("slash command completion returns ghost suffix and completed input")
    func completion() {
        let names = ["model", "compact", "queue"]

        #expect(slashCompletion(for: "/mod", commandNames: names) == SlashCompletion(
            suffix: "el",
            completedInput: "/model "
        ))
        #expect(slashCompletion(for: "/model", commandNames: names) == SlashCompletion(
            suffix: "",
            completedInput: "/model "
        ))
        #expect(slashCompletion(for: "/model claude", commandNames: names) == nil)
        #expect(slashCompletion(for: "hello /mod", commandNames: names) == nil)
    }
}

@Suite("/verbose command")
struct VerboseCommandTests {

    @MainActor
    @Test("toggles verbose mode and reports status")
    func togglesVerboseMode() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        let notifier = SlashNotifyRecorder()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-verbose-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let ctx = SlashContext(
            agent: agent,
            modal: ModalHost(
                layout: CodingLayout(statusRows: 1),
                restoreTranscript: {},
                requestRender: {}
            ),
            backgroundManager: BackgroundTaskManager(outputDir: outputDir),
            sessionId: "sess",
            notifyBlock: { lines in for line in lines { notifier.append(line) } },
            commitScrollback: { _ in },
            refreshTranscript: {}
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        #expect(agent.state.verboseEnabled == false)
        await registry.find("verbose")?.handler(ctx, "")
        #expect(agent.state.verboseEnabled == true)
        #expect(notifier.joined.contains("off"))
        #expect(notifier.joined.contains("on"))

        notifier.clear()
        await registry.find("verbose")?.handler(ctx, "status")
        #expect(agent.state.verboseEnabled == true)
        #expect(notifier.joined.contains("/verbose: on"))

        notifier.clear()
        await registry.find("verbose")?.handler(ctx, "off")
        #expect(agent.state.verboseEnabled == false)
        #expect(notifier.joined.contains("on"))
        #expect(notifier.joined.contains("off"))
    }
}

@MainActor
private final class SlashNotifyRecorder {
    private(set) var lines: [String] = []
    func append(_ s: String) { lines.append(s) }
    func clear() { lines.removeAll() }
    var joined: String { lines.joined(separator: "\n") }
}
