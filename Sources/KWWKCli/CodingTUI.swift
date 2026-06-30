import Foundation
import KWWKAI
import KWWKAgent

/// Internal implementation of the coding-agent TUI. Public entry points
/// live on `KWWK` (see KWWK.swift) and resolve credentials before calling
/// in here. `@MainActor` because `TranscriptRenderer` and the TUI frame
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

    // Persist the transcript as it grows. The recorder + its subscription
    // live in a reference box so `/resume` can hot-swap them to a different
    // session file mid-run (a plain `var` can't be mutated from the resume
    // closure under Swift 6 concurrency).
    let initialRecorder = SessionRecorder(
        store: sessionStore,
        sessionId: sessionId,
        cwd: cwd,
        model: model.id,
        provider: model.provider,
        persistedCount: resolvedResume.persistedCount
    )
    if !resolvedResume.resumed {
        await initialRecorder.ensureCreated()
    }
    let recorderBox = RecorderBox(
        recorder: initialRecorder,
        unsubscribe: initialRecorder.attach(to: agent),
        sessionId: sessionId
    )
    defer { recorderBox.unsubscribe() }
    // Turn on extended thinking by default — otherwise reasoning-capable
    // providers never produce `[thinking]` blocks. The level is a user
    // intent: the agent loop filters it to `nil` when the live model
    // isn't reasoning-capable, so non-thinking models pay no cost and
    // `/model` switches flow naturally in either direction. Toggle via
    // `/thinking off` (or `high` / `xhigh` for thornier problems).
    agent.state.thinkingLevel = thinkingLevel

    // --- TUI (inline, native-scroll) ------------------------------------
    //
    // Coding renders inline. Settled transcript
    // and the welcome card are committed to the terminal's native scrollback
    // via `runner.tui.commit(...)`, so the user can scroll back through
    // history with the trackpad. Only the live zone — running tool blocks,
    // the slash popup, and the prompt box — is redrawn in place each frame
    // by `frame`.
    let runner = TUIRunner(hideCursor: false)
    let renderer = TranscriptRenderer()
    renderer.displayWidth = runner.terminal.width
    let frame = CodingFrame(viewportHeight: runner.terminal.height)

    // Resolve the git branch once — used by the welcome card and the prompt
    // breadcrumb. Cheap one-shot shell call; nil outside a repo.
    let gitBranch = GitInfo.currentBranch(cwd: cwd)

    // Welcome card — committed once to scrollback so it scrolls away
    // naturally as the conversation grows (omp / Claude Code behavior).
    // Recent sessions are real data pulled from the session store.
    let recent = await sessionStore.list().prefix(5).map { info -> WelcomeContext.RecentSession in
        let base = (info.cwd as NSString).lastPathComponent
        return WelcomeContext.RecentSession(
            name: base.isEmpty ? info.cwd : base,
            relativeTime: WelcomeScreen.relativeTime(fromMillis: info.updatedAt),
            messageCount: info.messageCount
        )
    }
    let welcomeCtx = WelcomeContext(
        version: KWWKBuild.version,
        modelId: model.id,
        providerName: ProviderAttribution.getProviderDisplayName(model.provider),
        cwd: cwd,
        branch: gitBranch,
        recentSessions: Array(recent)
    )
    // The welcome card is a re-renderable header (not committed text): it
    // prints once into scrollback on the first frame and is re-rendered at
    // the new width on resize so its box re-fits cleanly.
    runner.tui.headerProvider = { width in
        WelcomeScreen.render(welcomeCtx, width: width) + [""]
    }
    if resolvedResume.resumed {
        runner.tui.commit([
            Theme.faintText("  ↻ resumed session \(sessionId.prefix(8)) · \(resolvedResume.messages.count) messages"),
            "",
        ])
    }

    runner.tui.addChild(frame)
    runner.focus(frame.promptRow)

    // Paste plumbing: `onPaste` is called whenever the terminal
    // delivers a bracketed-paste sequence. We route it through the
    // AttachmentStore so long / multi-line bodies stay out of the
    // single-line input, and show up as compact tokens instead.
    let attachments = AttachmentStore()
    frame.input.onPaste = { body in
        handlePastedBody(
            body,
            input: frame.input,
            attachments: attachments,
            tui: runner.tui
        )
    }

    var frameMode: CodingFrameMode = .idle
    var runningBackgroundTasks = 0

    let updateFrameStatus: @MainActor @Sendable () -> Void = {
        let capacityHint = formatCapacityHint(
            usage: AgentContextCompactor.currentUsage(
                messages: agent.state.messages,
                model: agent.state.model
            ),
            threshold: autoCompactThreshold
        )
        frame.breadcrumb = promptBreadcrumb(model: agent.state.model, branch: gitBranch)
        frame.metaRight = promptMetaLabel(
            model: agent.state.model,
            thinkingLevel: agent.state.thinkingLevel,
            capacityHint: capacityHint
        )
        frame.stateLine = codingFrameStateLine(
            mode: frameMode,
            isStreaming: agent.state.isStreaming,
            runningBackgroundTasks: runningBackgroundTasks,
            queuedPrompts: agent.queuedSteeringCount(),
            spinner: frame.spinner
        )
        // Surface the pending queue as a live list above the input (omp-style).
        frame.queuedPrompts = agent.queuedSteeringMessages().map { queuedPromptPreview($0) }
        // Slash commands are idle-only; mirror that into the popup footer hint.
        frame.isBusy = agent.state.isStreaming
    }

    let recomputeTranscript: @MainActor @Sendable () -> Void = {
        frame.setLiveLines(renderer.liveLines)
    }

    // Modal overlay host — takes over the transcript area for selectors
    // (/model). Only one modal is active at a time; its bindings are
    // wired below via `modal.routeXxx`. On close we both restore the
    // live tail and drain any commits that accumulated while the modal was
    // up, so the retained transcript catches up to what the agent did in
    // the meantime.
    let modal = ModalHost(
        renderModalLines: { lines in frame.setModalLines(lines) },
        restoreTranscript: {
            let committed = renderer.drainCommits()
            if !committed.isEmpty { runner.tui.commit(committed) }
            recomputeTranscript()
            updateFrameStatus()
        },
        requestRender: { runner.tui.requestRender() }
    )

    _ = runner.terminal.onResize { w, h in
        Task { @MainActor in
            frame.setViewport(height: h)
            renderer.displayWidth = w
            if !modal.isOpen {
                recomputeTranscript()
            }
            updateFrameStatus()
            runner.tui.requestRender()
        }
    }

    /// Drain the renderer's commit buffer into retained transcript history.
    /// Called after every agent event + after modal close.
    ///
    /// While a modal is open we deliberately leave commits sitting in
    /// the renderer's buffer: flushing would mutate the transcript behind
    /// the selector and make the UI feel noisy. They drain on close.
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
    updateFrameStatus()

    // Retry bookkeeping for `/retry`: remembers the last submitted prompt and
    // whether its turn failed/aborted so it can be resubmitted on request.
    // Declared before the agent subscription so the `.agentEnd` listener can
    // flip `failed` when a run reports `.error` / `.aborted` — the genuine
    // failure signal lives on the event stream, not on a thrown error.
    let retry = TurnRetryState()

    // Keep the renderer's display mode in sync with the agent's state on
    // every event, so `/thinking show|hide` (which only mutates agent
    // state) takes effect on the next turn without extra plumbing.
    renderer.setThinkingDisplay(agent.state.thinkingDisplay)
    _ = agent.subscribe { event, _ in
        await MainActor.run {
            renderer.setThinkingDisplay(agent.state.thinkingDisplay)
            renderer.apply(event)
            // Settled rows move into retained history; live rows stay mutable
            // in the same full-screen frame. When a modal is open we keep the
            // transcript behind it stable and drain pending rows on close.
            if !modal.isOpen {
                recomputeTranscript()
            }
            _ = flushCommits()
            switch event {
            case .agentStart:
                break
            case .agentEnd(_, let summary):
                frameMode = .idle
                // A genuine failure (retries exhausted, turn cap, abort) returns
                // NORMALLY from `agent.prompt()` — the executor error is caught
                // inside `runLifecycle` and surfaced as a synthetic `.agentEnd`
                // whose `summary.finalStopReason` is `.error` / `.aborted`. The
                // detached-task `catch` only fires for `AgentError.alreadyRunning`,
                // so this is the primary place `/retry` learns a turn failed.
                if turnEndedRetryable(summary) {
                    retry.failed = true
                }
            case .compactStart(let count, _):
                isAutoCompacting = true
                frameMode = .compacting(messageCount: count)
                runner.tui.commit([
                    "",
                    Style.dimmed("  ◐ auto-compacting \(count) messages…"),
                ])
            case .compactEnd(let outcome):
                isAutoCompacting = false
                frameMode = .idle
                switch outcome {
                case .compacted(let n, let hasLedger):
                    runner.tui.commit(renderCompactBoundary(
                        messagesCompacted: n,
                        hasRunningTasksLedger: hasLedger,
                        width: runner.terminal.width
                    ))
                case .refusedAgentBusy:
                    runner.tui.commit([
                        "",
                        Style.error("  auto-compact: agent is busy; compact skipped"),
                        "",
                    ])
                case .refusedTooFewMessages:
                    break
                case .failed(let msg):
                    runner.tui.commit([
                        "",
                        Style.error("  auto-compact failed: \(msg)"),
                        "",
                    ])
                }
            case .streamRetry(let attempt, let delayMs, let reason):
                frameMode = .retrying(
                    attempt: attempt,
                    until: Date().addingTimeInterval(Double(delayMs) / 1000.0),
                    reason: reason
                )
            case .messageStart:
                frameMode = .idle
            case .messageUpdate:
                break
            default: break
            }
            updateFrameStatus()
            runner.tui.requestRender()
        }
    }

    // Single submission path. Fires the prompt on a detached task (so the UI
    // keeps pumping while it streams), records it for `/retry`, and flips the
    // retry flag on failure. Both the Enter handler and `/retry` funnel through
    // here so a resubmit drives the exact same streaming/steering UI as a fresh
    // submission.
    let submitBuiltPrompt: @MainActor @Sendable (String, [ImageContent]) -> Void = { text, images in
        retry.lastText = text
        retry.lastImages = images
        retry.failed = false
        Task.detached {
            do {
                try await agent.prompt(text, images: images)
            } catch {
                await MainActor.run {
                    retry.failed = true
                    runner.tui.commit([
                        "",
                        Style.error("  error: \(error)"),
                    ])
                    updateFrameStatus()
                    runner.tui.requestRender()
                }
            }
        }
    }

    // Slash command registry. Handlers get a `SlashContext` with the agent,
    // modal host, and a `notify` hook that appends into retained history.
    let slashRegistry = SlashCommandRegistry()
    registerBuiltinSlashCommands(slashRegistry)
    // User/project prompt-template commands (`.kwwk/commands/*.md`,
    // `~/.kwwk/commands/*.md`). Registered after builtins so a custom file
    // can't shadow a core command; their handlers render the template against
    // the invocation args and submit it as an ordinary prompt.
    CustomSlashCommandLoader.register(into: slashRegistry, cwd: cwd)

    // `/resume` — restore a previous session into the running TUI. Opens an
    // arrow-key picker; on confirm it repoints persistence at the chosen
    // session file, swaps the agent's message history, and repaints a recap.
    slashRegistry.register(SlashCommand(
        name: "resume",
        description: "Restore a previous session",
        handler: { _, _ in
            let sessions = await sessionStore.list()
            let picker = SessionResumeModal(
                sessions: sessions,
                currentSessionId: recorderBox.sessionId,
                onSelect: { info in
                    Task { @MainActor in
                        let loaded = await sessionStore.resolveResume(.id(info.id), cwd: cwd)

                        // Repoint persistence at the restored session.
                        recorderBox.unsubscribe()
                        let recorder = SessionRecorder(
                            store: sessionStore,
                            sessionId: info.id,
                            cwd: cwd,
                            model: agent.state.model.id,
                            provider: agent.state.model.provider,
                            persistedCount: loaded.persistedCount
                        )
                        recorderBox.recorder = recorder
                        recorderBox.unsubscribe = recorder.attach(to: agent)
                        recorderBox.sessionId = info.id

                        // Swap the live context + commit a readable recap to
                        // scrollback. Native scrollback can't be cleared, so
                        // the prior conversation stays above and the restored
                        // one is appended below a labeled separator.
                        agent.state.messages = loaded.messages
                        var recap: [String] = [
                            "",
                            Theme.borderText(String(repeating: "─", count: max(8, runner.terminal.width - 2))),
                            Theme.accentText("↻ resumed session \(info.id.prefix(8)) · \(loaded.messages.count) messages", bold: false),
                        ]
                        let snapshot = TranscriptSnapshot.render(loaded.messages, width: runner.terminal.width)
                        if !snapshot.isEmpty { recap.append(contentsOf: [""] + snapshot) }
                        runner.tui.commit(recap)

                        modal.close()
                        recomputeTranscript()
                        updateFrameStatus()
                        runner.tui.requestRender()
                    }
                },
                onCancel: { modal.close() }
            )
            modal.open(picker)
        }
    ))

    // `/new` (alias `/clear`) — start a fresh, empty session mid-run without
    // leaving the TUI. Mirrors `/resume`'s persistence hot-swap but mints a
    // brand-new id and clears the live context instead of loading one.
    slashRegistry.register(SlashCommand(
        name: "new",
        description: "Start a fresh session",
        aliases: ["clear"],
        handler: { _, _ in
            await performNewSession(
                recorderBox: recorderBox,
                sessionStore: sessionStore,
                agent: agent,
                cwd: cwd,
                attachments: attachments,
                retry: retry,
                frame: frame,
                width: runner.terminal.width,
                commit: { runner.tui.commit($0) },
                recompute: recomputeTranscript,
                updateStatus: updateFrameStatus,
                requestRender: { runner.tui.requestRender() }
            )
        }
    ))

    // `/retry` — resubmit the last prompt when its turn ended in error or was
    // aborted. Idle-gated by the dispatcher; resubmission goes through the
    // normal streaming path so queued/steer UI behaves identically.
    slashRegistry.register(SlashCommand(
        name: "retry",
        description: "Resubmit the last failed/aborted prompt",
        handler: { ctx, _ in
            guard retry.failed, let text = retry.lastText else {
                ctx.notify(Style.dimmed("  /retry: nothing to retry"))
                return
            }
            ctx.notify(Style.dimmed("  ↻ retrying…"))
            submitBuiltPrompt(text, retry.lastImages)
        }
    ))

    let slashCommandInfos = slashRegistry.all.map {
        SlashCommandInfo(name: $0.name, description: $0.description, aliases: $0.aliases)
    }
    frame.slashCommands = slashCommandInfos
    frame.promptRow.ghostHintProvider = { input in
        // Suppress the inline ghost suffix while the slash popup is open — the
        // menu already shows (and highlights) the completion target, so a
        // second dimmed copy after the cursor is redundant. Reserve the ghost
        // for the no-popup case.
        guard !frame.slashMenuActive else { return nil }
        return slashCompletion(for: input, commands: slashCommandInfos)?.suffix
    }
    let slashContext = SlashContext(
        agent: agent,
        modal: modal,
        backgroundManager: bgManager,
        sessionId: sessionId,
        notifyBlock: { lines in
            guard !lines.isEmpty else { return }
            // "Every transcript block opens with a leading blank, never
            // closes with one" — the whole notification is one block so
            // we prepend exactly one blank regardless of how many lines
            // the caller supplies.
            runner.tui.commit([""] + lines)
            updateFrameStatus()
            runner.tui.requestRender()
        },
        commitScrollback: { render in
            let lines = render(runner.terminal.width)
            guard !lines.isEmpty else { return }
            runner.tui.commit(lines)
            updateFrameStatus()
            runner.tui.requestRender()
        },
        refreshTranscript: {
            renderer.setThinkingDisplay(agent.state.thinkingDisplay)
            recomputeTranscript()
            updateFrameStatus()
            runner.tui.requestRender()
        },
        recordCompaction: { messagesCompacted in
            await recorderBox.recorder.recordCompaction(
                messages: agent.state.messages,
                messagesCompacted: messagesCompacted
            )
        },
        setSessionTitle: { title in
            await recorderBox.recorder.recordTitle(title)
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
            // Slash popup open → resolve the highlighted command, so Enter on
            // `/comp` runs `/compact` rather than failing on the partial name.
            var text = frame.input.value
            if frame.slashMenuActive, let name = frame.selectedSlashCommandName() {
                text = "/\(name)"
            }
            guard !text.isEmpty else { return }

            let parsed = SlashInput.parse(text)
            let busy = agent.state.isStreaming || isAutoCompacting

            // Slash commands are idle-only. If the agent is mid-turn
            // we can't reliably run them (some mutate agent state, all
            // would need to interleave output with streaming). Keeping
            // the gate simple means we never need a floating
            // "notification block" to surface their output — they
            // always append to history on a quiet moment.
            if case .command = parsed, busy {
                runner.tui.commit([
                    "",
                    Style.error("  slash commands run only when the agent is idle — stop it first (Esc) or wait"),
                    "",
                ])
                updateFrameStatus()
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
                // Record the steered prompt as the most-recent submission so
                // `/retry` (after an Esc-abort of this turn) resubmits what was
                // actually queued, not the prior direct prompt. `submitBuiltPrompt`
                // only records on the idle path, so the steer branch must do it.
                retry.lastText = built.text
                retry.lastImages = built.images
                attachments.clear()
                frame.input.addToHistory(text)
                frame.input.value = ""
                // No scrollback notice: the queued prompt now shows live in
                // the pending list above the input box (updateFrameStatus
                // syncs frame.queuedPrompts), where it can be edited (Alt+↑)
                // or dropped (/queue clear) until the agent drains it.
                // Surface only attach problems.
                if let issues = built.issues {
                    runner.tui.commit([
                        "",
                        Style.error("  attach: " + issues),
                    ])
                }
                updateFrameStatus()
                runner.tui.requestRender()
                return
            }

            frame.input.value = ""
            updateFrameStatus()
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
                    updateFrameStatus()
                    runner.tui.requestRender()
                }
            case .prompt:
                // Recall ring: store the raw submission so Up/Down can bring
                // it back (input was already cleared above).
                frame.input.addToHistory(text)
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
                    updateFrameStatus()
                    runner.tui.requestRender()
                }
                submitBuiltPrompt(built.text, built.images)
            }
        }
    }

    runner.bind(.init("tab")) { _ in
        Task { @MainActor in
            guard !modal.isOpen else { return }
            // Slash popup open → complete to the highlighted command (which
            // may differ from the alphabetically-first ghost completion).
            if frame.slashMenuActive, let name = frame.selectedSlashCommandName() {
                frame.input.value = "/\(name) "
                frame.input.moveEnd()
            } else if frame.input.cursor == frame.input.value.count,
               let completion = slashCompletion(for: frame.input.value, commands: slashCommandInfos) {
                frame.input.value = completion.completedInput
                frame.input.moveEnd()
            } else {
                frame.input.insert("\t")
            }
            runner.tui.requestRender()
        }
    }

    // Arrow keys drive whichever overlay is up: a modal selector or the
    // slash-command popup. With neither open they recall prompt history —
    // gated to the first/last hard row of the editor so a multi-line draft
    // keeps in-text navigation once that lands.
    runner.bind(.init("up")) { _ in
        Task { @MainActor in
            if modal.isOpen { modal.routeUp() }
            else if frame.slashMenuActive { frame.menuMove(-1); runner.tui.requestRender() }
            else if frame.input.navigateHistoryUp() { updateFrameStatus(); runner.tui.requestRender() }
        }
    }
    runner.bind(.init("down")) { _ in
        Task { @MainActor in
            if modal.isOpen { modal.routeDown() }
            else if frame.slashMenuActive { frame.menuMove(1); runner.tui.requestRender() }
            else if frame.input.navigateHistoryDown() { updateFrameStatus(); runner.tui.requestRender() }
        }
    }

    // Option+↑ — pop the most recently queued prompt back into the input so
    // the user can edit it or drop it (omp's dequeue, LIFO). Guarded so we
    // never clobber a draft the user is mid-composing: it fires only when the
    // input is empty OR still holds the previously-popped prompt unedited. In
    // the latter case it keeps cycling — the popped prompt is pushed back to
    // the front of the queue and the next item is surfaced, rotating through
    // all queued prompts without losing any. The popped text is flattened to a
    // single line for the one-line editor.
    let dequeueCycle = DequeueCycleState()
    runner.bind(.alt("up")) { _ in
        Task { @MainActor in
            guard !modal.isOpen, !frame.slashMenuActive else { return }
            guard let newValue = dequeueCycleStep(
                input: frame.input.value,
                state: dequeueCycle,
                agent: agent
            ) else { return }
            frame.input.value = newValue
            frame.input.moveEnd()
            updateFrameStatus()
            runner.tui.requestRender()
        }
    }

    // Ctrl-C: always exits (single tap). Keep it as the hard-stop key so
    // there's always a predictable way out.
    runner.bind(.ctrl("c")) { _ in
        Task { @MainActor in
            await agent.abortAndKillBackgroundTasks()
            runner.exit()
        }
    }

    // Ctrl-D on an empty input: EOF-style exit, the same teardown path as
    // Ctrl-C. With text in the buffer it's a no-op (the editor doesn't bind
    // forward-delete to it), so an accidental Ctrl-D mid-draft never quits.
    runner.bind(.ctrl("d")) { _ in
        Task { @MainActor in
            guard !modal.isOpen, frame.input.value.isEmpty else { return }
            await agent.abortAndKillBackgroundTasks()
            runner.exit()
        }
    }

    // Ctrl-L: force an authoritative repaint of the visible window. The
    // conventional "redraw" key — recovers cleanly when a background writer or
    // a flaky terminal resize has corrupted the on-screen frame.
    runner.bind(.ctrl("l")) { _ in
        runner.tui.forceRepaint()
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
                frameMode = .aborting
                // The active turn was interrupted — mark it retryable so
                // `/retry` can resubmit the prompt that was streaming. The
                // resulting `.agentEnd(.aborted)` also flips this flag via
                // `turnEndedRetryable`; setting it here too is idempotent and
                // gives immediate feedback before the loop unwinds.
                retry.failed = true
                runner.tui.commit([
                    "",
                    Style.dimmed("  aborting…"),
                ])
                updateFrameStatus()
                runner.tui.requestRender()
                return
            }
            let running = await bgManager.list(sessionId: sessionId)
                .filter { $0.status == .running }.count
            if running > 0 {
                await bgManager.killAll(sessionId: sessionId)
                runningBackgroundTasks = 0
                runner.tui.commit([
                    "",
                    Style.dimmed("  killed \(running) background \(running == 1 ? "task" : "tasks")"),
                ])
                updateFrameStatus()
                runner.tui.requestRender()
            }
            // No bg tasks, nothing streaming → Esc does nothing. The
            // user exits via Ctrl-C.
        }
    }

    // Background-task poll. Refreshes the "N bg running" count + retry/abort
    // countdowns at a relaxed 250ms cadence. The spinner is NOT advanced here
    // anymore — it has its own faster tick below — so a slow bg poll can't make
    // the animation visibly step.
    let frameStatusTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 250_000_000)
        while !Task.isCancelled {
            let running = await bgManager.list(sessionId: sessionId)
                .filter { $0.status == .running }.count
            runningBackgroundTasks = running
            updateFrameStatus()
            runner.tui.requestRender()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // Dedicated spinner tick, decoupled from the bg poll. ~90ms gives the
    // 10-frame braille set a smooth, continuous spin. We only advance + repaint
    // while something is actually animating (streaming, compacting, aborting,
    // retrying), so an idle prompt isn't redrawn ~11×/s for no reason.
    let spinnerTask = Task { @MainActor in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard agent.state.isStreaming || isAutoCompacting || frameMode.isActive else { continue }
            frame.tick()
            updateFrameStatus()
            runner.tui.requestRender()
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
        frameStatusTask.cancel()
        spinnerTask.cancel()
        await shutdown()
        throw error
    }
    frameStatusTask.cancel()
    spinnerTask.cancel()
    await shutdown()
}

