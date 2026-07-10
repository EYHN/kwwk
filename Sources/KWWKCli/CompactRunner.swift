import Foundation
import KWWKAI
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

/// Run the shared compact flow: plan a tool-safe cut, iteratively update the
/// durable summary, retain the recent raw tail, attach deterministic file and
/// running-task facts, then revision-check the projected replacement. Returns
/// the outcome; never surfaces anything to the UI itself.
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
    ignoreStreaming: Bool = false,
    settle: @escaping @MainActor @Sendable (CompactOutcome) async -> Void = { _ in }
) async -> CompactOutcome {
    if !ignoreStreaming && agent.state.isStreaming {
        let outcome = CompactOutcome.refusedAgentBusy
        await settle(outcome)
        return outcome
    }
    let compact: @Sendable (CancellationHandle?) async -> AgentContextCompactionOutcome = { cancellation in
        await AgentContextCompactor.compactAgent(
            agent: agent,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            config: agent.autoCompact?.config ?? AgentContextCompactionConfig(),
            // `withMaintenance` is the authoritative ownership guard. Skip
            // the secondary streaming check while that ownership is held.
            ignoreStreaming: true,
            cancellation: cancellation
        )
    }

    let outcome: CompactOutcome
    if ignoreStreaming {
        // The automatic path already owns the enclosing Agent run.
        outcome = compactOutcome(from: await compact(nil))
        await settle(outcome)
    } else {
        do {
            outcome = try await agent.withMaintenance { cancellation in
                let outcome = compactOutcome(from: await compact(cancellation))
                // Settlement is part of the maintenance transaction. In
                // particular, background-delivery idle waiters are not resumed
                // until the compacted projection is durable and its UI boundary
                // has been committed.
                await settle(outcome)
                return outcome
            }
        } catch AgentError.alreadyRunning {
            outcome = .refusedAgentBusy
            await settle(outcome)
        } catch {
            outcome = .failed("\(error)")
            await settle(outcome)
        }
    }

    return outcome
}

private func compactOutcome(
    from outcome: AgentContextCompactionOutcome
) -> CompactOutcome {
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
