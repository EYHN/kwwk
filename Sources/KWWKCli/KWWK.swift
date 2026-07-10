import Foundation
import KWWKAgent

/// Public entry points for the `kwwk` binary. Everything else in KWWKCli is
/// internal — external consumers drive the CLI through these two
/// functions. Both work on macOS and Linux: the OAuth callback server
/// is backed by SwiftNIO and the browser launcher falls back to `xdg-open`
/// off-Apple, so no entry point is platform-gated.
public enum KWWK {

    /// Launch the interactive coding-agent TUI in `cwd` (defaults to the
    /// current working directory).
    ///
    /// Credentials are resolved automatically from the OAuth store
    /// (`~/.kwwk/oauth.json`) and then supported API-key environment
    /// variables. With none configured the TUI still starts, in a
    /// logged-out state: prompt submission is gated behind a "/login to
    /// sign in" notice, and running `/login` registers a provider live —
    /// no restart needed.
    ///
    /// `tools` controls which coding tools the agent is given. Default is
    /// `.standard` — read/write/edit/bash/grep/find/ls/job. The legacy
    /// `task_status` surface remains available through explicit selection.
    /// Pass `.readOnly` for a reviewer-style tool whitelist. It does not by
    /// itself create an operating-system filesystem sandbox.
    ///
    /// `autoCompactThreshold` fires a silent `/compact` (summarize the
    /// transcript → replace with a recap) once the turn's reported
    /// `usage.input + usage.output` crosses that ratio of the model's
    /// `contextWindow`. Pass `nil` to disable.
    public static func runCodingTUI(
        cwd: String? = nil,
        tools: CodingTools = .standard,
        builtinSubagents: BuiltinSubagentSelection = .all,
        autoCompactThreshold: Double? = 0.75,
        thinkingLevel: ThinkingLevel = .medium,
        modelOverride: String? = nil,
        context1m: Bool = false,
        resume: SessionResume = .none
    ) async throws {
        let workDir = cwd ?? FileManager.default.currentDirectoryPath
        let resolved: ResolvedAuth
        do {
            resolved = try await resolveAgentAuth(
                modelOverride: modelOverride,
                context1m: context1m
            )
        } catch AuthResolveError.noCredentials {
            // Logged-out start: sentinel model, no provider slots, and a
            // fresh resolver map so the first in-session `/login` can
            // install its provider's token resolver without an agent
            // rebuild. The TUI gates prompting on the empty slot list.
            let authResolvers = SessionAuthResolvers()
            resolved = ResolvedAuth(
                model: loggedOutModel,
                modelLabel: loggedOutModelLabel,
                authResolver: authResolvers.delegatingResolver(),
                providerSlots: [],
                authResolvers: authResolvers
            )
        }
        try await runCodingTUIInternal(
            model: resolved.model,
            modelLabel: resolved.modelLabel,
            cwd: workDir,
            tools: tools,
            builtinSubagents: builtinSubagents,
            authResolver: resolved.authResolver,
            providerSlots: resolved.providerSlots,
            authResolvers: resolved.authResolvers,
            autoCompactThreshold: autoCompactThreshold,
            thinkingLevel: thinkingLevel,
            context1m: context1m,
            resume: resume
        )
    }

    /// One-shot, non-interactive coding-agent run. Backs the `kwwk -p <prompt>`
    /// CLI mode — modeled on `claude -p`:
    ///
    ///   - `prompt` is handed to the agent verbatim;
    ///   - assistant text streams to stdout as it arrives;
    ///   - on a successful run nothing is written to stderr (no banner,
    ///     no tool breadcrumbs, no summary) — stdout carries only the
    ///     assistant reply so the output is pipe-clean;
    ///   - genuine failures (auth missing, stream error, abort) print a
    ///     one-line message to stderr;
    ///   - returns `0` on a clean stop, `1` on error / aborted / length-capped.
    ///
    /// Credentials are resolved from the OAuth store at `~/.kwwk/oauth.json`
    /// first, then supported API-key environment variables. Unlike
    /// `runCodingTUI` there is no logged-out fallback — headless runs throw
    /// `AuthResolveError.noCredentials` (launch `kwwk` and run `/login`, or
    /// export a supported API key) when none are configured.
    public static func runHeadless(
        prompt: String,
        cwd: String? = nil,
        tools: CodingTools = .standard,
        builtinSubagents: BuiltinSubagentSelection = .all,
        thinkingLevel: ThinkingLevel = .medium,
        modelOverride: String? = nil,
        context1m: Bool = false,
        resume: SessionResume = .none
    ) async throws -> Int32 {
        let workDir = cwd ?? FileManager.default.currentDirectoryPath
        return try await runHeadlessInternal(
            prompt: prompt,
            cwd: workDir,
            tools: tools,
            builtinSubagents: builtinSubagents,
            thinkingLevel: thinkingLevel,
            modelOverride: modelOverride,
            context1m: context1m,
            resume: resume
        )
    }
}
