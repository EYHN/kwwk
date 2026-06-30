import Foundation
import KWWKAI
import KWWKAgent

/// Internal implementation of the coding-agent TUI. Public entry points
/// live on `KWWK` (see KWWK.swift) and resolve credentials before calling
/// in here. `@MainActor` because `TranscriptRenderer` and the TUI layout
/// mutate main-thread-only state.
@MainActor
func runCodingTUIInternal(
    model: Model,
    modelLabel: String,
    cwd: String,
    tools: CodingTools,
    builtinSubagents: BuiltinSubagentSelection = .all,
    authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
    autoCompactThreshold: Double? = 0.75,
    thinkingLevel: ThinkingLevel = .medium,
    resume: SessionResume = .none
) async throws {
    // --- agent + background manager -------------------------------------
    let bgManager = BackgroundTaskManager()

    // Resolve session persistence up front: a fresh id by default, or a
    // stored transcript when `--resume` / `--session` was passed.
    let sessionStore = SessionStore(directory: SessionStore.defaultDirectory())
    // `--resume` opens an interactive picker across all projects; resolve the
    // user's choice to a concrete session id before loading. Cancelling exits
    // cleanly (pi parity: "No session selected", exit 0).
    var effectiveResume = resume
    if resume == .pickInteractive {
        if let chosen = await SessionPicker.choose(store: sessionStore) {
            effectiveResume = .id(chosen)
        } else {
            FileHandle.standardError.write(Data("No session selected\n".utf8))
            Foundation.exit(0)
        }
    }
    let resolvedResume = await sessionStore.resolveResume(effectiveResume, cwd: cwd)
    let sessionId = resolvedResume.sessionId

    let environment = ProcessInfo.processInfo.environment
    let tmuxManager = tools.contains(.tmux)
        ? try cliTmuxManager(environment: environment)
        : nil
    let agent = await makeCodingAgent(CodingAgentConfig(
        model: model,
        cwd: cwd,
        tools: tools,
        contextFiles: loadProjectContextFiles(cwd: cwd),
        skillDirectories: Skills.defaultDirectories(cwd: cwd, includeUserDirectory: true),
        backgroundManager: bgManager,
        subagents: defaultCLISubagents(for: tools, selection: builtinSubagents),
        sessionId: sessionId,
        authResolver: authResolver,
        autoCompactThreshold: autoCompactThreshold,
        bashEnvironment: environment,
        bashShellPath: cliShellPath(environment: environment),
        tmuxManager: tmuxManager
    ))

    // Seed the transcript from disk when resuming so the model continues
    // where it left off.
    if !resolvedResume.messages.isEmpty {
        agent.state.messages = resolvedResume.messages
    }

    // Persist the transcript as it grows.
    let sessionRecorder = SessionRecorder(
        store: sessionStore,
        sessionId: sessionId,
        cwd: cwd,
        model: model.id,
        provider: model.provider,
        persistedCount: resolvedResume.persistedCount
    )
    if !resolvedResume.resumed {
        await sessionRecorder.ensureCreated()
    }
    let unsubscribeSessionRecorder = sessionRecorder.attach(to: agent)
    defer { unsubscribeSessionRecorder() }
    // Turn on extended thinking by default — otherwise reasoning-capable
    // providers never produce `[thinking]` blocks. The level is a user
    // intent: the agent loop filters it to `nil` when the live model
    // isn't reasoning-capable, so non-thinking models pay no cost and
    // `/model` switches flow naturally in either direction. Toggle via
    // `/thinking off` (or `high` / `xhigh` for thornier problems).
    agent.state.thinkingLevel = thinkingLevel

    // --- TUI (shared layout) --------------------------------------------
    // Inline render mode — the frame anchors at the current cursor and
    // preserves the user's shell scrollback above it (the Claude Code
    // behavior). Pass `useAlternateScreen: true` if you want a blank
    // fullscreen buffer instead.
    let runner = TUIRunner(useAlternateScreen: false, hideCursor: false)
    let layout = CodingLayout(statusRows: 0, chromeMode: .promptOnly)
    let renderer = TranscriptRenderer()

    // Print the header banner once, as ordinary terminal output. It
    // sits above the live zone at startup and scrolls into native
    // scrollback as content piles up — same treatment as any other
    // committed line. Per-turn capacity (`42% ctx`) moves to the
    // status bar so we don't need to re-render this block.
    let cwdShort = shortenPath(cwd, to: max(20, runner.terminal.width - 4))
    let bannerLines: [String] = [
        Style.header("✻ kwwk coding agent"),
        Style.dimmed("  \(modelLabel)"),
        Style.dimmed("  \(cwdShort)"),
        "",
    ]
    for line in bannerLines {
        runner.terminal.write(line + "\r\n")
    }
    if resolvedResume.resumed {
        runner.terminal.write(
            Style.dimmed("  ↻ resumed session \(sessionId.prefix(8)) · \(resolvedResume.messages.count) messages")
            + "\r\n\r\n"
        )
    }

    layout.install(into: runner.tui)
    layout.fitViewport(height: runner.terminal.height, width: runner.terminal.width)
    runner.focus(layout.promptRow)

    // Paste plumbing: `onPaste` is called whenever the terminal
    // delivers a bracketed-paste sequence. We route it through the
    // AttachmentStore so long / multi-line bodies stay out of the
    // single-line input, and show up as compact tokens instead.
    let attachments = AttachmentStore()
    layout.input.onPaste = { body in
        handlePastedBody(
            body,
            input: layout.input,
            attachments: attachments,
            tui: runner.tui
        )
    }
    // Non-LLM messages the coding TUI wants to surface ("switched to
    // gpt-5.4", "unknown slash command /foo", attach issues, etc.) are
    // committed directly to scrollback via `runner.tui.commit(...)`.
    // There's no separate notification block in the live zone — those
    // were annoying (user couldn't dismiss them, took vertical space,
    // complicated the layout math). Slash commands are gated to the
    // idle state below so we never need to interleave them with
    // streaming output.
    //
    // `recomputeTranscript` deliberately leaves the live tail empty. The
    // coding surface is append-only now: assistant text, tool output, slash
    // command output, and notifications all flow through stdout so the
    // terminal owns autowrap and resize reflow. The only retained rows are
    // transient modal content and the editable prompt.
    let recomputeTranscript: @MainActor @Sendable () -> Void = {
        layout.setLiveTail([])
    }

    // Modal overlay host — takes over the transcript area for selectors
    // (/model). Only one modal is active at a time; its bindings are
    // wired below via `modal.routeXxx`. On close we both restore the
    // live tail and drain any commits that accumulated while the modal
    // was up, so scrollback catches up to what the agent did in the
    // meantime.
    let modal = ModalHost(
        layout: layout,
        restoreTranscript: {
            let committed = renderer.drainCommits()
            if !committed.isEmpty { runner.tui.commit(committed) }
            recomputeTranscript()
        },
        requestRender: { runner.tui.requestRender() }
    )

    _ = runner.terminal.onResize { w, h in
        Task { @MainActor in
            layout.fitViewport(height: h, width: w)
            if !modal.isOpen {
                recomputeTranscript()
            }
            runner.tui.requestRender()
        }
    }

    /// Drain the renderer's commit buffer and forward to the TUI so the
    /// newly-settled lines show up above the live zone on the next
    /// render. Called after every agent event + after modal close.
    ///
    /// While a modal is open we deliberately leave commits sitting in
    /// the renderer's buffer: flushing would print history lines above
    /// the modal and make the UI feel noisy. They drain on close.
    let flushCommits: @MainActor @Sendable () -> Bool = {
        guard !modal.isOpen else { return false }
        let committed = renderer.drainCommits()
        if !committed.isEmpty {
            runner.tui.commit(committed)
            return true
        }
        return false
    }

    var isAutoCompacting = false

    // Keep the renderer's display mode in sync with the agent's state on
    // every event, so `/thinking show|hide` (which only mutates agent
    // state) takes effect on the next turn without extra plumbing.
    renderer.setThinkingDisplay(agent.state.thinkingDisplay)
    _ = agent.subscribe { event, _ in
        await MainActor.run {
            renderer.setThinkingDisplay(agent.state.thinkingDisplay)
            renderer.apply(event)
            // Order matters here:
            //   1. recomputeTranscript() — may spill streaming overflow
            //      into the commit buffer as a side effect (long
            //      assistant turns need to scroll their head into
            //      scrollback as they grow).
            //   2. flushCommits() — forwards everything (settled lines
            //      from `apply` PLUS spill from the live-budget step)
            //      to the TUI in one batch so a single render emits
            //      all of it.
            // When a modal is open we leave the live tail alone and
            // let the modal keep the display; pending commits buffer
            // until close, then drain together.
            if !modal.isOpen {
                recomputeTranscript()
            }
            var needsRender = flushCommits()
            switch event {
            case .agentStart:
                break
            case .agentEnd:
                break
            case .compactStart(let count, _):
                isAutoCompacting = true
                runner.tui.commit([
                    "",
                    Style.dimmed("  ◐ auto-compacting \(count) messages…"),
                ])
                needsRender = true
            case .compactEnd(let outcome):
                isAutoCompacting = false
                switch outcome {
                case .compacted(let n, let hasLedger):
                    runner.tui.commit(renderCompactBoundary(
                        messagesCompacted: n,
                        hasRunningTasksLedger: hasLedger,
                        width: runner.terminal.width
                    ))
                    needsRender = true
                case .refusedAgentBusy:
                    runner.tui.commit([
                        "",
                        Style.error("  auto-compact: agent is busy; compact skipped"),
                        "",
                    ])
                    needsRender = true
                case .refusedTooFewMessages:
                    break
                case .failed(let msg):
                    runner.tui.commit([
                        "",
                        Style.error("  auto-compact failed: \(msg)"),
                        "",
                    ])
                    needsRender = true
                }
            case .streamRetry:
                break
            case .messageStart, .messageUpdate:
                break
            default: break
            }
            layout.fitViewport(height: runner.terminal.height, width: runner.terminal.width)
            if needsRender || modal.isOpen {
                runner.tui.requestRender()
            }
        }
    }

    // Slash command registry. Handlers get a `SlashContext` with the
    // agent + modal host + a `notify` hook that commits a line to
    // scrollback. There's no ephemeral notification area anymore:
    // every slash-command output — `/help`, `/queue`, `/model` status,
    // attach warnings, etc. — flows straight into history so the user
    // can scroll up to see what happened and no dedicated "block"
    // needs to be dismissed.
    let slashRegistry = SlashCommandRegistry()
    registerBuiltinSlashCommands(slashRegistry)
    // User/project prompt-template commands (`.kwwk/commands/*.md`,
    // `~/.kwwk/commands/*.md`). Registered after builtins so a custom file
    // can't shadow a core command; their handlers render the template against
    // the invocation args and submit it as an ordinary prompt.
    CustomSlashCommandLoader.register(into: slashRegistry, cwd: cwd)
    let slashCommandNames = slashRegistry.all.map(\.name)
    layout.promptRow.ghostHintProvider = { input in
        slashCompletion(for: input, commandNames: slashCommandNames)?.suffix
    }
    let slashContext = SlashContext(
        agent: agent,
        modal: modal,
        backgroundManager: bgManager,
        sessionId: sessionId,
        notifyBlock: { lines in
            guard !lines.isEmpty else { return }
            // "Every scrollback block opens with a leading blank, never
            // closes with one" — the whole notification is one block so
            // we prepend exactly one blank regardless of how many lines
            // the caller supplies.
            runner.tui.commit([""] + lines)
            runner.tui.requestRender()
        },
        commitScrollback: { render in
            let lines = render(runner.terminal.width)
            guard !lines.isEmpty else { return }
            runner.tui.commit(lines)
            runner.tui.requestRender()
        },
        refreshTranscript: {
            renderer.setThinkingDisplay(agent.state.thinkingDisplay)
            recomputeTranscript()
            runner.tui.requestRender()
        },
        recordCompaction: { messagesCompacted in
            await sessionRecorder.recordCompaction(
                messages: agent.state.messages,
                messagesCompacted: messagesCompacted
            )
        }
    )

    // --- keybindings ----------------------------------------------------

    // Enter. Four modes of operation:
    //   1. modal open → forward to modal's confirm handler.
    //   2. input starts with `/` → slash command dispatch.
    //   3. LLM prompt while the agent is idle → submit.
    //   4. LLM prompt while the agent is streaming → steer as a user
    //      message so it runs at the next turn boundary. We do NOT
    //      drop the typed text: starting a second agent.prompt while
    //      the first is streaming would throw `alreadyRunning` and
    //      blow the input away. Steering lets the user queue a
    //      follow-up without racing the current turn.
    runner.bind(.init("enter", shift: false)) { _ in
        Task { @MainActor in
            if modal.isOpen {
                modal.routeConfirm()
                return
            }
            let text = layout.input.value
            guard !text.isEmpty else { return }

            let parsed = SlashInput.parse(text)
            let busy = agent.state.isStreaming || isAutoCompacting

            // Slash commands are idle-only. If the agent is mid-turn
            // we can't reliably run them (some mutate agent state, all
            // would need to interleave output with streaming). Keeping
            // the gate simple means we never need a floating
            // "notification block" to surface their output — they
            // always commit to scrollback on a quiet moment.
            if case .command = parsed, busy {
                runner.tui.commit([
                    "",
                    Style.error("  slash commands run only when the agent is idle — stop it first (Esc) or wait"),
                    "",
                ])
                runner.tui.requestRender()
                return
            }

            // LLM prompt while the agent is busy: steer as a queued
            // user message so it runs at the next turn boundary. We
            // do NOT drop the typed text — starting a second
            // agent.prompt while the first is streaming would throw
            // `alreadyRunning`.
            if case .prompt = parsed, busy {
                let built = buildPromptWithAttachments(
                    text: text,
                    store: attachments,
                    cwd: cwd,
                    modelSupportsImages: agent.state.model.input.contains(.image)
                )
                var blocks: [UserBlock] = [.text(TextContent(text: built.text))]
                for img in built.images { blocks.append(.image(img)) }
                agent.steer(.user(UserMessage(content: blocks)))
                attachments.clear()
                layout.input.value = ""
                let queued = agent.queuedSteeringCount()
                runner.tui.commit([
                    "",
                    Style.dimmed("  queued prompt\(queued > 1 ? " (\(queued) waiting)" : "")"),
                ])
                // Surface only attach problems — a clean queueing
                // otherwise stays as the one-line queued prompt above.
                if let issues = built.issues {
                    runner.tui.commit([
                        "",
                        Style.error("  attach: " + issues),
                    ])
                }
                runner.tui.requestRender()
                return
            }

            layout.input.value = ""
            runner.tui.requestRender()

            switch parsed {
            case .command(let name, let args):
                if let cmd = slashRegistry.find(name) {
                    await cmd.handler(slashContext, args)
                    runner.tui.requestRender()
                } else {
                    runner.tui.commit([
                        "",
                        Style.error("  unknown slash command: /\(name)"),
                        "",
                    ])
                    runner.tui.requestRender()
                }
            case .prompt:
                // Rebuild with attachments — the raw `text` may carry
                // `@path` tokens and `[pasted-text #N]` placeholders
                // from earlier paste events.
                let built = buildPromptWithAttachments(
                    text: text,
                    store: attachments,
                    cwd: cwd,
                    modelSupportsImages: agent.state.model.input.contains(.image)
                )
                attachments.clear()
                if let issues = built.issues {
                    runner.tui.commit([
                        "",
                        Style.error("  attach: " + issues),
                        "",
                    ])
                    runner.tui.requestRender()
                }
                let promptText = built.text
                let promptImages = built.images
                Task.detached {
                    do {
                        try await agent.prompt(promptText, images: promptImages)
                    } catch {
                        await MainActor.run {
                            runner.tui.commit([
                                "",
                                Style.error("  error: \(error)"),
                            ])
                            runner.tui.requestRender()
                        }
                    }
                }
            }
        }
    }

    runner.bind(.init("tab")) { _ in
        Task { @MainActor in
            guard !modal.isOpen else { return }
            if layout.input.cursor == layout.input.value.count,
               let completion = slashCompletion(for: layout.input.value, commandNames: slashCommandNames) {
                layout.input.value = completion.completedInput
                layout.input.moveEnd()
            } else {
                layout.input.insert("\t")
            }
            runner.tui.requestRender()
        }
    }

    // Arrow keys — only have meaning inside a modal (move selection).
    // Outside a modal they're no-ops, which matches pi-mono's behavior
    // (we don't have a scrollback feature yet).
    runner.bind(.init("up"))   { _ in Task { @MainActor in modal.routeUp() } }
    runner.bind(.init("down")) { _ in Task { @MainActor in modal.routeDown() } }

    // Ctrl-C: always exits (single tap). Keep it as the hard-stop key so
    // there's always a predictable way out.
    runner.bind(.ctrl("c")) { _ in
        Task { @MainActor in
            await agent.abortAndKillBackgroundTasks()
            runner.exit()
        }
    }

    // Esc. Three modes of operation:
    //   1. modal open → cancel the modal (no agent state touched).
    //   2. agent streaming → abort the current generation.
    //   3. idle AND background tasks running → kill them all.
    //   4. idle, no bg tasks → no-op (Ctrl-C is the only way out).
    runner.bind(.init("escape")) { _ in
        Task { @MainActor in
            if modal.isOpen {
                modal.routeCancel()
                return
            }
            if agent.state.isStreaming {
                agent.abort()
                runner.tui.commit([
                    "",
                    Style.dimmed("  aborting…"),
                ])
                runner.tui.requestRender()
                return
            }
            let running = await bgManager.list(sessionId: sessionId)
                .filter { $0.status == .running }.count
            if running > 0 {
                await bgManager.killAll(sessionId: sessionId)
                runner.tui.commit([
                    "",
                    Style.dimmed("  killed \(running) background \(running == 1 ? "task" : "tasks")"),
                ])
                runner.tui.requestRender()
            }
            // No bg tasks, nothing streaming → Esc does nothing. The
            // user exits via Ctrl-C.
        }
    }

    let shutdown: @MainActor @Sendable () async -> Void = {
        // Kill any still-running background tasks, close provider-held
        // session resources, and tear down the isolated tmux socket so we
        // don't leak processes after the user exits.
        await agent.abortAndKillBackgroundTasks()
        await agent.closeSession()
        await tmuxManager?.teardown()
    }

    do {
        try await runner.run()
    } catch {
        await shutdown()
        throw error
    }
    await shutdown()
}

