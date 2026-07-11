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

    // Resolve session persistence: a fresh id by default, or a stored
    // transcript when `--resume` / `--session` was passed.
    let store = SessionStore(directory: SessionStore.defaultDirectory())
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
        autoCompactThreshold: autoCompactThreshold,
        bashEnvironment: environment,
        bashShellPath: cliShellPath(environment: environment)
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
        await cleanupHeadlessAgent(agent)
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        writeStderr("kwwk: \(msg)\n")
        return 1
    }

    let stop = box.lock.withLock { box.finalStopReason }
    await cleanupHeadlessAgent(agent)
    return stop == .stop ? 0 : 1
}

/// Build a one-shot agent with background execution forcibly disabled.
///
/// The caller may hand us a reusable config that has a manager attached; copy
/// it and clear that capability so `kwwk -p` can never report "started in the
/// background" immediately before its process exits. Without a manager the
/// bash schema omits background options, the task tool is absent, and
/// a subagent request that smuggles `run_in_background=true` is rejected by the
/// agent tool at runtime.
func makeHeadlessCodingAgent(_ input: CodingAgentConfig) async -> Agent {
    var config = input
    config.backgroundManager = nil
    // Reusable interactive definitions may default to background execution.
    // Hiding the explicit flag is not enough: an omitted argument would still
    // select that default and then fail because headless intentionally has no
    // manager. Make the semantic default foreground before building the tool.
    config.subagents = config.subagents.map { definition in
        var foreground = definition
        foreground.runInBackgroundByDefault = false
        return foreground
    }
    let agent = await makeCodingAgent(config).agent
    agent.state.tools = removingHeadlessBackgroundOptions(from: agent.state.tools)
    return agent
}

private func removingHeadlessBackgroundOptions(from tools: [AgentTool]) -> [AgentTool] {
    tools.map { original in
        guard original.name == "agent" else { return original }
        var tool = original
        if case .object(var schema) = tool.parameters,
           case .object(var properties) = schema["properties"] ?? .null {
            properties.removeValue(forKey: "run_in_background")
            schema["properties"] = .object(properties)
            tool.parameters = .object(schema)
        }
        tool.description = tool.description
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !line.contains("run_in_background")
                    && !line.contains("Background tasks started by the subagent")
            }
            .joined(separator: "\n")
        return tool
    }
}

/// Deterministic one-shot teardown for both success and failure paths. The
/// headless builder currently installs no background attachment, but keeping
/// the ownership cleanup here prevents future configuration changes (or an SDK
/// attachment added around this helper) from leaving work behind at exit.
func cleanupHeadlessAgent(_ agent: Agent) async {
    agent.retire()
    await agent.abortAndKillBackgroundTasks()
    // Retirement makes already-scheduled bridge wakes harmless. Discard any
    // exit-only queues and wait until an in-flight run observes cancellation
    // before closing provider resources.
    agent.abort()
    agent.clearAllQueues()
    await agent.waitForIdle()
    await agent.closeSession()
}

private func writeStdout(_ s: String) {
    FileHandle.standardOutput.write(Data(s.utf8))
}

private func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}
