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
    authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
    providerSlots: [ProviderSlot] = [],
    authResolvers: SessionAuthResolvers? = nil,
    autoCompactThreshold: Double? = 0.75,
    thinkingLevel: ThinkingLevel = .medium,
    context1m: Bool = false,
    resume: SessionResume = .none
) async throws {
    // --- agent + background manager -------------------------------------
    let bgManager = BackgroundTaskManager()

    // Resolve session persistence up front: a fresh id by default, or a
    // stored transcript when `--resume` / `--session` was passed.
    let sessionStore = SessionStore(directory: SessionStore.defaultDirectory())
    // `--resume` opens the same polished arrow-key picker that `/resume` uses,
    // rather than a bare numbered stdin prompt. The picker needs the TUI +
    // ModalHost to exist, so we start in a fresh session and open the resume
    // modal on the first frame (see `openResumePickerOnStart` below); its
    // confirm handler hot-swaps persistence into the chosen session exactly
    // like `/resume`. Cancelling the picker leaves the fresh session in place.
    let openResumePickerOnStart = (resume == .pickInteractive)
    let effectiveResume: SessionResume = openResumePickerOnStart ? .none : resume
    let resolvedResume = try await sessionStore.resolveResume(effectiveResume, cwd: cwd)
    let initialSessionId = resolvedResume.sessionId

    let environment = ProcessInfo.processInfo.environment
    let initialCodingAgent = await makeCodingAgent(CodingAgentConfig(
        model: model,
        cwd: cwd,
        tools: tools,
        contextFiles: loadProjectContextFiles(cwd: cwd),
        skillDirectories: Skills.defaultDirectories(cwd: cwd, includeUserDirectory: true),
        backgroundManager: bgManager,
        subagents: defaultCLISubagents(
            for: tools,
            selection: builtinSubagents,
            runInBackgroundByDefault: true
        ),
        sessionId: initialSessionId,
        authResolver: authResolver,
        autoCompactThreshold: autoCompactThreshold,
        bashEnvironment: environment,
        bashShellPath: cliShellPath(environment: environment)
    ))
    let agentBox = AgentSessionBox(initialCodingAgent)
    // Local computed values deliberately resolve through the box on every
    // access. `/new` and `/resume` replace the entire CodingAgent so immutable
    // session-scoped tools, delivery mailboxes, and provider resources rotate
    // together instead of merely swapping messages under an old session id.
    var agent: Agent { agentBox.agent }
    var sessionId: String { agentBox.sessionId }

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
        sessionId: initialSessionId,
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
        sessionId: initialSessionId
    )
    defer { recorderBox.unsubscribe() }
    // Turn on extended thinking by default — otherwise reasoning-capable
    // providers never produce `[thinking]` blocks. The level is a user
    // intent: the agent loop filters it to `nil` when the live model
    // isn't reasoning-capable, so non-thinking models pay no cost and
    // `/model` switches flow naturally in either direction. Toggle via
    // `/thinking off` (or `high` / `xhigh` for thornier problems).
    agent.state.thinkingLevel = thinkingLevel

    // --- goal mode (in-memory, session-scoped) --------------------------
    // Shared by the `goal` tool, the `/goal` command, the status line, and
    // the agent-end continuation loop. Evaporates on process exit.
    let goalStore = GoalStore()
    // Expose the `goal` tool to the model. The loop reads `state.tools` fresh
    // each turn, so a post-build append is picked up without an agent rebuild.
    do {
        var goalTools = agent.state.tools
        goalTools.append(createGoalTool(store: goalStore))
        agent.state.tools = goalTools
    }
    // Base prompt captured once; the ACTIVE <goal_context> block is patched on
    // top while a goal is active and stripped when it clears. The loop re-reads
    // state.systemPrompt every turn, so this takes effect with no rebuild.
    let baseSystemPrompt = agent.state.systemPrompt
    let applyGoalContext: @MainActor @Sendable () -> Void = {
        let snap = goalStore.snapshot()
        agent.state.systemPrompt = snap.status == .active
            ? baseSystemPrompt + "\n\n" + GoalMode.activeContext(objective: snap.objective)
            : baseSystemPrompt
    }
    // --- TUI (inline, native-scroll) ------------------------------------
    //
    // Coding renders inline. Settled transcript
    // and the welcome card are committed to the terminal's native scrollback
    // via `runner.tui.commit(...)`, so the user can scroll back through
    // history with the trackpad. Only the live zone — running tool blocks,
    // the slash popup, and the prompt box — is redrawn in place each frame
    // by `frame`.
    let runner = TUIRunner()
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
    // Providers logged in this session — read by `/model` to list + route
    // across accounts, mutated by `/login` / `/logout`. Created up front so
    // the welcome header and the goal-continuation gate read live login state.
    let sessionProviders = SessionProviders(providerSlots)

    // Logged-out start: no provider slots and the sentinel model. The welcome
    // card and prompt breadcrumb swap in a "/login to sign in" hint instead
    // of rendering the sentinel's empty id.
    let launchedLoggedOut = providerSlots.isEmpty && model.provider.isEmpty
    let welcomeCtx = WelcomeContext(
        version: KWWKBuild.version,
        modelId: launchedLoggedOut ? "no provider" : model.id,
        providerName: launchedLoggedOut
            ? "not signed in"
            : ProviderAttribution.getProviderDisplayName(model.provider),
        cwd: cwd,
        branch: gitBranch,
        recentSessions: Array(recent),
        loggedOut: launchedLoggedOut
    )
    // The welcome card is a re-renderable header (not committed text): it
    // prints once into scrollback on the first frame and is re-rendered at
    // the new width on resize so its box re-fits cleanly. It renders from a
    // live snapshot, NOT the launch context: a resize full-repaint after
    // `/login`, `/logout`, or a `/model` switch must not re-print a stale
    // "not signed in" banner or model id. Sync contract: `headerProvider` is
    // @Sendable and runs on the render path, so it never reads @MainActor
    // state directly — it reads the lock-protected `WelcomeHeaderState`
    // snapshot, which `updateFrameStatus` (the MainActor choke point every
    // login/logout/model-switch notification already funnels through)
    // refreshes before each repaint.
    let welcomeHeader = WelcomeHeaderState(welcomeCtx)
    runner.tui.headerProvider = { width in
        WelcomeScreen.render(welcomeHeader.snapshot(), width: width) + [""]
    }
    if resolvedResume.resumed {
        // Replay the restored session's visual history into scrollback (the
        // same recap `/resume` paints), then the trailing session note.
        var recap = TranscriptSnapshot.render(
            resolvedResume.displayMessages, width: runner.terminal.width)
        recap.append(contentsOf: [
            "",
            Theme.faintText("  ↻ resumed session \(sessionId.prefix(8)) · \(resolvedResume.displayMessages.count) messages"),
            "",
        ])
        runner.tui.commit(recap)
    }

    runner.tui.addChild(frame)
    // Focus is installed below (after the modal host exists) via a
    // ModalInputRouter that offers raw input to an open modal before the
    // prompt row.

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

    let frameStatus = FrameStatusState()

    let updateFrameStatus: @MainActor @Sendable () -> Void = {
        frameStatus.reconcileMode(
            messageCount: agent.state.messages.count,
            isStreaming: agent.state.isStreaming
        )
        let capacityHint = formatCapacityHint(
            usage: AgentContextCompactor.currentUsage(
                messages: agent.state.messages,
                model: agent.state.model
            ),
            threshold: autoCompactThreshold
        )
        let goalSnap = goalStore.snapshot()
        frame.breadcrumb = promptBreadcrumb(
            model: agent.state.model,
            branch: gitBranch,
            goalSegment: GoalMode.statusSegment(status: goalSnap.status, tokensUsed: goalSnap.tokensUsed)
        )
        frame.metaRight = promptMetaLabel(
            model: agent.state.model,
            thinkingLevel: agent.state.thinkingLevel,
            capacityHint: capacityHint
        )
        frame.stateLine = codingFrameStateLine(
            mode: frameStatus.mode,
            isStreaming: agent.state.isStreaming,
            runningBackgroundTasks: frameStatus.runningBackgroundTasks,
            queuedPrompts: agent.queuedSteeringCount(),
            spinner: frame.spinner
        )
        // Surface the pending queue as a live list above the input (omp-style).
        frame.queuedPrompts = agent.queuedSteeringMessages().map { queuedPromptPreview($0) }
        // Slash commands are idle-only; mirror that into the popup footer hint.
        frame.isBusy = agent.state.isStreaming
            || frameStatus.isAutoCompacting
            || frameStatus.isManualCompacting
            || frameStatus.isShaking
            || frameStatus.isPreparingAttachments
            || frameStatus.isRewinding
            || frameStatus.isSessionSwitching
        // Keep the re-renderable welcome header in sync with live login/model
        // state (same composite condition as the launch banner) so a resize
        // repaint after /login, /logout, or /model reflects the current state.
        var header = welcomeCtx
        let loggedOut = sessionProviders.isLoggedOut && agent.state.model.provider.isEmpty
        header.loggedOut = loggedOut
        header.modelId = loggedOut ? "no provider" : agent.state.model.id
        header.providerName = loggedOut
            ? "not signed in"
            : ProviderAttribution.getProviderDisplayName(agent.state.model.provider)
        welcomeHeader.update(header)
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
        requestRender: { runner.tui.requestRender() },
        // Rows available for the modal above the prompt box. Reserve ~4 for
        // the prompt box + a margin; queried per redraw so it tracks resizes.
        availableRows: { max(4, runner.terminal.height - 4) }
    )

    // Focus target: a thin router in front of the prompt row. While a modal
    // is open, typed input (and the unbound ←/→ arrows) is offered to the
    // modal first — form modals consume it, list modals decline and it falls
    // through to the prompt editor exactly as before. With no modal open the
    // router is a transparent pass-through, so prompt focus/cursor behavior
    // is unchanged.
    runner.focus(ModalInputRouter(host: modal, fallback: frame.promptRow))

    _ = runner.terminal.onResize { w, h in
        Task { @MainActor in
            frame.setViewport(height: h)
            renderer.displayWidth = w
            if modal.isOpen {
                // Re-window the open modal to the new height so a long list
                // re-fits this frame rather than lagging until the next key.
                modal.reflow()
            } else {
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

    // Start one hidden continuation turn from idle. Delivered via `prompt` (not
    // steer+continue): `continue()` only runs when the last message is an
    // assistant reply, so a goal started in a fresh session — no messages yet —
    // would silently queue forever. `prompt` starts a turn from any state; the
    // marker in the text keeps it out of the visible transcript (see
    // TranscriptRenderer). We wait for runLifecycle teardown first so a kick at
    // .agentEnd doesn't collide with the just-ending run (`alreadyRunning`).
    // This is the ONLY site that increments the cap counter, so agentEnd /
    // `/goal set` / `/goal resume` all share one path.
    let goalLoggedOutHint = GoalLoggedOutHintState()
    let kickGoalContinuation: @MainActor @Sendable () -> Void = {
        // Logged-out gate: with no registered provider a continuation turn on
        // the sentinel model can only die with a provider error. Guarding at
        // the single kick site covers every entry path — .agentEnd inject,
        // `/goal set`, `/goal resume` — including a goal that outlives its
        // provider (`/logout` of the last one mid-goal). The hint prints at
        // most once per logged-out stretch so repeated kicks don't spam.
        guard !sessionProviders.isLoggedOut else {
            if !goalLoggedOutHint.shown {
                goalLoggedOutHint.shown = true
                runner.tui.commit([
                    "",
                    Style.dimmed("  goal: no provider configured — /login to sign in"),
                ])
                runner.tui.requestRender()
            }
            return
        }
        goalLoggedOutHint.shown = false
        let continuationAgent = agent
        Task.detached {
            await continuationAgent.waitForIdle()
            let isCurrentSession = await MainActor.run {
                agentBox.agent === continuationAgent
            }
            guard isCurrentSession else { return }
            // Re-check on the far side of the idle wait: `/goal off`, a cap
            // pause, completion, or a replaced objective may have landed while
            // we waited. Read the current objective so we never fire a stale
            // one. This narrows — but cannot fully close — the check-then-prompt
            // window: if `/goal off` lands between here and `prompt()` below, at
            // most one continuation runs, and its own `.agentEnd` then sees the
            // goal inactive and stops. That single self-healing turn is
            // acceptable versus the complexity of an abortable atomic start.
            let snap = goalStore.snapshot()
            guard snap.status == .active else { return }
            goalStore.recordAutoContinue()
            do {
                try await continuationAgent.prompt(GoalMode.continuationText(objective: snap.objective))
            } catch {
                // Lost the race to a user prompt / another kick (alreadyRunning)
                // — no turn started, so don't spend a cap slot on it.
                goalStore.undoAutoContinue()
            }
        }
    }

    // `isAutoCompacting` / `isManualCompacting` live on `frameStatus`. The
    // latter is set for the duration of a manual `/compact` (via the
    // SlashContext `setCompacting` hook) and mirrors the auto flag in the Enter
    // busy gate so a prompt typed mid-compact queues instead of racing the
    // compactor.
    updateFrameStatus()

    // Retry bookkeeping for `/retry`: remembers the last submitted prompt and
    // whether its turn failed/aborted so it can be resubmitted on request.
    // Declared before the agent subscription so the `.agentEnd` listener can
    // flip `failed` when a run reports `.error` / `.aborted` — the genuine
    // failure signal lives on the event stream, not on a thrown error.
    let retry = TurnRetryState()

    // Alt+↑ dequeue-cycle bookkeeping. Declared here (before the `/new` and
    // `/resume` handlers) so those session-swap closures can reset it via
    // `resetSessionTransientState` — a stale cursor into a drained queue must
    // not survive into a fresh or restored session.
    let dequeueCycle = DequeueCycleState()

    // Background-task poll controller. The poll refreshes the "N bg active"
    // count + abort/retry countdowns, but only needs to run while something is
    // actually live: a turn is in flight (which may spawn tasks) or at least
    // one background task is queued or running. `ensurePoll` (re)starts it on
    // activity; the loop stops itself once idle so an idle prompt isn't
    // re-queried and repainted 4×/second for nothing.
    let pollHandle = PollHandle()
    let ensurePoll: @MainActor @Sendable () -> Void = {
        guard pollHandle.task == nil else { return }
        pollHandle.task = Task { @MainActor in
            defer { pollHandle.task = nil }
            while !Task.isCancelled {
                // Counting should not read every retained task's output tail.
                // The manager already exposes an active-only metadata path for
                // this high-frequency status refresh.
                let running = await bgManager.activeTaskIds(sessionId: sessionId).count
                frameStatus.runningBackgroundTasks = running
                updateFrameStatus()
                runner.tui.requestRender()
                // Nothing left to animate the count → stop. A later turn or
                // background task restarts the poll via `ensurePoll`.
                if running == 0 && !agent.state.isStreaming { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    // Keep the renderer's display mode in sync with the agent's state on
    // every event, so `/thinking show|hide` (which only mutates agent
    // state) takes effect on the next turn without extra plumbing.
    renderer.setThinkingDisplay(agent.state.thinkingDisplay)
    let streamCoalescer = RenderCoalescer {
        updateFrameStatus()
        runner.tui.requestRender()
    }
    let subscribeToAgentEvents: @MainActor @Sendable (Agent) -> Unsubscribe = { observedAgent in
        observedAgent.subscribe { event, _ in
            await MainActor.run {
                // An event already queued onto MainActor before a hot session
                // switch must not repaint or mutate retry/goal state for the
                // replacement session.
                guard agentBox.agent === observedAgent else { return }
                renderer.setThinkingDisplay(agent.state.thinkingDisplay)
                renderer.apply(event)
                // Settled rows move into retained history; live rows stay mutable
                // in the same full-screen frame. When a modal is open we keep the
                // transcript behind it stable and drain pending rows on close.
                if !modal.isOpen {
                    recomputeTranscript()
                }
                let flushedCommits = flushCommits()
                // A pure token delta that settled nothing only mutates the live
                // tail — render it on the coalesced ~30fps cadence rather than
                // synchronously per delta. Anything that reached scrollback (or
                // any non-delta event) keeps the immediate render below.
                if isPureStreamDelta(event), !flushedCommits {
                    streamCoalescer.schedule()
                    return
                }
                switch event {
                case .agentStart:
                    break
                case let .agentEnd(_, summary):
                    frameStatus.mode = .idle
                    // A genuine failure (retries exhausted, turn cap, abort) returns
                    // NORMALLY from `agent.prompt()` — the executor error is caught
                    // inside `runLifecycle` and surfaced as a synthetic `.agentEnd`
                    // whose `summary.finalStopReason` is `.error` / `.aborted`. The
                    // detached-task `catch` only fires for `AgentError.alreadyRunning`,
                    // so this is the primary place `/retry` learns a turn failed.
                    // Only user-initiated turns (trackedActive) arm /retry, and the
                    // target is derived from the message actually executed — never a
                    // separately-recorded copy that a steer or command could stale.
                    if let t = retryArmTarget(
                        summary: summary,
                        aborted: false,
                        trackedActive: retry.trackedActive,
                        messages: agent.state.messages
                    ) {
                        retry.lastText = t.text
                        retry.lastImages = t.images
                        retry.failed = true
                    }
                    // Consume the tracking flag: the turn is over either way.
                    retry.trackedActive = false

                    // --- goal mode autonomous loop ---
                    let gsnap = goalStore.snapshot()
                    // Attribute this turn's spend to the goal while it drove the
                    // turn — still active, or completed by the model mid-turn (so
                    // the final "done" notice reports the full spend). Feeds the
                    // omp-style `🎯 Goal 27K` breadcrumb segment and `/goal`.
                    if gsnap.status == .active || gsnap.status == .complete {
                        goalStore.addTokens(summary.usage.totalTokens)
                    }
                    if gsnap.status == .complete {
                        // The model called goal({op:"complete"}) during this turn.
                        // Drop the goal so this branch fires exactly once — .complete
                        // has no other exit transition, so without clearing it the
                        // done notice would re-print on every subsequent turn.
                        // Read the spend before stop() zeroes it with the goal.
                        let spent = compactTokenCount(goalStore.snapshot().tokensUsed)
                        goalStore.stop()
                        applyGoalContext()
                        runner.tui.commit([
                            "",
                            Style.dimmed("  🎯 goal complete (\(spent) tokens) — autonomous loop stopped."),
                        ])
                    } else {
                        switch goalLoopDecision(
                            isActive: gsnap.status == .active,
                            stopReason: summary.finalStopReason,
                            alreadyContinued: gsnap.autoContinueCount,
                            cap: GoalMode.autoContinueCap
                        ) {
                        case .inject:
                            kickGoalContinuation()
                        case .pauseCap:
                            goalStore.pauseForCap()
                            // Strip the ACTIVE <goal_context> from the system prompt
                            // to match the paused state — otherwise the next user
                            // message still ships "Goal mode is active" at
                            // system-prompt priority while the status line shows no
                            // goal (the .stop path already does this).
                            applyGoalContext()
                            runner.tui.commit([
                                "",
                                Style.error(
                                    "  goal: hit auto-continue cap (\(GoalMode.autoContinueCap)) — paused. /goal resume to keep going, /goal off to stop."
                                ),
                            ])
                        case .stop:
                            // The loop was active but the turn ended on a non-natural
                            // stop reason (abort / provider error / output-length cap).
                            // Pause the goal so the status line stops advertising it
                            // as actively working and the user gets a resume affordance
                            // instead of a silent stall. A plain no-goal turn (status
                            // not active) falls through with no notice.
                            if gsnap.status == .active {
                                goalStore.pauseForCap()
                                applyGoalContext()
                                let reason: String
                                switch summary.finalStopReason {
                                case .aborted: reason = "interrupted"
                                case .length: reason = "output limit reached"
                                case .error: reason = "provider error"
                                default: reason = "turn did not complete"
                                }
                                runner.tui.commit([
                                    "",
                                    Style.error(
                                        "  goal: autonomous loop stopped (\(reason)) — /goal resume to keep going, /goal off to stop."
                                    ),
                                ])
                            }
                        }
                    }
                case let .compactStart(count, _):
                    frameStatus.isAutoCompacting = true
                    frameStatus.mode = .compacting(messageCount: count)
                    runner.tui.commit([
                        "",
                        Style.dimmed("  ◐ auto-compacting \(count) messages…"),
                    ])
                case let .compactEnd(outcome):
                    frameStatus.isAutoCompacting = false
                    frameStatus.mode = .idle
                    switch outcome {
                    case let .compacted(n, hasLedger):
                        runner.tui.commit(
                            renderCompactBoundary(
                                messagesCompacted: n,
                                hasRunningTasksLedger: hasLedger,
                                width: runner.terminal.width
                            )
                        )
                    case .refusedAgentBusy:
                        runner.tui.commit([
                            "",
                            Style.error("  auto-compact: agent is busy; compact skipped"),
                            "",
                        ])
                    case .refusedTooFewMessages:
                        break
                    case let .failed(msg):
                        runner.tui.commit([
                            "",
                            Style.error("  auto-compact failed: \(msg)"),
                            "",
                        ])
                    }
                case let .streamRetry(attempt, delayMs, reason):
                    frameStatus.mode = .retrying(
                        attempt: attempt,
                        until: Date().addingTimeInterval(Double(delayMs) / 1000.0),
                        reason: reason
                    )
                case .messageStart:
                    frameStatus.mode = .idle
                case .messageUpdate:
                    break
                default: break
                }
                // A turn is live (and may spawn background tasks) — make sure the
                // bg-task poll is running so the count + countdowns stay fresh.
                if agent.state.isStreaming { ensurePoll() }
                updateFrameStatus()
                runner.tui.requestRender()
            }
        }
    }
    agentBox.eventUnsubscribe = subscribeToAgentEvents(agent)

    // --- ask tool (UI-only) ----------------------------------------------
    // `ask` suspends its tool call mid-turn until the user answers in a
    // selector modal, so it needs the ModalHost and is appended post-build
    // like `goal` (the loop reads state.tools fresh each turn). Esc in the
    // modal cancels the whole call and aborts the run, mirroring omp — the
    // modal consumed the Esc that would otherwise have hit the streaming
    // abort binding, so the abort is re-issued explicitly below.
    let presentAsk: AskPresenter = { prompt, cancellation in
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let presentation = AskPresentation(continuation)
                let askModal = AskModal(
                    prompt: prompt,
                    // The live zone renders children one column narrow
                    // (TUI reserves the last column against pending-wrap);
                    // wrapping at the full width would get every exactly-full
                    // row re-wrapped by the frame into a spilled orphan cell.
                    displayWidth: { max(0, runner.terminal.width - 1) }
                ) { outcome in
                    modal.close()
                    // The cancel teardown below reaches this actor on a Task
                    // hop, so a user confirm can race in after the run was
                    // already cancelled. Resolve the race at this single
                    // resume point: a cancelled run never gets an answer.
                    presentation.resume(cancellation?.isCancelled == true ? .cancelled : outcome)
                }
                modal.open(askModal)
                // A run abort landing while the modal is still up (Ctrl-C
                // force-quit teardown, provider failure in a parallel branch)
                // must not strand the suspended tool call behind a dead run.
                cancellation?.onCancel { _ in
                    Task { @MainActor in
                        guard !presentation.finished else { return }
                        modal.close()
                        presentation.resume(.cancelled)
                    }
                }
            }
        }
    }
    let askAbortRun: @Sendable () -> Void = {
        Task { @MainActor in
            let wasStreaming = agent.state.isStreaming
            guard abortInteractiveAgentWork(
                agent: agent,
                isManualCompacting: frameStatus.isManualCompacting
            ) else { return }
            frameStatus.mode = .aborting
            if wasStreaming {
                // Same bookkeeping as the Esc abort path: drop queued steers
                // so they can't double-drain, and arm /retry from the message
                // actually in flight.
                agent.clearSteeringQueue()
                if let t = retryArmTarget(
                    summary: nil,
                    aborted: true,
                    trackedActive: retry.trackedActive,
                    messages: agent.state.messages
                ) {
                    retry.lastText = t.text
                    retry.lastImages = t.images
                    retry.failed = true
                }
                retry.trackedActive = false
            }
            updateFrameStatus()
            runner.tui.requestRender()
        }
    }
    let askTool = createAskTool(present: presentAsk, abortRun: askAbortRun)
    do {
        var withAsk = agent.state.tools
        withAsk.append(askTool)
        agent.state.tools = withAsk
    }

    let setSessionSwitching: @MainActor @Sendable (Bool) -> Void = { active in
        frameStatus.isSessionSwitching = active
        updateFrameStatus()
        runner.tui.requestRender()
    }

    /// Replace every session-scoped runtime component as one idle-only
    /// transaction. In particular, tools and the background delivery consumer
    /// are rebuilt with `newSessionId`; none retain the outgoing task namespace.
    let replaceSessionAgent: @MainActor @Sendable (String, [Message]) async -> Agent = {
        newSessionId, messages in
        let outgoingCodingAgent = agentBox.codingAgent
        let outgoing = outgoingCodingAgent.agent
        let outgoingSessionId = outgoing.sessionId

        // Stop all outgoing observers before cancelling its work. Session
        // closure is silent, so killed tasks cannot wake an idle old Agent and
        // generate an unsolicited continuation during the handoff.
        outgoing.retire()
        agentBox.eventUnsubscribe?()
        agentBox.eventUnsubscribe = nil
        await outgoingCodingAgent.detachBackground?()
        outgoing.clearAllQueues()
        if let outgoingSessionId, !outgoingSessionId.isEmpty {
            await bgManager.closeSession(sessionId: outgoingSessionId)
        }
        await outgoing.waitForIdle()
        await outgoing.closeSession()

        let replacementCodingAgent = await makeCodingAgent(CodingAgentConfig(
            model: outgoing.state.model,
            cwd: cwd,
            tools: tools,
            contextFiles: loadProjectContextFiles(cwd: cwd),
            skillDirectories: Skills.defaultDirectories(cwd: cwd, includeUserDirectory: true),
            backgroundManager: bgManager,
            subagents: defaultCLISubagents(
                for: tools,
                selection: builtinSubagents,
                runInBackgroundByDefault: true
            ),
            sessionId: newSessionId,
            authResolver: outgoing.authResolver ?? authResolver,
            autoCompactThreshold: outgoing.autoCompact?.threshold ?? autoCompactThreshold,
            autoCompactConfig: outgoing.autoCompact?.config ?? .init(),
            compactionModel: outgoing.compactionModel,
            bashEnvironment: environment,
            bashShellPath: cliShellPath(environment: environment)
        ))
        let replacement = replacementCodingAgent.agent
        copyAgentRuntimePreferences(from: outgoing, to: replacement)
        replacement.state.messages = messages
        var replacementTools = replacement.state.tools
        replacementTools.append(createGoalTool(store: goalStore))
        replacementTools.append(askTool)
        replacement.state.tools = replacementTools

        agentBox.replace(with: replacementCodingAgent)
        agentBox.eventUnsubscribe = subscribeToAgentEvents(replacement)
        renderer.setThinkingDisplay(replacement.state.thinkingDisplay)
        return replacement
    }

    // Single submission path. Fires the prompt on a detached task (so the UI
    // keeps pumping while it streams), records it for `/retry`, and flips the
    // retry flag on failure. Both the Enter handler and `/retry` funnel through
    // here so a resubmit drives the exact same streaming/steering UI as a fresh
    // submission.
    let submitBuiltPrompt: @MainActor @Sendable (String, [ImageContent]) -> Void = { text, images in
        // Mark this as a user-initiated turn eligible for /retry, and clear any
        // prior failure. The retry target is NOT recorded here — it's derived at
        // arm time (.agentEnd / Esc-abort) from the message actually executed.
        retry.trackedActive = true
        retry.failed = false
        goalStore.resetAutoContinue()
        let submittedAgent = agent
        Task.detached {
            do {
                try await promptPreservingContention(
                    agent: submittedAgent,
                    text: text,
                    images: images,
                    isCurrent: {
                        await MainActor.run {
                            agentBox.agent === submittedAgent
                        }
                    }
                )
            } catch {
                await MainActor.run {
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

    // Rewind-to-message selector, opened by double-Esc from idle and by
    // `/rewind`. Defined once here so both trigger points share the exact
    // same opener (candidate list, truncation, persistence, recap).
    let openRewind: @MainActor @Sendable () -> Void = {
        let rewindAgent = agent
        let rewindGeneration = agentBox.generation
        openRewindSelector(
            agent: rewindAgent,
            modal: modal,
            frame: frame,
            sessionStore: sessionStore,
            recorderBox: recorderBox,
            retry: retry,
            attachments: attachments,
            dequeueCycle: dequeueCycle,
            terminalWidth: { runner.terminal.width },
            commit: { runner.tui.commit($0) },
            replaceTranscript: { runner.tui.replaceCommitted($0) },
            recomputeTranscript: recomputeTranscript,
            updateFrameStatus: updateFrameStatus,
            requestRender: { runner.tui.requestRender() },
            isCurrentSession: {
                !frameStatus.isSessionSwitching
                    && agentBox.isCurrent(agent: rewindAgent, generation: rewindGeneration)
            },
            setRewinding: { active in
                frameStatus.isRewinding = active
                updateFrameStatus()
                runner.tui.requestRender()
            }
        )
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

    // `/resume`, `/new`, `/retry`, `/goal` — session-lifecycle commands. Their
    // handlers close over live session state (recorder box, goal store, retry
    // record) and the TUI's repaint closures; see SessionSlashCommands.swift.
    registerSessionSlashCommands(slashRegistry, ctx: SessionCommandContext(
        agentProvider: { agent },
        replaceSessionAgent: replaceSessionAgent,
        setSessionSwitching: setSessionSwitching,
        modal: modal,
        frame: frame,
        cwd: cwd,
        sessionStore: sessionStore,
        recorderBox: recorderBox,
        goalStore: goalStore,
        retry: retry,
        attachments: attachments,
        dequeueCycle: dequeueCycle,
        terminalWidth: { runner.terminal.width },
        commit: { runner.tui.commit($0) },
        replaceTranscript: { runner.tui.replaceCommitted($0) },
        requestRender: { runner.tui.requestRender() },
        recomputeTranscript: recomputeTranscript,
        updateFrameStatus: updateFrameStatus,
        applyGoalContext: applyGoalContext,
        kickGoalContinuation: kickGoalContinuation,
        submitBuiltPrompt: submitBuiltPrompt,
        openRewindSelector: openRewind
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
        agentProvider: { agent },
        modal: modal,
        backgroundManager: bgManager,
        sessionIdProvider: { sessionId },
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
                messagesCompacted: messagesCompacted,
                reason: .compact
            )
        },
        persistShake: { mode in
            switch mode {
            case .elide:
                return await recorderBox.recorder.rewriteShakenToolOutputs()
            case .images:
                return await recorderBox.recorder.rewriteRemovingImages()
            }
        },
        setSessionTitle: { title in
            await recorderBox.recorder.recordTitle(title)
        },
        sessionProviders: sessionProviders,
        authResolvers: authResolvers,
        context1m: context1m,
        withSuspendedTUI: { body in
            // Release the terminal so the `/login` OAuth handoff can run on a
            // cooked terminal — stderr progress plus a cbreak RawStdin watcher
            // that maps Esc/Ctrl-C to cancellation (see `runOAuthFlow`); no
            // second TUIRunner is involved and SIGINT stays SIG_IGN throughout
            // — then repaint the coding frame when it returns.
            runner.suspend()
            await body()
            try? runner.resume()
            recomputeTranscript()
            updateFrameStatus()
            runner.tui.requestRender()
        },
        setCompacting: { active in
            frameStatus.isManualCompacting = active
            // Show the compacting spinner (frameMode.isActive drives the
            // dedicated spinner tick) for the whole round-trip, and clear back
            // to idle when it finishes.
            frameStatus.mode = active ? .compacting(messageCount: agent.state.messages.count) : .idle
            updateFrameStatus()
            runner.tui.requestRender()
        },
        setShaking: { active in
            frameStatus.isShaking = active
            frameStatus.mode = active ? .shaking : .idle
            updateFrameStatus()
            runner.tui.requestRender()
        }
    )

    // --- keybindings ----------------------------------------------------

    // Enter. Four modes of operation:
    //   1. modal open → forward to modal's confirm handler.
    //   2. input starts with `/` → slash command dispatch.
    //   3. LLM prompt while the agent is idle → submit.
    //   4. LLM prompt while the agent is streaming → prepare its
    //      attachments off-main, then steer it at the next turn boundary.
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

            // Submission only dispatches exact registered names/aliases.
            // Fuzzy matching is an explicit popup/completion affordance; if
            // nothing was selected, slash-looking text (notably absolute
            // paths) continues through the normal prompt path.
            let parsed = SlashInput.parse(text, recognizing: slashRegistry)
            guard !frameStatus.isPreparingAttachments else { return }
            if case .prompt = parsed,
               frameStatus.isSessionSwitching || frameStatus.isRewinding {
                return
            }
            let busy = agent.state.isStreaming
                || frameStatus.isAutoCompacting
                || frameStatus.isManualCompacting
                || frameStatus.isShaking
                || frameStatus.isRewinding
                || frameStatus.isSessionSwitching
                || retry.trackedActive

            // Logged-out gate: with no registered provider a prompt has
            // nowhere to route — surface the /login hint instead of letting
            // agent.prompt fail on the sentinel model. The typed text stays
            // in the input so it survives the /login round-trip; slash
            // commands (notably /login itself) pass through.
            if case .prompt = parsed,
               gatePromptWhenLoggedOut(
                   sessionProviders: sessionProviders,
                   commit: { runner.tui.commit($0) }
               ) {
                updateFrameStatus()
                runner.tui.requestRender()
                return
            }

            switch parsed {
            case .command(let name, let args):
                // Commands mutate shared session state and therefore remain
                // idle-only.
                guard !busy else {
                    runner.tui.commit([
                        "",
                        Style.error("  slash commands run only when the agent is idle — stop it first (Esc) or wait"),
                        "",
                    ])
                    updateFrameStatus()
                    runner.tui.requestRender()
                    return
                }
                frame.input.value = ""
                updateFrameStatus()
                runner.tui.requestRender()
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
                // Release the editor immediately so the user can start the
                // next draft while image decoding and encoding run off-main.
                let submittedAgent = agent
                let submittedGeneration = agentBox.generation
                let attachmentSnapshot = attachments.promptSnapshot(for: text)
                frame.input.value = ""
                frameStatus.isPreparingAttachments = true
                frameStatus.mode = .preparingAttachments
                updateFrameStatus()
                runner.tui.requestRender()

                let built: BuiltPrompt
                do {
                    built = try await buildPromptWithAttachments(
                        snapshot: attachmentSnapshot,
                        cwd: cwd,
                        modelSupportsImages: submittedAgent.state.model.input.contains(.image)
                    )
                } catch {
                    frameStatus.isPreparingAttachments = false
                    if case .preparingAttachments = frameStatus.mode {
                        frameStatus.mode = .idle
                    }
                    guard agentBox.isCurrent(
                        agent: submittedAgent,
                        generation: submittedGeneration
                    ) else { return }
                    let nextDraft = frame.input.value
                    frame.input.value = nextDraft.isEmpty
                        ? text
                        : text + "\n" + nextDraft
                    frame.input.moveEnd()
                    runner.tui.commit([
                        "",
                        Style.error("  attach: \(error.localizedDescription)"),
                        "",
                    ])
                    updateFrameStatus()
                    runner.tui.requestRender()
                    return
                }
                frameStatus.isPreparingAttachments = false
                if case .preparingAttachments = frameStatus.mode {
                    frameStatus.mode = .idle
                }
                guard agentBox.isCurrent(
                    agent: submittedAgent,
                    generation: submittedGeneration
                ) else { return }
                attachments.consume(attachmentSnapshot)
                frame.input.addToHistory(built.recallText)
                if let issues = built.issues {
                    runner.tui.commit([
                        "",
                        Style.error("  attach: " + issues),
                        "",
                    ])
                    updateFrameStatus()
                    runner.tui.requestRender()
                }

                let shouldSteer = submittedAgent.state.isStreaming
                    || frameStatus.isAutoCompacting
                    || frameStatus.isManualCompacting
                    || frameStatus.isShaking
                    || frameStatus.isRewinding
                    || frameStatus.isSessionSwitching
                    || retry.trackedActive
                if shouldSteer {
                    var blocks: [UserBlock] = [.text(TextContent(text: built.text))]
                    blocks.append(contentsOf: built.images.map(UserBlock.image))
                    submittedAgent.steer(.user(UserMessage(content: blocks)))
                    submittedAgent.resumeQueuedWork()
                    retry.trackedActive = true
                    goalStore.resetAutoContinue()
                    updateFrameStatus()
                    runner.tui.requestRender()
                } else {
                    submitBuiltPrompt(built.text, built.images)
                }
            }
        }
    }

    // Tab. Modal open → the modal decides (tab-bar cycling / field focus);
    // otherwise slash-menu completion, then literal insert, as before.
    runner.bind(.init("tab")) { _ in
        Task { @MainActor in
            if modal.isOpen {
                modal.routeTab()
                return
            }
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
    // slash-command popup. With neither open they go to the editor, which
    // disambiguates per omp: Up/Down move the cursor by visual row (sticky
    // goal column) and recall history only from an empty buffer — or, while
    // already browsing, from the first/last visual row.
    runner.bind(.init("up")) { _ in
        Task { @MainActor in
            if modal.isOpen { modal.routeUp() }
            else if frame.slashMenuActive { frame.menuMove(-1); runner.tui.requestRender() }
            else { frame.input.cursorUp(); updateFrameStatus(); runner.tui.requestRender() }
        }
    }
    runner.bind(.init("down")) { _ in
        Task { @MainActor in
            if modal.isOpen { modal.routeDown() }
            else if frame.slashMenuActive { frame.menuMove(1); runner.tui.requestRender() }
            else { frame.input.cursorDown(); updateFrameStatus(); runner.tui.requestRender() }
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

    // Ctrl-C: pi/omp two-stage convention. The first press does the least
    // destructive useful thing — cancel a live generation/compaction, else clear a
    // non-empty input, else arm the exit and hint — and a second press within
    // the window quits. This stops a single accidental Ctrl-C from tearing the
    // app down mid-stream. (Ctrl-D on an empty input is still the one-tap exit.)
    let ctrlC = CtrlCState()
    runner.bind(.ctrl("c")) { _ in
        Task { @MainActor in
            let now = Date()
            let armed = ctrlC.lastPress.map { now.timeIntervalSince($0) < CtrlCState.window } ?? false
            if armed {
                await agent.abortAndKillBackgroundTasks()
                runner.exit()
                return
            }
            ctrlC.lastPress = now
            if modal.isOpen {
                modal.routeCancel()
                return
            }
            let wasStreaming = agent.state.isStreaming
            if abortInteractiveAgentWork(
                agent: agent,
                isManualCompacting: frameStatus.isManualCompacting
            ) {
                // Cancel the active generation or compaction, mirroring Esc's abort path. The
                // "Ctrl-C to force quit" state line already tells the user a
                // second press exits, so no extra scrollback notice here.
                frameStatus.mode = .aborting
                if wasStreaming {
                    agent.clearSteeringQueue()
                    if let t = retryArmTarget(
                        summary: nil,
                        aborted: true,
                        trackedActive: retry.trackedActive,
                        messages: agent.state.messages
                    ) {
                        retry.lastText = t.text
                        retry.lastImages = t.images
                        retry.failed = true
                    }
                    retry.trackedActive = false
                }
            } else if !frame.input.value.isEmpty {
                frame.input.value = ""
                runner.tui.commit(["", Style.dimmed("  cleared — press Ctrl-C again to exit")])
            } else {
                runner.tui.commit(["", Style.dimmed("  press Ctrl-C again to exit")])
            }
            updateFrameStatus()
            runner.tui.requestRender()
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
    //   2. agent streaming or manual compacting → abort the active owner.
    //   3. idle with an empty editor → arm double-Esc; a second press
    //      within the window opens the rewind-to-message selector.
    //
    // Double-Esc invariant: only an Esc that did NOTHING else may count as a
    // tap of the double-tap. Every branch that consumes the press for another
    // purpose (modal cancel or abort) — and any press with draft text
    // in the editor — resets the arm, so cancelling a modal and then pressing
    // Esc again can never surprise-open the selector.
    let doubleEsc = DoubleEscState()
    runner.bind(.init("escape")) { _ in
        Task { @MainActor in
            let now = Date()
            if modal.isOpen {
                doubleEsc.lastPress = nil
                modal.routeCancel()
                return
            }
            let wasStreaming = agent.state.isStreaming
            if abortInteractiveAgentWork(
                agent: agent,
                isManualCompacting: frameStatus.isManualCompacting
            ) {
                doubleEsc.lastPress = nil
                frameStatus.mode = .aborting
                if wasStreaming {
                    // Drop any queued-but-unstarted steer messages so they can't
                    // double-drain: without this the initial steering drain would
                    // still inject them AND /retry would resubmit, sending twice.
                    agent.clearSteeringQueue()
                    // Arm /retry from the message actually in flight (the last user
                    // message in the transcript), gated to user-initiated turns. The
                    // trailing `.agentEnd(.aborted)` won't re-arm because we consume
                    // trackedActive here.
                    if let t = retryArmTarget(
                        summary: nil,
                        aborted: true,
                        trackedActive: retry.trackedActive,
                        messages: agent.state.messages
                    ) {
                        retry.lastText = t.text
                        retry.lastImages = t.images
                        retry.failed = true
                    }
                    retry.trackedActive = false
                }
                updateFrameStatus()
                runner.tui.requestRender()
                return
            }
            // Idle fall-through. Background tasks are deliberately left alone:
            // cancellation is an explicit task action, never a destructive
            // side effect of a navigation key. Rewind arms
            // only with an empty editor while no compaction (auto or manual)
            // is mutating the transcript — any other idle Esc resets the arm
            // so a stray earlier press can't complete the double-tap.
            guard frame.input.value.isEmpty,
                  !agent.state.isStreaming,
                  !frameStatus.isAutoCompacting,
                  !frameStatus.isManualCompacting,
                  !frameStatus.isShaking,
                  !frameStatus.isPreparingAttachments,
                  !frameStatus.isRewinding,
                  !frameStatus.isSessionSwitching
            else {
                doubleEsc.lastPress = nil
                return
            }
            let armed = doubleEsc.lastPress
                .map { now.timeIntervalSince($0) < DoubleEscState.window } ?? false
            if armed {
                doubleEsc.lastPress = nil
                openRewind()
            } else {
                doubleEsc.lastPress = now
            }
        }
    }

    // The background-task poll (see `ensurePoll` above) refreshes the
    // "N bg active" count + retry/abort countdowns at a relaxed 250ms cadence,
    // but only while a turn or a background task is live — it is started on
    // demand rather than spinning forever. The spinner is NOT advanced there —
    // it has its own faster tick below — so a slow bg poll can't make the
    // animation visibly step.

    // Dedicated spinner tick, decoupled from the bg poll. ~90ms gives the
    // 10-frame braille set a smooth, continuous spin. We only advance + repaint
    // while something is actually animating (streaming, compacting, aborting,
    // retrying), so an idle prompt isn't redrawn ~11×/s for no reason.
    let spinnerTask = Task { @MainActor in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard agent.state.isStreaming || frameStatus.isAutoCompacting || frameStatus.mode.isActive else { continue }
            frame.tick()
            // Advance the collapsed `[thinking Ns…]` elapsed counter between
            // provider deltas — liveLines is cached state, so it must be
            // re-derived here for the label to tick.
            if renderer.hasActiveThinking && !modal.isOpen {
                renderer.tickLive()
                recomputeTranscript()
            }
            updateFrameStatus()
            runner.tui.requestRender()
        }
    }

    let shutdown: @MainActor @Sendable () async -> Void = {
        // Detach delivery before silent cancellation. Otherwise a terminal
        // kill notification can win the shutdown race and start a fresh,
        // billable continuation while the process is trying to exit.
        let currentCodingAgent = agentBox.codingAgent
        currentCodingAgent.agent.retire()
        agentBox.eventUnsubscribe?()
        agentBox.eventUnsubscribe = nil
        await currentCodingAgent.detachBackground?()
        await bgManager.closeSession(sessionId: agentBox.sessionId)
        currentCodingAgent.agent.clearAllQueues()
        await currentCodingAgent.agent.waitForIdle()
        await currentCodingAgent.agent.closeSession()
    }

    // `--resume`: open the arrow-key session picker on the first frame, reusing
    // the exact `/resume` modal + confirm/hot-swap. Opening it before `run()`
    // is safe — `modal.open` just stages the overlay; the first render (once
    // the runner starts) paints it, and the ModalInputRouter already routes
    // keys to it. Cancel leaves the fresh session in place.
    if openResumePickerOnStart, let resumeCmd = slashRegistry.find("resume") {
        await resumeCmd.handler(slashContext, "")
    }

    do {
        try await runner.run()
    } catch {
        pollHandle.task?.cancel()
        spinnerTask.cancel()
        await shutdown()
        throw error
    }
    pollHandle.task?.cancel()
    spinnerTask.cancel()
    await shutdown()
    // A signal-driven teardown (SIGINT/SIGTERM) records a non-zero exit code.
    // `runner.run()` no longer calls `Foundation.exit` itself, so the graceful
    // shutdown above always runs first; propagate the code now.
    if runner.exitCode != 0 {
        Foundation.exit(runner.exitCode)
    }
}

// MARK: - Helpers

/// Lock-protected snapshot of the welcome card's context, bridging the
/// MainActor (where login/logout/model-switch state changes) and the render
/// path (where the @Sendable `headerProvider` re-renders the header on a
/// resize full-repaint). Writers call `update` from the MainActor; readers
/// take an immutable copy under the lock — no unsynchronized MainActor reads.
final class WelcomeHeaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var context: WelcomeContext

    init(_ context: WelcomeContext) {
        self.context = context
    }

    func update(_ context: WelcomeContext) {
        lock.withLock { self.context = context }
    }

    func snapshot() -> WelcomeContext {
        lock.withLock { context }
    }
}

/// Tracks the last Ctrl-C press so a second press within `window` exits while
/// a lone press cancels/clears (pi's two-stage Ctrl-C). Reference type so the
/// @MainActor keybinding closure can mutate it under Swift 6 concurrency.
@MainActor
final class CtrlCState {
    static let window: TimeInterval = 1.5
    var lastPress: Date?
}

/// Holds the frame's live status: the animation/spinner mode and the running
/// background-task count. Both are mutated from several @MainActor closures
/// (keybindings, the event handler, the bg poll), so a reference type lets them
/// share one storage without capturing a `var` (rejected under Swift 6 strict
/// concurrency).
@MainActor
private final class FrameStatusState {
    var mode: CodingFrameMode = .idle
    var runningBackgroundTasks = 0
    var isAutoCompacting = false
    var isManualCompacting = false
    var isShaking = false
    var isPreparingAttachments = false
    var isRewinding = false
    var isSessionSwitching = false

    func reconcileMode(messageCount: Int, isStreaming: Bool) {
        switch mode {
        case .aborting:
            // Hold only while the aborted owner (run or manual compaction) is
            // still winding down. An Esc can race the natural end of a turn:
            // it lands after .agentEnd already reconciled the mode, sees a
            // still-true isStreaming, and re-enters .aborting with no further
            // event coming to clear it. Falling through here once the owner is
            // gone lets the next reconcile (spinner tick) self-heal instead of
            // spinning on "aborting" forever.
            if isStreaming || isManualCompacting { return }
        case .retrying:
            if isStreaming { return }
        default:
            break
        }

        if isPreparingAttachments {
            mode = .preparingAttachments
        } else if isShaking {
            mode = .shaking
        } else if isAutoCompacting || isManualCompacting {
            mode = .compacting(messageCount: messageCount)
        } else {
            mode = .idle
        }
    }
}

/// Tracks the last idle no-op Esc press so a second press within `window`
/// opens the rewind-to-message selector (omp's double-Esc). Only an Esc that
/// did nothing else records a press — every consuming branch of the Esc
/// ladder resets `lastPress` (see the binding). Reference type so the
/// @MainActor keybinding closure can mutate it under Swift 6 concurrency.
@MainActor
final class DoubleEscState {
    static let window: TimeInterval = 0.5
    var lastPress: Date?
}

/// Holds the on-demand background-task poll task so the @MainActor closures
/// that start and cancel it can share one mutable handle (a captured `var` is
/// rejected under Swift 6 strict concurrency).
@MainActor
final class PollHandle {
    var task: Task<Void, Never>?
}

/// Owns the complete session-scoped coding runtime. An Agent's session id and
/// its bash/task/subagent tools are immutable by design, so a hot session switch
/// replaces this whole value rather than mutating transcript state in place.
@MainActor
final class AgentSessionBox {
    private(set) var codingAgent: CodingAgent
    var eventUnsubscribe: Unsubscribe?
    private(set) var generation: UInt64 = 0

    init(_ codingAgent: CodingAgent) {
        self.codingAgent = codingAgent
    }

    var agent: Agent { codingAgent.agent }
    var sessionId: String { agent.sessionId ?? "" }

    func replace(with replacement: CodingAgent) {
        codingAgent = replacement
        generation &+= 1
    }

    func isCurrent(agent expectedAgent: Agent, generation expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration && agent === expectedAgent
    }
}

/// Carry user/runtime preferences across a session replacement without
/// copying session-scoped tools, queues, listeners, messages, or background
/// attachments. Those are intentionally rebuilt for the new identity.
@MainActor
func copyAgentRuntimePreferences(from source: Agent, to destination: Agent) {
    destination.state.systemPrompt = source.state.systemPrompt
    destination.state.model = source.state.model
    destination.state.thinkingLevel = source.state.thinkingLevel
    destination.state.thinkingDisplay = source.state.thinkingDisplay
    destination.state.verboseEnabled = source.state.verboseEnabled
    destination.thinkingBudgets = source.thinkingBudgets
    destination.maxRetryDelayMs = source.maxRetryDelayMs
    destination.maxTurns = source.maxTurns
    destination.toolExecution = source.toolExecution
    destination.toolChoice = source.toolChoice
    destination.parallelToolCalls = source.parallelToolCalls
    destination.beforeToolCall = source.beforeToolCall
    destination.afterToolCall = source.afterToolCall
    destination.userPromptSubmit = source.userPromptSubmit
    destination.convertToLlm = source.convertToLlm
    destination.transformContext = source.transformContext
    destination.betweenTurns = source.betweenTurns
    destination.compactionModel = source.compactionModel
}

/// Whether the goal-continuation loop's logged-out "/login" hint has already
/// been shown for the current logged-out stretch. Reference type so the
/// @MainActor `kickGoalContinuation` closure can mutate it (a captured `var`
/// is rejected under Swift 6 strict concurrency).
@MainActor
final class GoalLoggedOutHintState {
    var shown = false
}

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
    /// True while a user-initiated turn (direct submit or steer) is in flight
    /// and eligible for `/retry`. Command-driven prompts (`/init`, custom
    /// commands) never set this, so a failure on one of those internal turns
    /// can't arm `/retry` with a stale internal prompt. Consumed (reset to
    /// false) at every `.agentEnd` and on Esc-abort.
    var trackedActive = false

    func clear() {
        lastText = nil
        lastImages.removeAll(keepingCapacity: false)
        failed = false
        trackedActive = false
    }
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
    case shaking
    case preparingAttachments
    case retrying(attempt: Int, until: Date, reason: String)

    /// True whenever the state line is showing a spinner (anything but plain
    /// idle). Drives the dedicated spinner tick so we only repaint at the
    /// fast cadence while something is actually animating.
    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// Cancel whichever user-visible operation currently owns the Agent. Manual
/// compaction is maintenance rather than generation, so `state.isStreaming`
/// alone is not an adequate Esc/Ctrl-C gate.
@discardableResult
func abortInteractiveAgentWork(
    agent: Agent,
    isManualCompacting: Bool
) -> Bool {
    guard agent.state.isStreaming || isManualCompacting else { return false }
    agent.abort()
    return true
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

/// Derive the `/retry` target for a just-finished (or just-aborted) turn, or
/// `nil` when the turn must not arm `/retry`. Two gates must both hold:
///
///   1. The turn is *retryable*: it was aborted by the user (`aborted`), or its
///      `summary.finalStopReason` is `.error` / `.aborted` (see
///      `turnEndedRetryable`).
///   2. The turn was *user-initiated*: `trackedActive` is true. Command-driven
///      turns (`/init`, custom commands) never set it, so a failed internal
///      prompt can't leak into `/retry`.
///
/// When both hold, the target is derived from the LAST `.user` message actually
/// in `messages` — the message the agent was executing — so a direct submit, a
/// steered follow-up, or a `/retry` resubmit all resolve to the real prompt in
/// flight rather than any separately-recorded copy. Text is the message's
/// `.text` blocks joined with newlines; images are its `.image` blocks.
@MainActor
func retryArmTarget(
    summary: AgentRunSummary?,
    aborted: Bool,
    trackedActive: Bool,
    messages: [Message]
) -> (text: String, images: [ImageContent])? {
    guard trackedActive else { return nil }
    let retryable = aborted || (summary.map(turnEndedRetryable) ?? false)
    guard retryable else { return nil }
    guard let last = messages.last(where: { if case .user = $0 { return true } else { return false } }),
          case .user(let u) = last else { return nil }
    let text = u.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined(separator: "\n")
    let images = u.content.compactMap { block -> ImageContent? in
        if case .image(let i) = block { return i }
        return nil
    }
    return (text: text, images: images)
}

/// Submit a direct prompt without losing it if another run acquires ownership
/// in the gap between the UI's idle check and the detached prompt task. The
/// exact content is converted to a steer and is then picked up by the competing
/// run or by one continuation after it becomes idle.
func promptPreservingContention(
    agent: Agent,
    text: String,
    images: [ImageContent],
    isCurrent: @escaping @Sendable () async -> Bool = { true }
) async throws {
    do {
        try await agent.prompt(text, images: images)
    } catch AgentError.alreadyRunning {
        guard await isCurrent() else { return }
        var blocks: [UserBlock] = [.text(TextContent(text: text))]
        for image in images { blocks.append(.image(image)) }
        agent.steer(.user(UserMessage(content: blocks)))
        await agent.waitForIdle()
        try? await agent.continue()
    }
}

/// Reset the per-session transient state that must not survive a session swap
/// (`/new` or `/resume`): drain the steering queue, clear the `/retry` record,
/// drop outgoing attachments, and forget the Alt+↑ dequeue cursor. Shared by both
/// session-swap paths so neither leaks stale state into the incoming session
/// (e.g. a `failed`/`lastText` record that `/retry` would resubmit into the
/// wrong transcript). Does NOT touch `agent.state.messages` or the input
/// buffer — each caller manages those (clear vs. load).
@MainActor
func resetSessionTransientState(
    agent: Agent,
    retry: TurnRetryState,
    attachments: AttachmentStore,
    dequeueCycle: DequeueCycleState,
    discardingAttachments snapshot: AttachmentPromptSnapshot? = nil
) {
    agent.clearSteeringQueue()
    retry.clear()
    if let snapshot {
        attachments.consume(snapshot)
    } else {
        attachments.clear()
    }
    dequeueCycle.last = nil
}

/// Start a fresh, empty session in place: repoint persistence at a brand-new
/// session file, clear the live agent context + steering queue, reset retry and
/// attachment state, and commit a labeled separator to scrollback. A draft
/// composed while the async handoff is running belongs to the new session and
/// is preserved. This helper is extracted from the `/new` handler so the reset
/// is unit-testable.
@MainActor
func performNewSession(
    newId: String = UUID().uuidString,
    recorderBox: RecorderBox,
    sessionStore: SessionStore,
    agent: Agent,
    replaceSessionAgent: (@MainActor @Sendable (String, [Message]) async -> Agent)? = nil,
    cwd: String,
    attachments: AttachmentStore,
    retry: TurnRetryState,
    dequeueCycle: DequeueCycleState,
    frame: CodingFrame,
    width: Int,
    commit: ([String]) -> Void,
    recompute: () -> Void,
    updateStatus: () -> Void,
    requestRender: () -> Void
) async {
    let inputBeforeSwitch = frame.input.value
    let attachmentsBeforeSwitch = attachments.promptSnapshot(for: inputBeforeSwitch)

    // Stop the outgoing recorder before the runtime replacement so a late
    // callback cannot append to the new session file.
    recorderBox.unsubscribe()
    let sessionAgent: Agent
    if let replaceSessionAgent {
        sessionAgent = await replaceSessionAgent(newId, [])
    } else {
        // Retained for focused helper tests and embedders that don't own a
        // rebuild factory. The interactive TUI always supplies the factory.
        agent.state.messages = []
        sessionAgent = agent
    }
    let recorder = SessionRecorder(
        store: sessionStore,
        sessionId: newId,
        cwd: cwd,
        model: sessionAgent.state.model.id,
        provider: sessionAgent.state.model.provider,
        persistedCount: 0
    )
    await recorder.ensureCreated()
    recorderBox.recorder = recorder
    recorderBox.unsubscribe = recorder.attach(to: sessionAgent)
    recorderBox.sessionId = newId

    // Reset the live context. Native scrollback can't be cleared, so the prior
    // conversation stays above a labeled separator and the fresh session begins
    // below it.
    resetSessionTransientState(
        agent: sessionAgent,
        retry: retry,
        attachments: attachments,
        dequeueCycle: dequeueCycle,
        discardingAttachments: attachmentsBeforeSwitch
    )
    if frame.input.value == inputBeforeSwitch {
        frame.input.value = ""
    }

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

/// Gate a prompt submission when the session has no registered provider
/// (logged-out): commits a "/login to sign in" notice and returns true, in
/// which case the caller must not start a turn. Returns false (no output)
/// whenever at least one provider slot exists. Extracted from the Enter
/// keybinding so the gate is unit-testable.
@MainActor
func gatePromptWhenLoggedOut(
    sessionProviders: SessionProviders,
    commit: ([String]) -> Void
) -> Bool {
    guard sessionProviders.isLoggedOut else { return false }
    commit([
        "",
        Style.dimmed("  no provider configured — /login to sign in"),
    ])
    return true
}

/// Top-border breadcrumb for the prompt box: the live model id, then the
/// git branch when inside a repo, then the goal segment while a goal exists
/// (omp keeps its goal indicator in this persistent status row, next to the
/// model — not in the transient state line). Already styled. The logged-out
/// sentinel (empty id) renders a "/login" hint instead of a blank label.
private func promptBreadcrumb(model: Model, branch: String?, goalSegment: String?) -> String {
    var out = model.id.isEmpty
        ? Theme.faintText(loggedOutModelLabel)
        : Theme.accentText(model.id, bold: false)
    if let branch, !branch.isEmpty {
        out += Theme.faintText("  ⎇ \(branch)")
    }
    if let goalSegment {
        out += "  " + goalSegment
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
        parts.append(Theme.paint("\(spinner) compacting \(count) messages", Theme.warn, bold: true))
        parts.append(Theme.faintText("new prompts queue"))
        parts.append(Theme.faintText("Esc to cancel"))
    case .shaking:
        parts.append(Theme.paint("\(spinner) shaking context", Theme.warn, bold: true))
    case .preparingAttachments:
        parts.append(Theme.paint("\(spinner) preparing attachments", Theme.accent, bold: true))
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
        parts.append(Theme.paint("\(runningBackgroundTasks) bg active", Theme.accentDim))
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
    // Pasted TEXT always wins. Only when the bracketed-paste body carries no
    // text do we fall back to the clipboard image: on macOS a ⌘V of a
    // screenshot delivers an empty/whitespace paste body while NSPasteboard
    // holds the real image. Peeking the pasteboard first (the old behavior)
    // discarded genuinely pasted text whenever a stale image lingered on the
    // clipboard.
    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let image = ClipboardImageReader.readIfPresent() {
            let token = attachments.addClipboardImage(data: image.data, mimeType: image.mimeType)
            input.insert("\(token) ")
            tui.requestRender()
        }
        // Empty paste with no clipboard image: nothing to insert.
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
