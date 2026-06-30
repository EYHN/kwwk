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

    // --- TUI (full-screen retained frame) -------------------------------
    //
    // Coding runs in the alternate screen now: transcript, live tool calls,
    // status, modals, and prompt are one retained frame. We never mutate
    // native scrollback while the app is active, so terminal resize can no
    // longer reflow stale retained rows into repeated clear-line trails.
    let runner = TUIRunner(useAlternateScreen: true, hideCursor: false)
    let renderer = TranscriptRenderer()
    let resumedLine = resolvedResume.resumed
        ? "↻ resumed session \(sessionId.prefix(8)) · \(resolvedResume.messages.count) messages"
        : nil
    let frame = CodingFrame(
        cwd: cwd,
        resumedLine: resumedLine,
        viewportHeight: runner.terminal.height
    )
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
        frame.metadataLine = statusMetadataLine(
            model: agent.state.model,
            thinkingLevel: agent.state.thinkingLevel,
            thinkingDisplay: agent.state.thinkingDisplay,
            capacityHint: capacityHint,
            width: max(0, runner.terminal.width)
        )
        frame.stateLine = codingFrameStateLine(
            mode: frameMode,
            isStreaming: agent.state.isStreaming,
            runningBackgroundTasks: runningBackgroundTasks,
            queuedPrompts: agent.queuedSteeringCount(),
            spinner: frame.spinner
        )
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
            if !committed.isEmpty { frame.appendHistory(committed) }
            recomputeTranscript()
            updateFrameStatus()
        },
        requestRender: { runner.tui.requestRender() }
    )

    _ = runner.terminal.onResize { w, h in
        Task { @MainActor in
            frame.setViewport(height: h)
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
            frame.appendHistory(committed)
            return true
        }
        return false
    }

    var isAutoCompacting = false
    updateFrameStatus()

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
            case .agentEnd:
                frameMode = .idle
            case .compactStart(let count, _):
                isAutoCompacting = true
                frameMode = .compacting(messageCount: count)
                frame.appendHistory([
                    "",
                    Style.dimmed("  ◐ auto-compacting \(count) messages…"),
                ])
            case .compactEnd(let outcome):
                isAutoCompacting = false
                frameMode = .idle
                switch outcome {
                case .compacted(let n, let hasLedger):
                    frame.appendHistory(renderCompactBoundary(
                        messagesCompacted: n,
                        hasRunningTasksLedger: hasLedger,
                        width: runner.terminal.width
                    ))
                case .refusedAgentBusy:
                    frame.appendHistory([
                        "",
                        Style.error("  auto-compact: agent is busy; compact skipped"),
                        "",
                    ])
                case .refusedTooFewMessages:
                    break
                case .failed(let msg):
                    frame.appendHistory([
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

    // Slash command registry. Handlers get a `SlashContext` with the agent,
    // modal host, and a `notify` hook that appends into retained history.
    let slashRegistry = SlashCommandRegistry()
    registerBuiltinSlashCommands(slashRegistry)
    // User/project prompt-template commands (`.kwwk/commands/*.md`,
    // `~/.kwwk/commands/*.md`). Registered after builtins so a custom file
    // can't shadow a core command; their handlers render the template against
    // the invocation args and submit it as an ordinary prompt.
    CustomSlashCommandLoader.register(into: slashRegistry, cwd: cwd)
    let slashCommandNames = slashRegistry.all.map(\.name)
    frame.promptRow.ghostHintProvider = { input in
        slashCompletion(for: input, commandNames: slashCommandNames)?.suffix
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
            frame.appendHistory([""] + lines)
            updateFrameStatus()
            runner.tui.requestRender()
        },
        commitScrollback: { render in
            let lines = render(runner.terminal.width)
            guard !lines.isEmpty else { return }
            frame.appendHistory(lines)
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
            let text = frame.input.value
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
                frame.appendHistory([
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
                attachments.clear()
                frame.input.value = ""
                let queued = agent.queuedSteeringCount()
                frame.appendHistory([
                    "",
                    Style.dimmed("  queued prompt\(queued > 1 ? " (\(queued) waiting)" : "")"),
                ])
                // Surface only attach problems — a clean queueing
                // otherwise stays as the one-line queued prompt above.
                if let issues = built.issues {
                    frame.appendHistory([
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
                    frame.appendHistory([
                        "",
                        Style.error("  unknown slash command: /\(name)"),
                        "",
                    ])
                    updateFrameStatus()
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
                    frame.appendHistory([
                        "",
                        Style.error("  attach: " + issues),
                        "",
                    ])
                    updateFrameStatus()
                    runner.tui.requestRender()
                }
                let promptText = built.text
                let promptImages = built.images
                Task.detached {
                    do {
                        try await agent.prompt(promptText, images: promptImages)
                    } catch {
                        await MainActor.run {
                            frame.appendHistory([
                                "",
                                Style.error("  error: \(error)"),
                            ])
                            updateFrameStatus()
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
            if frame.input.cursor == frame.input.value.count,
               let completion = slashCompletion(for: frame.input.value, commandNames: slashCommandNames) {
                frame.input.value = completion.completedInput
                frame.input.moveEnd()
            } else {
                frame.input.insert("\t")
            }
            runner.tui.requestRender()
        }
    }

    // Arrow keys — only have meaning inside a modal (move selection).
    // Outside a modal they're no-ops for now; transcript scrolling can be
    // layered on top of the retained frame later.
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
                frameMode = .aborting
                frame.appendHistory([
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
                frame.appendHistory([
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

    let frameStatusTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 250_000_000)
        while !Task.isCancelled {
            let running = await bgManager.list(sessionId: sessionId)
                .filter { $0.status == .running }.count
            runningBackgroundTasks = running
            frame.tick()
            updateFrameStatus()
            runner.tui.requestRender()
            try? await Task.sleep(nanoseconds: 250_000_000)
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
        await shutdown()
        throw error
    }
    frameStatusTask.cancel()
    await shutdown()
}

// MARK: - Helpers

private enum CodingFrameMode {
    case idle
    case aborting
    case compacting(messageCount: Int)
    case retrying(attempt: Int, until: Date, reason: String)
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
        parts.append(Style.badge("\(spinner) compacting \(count)", fg: 16, bg: 178))
        parts.append(Style.badge("new prompts queue", bg: 238))
    case .aborting:
        parts.append(Style.badge("\(spinner) aborting", fg: 16, bg: 160))
        parts.append(Style.badge("Ctrl-C force quit", bg: 238))
    case .retrying(let attempt, let until, let reason):
        let remaining = max(0, until.timeIntervalSinceNow)
        let countdown = remaining >= 1.0 ? "\(Int(remaining.rounded(.up)))s" : "now"
        parts.append(Style.badge("retry \(attempt + 2)/5 \(countdown)", fg: 16, bg: 178))
        if !reason.isEmpty {
            parts.append(Style.badge(String(reason.prefix(40)), bg: 238))
        }
        parts.append(Style.badge("Esc cancel", bg: 238))
    case .idle:
        if isStreaming {
            parts.append(Style.badge("\(spinner) generating", fg: 16, bg: 178))
            parts.append(Style.badge("Esc cancel", bg: 238))
        } else {
            parts.append(Style.badge("ready", bg: 238))
        }
    }

    if queuedPrompts > 0 {
        parts.append(Style.badge("\(queuedPrompts) queued", bg: 61))
    }
    if runningBackgroundTasks > 0 {
        parts.append(Style.badge("\(runningBackgroundTasks) bg running", bg: 24))
        if !isStreaming {
            parts.append(Style.badge("Esc stop bg", bg: 238))
        }
    }

    return parts.joined()
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