// MARK: - Helpers

/// Mutable holder for the live session recorder + its agent subscription.
/// `/resume` swaps both to repoint persistence at the restored session file;
/// a reference type lets the resume closure mutate them without capturing a
/// `var` (rejected under Swift 6 strict concurrency).
@MainActor
final class RecorderBox {
    var recorder: SessionRecorder
    var unsubscribe: Unsubscribe
    var sessionId: String

    init(recorder: SessionRecorder, unsubscribe: @escaping Unsubscribe, sessionId: String) {
        self.recorder = recorder
        self.unsubscribe = unsubscribe
        self.sessionId = sessionId
    }
}

/// Tracks the most recent prompt submission so `/retry` can resubmit it when
/// the turn ended in error or was interrupted. A reference type so the submit
/// path, the failure edges (catch / Esc-abort), and the `/retry` handler all
/// share one mutable record under Swift 6 strict concurrency.
@MainActor
final class TurnRetryState {
    /// The built prompt text of the last submission (already attachment-expanded).
    var lastText: String?
    /// The built image attachments of the last submission.
    var lastImages: [ImageContent] = []
    /// True when the last turn ended in error or was aborted — the only state
    /// in which `/retry` resubmits.
    var failed = false
}

/// Concatenated text of a queued user message's text blocks (image blocks
/// are ignored). Used to restore a popped prompt back into the editor.
@MainActor
func queuedMessageBodyText(_ msg: Message) -> String {
    guard case .user(let u) = msg else { return "" }
    return u.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined(separator: "\n")
}

