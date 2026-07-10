import Foundation
import KWWKAI
import KWWKAgent

/// Whether a transcript message is a REAL user prompt — something the human
/// typed (or a custom-command template submitted on their behalf) — as opposed
/// to one of the synthetic user-role messages the system injects. Only real
/// prompts are valid rewind targets:
///   - hidden goal continuations carry the goal marker (GoalTool),
///   - runtime asides carry an explicit source marker,
///   - a compaction recap is the summary message the compactor swapped in —
///     nothing exists before it in the projected context, so rewinding to it
///     would leave the agent with an empty, meaningless history.
func isRewindableUserPrompt(_ message: Message) -> Bool {
    guard case .user(let u) = message else { return false }
    if isHiddenGoalContinuation(message) { return false }
    if u.source == .runtime { return false }
    let text = u.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined(separator: "\n")
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
    requestRender: @escaping @MainActor @Sendable () -> Void,
    isCurrentSession: @escaping @MainActor @Sendable () -> Bool = { true },
    setRewinding: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
) {
    let messages = agent.state.messages
    // Persistence is part of the session identity. Never resolve it through
    // the mutable box after an await: `/new` or `/resume` may have installed a
    // different recorder by then.
    let expectedRecorder = recorderBox.recorder
    let expectedSessionId = recorderBox.sessionId
    let stillCurrent: @MainActor @Sendable () -> Bool = {
        isCurrentSession()
            && recorderBox.recorder === expectedRecorder
            && recorderBox.sessionId == expectedSessionId
    }
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
            // Mark busy before closing: ModalHost.close synchronously restores
            // the ordinary frame, whose Enter path must already reject a
            // session switch or prompt until this transaction settles.
            setRewinding(true)
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
                defer { setRewinding(false) }
                guard stillCurrent() else { return }

                // A background wake can win the tiny idle-to-maintenance race.
                // Abort that contender and retry a bounded number of times; a
                // retired/replaced Agent cannot spin this task indefinitely.
                for _ in 0..<8 {
                    guard stillCurrent() else { return }
                    if agent.state.isStreaming {
                        agent.abort()
                        agent.clearAllQueues()
                    }
                    // Agent listeners (including persistence) finish before
                    // idle waiters resume, so the prior turn is fully settled.
                    await agent.waitForIdle()
                    guard stillCurrent() else { return }

                    do {
                        let applied = try await agent.withMaintenance { @MainActor in
                            guard stillCurrent() else { return false }

                            // Recompute against the live transcript under the
                            // same exclusive ownership used by manual compact.
                            // A changed snapshot is stale, not process-fatal.
                            let live = agent.state.messages
                            guard cut < live.count, live[cut] == captured else {
                                return false
                            }
                            let kept = Array(live[..<cut])
                            let removed = live.count - cut
                            agent.state.messages = kept

                            resetSessionTransientState(
                                agent: agent,
                                retry: retry,
                                attachments: attachments,
                                dequeueCycle: dequeueCycle
                            )

                            frame.input.value = queuedMessageBodyText(captured)
                                .replacingOccurrences(of: "\n", with: " ")
                            frame.input.moveEnd()
                            recomputeTranscript()
                            updateFrameStatus()

                            // Persist through the recorder captured with this
                            // Agent/session, never whatever the mutable box may
                            // contain after an await. Ownership stays held so a
                            // queued runtime/user turn cannot overtake the marker.
                            await expectedRecorder.recordCompaction(
                                messages: kept,
                                messagesCompacted: removed,
                                reason: .rewind
                            )
                            guard stillCurrent() else { return false }

                            let display = (try? await sessionStore.load(id: expectedSessionId))?
                                .displayMessages ?? kept
                            guard stillCurrent() else { return false }
                            var snapshot = TranscriptSnapshot.render(
                                display,
                                width: terminalWidth()
                            )
                            snapshot.append(contentsOf: [
                                "",
                                Theme.accentText(
                                    "⤺ rewound · dropped \(removed) message\(removed == 1 ? "" : "s")",
                                    bold: false
                                ),
                            ])
                            replaceTranscript(snapshot)
                            requestRender()
                            return true
                        }
                        // `false` means the selection/session snapshot became
                        // stale; retrying it against a changed transcript would
                        // target the wrong message.
                        if applied { return }
                        return
                    } catch AgentError.alreadyRunning {
                        await Task.yield()
                    } catch {
                        if stillCurrent() {
                            commit(["", Style.error("  rewind failed: \(error)")])
                            requestRender()
                        }
                        return
                    }
                }

                if stillCurrent() {
                    commit(["", Style.error("  rewind: agent remained busy; try again")])
                    requestRender()
                }
            }
        },
        onCancel: { modal.close() }
    ))
}
