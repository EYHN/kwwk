import Foundation
import KWWKAI
import KWWKAgent

/// Everything the session-lifecycle slash commands (`/resume`, `/new`,
/// `/retry`, `/goal`) close over from the running TUI. Unlike the stateless
/// builtins (BuiltinSlashCommands.swift), these handlers mutate live session
/// state — the recorder, goal store, and retry record — and repaint through
/// the TUI's own closures, so the wiring is bundled here instead of widening
/// `SlashContext` for every command.
@MainActor
struct SessionCommandContext {
    let agent: Agent
    let modal: ModalHost
    let frame: CodingFrame
    let cwd: String
    let sessionStore: SessionStore
    let recorderBox: RecorderBox
    let goalStore: GoalStore
    let retry: TurnRetryState
    let attachments: AttachmentStore
    let dequeueCycle: DequeueCycleState
    /// Current terminal width, queried per invocation so recaps/separators
    /// render at the live width.
    let terminalWidth: @MainActor @Sendable () -> Int
    /// Append lines to the terminal's native scrollback.
    let commit: @MainActor @Sendable ([String]) -> Void
    let requestRender: @MainActor @Sendable () -> Void
    /// Re-derive the live tail from the transcript renderer.
    let recomputeTranscript: @MainActor @Sendable () -> Void
    /// Refresh the prompt-box breadcrumb / meta / state line.
    let updateFrameStatus: @MainActor @Sendable () -> Void
    /// Patch or strip the ACTIVE `<goal_context>` block on the system prompt
    /// to match the goal store's current status.
    let applyGoalContext: @MainActor @Sendable () -> Void
    /// Start one hidden goal-continuation turn from idle (the single kick
    /// site — see runCodingTUIInternal).
    let kickGoalContinuation: @MainActor @Sendable () -> Void
    /// The TUI's single submission path; `/retry` funnels resubmits through
    /// it so they drive the exact same streaming/steering UI.
    let submitBuiltPrompt: @MainActor @Sendable (String, [ImageContent]) -> Void
}

