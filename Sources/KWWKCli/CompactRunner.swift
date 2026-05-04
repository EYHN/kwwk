import Foundation
import KWWKAgent

/// Outcome of a `performCompact` call. Callers decide how to render
/// each case (status line, notification, silent log, etc.) - the runner
/// stays pure.
enum CompactOutcome: Sendable {
    case compacted(messagesCompacted: Int, hasRunningTasksLedger: Bool)
    case refusedAgentBusy
    case refusedTooFewMessages(count: Int)
    case failed(String)
}

/// Run the shared compact flow: validate -> grab a running-task snapshot ->
/// one-shot LLM summarize -> replace `agent.state.messages` with a
/// `<previous-session-summary>` recap. Returns the outcome; never
/// surfaces anything to the UI itself.
///
/// Used by the manual `/compact` slash command. The automatic path uses
/// the same KWWKAgent compactor directly from `Agent`, so every agent
/// entry point shares one bottom-layer behavior.
@MainActor
func performCompact(
    agent: Agent,
    backgroundManager: BackgroundTaskManager,
    sessionId: String,
    // The isStreaming check prevents racing agent.state.messages with a
    // live agent loop. That is the right default for /compact (the user
    // can invoke it any time) and for the post-agentEnd deferred path.
    // For the between-turns hook the guard is inverted: we run *inside*
    // the loop, in a windowed gap where no LLM call is in flight and the
    // loop is awaiting the hook - safe to compact. Pass true to skip.
    ignoreStreaming: Bool = false
) async -> CompactOutcome {
    let outcome = await AgentContextCompactor.compactAgent(
        agent: agent,
        backgroundManager: backgroundManager,
        sessionId: sessionId,
        config: agent.autoCompact?.config ?? AgentContextCompactionConfig(),
        ignoreStreaming: ignoreStreaming
    )

    switch outcome {
    case .compacted(let messagesCompacted, let hasRunningTasksLedger):
        return .compacted(
            messagesCompacted: messagesCompacted,
            hasRunningTasksLedger: hasRunningTasksLedger
        )
    case .refusedAgentBusy:
        return .refusedAgentBusy
    case .refusedTooFewMessages(let count):
        return .refusedTooFewMessages(count: count)
    case .failed(let reason):
        return .failed(reason)
    }
}

/// Render a dimmed, full-width boundary marker that sits in scrollback
/// to show the user "everything above this line was summarized". Used
/// by both `/compact` and the auto-compact driver so the two paths
/// leave an identical visual trail.
///
/// Returns three lines (leading blank, rule, trailing blank) so callers
/// can hand them straight to `TUI.commit(_:)`.
func renderCompactBoundary(messagesCompacted: Int, hasRunningTasksLedger: Bool, width: Int) -> [String] {
    var label = "compacted"
    if hasRunningTasksLedger { label += " (+ running-task ledger)" }
    let prefix = "── "
    let spacedLabel = " \(label) "
    let overhead = prefix.count + spacedLabel.count
    let fill = max(3, width - overhead)
    let rule = Style.dimmed(prefix + spacedLabel + String(repeating: "─", count: fill))
    return ["", rule, ""]
}
