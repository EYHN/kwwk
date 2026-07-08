import Foundation
import KWWKAI
import KWWKAgent

/// Whether a transcript message is a REAL user prompt — something the human
/// typed (or a custom-command template submitted on their behalf) — as opposed
/// to one of the synthetic user-role messages the system injects. Only real
/// prompts are valid rewind targets:
///   - hidden goal continuations carry the goal marker (GoalTool),
///   - background-task notifications are steered in by the bg bridge and
///     recognised by their lead-in (BgNotificationSummary),
///   - a compaction recap is the summary message the compactor swapped in —
///     nothing exists before it in the projected context, so rewinding to it
///     would leave the agent with an empty, meaningless history.
func isRewindableUserPrompt(_ message: Message) -> Bool {
    guard case .user(let u) = message else { return false }
    if isHiddenGoalContinuation(message) { return false }
    let text = u.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined(separator: "\n")
    if BgNotificationSummary.parse(text) != nil { return false }
    if text.hasPrefix("<previous-session-summary>") { return false }
    return true
}

/// Indices into `messages` of every rewindable user prompt, in transcript
/// order (oldest first). The selector lists them in this order so the newest
/// prompt sits at the bottom, matching omp's message picker.
func rewindCandidateIndices(_ messages: [Message]) -> [Int] {
    messages.enumerated().compactMap { isRewindableUserPrompt($1) ? $0 : nil }
}

/// Single-line selector row for a rewind candidate: text blocks flattened
/// onto one line (with the `[image]` marker), clipped to 80 chars like the
/// queued-prompt previews.
@MainActor
func rewindRowLabel(_ msg: Message) -> String {
    let flat = queuedPromptPreview(msg)
    return flat.count <= 80 ? flat : String(flat.prefix(80)) + "…"
}