// MARK: - Helpers

private func shortenPath(_ path: String, to maxLen: Int) -> String {
    if path.count <= maxLen { return path }
    let head = path.prefix(maxLen / 2 - 1)
    let tail = path.suffix(maxLen / 2 - 2)
    return "\(head)…\(tail)"
}

/// Decide how to route a bracketed-paste body into the single-line
/// input. Ordered checks:
///   - NSPasteboard has an image (⌘V of a screenshot) → register
///     with the attachment store as a clipboard image, insert
///     `[image #N]`. The terminal's paste body is typically empty
///     or garbage in this case, so we discard it.
///   - single-line absolute/home/relative path → insert as `@<path> `
///     so the token survives editing and resolves at submit time.
///   - small single-line text (< 80 chars, no newlines) → insert
///     inline verbatim.
///   - anything else (multi-line, huge paste) → register with the
///     attachment store and insert a short `[pasted-text #N]`
///     placeholder so the user sees what's pending without the input
///     line exploding.
@MainActor
func handlePastedBody(
    _ body: String,
    input: InputComponent,
    attachments: AttachmentStore,
    tui: TUI,
    inlineLimit: Int = 80
) {
    // Clipboard-image takes precedence: on macOS the user can ⌘V a
    // screenshot whose bytes never reach stdin — the terminal sends
    // an empty/degenerate paste body while NSPasteboard holds the
    // real image. Peek the pasteboard before interpreting the body.
    if let image = ClipboardImageReader.readIfPresent() {
        let token = attachments.addClipboardImage(data: image.data, mimeType: image.mimeType)
        input.insert("\(token) ")
        tui.requestRender()
        return
    }

    if looksLikeSinglePath(body) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip surrounding quotes (Finder drag-n-drop wraps paths with
        // whitespace in double quotes).
        let unquoted: String = {
            var t = trimmed
            if t.count >= 2, let first = t.first, let last = t.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                t = String(t.dropFirst().dropLast())
            }
            return t
        }()
        input.insert("@\(unquoted) ")
        tui.requestRender()
        return
    }

    // Multi-line or long paste → promote to a pasted-text attachment.
    // The threshold is generous enough that an IDE one-liner
    // (e.g. a copied SQL query) still inserts directly, but a multi-
    // paragraph paste goes through the attachment path.
    if body.contains("\n") || body.count > inlineLimit {
        let token = attachments.addPastedText(body)
        input.insert("\(token) ")
        tui.requestRender()
        return
    }

    // Plain short paste: insert as-is, no transformation.
    input.insert(body)
    tui.requestRender()
}
