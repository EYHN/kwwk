import Foundation
import KWWKAgent

/// Public entry points for the `kwwk` binary. Everything else in KWWKCli is
/// internal — external consumers drive the CLI through these two functions.
public enum KWWK {

    /// Launch the interactive coding-agent TUI in `cwd` (defaults to the
    /// current working directory).
    ///
    /// Credentials are resolved automatically from the OAuth store
    /// (`~/.kwwk/oauth.json`). Throws `AuthResolveError.noCredentials`
    /// with a message pointing at `kwwk login` if none are configured.
    ///
    /// `tools` controls which coding tools the agent is given. Default is
    /// `.all` — read/write/edit/bash/grep/find/ls/task_status/wait_task +
    /// optional tmux. Pass `.readOnly` for a sandboxed reviewer-style agent.
    ///
    /// `autoCompactThreshold` fires a silent `/compact` (summarize the
    /// transcript → replace with a recap) once the turn's reported
    /// `usage.input + usage.output` crosses that ratio of the model's
    /// `contextWindow`. Pass `nil` to disable.
    public static func runCodingTUI(
        cwd: String? = nil,
        tools: CodingTools = .all,
        autoCompactThreshold: Double? = 0.75
    ) async throws {
        let resolved = try await resolveAgentAuth()
        let workDir = cwd ?? FileManager.default.currentDirectoryPath
        try await runCodingTUIInternal(
            model: resolved.model,
            modelLabel: resolved.modelLabel,
            cwd: workDir,
            tools: tools,
            apiKeyResolver: resolved.apiKeyResolver,
            autoCompactThreshold: autoCompactThreshold
        )
    }

    /// Launch the interactive `kwwk login` flow: TUI selector over the
    /// supported OAuth providers → browser-based OAuth dance → persist
    /// credentials to `~/.kwwk/oauth.json`.
    public static func runLogin() async throws {
        try await runLoginInternal()
    }
}
