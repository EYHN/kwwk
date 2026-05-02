import Foundation
import KWWKAI
import KWWKAgent

/// Internal implementation of `kwwk -p <prompt>` — a one-shot, non-interactive
/// coding-agent run. Mirrors the ergonomics of `claude -p`:
///
///   - assistant text streams to **stdout** as it's produced; stdout
///     carries *only* the assistant's reply so the output can be piped
///     without a post-filter;
///   - no chrome is written to stderr during a successful run (no
///     banner, no tool breadcrumbs, no summary);
///   - genuine failures — auth missing, stream error, abort — *do* print
///     a one-line message to stderr so the user isn't left staring at a
///     silent non-zero exit;
///   - exit code is `0` when the model reached a clean stop, `1` otherwise.
///
/// Credentials are resolved from the OAuth store exactly like
/// `runCodingTUIInternal` — whichever provider `kwwk login` last wrote wins.
///
/// `@MainActor` matches the TUI entry point so the headless path can
/// reuse `AutoCompactController` (which is main-actor-isolated) without
/// cross-actor hops. The runtime impact is zero — `kwwk -p` is one-shot
/// and the main actor isn't serving UI work.
@MainActor
func runHeadlessInternal(
    prompt text: String,
    cwd: String,
    tools: CodingTools,
    builtinSubagents: BuiltinSubagentSelection = .all,
    thinkingLevel: ThinkingLevel = .medium,
    autoCompactThreshold: Double? = 0.75,
    modelOverride: String? = nil,
    context1m: Bool = false
) async throws -> Int32 {
    let resolved = try await resolveAgentAuth(modelOverride: modelOverride, context1m: context1m)

    let bgManager = BackgroundTaskManager()
    let sessionId = UUID().uuidString
    let agent = await makeCodingAgent(CodingAgentConfig(
        model: resolved.model,
        cwd: cwd,
        tools: tools,
        backgroundManager: bgManager,
        subagents: defaultCLISubagents(for: tools, selection: builtinSubagents),
        sessionId: sessionId,
        authResolver: resolved.authResolver
    ))
    agent.state.thinkingLevel = thinkingLevel

    // Auto-compact: watch per-turn usage and summarize the transcript
    // when it approaches the model's contextWindow. Without this, long
    // runs (zork, ML autotune, blind-maze exploration) blow past the
    // context limit mid-reasoning. All UI callbacks are no-ops — in
    // headless mode we intentionally don't emit compact chrome to
    // stdout/stderr; stop-reason reporting stays exclusively on the
    // assistant-message path.
    let autoCompact = AutoCompactController(
        agent: agent,
        backgroundManager: bgManager,
        sessionId: sessionId,
        threshold: autoCompactThreshold,
        onStatusChange: { _ in },
        onUsageChange: { _ in },
        onCompactFinished: { _ in }
    )
    agent.betweenTurns = { context, _ in
        await autoCompact.maybeCompactInline(context: context)
    }

    // Shared mutable state carried out of the @Sendable listener. All
    // reads/writes go through the lock — listener callbacks can fire on
    // arbitrary threads.
    final class Box: @unchecked Sendable {
        var finalStopReason: StopReason?
        var needsTrailingNewline = false
        let lock = NSLock()
    }
    let box = Box()

    let unsubscribe = agent.subscribe { event, _ in
        switch event {
        case .messageUpdate(_, let inner):
            if case .textDelta(_, let delta, _) = inner {
                writeStdout(delta)
                box.lock.withLock {
                    box.needsTrailingNewline = !delta.hasSuffix("\n")
                }
            }

        case .messageEnd:
            // Separate consecutive assistant messages (tool-use → text →
            // more text) with a newline so piped output doesn't run
            // together.
            let needs = box.lock.withLock { () -> Bool in
                let v = box.needsTrailingNewline
                box.needsTrailingNewline = false
                return v
            }
            if needs { writeStdout("\n") }

        case .agentEnd(_, let summary):
            box.lock.withLock { box.finalStopReason = summary.finalStopReason }
            if summary.finalStopReason != .stop,
               let err = agent.state.errorMessage {
                writeStderr("kwwk: \(err)\n")
            }

        default:
            break
        }
        // `observe` fires a post-run compact if the final turn crossed
        // the threshold — a no-op for one-shot runs that ended cleanly
        // under the limit, essential for chained tool-use runs that
        // just squeaked past it.
        await autoCompact.observe(event)
    }
    defer { unsubscribe() }

    do {
        try await agent.prompt(text)
    } catch {
        await agent.closeSession()
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        writeStderr("kwwk: \(msg)\n")
        return 1
    }

    let stop = box.lock.withLock { box.finalStopReason }
    await agent.closeSession()
    return stop == .stop ? 0 : 1
}

private func writeStdout(_ s: String) {
    FileHandle.standardOutput.write(Data(s.utf8))
}

private func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}
