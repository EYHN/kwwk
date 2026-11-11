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

    private static let catalog = [
        SlashCommandInfo(name: "compact", description: "Summarize older turns and retain recent context"),
        SlashCommandInfo(name: "compact-model", description: "Pick the model used for context summaries"),
        SlashCommandInfo(name: "goal", description: "Set/show/stop an autonomous goal the agent pursues across turns"),
        SlashCommandInfo(name: "idle-compact", description: "Compact automatically while idle"),
        SlashCommandInfo(name: "mcp", description: "Manage MCP servers"),
        SlashCommandInfo(name: "model", description: "Pick a model for this session"),
        SlashCommandInfo(name: "new", description: "Start a fresh session", aliases: ["clear"]),
        SlashCommandInfo(name: "rewind", description: "Rewind the conversation to a prior message"),
        SlashCommandInfo(name: "thinking", description: "Show / set thinking level"),
    ]

    @Test("ranking keeps prefix and word-start hits and drops loose ones")
    func tieredRanking() {
        // `/m`: prefix hits first, then the word-start hit; `/compact` and
        // `/idle-compact` merely contain an `m` and stay out.
        #expect(rankSlashCommands(query: "m", commands: Self.catalog).map(\.name)
            == ["mcp", "model", "compact-model"])
        // Word-start brings in `/idle-compact`, ranked after the prefix hits.
        #expect(rankSlashCommands(query: "comp", commands: Self.catalog).map(\.name)
            == ["compact", "compact-model", "idle-compact"])
        // Descriptions never match: `/nope` lists nothing.
        #expect(rankSlashCommands(query: "nope", commands: Self.catalog).isEmpty)
        // With no prefix/word-start hit the loose tiers remain the fallback.
        #expect(rankSlashCommands(query: "cpt", commands: Self.catalog).first?.name == "compact")
    }

    @MainActor
    @Test("Enter runs a popup row only on a prefix match or an explicit pick")
    func submitNeedsPrefixOrSelection() {
        let frame = CodingFrame(viewportHeight: 20)
        frame.slashCommands = Self.catalog

        frame.input.value = "/mod"
        #expect(frame.slashCommandNameForSubmit() == "model")
        frame.input.value = "/cle"
        #expect(frame.slashCommandNameForSubmit() == "new")

        // Loose subsequence hit: highlighted, but Enter must not run it…
        frame.input.value = "/cpt"
        #expect(frame.slashMenuActive)
        #expect(frame.selectedSlashCommandName() == "compact")
        #expect(frame.slashCommandNameForSubmit() == nil)
        // …until the user picks a row with ↑/↓.
        frame.menuMove(1)
        frame.menuMove(-1)
        #expect(frame.slashCommandNameForSubmit() == "compact")
        // Editing the query drops the explicit pick again.
        frame.input.value = "/cpc"
        #expect(frame.slashCommandNameForSubmit() == nil)

        frame.input.value = "/nope"
        #expect(!frame.slashMenuActive)
        #expect(frame.slashCommandNameForSubmit() == nil)
    }

    @MainActor
    @Test("Enter on a lone / keeps the popup open until a row is picked")
    func bareSlashSubmitKeepsMenuOpen() {
        let frame = CodingFrame(viewportHeight: 20)
        frame.slashCommands = Self.catalog

        frame.input.value = "/"
        #expect(frame.slashMenuActive)
        #expect(frame.slashSubmitKeepsMenuOpen())
        #expect(frame.slashCommandNameForSubmit() == nil)
        // An ↑/↓ pick makes Enter run the highlighted row.
        frame.menuMove(1)
        #expect(!frame.slashSubmitKeepsMenuOpen())
        #expect(frame.slashCommandNameForSubmit() == "compact-model")

        frame.input.value = "/mod"
        #expect(!frame.slashSubmitKeepsMenuOpen())
        frame.input.value = "/Users/me/file"
        #expect(!frame.slashSubmitKeepsMenuOpen())
    }

    @MainActor
    @Test("slash menu footer offers ↵ run only when Enter would run the row")
    func footerRunHintFollowsEnterRule() {
        let frame = CodingFrame(viewportHeight: 20)
        frame.slashCommands = Self.catalog
        func footer() -> String { frame.render(width: 100).joined(separator: "\n") }

        frame.input.value = "/mod"
        #expect(footer().contains("↵ run"))
        // Loose match: highlighted but not runnable until picked.
        frame.input.value = "/cpt"
        #expect(!footer().contains("↵ run"))
        #expect(footer().contains("Tab complete"))
        frame.menuMove(1)
        frame.menuMove(-1)
        #expect(footer().contains("↵ run"))
        // A lone `/` waits for a pick too.
        frame.input.value = "/"
        #expect(!footer().contains("↵ run"))
        frame.menuMove(1)
        #expect(footer().contains("↵ run"))
    }

    @MainActor
    @Test("a bare unknown /name is reported; paths and args still prompt")
    func unknownBareCommand() {
        let registry = SlashCommandRegistry()
        registry.register(SlashCommand(
            name: "new",
            description: "start a new session",
            aliases: ["clear"],
            handler: { _, _ in }
        ))

        #expect(unknownBareSlashCommand("/nope", registry: registry) == "nope")
        #expect(unknownBareSlashCommand("/new", registry: registry) == nil)
        #expect(unknownBareSlashCommand("/clear", registry: registry) == nil)
        #expect(unknownBareSlashCommand("/Users/me/file", registry: registry) == nil)
        #expect(unknownBareSlashCommand("/notes.md", registry: registry) == nil)
        #expect(unknownBareSlashCommand("/unknown with args", registry: registry) == nil)
        #expect(unknownBareSlashCommand("/", registry: registry) == nil)
        #expect(unknownBareSlashCommand("hello", registry: registry) == nil)
    }

    @Test("Esc clears the slash query first, then any draft, then reaches the agent")
    func escapeLadder() {
        #expect(escapeClearsSlashMenu("/m") == true)
        #expect(escapeClearsSlashMenu("/nope") == true)
        #expect(escapeClearsSlashMenu("fix the test") == false)
        #expect(escapeClearsSlashMenu("/model gpt") == false)
        // A path-like draft is an ordinary draft, so Esc keeps it in history.
        #expect(escapeClearsSlashMenu("/Users/me/some/long/path") == false)
        #expect(escapeClearsSlashMenu("/notes.md") == false)
        #expect(escapeClearsSlashMenu("/") == true)
        #expect(escapeClearsSlashMenu("") == nil)
    }

    @Test("cancel hints ask for two Esc presses while a draft is in the editor")
    func cancelHintCountsTheDraftStep() {
        func line(_ mode: CodingFrameMode, streaming: Bool, draft: Bool) -> String {
            ANSI.stripEscapes(codingFrameStateLine(
                mode: mode,
                isStreaming: streaming,
                hasDraft: draft,
                runningBackgroundTasks: 0,
                queuedPrompts: 0,
                spinner: "*"
            ))
        }
        #expect(line(.idle, streaming: true, draft: false).contains("Esc to cancel"))
        #expect(line(.idle, streaming: true, draft: true).contains("Esc twice to cancel"))
        #expect(line(.compacting(messageCount: 3), streaming: false, draft: true).contains("Esc twice to cancel"))
        let retrying = CodingFrameMode.retrying(attempt: 0, until: Date(), reason: "")
        #expect(line(retrying, streaming: true, draft: true).contains("Esc twice to cancel"))
        #expect(!line(.idle, streaming: false, draft: true).contains("Esc"))
        #expect(busySlashCommandNotice.contains("Esc twice"))
    }

    @Test("idle state line names the send key; a transient notice replaces it")
    func stateLineIdleHintAndNotice() {
        func line(streaming: Bool, notice: String?) -> String {
            ANSI.stripEscapes(codingFrameStateLine(
                mode: .idle,
                isStreaming: streaming,
                hasDraft: false,
                runningBackgroundTasks: 0,
                queuedPrompts: 0,
                spinner: "*",
                notice: notice
            ))
        }
        #expect(line(streaming: false, notice: nil) == "↵ send · / commands · @ attach · ⇧↵ newline")
        let noticed = line(streaming: false, notice: "press Ctrl-C again to exit")
        #expect(noticed == "press Ctrl-C again to exit")
        let busy = line(streaming: true, notice: "/model: cancelled")
        #expect(busy.contains("/model: cancelled"))
        #expect(busy.contains("generating"))
        #expect(busy.contains("Esc to cancel"))
    }

    @Test("a busy state line keeps the spinner and cancel hint ahead of a notice")
    func stateLineBusyNoticeTrails() {
        func line(_ mode: CodingFrameMode, streaming: Bool) -> String {
            ANSI.stripEscapes(codingFrameStateLine(
                mode: mode,
                isStreaming: streaming,
                hasDraft: false,
                runningBackgroundTasks: 0,
                queuedPrompts: 0,
                spinner: "*",
                notice: "/goal: no active goal — /goal <objective> to start one"
            ))
        }
        let generating = line(.idle, streaming: true)
        #expect(generating.hasPrefix("* generating  ·  Esc to cancel"))
        #expect(ANSI.truncate(generating, to: 78).contains("Esc to cancel"))
        let compacting = line(.compacting(messageCount: 3), streaming: false)
        #expect(compacting.hasPrefix("* compacting 3 messages"))
        #expect(compacting.hasSuffix("/goal <objective> to start one"))
        let retrying = line(.retrying(attempt: 0, until: Date(), reason: ""), streaming: true)
        #expect(retrying.hasPrefix("* retry 2/8 in now  ·  Esc to cancel"))
    }

    @MainActor
    @Test("slash menu footer offers Esc close like the @ menu")
    func slashFooterEscClose() {
        let frame = CodingFrame(viewportHeight: 20)
        frame.slashCommands = [SlashCommandInfo(name: "compact", description: "summarize")]
        frame.input.value = "/comp"
        let footer = frame.render(width: 80).map { ANSI.stripEscapes($0) }
            .first { $0.contains("Tab complete") } ?? ""
        #expect(footer.contains("↑↓ move · Tab complete · ↵ run · Esc close"))
    }

    @MainActor
    @Test("slash menu marks a cut description with an ellipsis")
    func descriptionEllipsis() {
        let frame = CodingFrame(viewportHeight: 20)
        frame.slashCommands = Self.catalog
        frame.input.value = "/goal"

        let width = 48
        let lines = frame.render(width: width).map { ANSI.stripEscapes($0) }
        let row = lines.first { $0.contains("/goal") && $0.contains("Set/show") }
        #expect(row?.hasSuffix("…") == true)
        #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= width })
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
