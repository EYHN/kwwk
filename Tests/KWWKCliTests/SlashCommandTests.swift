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

    @MainActor
    @Test("submission recognizes only exact registered commands and aliases")
    func registryAwareSubmission() {
        let registry = SlashCommandRegistry()
        registry.register(SlashCommand(
            name: "new",
            description: "start a new session",
            aliases: ["clear"],
            handler: { _, _ in }
        ))

        #expect(SlashInput.parse("/new", recognizing: registry) == .command(name: "new", args: ""))
        #expect(SlashInput.parse("/clear", recognizing: registry) == .command(name: "clear", args: ""))
        #expect(SlashInput.parse("/new title", recognizing: registry) == .command(name: "new", args: "title"))
    }

    @MainActor
    @Test("unmatched slash text remains a prompt on submission")
    func unmatchedSlashIsPrompt() {
        let registry = SlashCommandRegistry()
        registry.register(SlashCommand(
            name: "model",
            description: "switch model",
            handler: { _, _ in }
        ))

        let absolutePath = "/Users/eyhn/Downloads/345796292\\"
        #expect(SlashInput.parse(absolutePath, recognizing: registry) == .prompt(text: absolutePath))
        #expect(SlashInput.parse("/mod", recognizing: registry) == .prompt(text: "/mod"))
        #expect(SlashInput.parse("/unknown with args", recognizing: registry) == .prompt(text: "/unknown with args"))
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

    @Test("fuzzy ranker scores exact > prefix > contains > subsequence")
    func fuzzyRankingOrder() {
        let infos = [
            SlashCommandInfo(name: "compact"),
            SlashCommandInfo(name: "model"),
            SlashCommandInfo(name: "queue"),
        ]
        // Prefix match resolves to the right command.
        #expect(rankSlashCommands(query: "comp", commands: infos).first?.name == "compact")
        // Looser subsequence (c-p-t) still lands on /compact.
        #expect(rankSlashCommands(query: "cpt", commands: infos).first?.name == "compact")
        // No subsequence → no candidates.
        #expect(rankSlashCommands(query: "zzz", commands: infos).isEmpty)
        // Empty query lists the whole catalog in input order.
        #expect(rankSlashCommands(query: "", commands: infos).map(\.name) == ["compact", "model", "queue"])
    }

    @Test("completion finds fuzzy matches and only ghosts contiguous prefixes")
    func fuzzyCompletion() {
        let infos = [
            SlashCommandInfo(name: "compact"),
            SlashCommandInfo(name: "model"),
        ]
        // Prefix: ghost suffix is the contiguous tail.
        #expect(slashCompletion(for: "/comp", commands: infos) == SlashCompletion(
            suffix: "act",
            completedInput: "/compact "
        ))
        // Subsequence: complete on Tab but suppress the inline ghost suffix.
        #expect(slashCompletion(for: "/cpt", commands: infos) == SlashCompletion(
            suffix: "",
            completedInput: "/compact "
        ))
    }

    @Test("aliases participate in ranking")
    func aliasRanking() {
        let infos = [SlashCommandInfo(name: "new", aliases: ["clear"])]
        #expect(rankSlashCommands(query: "clr", commands: infos).first?.name == "new")
        #expect(slashCompletion(for: "/clear", commands: infos)?.completedInput == "/new ")
    }

    @MainActor
    @Test("popup highlight and Tab completion agree on the top match")
    func popupAndCompletionAgree() {
        let frame = CodingFrame(viewportHeight: 20)
        let infos = [
            SlashCommandInfo(name: "compact", description: "summarize the conversation"),
            SlashCommandInfo(name: "model", description: "switch model"),
            SlashCommandInfo(name: "queue", description: "manage the queue"),
        ]
        frame.slashCommands = infos
        frame.input.value = "/comp"

        #expect(frame.slashMenuActive)
        // The popup's highlighted (default-selected) row and the sync
        // completion path resolve to the same command.
        let highlighted = frame.selectedSlashCommandName()
        let completion = slashCompletion(for: frame.input.value, commands: infos)
        #expect(highlighted == "compact")
        #expect(completion?.completedInput == "/compact ")
    }

    @MainActor
    @Test("slash menu footer drops ↵ run while the agent is busy")
    func busyFooterHint() {
        let frame = CodingFrame(viewportHeight: 20)
        frame.slashCommands = [SlashCommandInfo(name: "compact", description: "summarize")]
        frame.input.value = "/comp"

        let idle = frame.render(width: 60).joined(separator: "\n")
        #expect(idle.contains("↵ run"))

        frame.isBusy = true
        let busy = frame.render(width: 60).joined(separator: "\n")
        #expect(!busy.contains("↵ run"))
        #expect(busy.contains("commands run when idle"))
        // Tab completion stays advertised mid-stream.
        #expect(busy.contains("Tab complete"))
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
                renderModalLines: { _ in },
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

@Suite("/shake command")
struct ShakeCommandTests {

    @MainActor
    @Test("registered and listed in /help")
    func registeredAndListed() async {
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        let shake = registry.find("shake")
        #expect(shake != nil)
        #expect(shake?.description.contains("no LLM") == true)
        #expect(registry.all.contains { $0.name == "shake" })
    }

    @MainActor
    @Test("images mode persists, replaces live messages, and closes provider session state")
    func imagesModeRewritesSessionAndLiveState() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let lifecycle = ShakeLifecycleProvider(api: "shake-lifecycle-\(UUID().uuidString)")
        let sourceId = "shake-lifecycle-source-\(UUID().uuidString)"
        await APIRegistry.shared.register(lifecycle, sourceId: sourceId)

        let sessionId = "shake-images-session"
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                messages: [
                    .user(UserMessage(content: [
                        .image(ImageContent(data: "user-image", mimeType: "image/png")),
                    ])),
                    .toolResult(ToolResultMessage(
                        toolCallId: "image-tool",
                        toolName: "read",
                        content: [
                            .text(TextContent(text: "keep")),
                            .image(ImageContent(data: "tool-image", mimeType: "image/jpeg")),
                        ]
                    )),
                ]
            ),
            sessionId: sessionId
        ))
        let notifier = SlashNotifyRecorder()
        let persistence = ShakePersistenceRecorder(result: 4)
        let refresh = ShakeRefreshRecorder()
        let activity = ShakeActivityRecorder()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-shake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let ctx = SlashContext(
            agent: agent,
            modal: makeShakeModalHost(),
            backgroundManager: BackgroundTaskManager(outputDir: outputDir),
            sessionId: sessionId,
            notifyBlock: { lines in for line in lines { notifier.append(line) } },
            commitScrollback: { _ in },
            refreshTranscript: { refresh.count += 1 },
            persistShake: { mode in persistence.record(mode) },
            setShaking: { active in activity.record(active) }
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        await registry.find("shake")?.handler(ctx, "images")

        #expect(persistence.modes == [.images])
        #expect(refresh.count == 1)
        #expect(activity.states == [true, false])
        #expect(notifier.joined.contains("dropped 2 images"))
        guard case .user(let user) = agent.state.messages[0] else {
            Issue.record("expected user message")
            await APIRegistry.shared.unregisterSource(sourceId)
            return
        }
        #expect(user.content == [.text(TextContent(text: "[image removed]"))])
        guard case .toolResult(let tool) = agent.state.messages[1] else {
            Issue.record("expected tool result")
            await APIRegistry.shared.unregisterSource(sourceId)
            return
        }
        #expect(tool.content == [.text(TextContent(text: "keep"))])
        #expect(lifecycle.closedSessions.contains(sessionId))
        await APIRegistry.shared.unregisterSource(sourceId)
    }

    @MainActor
    @Test("bare mode persists the existing tool-output elision")
    func bareModePersistsElision() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: [.toolResult(ToolResultMessage(
                toolCallId: "heavy",
                toolName: "bash",
                content: [.text(TextContent(text: String(repeating: "x", count: 2_000)))]
            ))]
        ))
        let notifier = SlashNotifyRecorder()
        let persistence = ShakePersistenceRecorder(result: 1)
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-shake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let ctx = SlashContext(
            agent: agent,
            modal: makeShakeModalHost(),
            backgroundManager: BackgroundTaskManager(outputDir: outputDir),
            sessionId: "shake-elide-session",
            notifyBlock: { lines in for line in lines { notifier.append(line) } },
            commitScrollback: { _ in },
            refreshTranscript: {},
            persistShake: { mode in persistence.record(mode) }
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        await registry.find("shake")?.handler(ctx, "")

        #expect(persistence.modes == [.elide])
        guard case .toolResult(let result) = agent.state.messages[0],
              case .text(let text)? = result.content.first else {
            Issue.record("expected rewritten tool result")
            return
        }
        #expect(text.text.hasPrefix("[tool result elided to reclaim context"))
        #expect(notifier.joined.contains("elided 1 heavy tool result"))
        #expect(!notifier.joined.contains("in-memory only"))
    }

    @MainActor
    @Test("unknown mode prints usage without rewriting")
    func unknownModePrintsUsage() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let original = Message.user(UserMessage(content: [
            .image(ImageContent(data: "unchanged", mimeType: "image/png")),
        ]))
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: [original]
        ))
        let notifier = SlashNotifyRecorder()
        let persistence = ShakePersistenceRecorder(result: 1)
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-shake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let ctx = SlashContext(
            agent: agent,
            modal: makeShakeModalHost(),
            backgroundManager: BackgroundTaskManager(outputDir: outputDir),
            sessionId: "shake-usage-session",
            notifyBlock: { lines in for line in lines { notifier.append(line) } },
            commitScrollback: { _ in },
            refreshTranscript: {},
            persistShake: { mode in persistence.record(mode) }
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        await registry.find("shake")?.handler(ctx, "bogus")

        #expect(agent.state.messages == [original])
        #expect(persistence.modes.isEmpty)
        #expect(notifier.joined.contains("usage: /shake [elide|images]"))
    }
}

