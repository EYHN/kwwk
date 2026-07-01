import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("new builtin slash commands")
struct NewSlashCommandTests {

    @MainActor
    @Test("all new commands are registered and listed by /help")
    func registeredAndInHelp() async {
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        for name in ["context", "init", "tools", "hotkeys", "copy", "dump", "rename"] {
            #expect(registry.find(name) != nil, "/\(name) should be registered")
        }

        let (ctx, notifier) = await makeContext()
        await registry.find("help")?.handler(ctx, "")
        for name in ["context", "init", "tools", "hotkeys", "copy", "dump", "rename"] {
            #expect(notifier.joined.contains("/\(name)"), "/help should list /\(name)")
        }
    }

    @MainActor
    @Test("/context reports the window, usage, and auto-compact threshold")
    func contextBreakdown() async {
        let (ctx, notifier) = await makeContext()
        // Seed an assistant message carrying usage so currentUsage is non-zero.
        let window = ctx.agent.state.model.contextWindow
        guard window > 0 else { return }
        ctx.agent.state.messages = [
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "hi"))],
                api: "test",
                provider: "test",
                model: ctx.agent.state.model.id,
                usage: Usage(input: window / 4)
            )),
        ]
        await runCommand("context", ctx: ctx)
        #expect(notifier.joined.contains("token window"))
        #expect(notifier.joined.contains("tokens used"))
        #expect(notifier.joined.contains("%"))
    }

    @MainActor
    @Test("/tools lists registered tool names")
    func toolsLists() async {
        let (ctx, notifier) = await makeContext()
        ctx.agent.state.tools = [
            AgentTool(
                name: "read_file",
                label: "read_file",
                description: "Read a file from disk",
                parameters: .object([:]),
                execute: { _, _, _, _ in AgentToolResult(content: []) }
            ),
        ]
        await runCommand("tools", ctx: ctx)
        #expect(notifier.joined.contains("read_file"))
        #expect(notifier.joined.contains("Read a file"))
    }

    @MainActor
    @Test("/hotkeys prints a static binding table")
    func hotkeysTable() async {
        let (ctx, notifier) = await makeContext()
        await runCommand("hotkeys", ctx: ctx)
        #expect(notifier.joined.contains("Enter"))
        #expect(notifier.joined.contains("dequeue") || notifier.joined.contains("queued"))
        #expect(notifier.joined.contains("Esc"))
    }

    @MainActor
    @Test("/copy copies the LAST assistant reply's real text")
    func copyLastReply() async {
        let (ctx, notifier) = await makeContext()
        // Seed two assistant replies of different lengths; /copy must pick the
        // last one. "an earlier, much longer reply" != "the answer" (10 chars),
        // so grabbing the wrong message yields a different char count.
        ctx.agent.state.messages = [
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "an earlier, much longer reply"))],
                api: "test",
                provider: "test",
                model: ctx.agent.state.model.id
            )),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "the answer"))],
                api: "test",
                provider: "test",
                model: ctx.agent.state.model.id
            )),
        ]
        // The selection logic `/copy` feeds to ClipboardWriter must resolve to
        // the LAST reply's real text, not the earlier, longer one.
        #expect(lastAssistantText(ctx.agent.state.messages) == "the answer")
        await runCommand("copy", ctx: ctx)
        #expect(notifier.joined.contains("copied last reply"))
        // "the answer" is exactly 10 characters — the reported count pins that
        // the last reply (not the 29-char earlier one) is what got copied.
        #expect(notifier.joined.contains("(10 chars)"))
        // Sanity-check the OSC52 encoder against a hand-computed base64 (not a
        // literal-on-both-sides tautology): "the answer" → "dGhlIGFuc3dlcg==".
        #expect(ClipboardWriter.osc52Sequence(for: "the answer")
            == "\u{1B}]52;c;dGhlIGFuc3dlcg==\u{07}")
    }

    @MainActor
    @Test("/copy with no assistant message reports nothing to copy")
    func copyEmpty() async {
        let (ctx, notifier) = await makeContext()
        await runCommand("copy", ctx: ctx)
        #expect(notifier.joined.contains("no assistant message"))
    }

    @MainActor
    @Test("/rename without a title shows usage; with a title persists it")
    func renamePlumbing() async {
        let (ctx, notifier) = await makeContext()
        await runCommand("rename", ctx: ctx, args: "")
        #expect(notifier.joined.contains("usage"))

        let recorded = TitleRecorder()
        let (ctx2, notifier2) = await makeContext(setSessionTitle: { title in
            recorded.value = title
        })
        await runCommand("rename", ctx: ctx2, args: "  My session  ")
        #expect(recorded.value == "My session")
        #expect(notifier2.joined.contains("My session"))
    }

    @Test("ClipboardWriter OSC 52 payload is a base64 set-clipboard escape")
    func osc52Payload() {
        let seq = ClipboardWriter.osc52Sequence(for: "hi")
        #expect(seq.hasPrefix("\u{1B}]52;c;"))
        #expect(seq.hasSuffix("\u{07}"))
        #expect(seq.contains(Data("hi".utf8).base64EncodedString()))
    }

    @Test("renderContextBar clamps and renders fill + percent")
    func contextBar() {
        #expect(renderContextBar(fraction: 0).contains("0%"))
        #expect(renderContextBar(fraction: 1).contains("100%"))
        #expect(renderContextBar(fraction: 1.5).contains("100%"), "over-full clamps to 100%")
        #expect(renderContextBar(fraction: 0.5).contains("50%"))
    }
}

// MARK: - Helpers

@MainActor
private final class TitleRecorder {
    var value: String?
}

@MainActor
private func runCommand(_ name: String, ctx: SlashContext, args: String = "") async {
    let registry = SlashCommandRegistry()
    registerBuiltinSlashCommands(registry)
    await registry.find(name)?.handler(ctx, args)
}

@MainActor
private func makeContext(
    setSessionTitle: @MainActor @escaping (String) async -> Void = { _ in }
) async -> (SlashContext, NewSlashNotifyRecorder) {
    let faux = await registerFauxProvider()
    _ = faux
    let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
    let notifier = NewSlashNotifyRecorder()
    let outputDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwwk-newcmd-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let ctx = SlashContext(
        agent: agent,
        modal: ModalHost(
            renderModalLines: { _ in },
            restoreTranscript: {},
            requestRender: {}
        ),
        backgroundManager: BackgroundTaskManager(outputDir: outputDir),
        sessionId: "sess",
        notifyBlock: { lines in for l in lines { notifier.append(l) } },
        commitScrollback: { _ in },
        refreshTranscript: {},
        setSessionTitle: setSessionTitle
    )
    return (ctx, notifier)
}

@MainActor
private final class NewSlashNotifyRecorder {
    private(set) var lines: [String] = []
    func append(_ s: String) { lines.append(s) }
    func clear() { lines.removeAll() }
    var joined: String { lines.joined(separator: "\n") }
}