/// Register the session-lifecycle slash commands. Called from
/// `runCodingTUIInternal` after the builtins and custom commands, preserving
/// the pre-extraction registration order.
@MainActor
func registerSessionSlashCommands(_ registry: SlashCommandRegistry, ctx: SessionCommandContext) {
    let agent = ctx.agent
    let modal = ctx.modal
    let frame = ctx.frame
    let cwd = ctx.cwd
    let sessionStore = ctx.sessionStore
    let recorderBox = ctx.recorderBox
    let goalStore = ctx.goalStore
    let retry = ctx.retry
    let attachments = ctx.attachments
    let dequeueCycle = ctx.dequeueCycle
    let terminalWidth = ctx.terminalWidth
    let commit = ctx.commit
    let requestRender = ctx.requestRender
    let recomputeTranscript = ctx.recomputeTranscript
    let updateFrameStatus = ctx.updateFrameStatus
    let applyGoalContext = ctx.applyGoalContext
    let kickGoalContinuation = ctx.kickGoalContinuation
    let submitBuiltPrompt = ctx.submitBuiltPrompt

    // `/resume` — restore a previous session into the running TUI. Opens an
    // arrow-key picker; on confirm it repoints persistence at the chosen
    // session file, swaps the agent's message history, and repaints a recap.
    registry.register(SlashCommand(
        name: "resume",
        description: "Restore a previous session",
        handler: { _, _ in
            let sessions = await sessionStore.list()
            let picker = SessionResumeModal(
                sessions: sessions,
                currentSessionId: recorderBox.sessionId,
                onSelect: { info in
                    Task { @MainActor in
                        // `info.id` comes from the on-disk listing, so its
                        // format is always valid; `try?` only guards the
                        // (unreachable here) invalid-id throw.
                        guard let loaded = try? await sessionStore.resolveResume(
                            .id(info.id), cwd: cwd) else { return }

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
                        // Clear per-session transient state so a pending /retry,
                        // queued steer, attachment, or dequeue cursor from the
                        // outgoing session can't leak into the restored one.
                        resetSessionTransientState(
                            agent: agent,
                            retry: retry,
                            attachments: attachments,
                            dequeueCycle: dequeueCycle
                        )
                        // Goals are session-scoped: drop the outgoing session's
                        // goal and strip its <goal_context> so it can't drive the
                        // restored session. A pending continuation kick re-checks
                        // goalStore after its idle wait and bails once inactive.
                        goalStore.stop()
                        applyGoalContext()
                        var recap: [String] = [
                            "",
                            Theme.borderText(String(repeating: "─", count: max(8, terminalWidth() - 2))),
                            Theme.accentText("↻ resumed session \(info.id.prefix(8)) · \(loaded.messages.count) messages", bold: false),
                        ]
                        let snapshot = TranscriptSnapshot.render(loaded.messages, width: terminalWidth())
                        if !snapshot.isEmpty { recap.append(contentsOf: [""] + snapshot) }
                        commit(recap)

                        modal.close()
                        recomputeTranscript()
                        updateFrameStatus()
                        requestRender()
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
    registry.register(SlashCommand(
        name: "new",
        description: "Start a fresh session",
        aliases: ["clear"],
        handler: { _, _ in
            // A fresh session starts with no goal — drop any active one (and its
            // <goal_context>) before minting the new id so it can't carry over.
            goalStore.stop()
            applyGoalContext()
            await performNewSession(
                recorderBox: recorderBox,
                sessionStore: sessionStore,
                agent: agent,
                cwd: cwd,
                attachments: attachments,
                retry: retry,
                dequeueCycle: dequeueCycle,
                frame: frame,
                width: terminalWidth(),
                commit: commit,
                recompute: recomputeTranscript,
                updateStatus: updateFrameStatus,
                requestRender: requestRender
            )
        }
    ))

    // `/retry` — resubmit the last prompt when its turn ended in error or was
    // aborted. Idle-gated by the dispatcher; resubmission goes through the
    // normal streaming path so queued/steer UI behaves identically.
    registry.register(SlashCommand(
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

    // `/goal` — autonomous goal mode (in-memory, session-scoped).
    //   /goal <text>      set + start the objective (kicks the loop)
    //   /goal             show the current goal
    //   /goal off|stop    clear the goal
    //   /goal resume      un-pause after the guardrail cap tripped
    registry.register(SlashCommand(
        name: "goal",
        description: "Set/show/stop an autonomous goal the agent pursues across turns",
        handler: { ctx, args in
            let arg = args.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = arg.lowercased()

            // Show current goal.
            if arg.isEmpty {
                let s = goalStore.snapshot()
                switch s.status {
                case .active:
                    ctx.notify(Style.dimmed("  🎯 goal (active): \(s.objective)"))
                case .paused:
                    ctx.notify(Style.dimmed("  🎯 goal (paused — cap hit): \(s.objective) · /goal resume to keep going"))
                case .complete:
                    ctx.notify(Style.dimmed("  🎯 goal: complete"))
                case .dropped:
                    ctx.notify(Style.dimmed("  /goal: no active goal — /goal <objective> to start one"))
                }
                return
            }

            // Stop / clear.
            if lower == "off" || lower == "stop" {
                goalStore.stop()
                // A continuation kick already in flight re-checks goalStore after
                // its idle wait and bails when the goal isn't active, so stopping
                // here is enough — no need to touch the user's steering queue.
                applyGoalContext()
                updateFrameStatus()
                requestRender()
                ctx.notify(Style.dimmed("  🎯 goal cleared"))
                return
            }

            // Resume after a cap pause.
            if lower == "resume" {
                let s = goalStore.snapshot()
                guard s.status == .paused else {
                    ctx.notify(Style.dimmed("  /goal resume: no paused goal to resume"))
                    return
                }
                // Logged-out gate: a continuation turn on the sentinel model
                // would only die with a provider error.
                guard !ctx.sessionProviders.isLoggedOut else {
                    ctx.notify(Style.dimmed("  /goal: no provider configured — /login to sign in"))
                    return
                }
                goalStore.resume()
                applyGoalContext()
                updateFrameStatus()
                requestRender()
                ctx.notify(Style.dimmed("  🎯 goal resumed"))
                if !agent.state.isStreaming { kickGoalContinuation() }
                return
            }

            // Set + start a new objective. Clamp its length first so a pasted
            // mega-string can't bloat the system prompt / every continuation.
            // Any continuation kick still pending from a prior objective re-checks
            // goalStore after its idle wait and picks up this new objective (or
            // bails), so there's nothing to drop.
            // Logged-out gate: starting a goal would immediately kick a hidden
            // continuation turn on the sentinel model and fail with a provider
            // error instead of this hint.
            guard !ctx.sessionProviders.isLoggedOut else {
                ctx.notify(Style.dimmed("  /goal: no provider configured — /login to sign in"))
                return
            }
            var objective = arg
            if objective.count > GoalMode.maxObjectiveChars {
                objective = String(objective.prefix(GoalMode.maxObjectiveChars))
                ctx.notify(Style.dimmed("  /goal: objective truncated to \(GoalMode.maxObjectiveChars) characters"))
            }
            goalStore.start(objective)
            applyGoalContext()
            updateFrameStatus()
            requestRender()
            // Echo a bounded preview — the full objective can be long.
            let echo = objective.count > 120 ? String(objective.prefix(120)) + "…" : objective
            ctx.notify(Style.dimmed("  🎯 goal set: \(echo)"))
            // Kick the loop now if idle; otherwise the running turn already sees
            // the ACTIVE context and its .agentEnd will continue.
            if !agent.state.isStreaming { kickGoalContinuation() }
        }
    ))
}