@Suite("SlashCommandRegistry alias resolution")
struct SlashCommandAliasTests {

    @MainActor
    @Test("find resolves a command by its alias")
    func aliasResolves() {
        let registry = SlashCommandRegistry()
        registry.register(SlashCommand(
            name: "new",
            description: "Start a fresh session",
            aliases: ["clear"],
            handler: { _, _ in }
        ))

        // Primary name still resolves.
        #expect(registry.find("new") != nil)
        // Alias resolves to the same command.
        #expect(registry.find("clear")?.name == "new")
        // Unknown name doesn't resolve.
        #expect(registry.find("nope") == nil)
    }

    @MainActor
    @Test("the primary name wins over an alias collision")
    func primaryNameWins() {
        let registry = SlashCommandRegistry()
        registry.register(SlashCommand(
            name: "clear",
            description: "real clear",
            handler: { _, _ in }
        ))
        registry.register(SlashCommand(
            name: "new",
            description: "aliases clear",
            aliases: ["clear"],
            handler: { _, _ in }
        ))
        // A real command named "clear" takes precedence over the alias.
        #expect(registry.find("clear")?.name == "clear")
    }

    @MainActor
    @Test("/help lists a command's aliases")
    func helpListsAliases() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        let notifier = SlashNotifyRecorder()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-alias-help-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let ctx = SlashContext(
            agent: agent,
            modal: ModalHost(
                renderModalLines: { _ in },
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
        registry.register(SlashCommand(
            name: "new",
            description: "Start a fresh session",
            aliases: ["clear"],
            handler: { _, _ in }
        ))
        await registry.find("help")?.handler(ctx, "")
        #expect(notifier.joined.contains("/new"))
        #expect(notifier.joined.contains("alias: /clear"))
    }
}

@MainActor
private final class SlashNotifyRecorder {
    private(set) var lines: [String] = []
    func append(_ s: String) { lines.append(s) }
    func clear() { lines.removeAll() }
    var joined: String { lines.joined(separator: "\n") }
}

@MainActor
private final class ShakePersistenceRecorder {
    private let result: Int?
    private(set) var modes: [ShakeMode] = []

    init(result: Int?) {
        self.result = result
    }

    func record(_ mode: ShakeMode) -> Int? {
        modes.append(mode)
        return result
    }
}

@MainActor
private final class ShakeRefreshRecorder {
    var count = 0
}

@MainActor
private final class ShakeActivityRecorder {
    private(set) var states: [Bool] = []

    func record(_ active: Bool) {
        states.append(active)
    }
}

@MainActor
private func makeShakeModalHost() -> ModalHost {
    ModalHost(
        renderModalLines: { _ in },
        restoreTranscript: {},
        requestRender: {}
    )
}

private final class ShakeLifecycleProvider:
    APIProvider,
    APIProviderSessionLifecycle,
    @unchecked Sendable
{
    let api: String
    private let lock = NSLock()
    private var sessions: [String] = []

    init(api: String) {
        self.api = api
    }

    var closedSessions: [String] {
        lock.withLock { sessions }
    }

    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        AssistantMessageStream()
    }

    func closeSession(sessionId: String) async {
        lock.withLock { sessions.append(sessionId) }
    }
}