/// Open the "rewind to message" selector (double-Esc from idle, or `/rewind`).
/// Lists every rewindable user prompt in the transcript; on confirm the live
/// context is truncated to just BEFORE the chosen prompt (the prompt and
/// everything after it are dropped), the cut is persisted, the screen is
/// cleared and the kept prefix re-rendered in place of the old transcript
/// (omp's branch treatment), and the dropped prompt's text is placed back
/// into the editor for edit-and-resubmit. Esc/cancel closes the picker with
/// nothing changed.
///
/// Callers open this from idle (not streaming, not compacting), but idleness
/// does NOT hold for the picker's whole lifetime: a background task can finish
/// behind the modal, and its bridge steers a notification and kicks
/// `agent.continue()` whenever the agent is idle — growing the transcript the
/// snapshot below was taken from. The rewind is FORCED anyway (matching omp's
/// `session.branch`): confirm aborts any turn that started behind the picker,
/// waits for the run to fully tear down, and truncates the LIVE transcript at
/// the chosen prompt — the newly grown tail is simply cut along with
/// everything else after the cut. There is no cancel path.
@MainActor
func openRewindSelector(
    agent: Agent,
    modal: ModalHost,
    frame: CodingFrame,
    sessionStore: SessionStore,
    recorderBox: RecorderBox,
    retry: TurnRetryState,
    attachments: AttachmentStore,
    dequeueCycle: DequeueCycleState,
    terminalWidth: @escaping @MainActor @Sendable () -> Int,
    commit: @escaping @MainActor @Sendable ([String]) -> Void,
    replaceTranscript: @escaping @MainActor @Sendable ([String]) -> Void,
    recomputeTranscript: @escaping @MainActor @Sendable () -> Void,
    updateFrameStatus: @escaping @MainActor @Sendable () -> Void,
    requestRender: @escaping @MainActor @Sendable () -> Void
) {
    let messages = agent.state.messages
    let candidates = rewindCandidateIndices(messages)
    guard !candidates.isEmpty else {
        commit(["", Style.dimmed("  no messages to rewind to")])
        updateFrameStatus()
        requestRender()
        return
    }

    modal.open(ListSelectorModal(
        title: "Rewind to message",
        items: candidates.map { ListSelectorModal.Item(label: rewindRowLabel(messages[$0])) },
        selectedIndex: candidates.count - 1,
        onSelect: { row in
            // Close before doing anything else so confirm is one-shot:
            // routeConfirm gates only on `isOpen`, and a key-repeat Enter
            // would otherwise re-run the whole rewind body.
            modal.close()

            let cut = candidates[row]
            let captured = messages[cut]

            // The rest of the confirm is async (it may have to wind down an
            // in-flight run), so it lives on a single MainActor task; the
            // one-shot close above already happened synchronously.
            Task { @MainActor in
                // A bg-task notification may have kicked a turn behind the
                // open picker (see the doc comment). The rewind is forced:
                // stop that turn dead — same abort idiom as Esc-interrupt,
                // minus the /retry arming (the turn is being rewound away,
                // not resubmitted). The steering queue is cleared BEFORE the
                // idle wait so the bridge's post-agentEnd safety drain
                // (Agent+Background.swift) finds nothing to `continue()` on.
                // (No `.aborting` frame mode here, unlike Esc: the whole
                // wind-down happens inside this awaited block, and the
                // `.agentEnd` handler flips frameMode back to .idle before
                // `waitForIdle` resumes — the streaming spinner covers the
                // brief interim.)
                if agent.state.isStreaming {
                    agent.abort()
                    agent.clearAllQueues()
                }
                // `runLifecycle` awaits every `.agentEnd` listener BEFORE it
                // resumes idle waiters, so on the far side of this wait the
                // TUI's .agentEnd handler has already run: frameMode is back
                // to .idle and any /retry record it armed is about to be
                // cleared by resetSessionTransientState below. When the agent
                // is already idle this resumes immediately.
                await agent.waitForIdle()

                // Recompute the cut against the LIVE transcript: behind an
                // idle picker the message array only ever grows by appending,
                // so the captured index must still name the same prompt. If
                // it doesn't, something replaced the projection wholesale
                // (auto-compaction cannot — the picker never opens while
                // compacting, and a mid-run compaction dies with the abort
                // above before its between-turns swap) — that is omp's
                // "invalid entry" case and a bug, not a user state.
                //
                // Residual race, same shape as the bridge's steer-vs-continue
                // note (Agent+Background.swift): a bg notification landing in
                // the suspension between waitForIdle resuming and this
                // MainActor block running can steer + kick `continue()`, and
                // that run's appends would interleave with the truncation.
                // The window is a few instructions wide and the notification
                // itself is synthetic, so we accept it — the alternative is
                // an abortable atomic idle-and-freeze on the agent.
                let live = agent.state.messages
                precondition(
                    cut < live.count && live[cut] == captured,
                    "rewind: live transcript no longer contains the chosen prompt at index \(cut)"
                )
                let kept = Array(live[..<cut])
                let removed = live.count - cut
                agent.state.messages = kept

                // A stale /retry record (including one the aborted turn's
                // .agentEnd just armed) or queued steer must not resurrect a
                // message that was just rewound away.
                resetSessionTransientState(
                    agent: agent,
                    retry: retry,
                    attachments: attachments,
                    dequeueCycle: dequeueCycle
                )

                // The dropped prompt goes back into the editor for
                // edit-and-resubmit, flattened to one line like the Alt+↑
                // dequeue (image blocks are not restored). Editor + live zone
                // are updated BEFORE the repaint below so it draws the final
                // post-rewind frame in one pass.
                frame.input.value = queuedMessageBodyText(captured)
                    .replacingOccurrences(of: "\n", with: " ")
                frame.input.moveEnd()
                recomputeTranscript()
                updateFrameStatus()

                // Persist the cut as a projection replacement (the same store
                // entry compaction uses): it resets the recorder's baseline so
                // post-rewind turns flush from the new count, and a later
                // /resume loads the kept prefix instead of replaying the
                // dropped tail — the JSONL store is append-only, so the tail
                // can't be deleted, only superseded. Persisted BEFORE the
                // repaint so the recap below can read the updated visual
                // history back from the store.
                await recorderBox.recorder.recordCompaction(
                    messages: kept,
                    messagesCompacted: removed,
                    reason: .rewind
                )

                // omp's branch treatment: clear the screen (and scrollback,
                // where the terminal allows) and re-render the surviving
                // transcript — the dropped tail vanishes from view instead of
                // piling a recap under the stale conversation. The recap
                // replays the store's visual history (displayMessages), NOT
                // `kept`: after a context compaction the model context starts
                // with a `<previous-session-summary>` message the user never
                // saw, and everything the compaction summarized away is still
                // part of the on-screen history. Falls back to the kept model
                // prefix only when the session file can't be read back.
                // The welcome header is re-emitted on top by the repaint; a
                // trailing note keeps the cut visible after the clear.
                let display = (try? await sessionStore.load(id: recorderBox.sessionId))?
                    .displayMessages ?? kept
                var snapshot = TranscriptSnapshot.render(display, width: terminalWidth())
                snapshot.append(contentsOf: [
                    "",
                    Theme.accentText(
                        "⤺ rewound · dropped \(removed) message\(removed == 1 ? "" : "s")",
                        bold: false
                    ),
                ])
                replaceTranscript(snapshot)
                requestRender()
            }
        },
        onCancel: { modal.close() }
    ))
}
