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
/// Credentials are resolved exactly like `runCodingTUIInternal`: the CLI checks
/// `~/.kwwk/oauth.json` first, then supported API-key environment variables.
///
/// `@MainActor` matches the TUI entry point. The runtime impact is zero:
/// `kwwk -p` is one-shot and the main actor isn't serving UI work.
@MainActor
func runHeadlessInternal(
    prompt text: String,
    cwd: String,
    tools: CodingTools,
    builtinSubagents: BuiltinSubagentSelection = .all,
    thinkingLevel: ThinkingLevel = .medium,
    autoCompactThreshold: Double? = 0.75,
    modelOverride: String? = nil,
    context1m: Bool = false,
    resume: SessionResume = .none
) async throws -> Int32 {
    let resolved = try await resolveAgentAuth(
        modelOverride: modelOverride,
        context1m: context1m
    )

    let bgManager = BackgroundTaskManager()

    // Resolve session persistence: a fresh id by default, or a stored
    // transcript when `--resume` / `--session` was passed.
    let store = SessionStore(directory: SessionStore.defaultDirectory())
    let resolvedResume = await store.resolveResume(resume, cwd: cwd)
    let sessionId = resolvedResume.sessionId

    let environment = ProcessInfo.processInfo.environment
    let tmuxManager = tools.contains(.tmux)
        ? try cliTmuxManager(environment: environment)
        : nil
    let agent = await makeCodingAgent(CodingAgentConfig(
        model: resolved.model,
        cwd: cwd,
        tools: tools,
        contextFiles: loadProjectContextFiles(cwd: cwd),
        skillDirectories: Skills.defaultDirectories(cwd: cwd, includeUserDirectory: true),
        backgroundManager: bgManager,
        subagents: defaultCLISubagents(for: tools, selection: builtinSubagents),
        sessionId: sessionId,
        authResolver: resolved.authResolver,
        autoCompactThreshold: autoCompactThreshold,
        bashEnvironment: environment,
        bashShellPath: cliShellPath(environment: environment),
        tmuxManager: tmuxManager
    ))
    agent.state.thinkingLevel = thinkingLevel

    // Seed the transcript from disk when resuming so the model continues
    // where it left off.
    if !resolvedResume.messages.isEmpty {
        agent.state.messages = resolvedResume.messages
    }

    // Persist the transcript as it grows. `ensureCreated` writes the header
    // for a brand-new session; resumed sessions already have one.
    let recorder = SessionRecorder(
        store: store,
        sessionId: sessionId,
        cwd: cwd,
        model: resolved.model.id,
        provider: resolved.model.provider,
        persistedCount: resolvedResume.persistedCount
    )
    if !resolvedResume.resumed {
        await recorder.ensureCreated()
    }
    let unsubscribeRecorder = recorder.attach(to: agent)
    defer { unsubscribeRecorder() }

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
    }
    defer { unsubscribe() }

    do {
        try await agent.prompt(text)
    } catch {
        await agent.closeSession()
        await tmuxManager?.teardown()
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        writeStderr("kwwk: \(msg)\n")
        return 1
    }

    let stop = box.lock.withLock { box.finalStopReason }
    await agent.closeSession()
    await tmuxManager?.teardown()
    return stop == .stop ? 0 : 1
}

private func writeStdout(_ s: String) {
    FileHandle.standardOutput.write(Data(s.utf8))
}

private func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}
