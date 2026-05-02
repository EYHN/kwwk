import Foundation
import KWWKAI
import KWWKAgent

/// Internal implementation of the coding-agent TUI. Public entry points
/// live on `KWWK` (see KWWK.swift) and resolve credentials before calling
/// in here. `@MainActor` because `TranscriptRenderer`, `CodingStatusBar`,
/// and the TUI layout mutate main-thread-only state.
@MainActor
func runCodingTUIInternal(
    model: Model,
    modelLabel: String,
    cwd: String,
    tools: CodingTools,
    builtinSubagents: BuiltinSubagentSelection = .all,
    authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
    autoCompactThreshold: Double? = 0.75,
    thinkingLevel: ThinkingLevel = .medium
) async throws {
    // --- agent + background manager -------------------------------------
    let bgManager = BackgroundTaskManager()
    let sessionId = UUID().uuidString
    let agent = await makeCodingAgent(CodingAgentConfig(
        model: model,
        cwd: cwd,
        tools: tools,
        backgroundManager: bgManager,
        subagents: defaultCLISubagents(for: tools, selection: builtinSubagents),
        sessionId: sessionId,
        authResolver: authResolver
    ))
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
    let layout = CodingLayout(statusRows: 1)
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
    _ = runner.terminal.onResize { w, h in
        Task { @MainActor in
            layout.fitViewport(height: h, width: w)
            runner.tui.requestRender()
        }
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
    // `recomputeTranscript` rebuilds the live tail (streaming body +
    // running tool markers) from the renderer's current state. Before
    // reading the tail we let the renderer spill any streaming-body
    // overflow into its commit buffer — that way long assistant turns
    // scroll into native scrollback as they stream instead of just
    // clipping at the top of the viewport.
    let recomputeTranscript: @MainActor @Sendable () -> Void = {
        renderer.applyLiveBudget(layout.liveTailBudget, reserved: 0)
        layout.setLiveTail(renderer.liveLines)
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

    /// Drain the renderer's commit buffer and forward to the TUI so the
    /// newly-settled lines show up above the live zone on the next
    /// render. Called after every agent event + after modal close.
    ///
    /// While a modal is open we deliberately leave commits sitting in
    /// the renderer's buffer: flushing would print history lines above
    /// the modal and make the UI feel noisy. They drain on close.
    let flushCommits: @MainActor @Sendable () -> Void = {
        guard !modal.isOpen else { return }
        let committed = renderer.drainCommits()
        if !committed.isEmpty {
            runner.tui.commit(committed)
        }
    }

    // Queue panel: a persistent listing of steering messages waiting
    // for a turn boundary, rendered between the status bar and the
    // prompt. Rebuilt from `agent.queuedSteeringMessages()` whenever
    // something might have changed the queue:
    //   - Enter handler after an implicit steer.
    //   - `/queue clear` outcome.
    //   - Every agent event (turn boundaries drain the queue).
    //   - The 500ms poll tick already used by the status bar.
    //
    // The panel collapses to zero rows when empty, so the transcript
    // reclaims the space — no wasted real estate when idle.
    let refreshQueuePanel: @MainActor @Sendable () -> Void = {
        let messages = agent.queuedSteeringMessages()
        if messages.isEmpty {
            layout.setQueueLines([])
            return
        }
        var lines: [String] = [
            Style.dimmed("  ↓ \(messages.count) queued \(messages.count == 1 ? "prompt" : "prompts"):")
        ]
        for (i, msg) in messages.enumerated() {
            let preview = previewQueuedMessageLine(msg)
            lines.append(Style.dimmed("    \(i + 1). \(preview)"))
        }
        layout.setQueueLines(lines)
    }
    refreshQueuePanel()

    let statusBar = CodingStatusBar(
        layout: layout,
        runner: runner,
        agent: agent,
        bgManager: bgManager,
        sessionId: sessionId
    )
    await statusBar.render()

    // Auto-compact controller. Watches per-turn usage and summarizes
    // the transcript when it approaches the model's contextWindow.
    // The controller fires `performCompact` only on `agentEnd` so we
    // never rewrite `agent.state.messages` while the loop is mid-flight.
    let autoCompact = AutoCompactController(
        agent: agent,
        backgroundManager: bgManager,
        sessionId: sessionId,
        threshold: autoCompactThreshold,
        onStatusChange: { status in
            switch status {
            case .compacting(let count):
                statusBar.setCompacting(messageCount: count)
                // Leave a visible trail in scrollback so history shows
                // WHEN the compact started — the terminating boundary
                // line in onCompactFinished pairs with this one to
                // frame the compact block.
                runner.tui.commit([
                    "",
                    Style.dimmed("  ◐ auto-compacting…"),
                ])
                runner.tui.requestRender()
            case .idle:
                statusBar.setMode(.idle)
            }
        },
        onUsageChange: { usage in
            statusBar.setCapacityHint(formatCapacityHint(
                usage: usage,
                threshold: autoCompactThreshold
            ))
            Task { @MainActor in
                await statusBar.render()
                runner.tui.requestRender()
            }
        },
        onCompactFinished: { outcome in
            switch outcome {
            case .compacted(let n, let hasLedger):
                // The start marker was already committed in onStatusChange
                // when the compact began; just add the terminating
                // boundary here so the pair frames the compact block.
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
            runner.tui.requestRender()
        }
    )

    // Install the between-turns compact hook. The agent loop calls this
    // synchronously at each sub-turn boundary; if it returns a
    // replacement context, the loop swaps in the summarized transcript
    // before the next LLM request. User input typed during the compact
    // lands in the steering queue via the `busy` branch below and
    // drains at the next turnStart.
    agent.betweenTurns = { context, _ in
        await autoCompact.maybeCompactInline(context: context)
    }

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
            flushCommits()
            switch event {
            case .agentStart:
                statusBar.setMode(.streaming)
            case .agentEnd:
                // Only flip to idle when no auto-compact took over.
                // `observe(event:)` below runs synchronously-enough that
                // its status-change callback beats this switch, so if
                // a compact is about to fire the bar will read
                // "auto-compacting…" on the next render.
                if !autoCompact.isCompacting {
                    statusBar.setMode(.idle)
                }
            case .streamRetry(let attempt, let delayMs, let reason):
                statusBar.setRetrying(attempt: attempt, delayMs: delayMs, reason: reason)
            case .messageStart, .messageUpdate:
                // A new stream is producing output again — drop the
                // retrying banner. We don't fall out of retrying on the
                // next `streamRetry` (back-to-back failures): setRetrying
                // simply overwrites the payload with fresher info.
                statusBar.setMode(.streaming)
            default: break
            }
            // The agent loop drains the steering queue at turn
            // boundaries — refresh the panel on every event so a
            // queued prompt disappears as soon as it enters context.
            refreshQueuePanel()
            layout.fitViewport(height: runner.terminal.height, width: runner.terminal.width)
            runner.tui.requestRender()
        }
        await autoCompact.observe(event)
        await statusBar.render()
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
            let busy = agent.state.isStreaming || autoCompact.isCompacting

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
            // `alreadyRunning`. The queue panel above the input
            // shows what's waiting.
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
                // Surface only attach problems — a clean queueing
                // needs no confirmation, the queue panel already
                // shows the pending item.
                if let issues = built.issues {
                    runner.tui.commit([
                        "",
                        Style.error("  attach: " + issues),
                        "",
                    ])
                }
                refreshQueuePanel()
                runner.tui.requestRender()
                return
            }

            layout.input.value = ""
            runner.tui.requestRender()

            switch parsed {
            case .command(let name, let args):
                if let cmd = slashRegistry.find(name) {
                    await cmd.handler(slashContext, args)
                    // `/queue clear` (and maybe future commands) may
                    // mutate the steering queue — refresh so the
                    // panel above the input stays accurate.
                    refreshQueuePanel()
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
                            layout.status.lines = [Style.error("error: \(error)")]
                            runner.tui.requestRender()
                        }
                    }
                }
            }
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
                statusBar.setMode(.aborting)
                await statusBar.render()
                return
            }
            let running = await bgManager.list(sessionId: sessionId)
                .filter { $0.status == .running }.count
            if running > 0 {
                await bgManager.killAll(sessionId: sessionId)
                statusBar.flashKilled(count: running)
                await statusBar.render()
            }
            // No bg tasks, nothing streaming → Esc does nothing. The
            // user exits via Ctrl-C.
        }
    }

    // Periodic refresh so the background-task count + queue panel stay
    // live even when there aren't any agent events firing. 500ms is
    // invisibly slow for a human but cheap — just an actor dict count
    // and a queue snapshot.
    let pollTask = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await statusBar.render()
            await MainActor.run {
                refreshQueuePanel()
                // Tick the collapsed-thinking elapsed counter while a
                // thinking block is open so seconds advance even without
                // new provider deltas. No-op otherwise.
                if renderer.hasActiveThinking {
                    recomputeTranscript()
                    runner.tui.requestRender()
                }
            }
        }
    }
    defer { pollTask.cancel() }

    let shutdown: @MainActor @Sendable () async -> Void = {
        // Kill any still-running background tasks, close provider-held
        // session resources, and tear down the isolated tmux socket so we
        // don't leak processes after the user exits.
        pollTask.cancel()
        await agent.abortAndKillBackgroundTasks()
        await agent.closeSession()
        await TmuxSessionManager.shared.teardown()
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

/// Flatten a queued user message to a single truncated line for the
/// queue panel above the input. Multi-line bodies collapse to spaces
/// so the panel's row count stays predictable (1 per queued message
/// plus a header line).
func previewQueuedMessageLine(_ msg: Message, max: Int = 100) -> String {
    let raw: String = {
        switch msg {
        case .user(let u):
            return u.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: " ")
        default:
            return "(\(msg.role.rawValue) message)"
        }
    }()
    let flat = raw.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
}
