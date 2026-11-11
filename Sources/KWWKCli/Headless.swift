import Foundation
import KWWKAI
import KWWKAgent
import NIOConcurrencyHelpers

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
///   - background tools are available while the top-level Agent loop is live,
///     but unfinished tasks are cancelled as soon as that loop returns;
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
    modelOverride: String? = nil,
    context1m: Bool = false,
    resume: SessionResume = .none
) async throws -> Int32 {
    let resolved = try await resolveAgentAuth(
        modelOverride: modelOverride,
        context1m: context1m
    )

    // Resolve session persistence: a fresh id by default, or a stored
    // transcript when `--resume` / `--session` was passed.
    let store = SessionStore(directory: cliSessionDirectory(cwd: cwd))
    let resolvedResume = try await store.resolveResume(resume, cwd: cwd)
    let sessionId = resolvedResume.sessionId

    let environment = ProcessInfo.processInfo.environment
    let agent = await makeHeadlessCodingAgent(CodingAgentConfig(
        model: resolved.model,
        cwd: cwd,
        tools: tools,
        contextFiles: loadProjectContextFiles(cwd: cwd),
        skillDirectories: Skills.defaultDirectories(cwd: cwd, includeUserDirectory: true),
        subagents: defaultCLISubagents(for: tools, selection: builtinSubagents),
        sessionId: sessionId,
        authResolver: resolved.authResolver,
        autoCompactThreshold: 0.75,
        bashEnvironment: environment,
        bashShellPath: cliShellPath(environment: environment),
        subagentTranscriptStore: store.subagentTranscripts
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
    struct Box: Sendable {
        var finalStopReason: StopReason?
        var needsTrailingNewline = false
    }
    let box = NIOLockedValueBox(Box())

    let unsubscribe = agent.subscribe { event, _ in
        switch event {
        case .messageUpdate(_, let inner):
            if case .textDelta(_, let delta, _) = inner {
                writeStdout(delta)
                box.withLockedValue {
                    $0.needsTrailingNewline = !delta.hasSuffix("\n")
                }
            }

        case .messageEnd:
            // Separate consecutive assistant messages (tool-use → text →
            // more text) with a newline so piped output doesn't run
            // together.
            let needs = box.withLockedValue { state -> Bool in
                let v = state.needsTrailingNewline
                state.needsTrailingNewline = false
                return v
            }
            if needs { writeStdout("\n") }

        case .agentEnd(_, let summary):
            box.withLockedValue { $0.finalStopReason = summary.finalStopReason }
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
        await cleanupHeadlessAgent(agent)
        let msg = error.displayDescription
        writeStderr("kwwk: \(msg)\n")
        return 1
    }

    let stop = box.withLockedValue { $0.finalStopReason }
    await cleanupHeadlessAgent(agent)
    return stop == .stop ? 0 : 1
}

/// Build a one-shot Agent with the config's normal background capabilities.
/// The caller owns the top-level loop boundary and must call
/// `cleanupHeadlessAgent` immediately after it returns; cleanup retires the
/// Agent and kills unfinished work instead of waiting for background tasks to
/// extend the one-shot process lifetime.
func makeHeadlessCodingAgent(_ input: CodingAgentConfig) async -> Agent {
    var config = input
    config.backgroundAutoContinue = false
    let agent = await makeCodingAgent(config).agent
    // `runHeadlessInternal` writes text deltas straight to stdout, which
    // cannot be taken back: an attempt that already streamed output is not
    // replayed after a provider failure (thinking-only attempts still are).
    agent.streamsToIrreversibleSink = true
    return agent
}

/// Deterministic one-shot teardown for both success and failure paths. This is
/// deliberately called when the top-level prompt returns rather than when the
/// background registry becomes idle: headless work may use background tools
/// during the Agent loop, but cannot keep the process alive afterward.
func cleanupHeadlessAgent(_ agent: Agent) async {
    await agent.closeSession()
}

private func writeStdout(_ s: String) {
    FileHandle.standardOutput.write(Data(s.utf8))
}

private func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}