/// One-line preview of a queued prompt for the live pending list: text blocks
/// flattened onto a single line, with an `[image]` marker appended when the
/// queued message also carries image content.
@MainActor
func queuedPromptPreview(_ msg: Message) -> String {
    var text = queuedMessageBodyText(msg).replacingOccurrences(of: "\n", with: " ")
    if case .user(let u) = msg,
       u.content.contains(where: { if case .image = $0 { return true } else { return false } }) {
        text = text.isEmpty ? "[image]" : text + "  [image]"
    }
    return text
}

private enum CodingFrameMode {
    case idle
    case aborting
    case compacting(messageCount: Int)
    case retrying(attempt: Int, until: Date, reason: String)

    /// True whenever the state line is showing a spinner (anything but plain
    /// idle). Drives the dedicated spinner tick so we only repaint at the
    /// fast cadence while something is actually animating.
    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// Tracks the prompt most recently popped back into the editor by Alt+↑ so a
/// repeat press can keep cycling through the remaining queued items instead of
/// stopping after one. Reference type so the @MainActor keybinding closures can
/// mutate it without capturing a `var` (rejected under Swift 6 concurrency).
@MainActor
final class DequeueCycleState {
    var last: Message?
}

/// Whether a finished run should be marked retryable for `/retry`: true when it
/// ended in a hard error (retries exhausted / turn cap / synthetic failure) or
/// was aborted by the user. This is the authoritative failure signal — genuine
/// failures return normally from `agent.prompt()` and surface only as an
/// `.agentEnd` whose `summary.finalStopReason` is `.error` / `.aborted`.
func turnEndedRetryable(_ summary: AgentRunSummary) -> Bool {
    summary.finalStopReason == .error || summary.finalStopReason == .aborted
}

/// Start a fresh, empty session in place: repoint persistence at a brand-new
/// session file, clear the live agent context + steering queue, reset retry and
/// attachment state, and commit a labeled separator to scrollback. Extracted
/// from the `/new` handler so the reset is unit-testable.
@MainActor
func performNewSession(
    newId: String = UUID().uuidString,
    recorderBox: RecorderBox,
    sessionStore: SessionStore,
    agent: Agent,
    cwd: String,
    attachments: AttachmentStore,
    retry: TurnRetryState,
    frame: CodingFrame,
    width: Int,
    commit: ([String]) -> Void,
    recompute: () -> Void,
    updateStatus: () -> Void,
    requestRender: () -> Void
) async {
    // Repoint persistence at a brand-new session file.
    recorderBox.unsubscribe()
    let recorder = SessionRecorder(
        store: sessionStore,
        sessionId: newId,
        cwd: cwd,
        model: agent.state.model.id,
        provider: agent.state.model.provider,
        persistedCount: 0
    )
    await recorder.ensureCreated()
    recorderBox.recorder = recorder
    recorderBox.unsubscribe = recorder.attach(to: agent)
    recorderBox.sessionId = newId

    // Reset the live context. Native scrollback can't be cleared, so the prior
    // conversation stays above a labeled separator and the fresh session begins
    // below it.
    agent.state.messages = []
    agent.clearSteeringQueue()
    attachments.clear()
    frame.input.value = ""
    retry.failed = false
    retry.lastText = nil
    retry.lastImages = []

    commit([
        "",
        Theme.borderText(String(repeating: "─", count: max(8, width - 2))),
        Theme.accentText("✦ new session \(newId.prefix(8))", bold: false),
    ])

    recompute()
    updateStatus()
    requestRender()
}

/// One Alt+↑ dequeue-cycle step. Returns the new single-line input value to
/// install, or `nil` for a no-op (the editor holds an edited draft, or the
/// steering queue is empty). Extracted from the keybinding so the cycle logic —
/// draft protection, LIFO rotation, and newline flattening — is unit-testable.
///
/// `input` is the current editor text; `state.last` is the prompt most recently
/// popped back into the editor. When `input` still equals that popped prompt
/// (unedited), the prompt is returned to the front of the queue before the next
/// pop, so repeated presses rotate through every queued item without loss.
@MainActor
func dequeueCycleStep(input: String, state: DequeueCycleState, agent: Agent) -> String? {
    let matchesLast = state.last.map {
        input == queuedMessageBodyText($0).replacingOccurrences(of: "\n", with: " ")
    } ?? false
    // Never clobber a draft the user is mid-composing.
    guard input.isEmpty || matchesLast else { return nil }
    // Cycling onward: return the unedited prompt to the front so the next pop
    // walks back to the prior item rather than re-popping it.
    if matchesLast, let last = state.last {
        agent.pushFrontSteeringMessage(last)
    }
    guard let msg = agent.popLastSteeringMessage() else {
        state.last = nil
        return nil
    }
    state.last = msg
    return queuedMessageBodyText(msg).replacingOccurrences(of: "\n", with: " ")
}

/// Top-border breadcrumb for the prompt box: the live model id, then the
/// git branch when inside a repo. Already styled.
private func promptBreadcrumb(model: Model, branch: String?) -> String {
    var out = Theme.accentText(model.id, bold: false)
    if let branch, !branch.isEmpty {
        out += Theme.faintText("  ⎇ \(branch)")
    }
    return out
}

/// Bottom-border right label for the prompt box: reasoning effort + context
/// usage. The capacity portion glows amber once auto-compact is imminent.
private func promptMetaLabel(
    model: Model,
    thinkingLevel: ThinkingLevel,
    capacityHint: String
) -> String {
    var parts: [String] = []
    if model.reasoning {
        parts.append(Theme.faintText("reasoning \(thinkingLevel.rawValue)"))
    }
    let capacity = ANSI.stripEscapes(capacityHint)
    if !capacity.isEmpty {
        let short = capacity.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? capacity
        parts.append(short.hasPrefix("●") ? Theme.paint(short, Theme.warn) : Theme.faintText(short))
    }
    return parts.joined(separator: Theme.faintText(" · "))
}

private func codingFrameStateLine(
    mode: CodingFrameMode,
    isStreaming: Bool,
    runningBackgroundTasks: Int,
    queuedPrompts: Int,
    spinner: String
) -> String {
    var parts: [String] = []

    switch mode {
    case .compacting(let count):
        parts.append(Theme.paint("\(spinner) auto-compacting \(count)", Theme.warn, bold: true))
        parts.append(Theme.faintText("new prompts queue"))
    case .aborting:
        parts.append(Theme.paint("\(spinner) aborting", Theme.warn, bold: true))
        parts.append(Theme.faintText("Ctrl-C to force quit"))
    case .retrying(let attempt, let until, let reason):
        let remaining = max(0, until.timeIntervalSinceNow)
        let countdown = remaining >= 1.0 ? "\(Int(remaining.rounded(.up)))s" : "now"
        parts.append(Theme.paint("\(spinner) retry \(attempt + 2)/5 in \(countdown)", Theme.warn, bold: true))
        if !reason.isEmpty {
            parts.append(Theme.faintText(String(reason.prefix(40))))
        }
        parts.append(Theme.faintText("Esc to cancel"))
    case .idle:
        if isStreaming {
            parts.append(Theme.paint("\(spinner) generating", Theme.accent, bold: true))
            parts.append(Theme.faintText("Esc to cancel"))
        } else {
            parts.append(Theme.faintText("/ commands · @ attach · ⇧⏎ newline"))
        }
    }

    if queuedPrompts > 0 {
        parts.append(Theme.paint("\(queuedPrompts) queued", Theme.accentDim))
    }
    if runningBackgroundTasks > 0 {
        parts.append(Theme.paint("\(runningBackgroundTasks) bg running", Theme.accentDim))
        if !isStreaming {
            parts.append(Theme.faintText("Esc to stop"))
        }
    }

    return parts.joined(separator: Theme.faintText("  ·  "))
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
