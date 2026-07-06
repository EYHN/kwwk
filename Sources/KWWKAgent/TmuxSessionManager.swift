import Foundation
import KWWKAI

/// Manages an isolated tmux server for running interactive TUI programs the
/// agent can drive via `send_keys` and observe via `capture_pane`. Every kw
/// process gets its own socket (`kw-<PID>`) so we don't reach into the user's
/// tmux session.
///
/// Why tmux and not a bespoke PTY:
///   - tmux gives us a real PTY + vt100 parser + scrollback + resize handling
///     for free.
///   - Claude Code uses the same trick for its Ant-only TungstenTool.
///   - `send-keys` and `capture-pane` are the only primitives needed — the
///     model doesn't need raw byte control.
///
/// Availability is probed lazily via `<tmuxPath> -V`. `tmuxPath` must be an
/// explicit executable path; the SDK does not search PATH on behalf of callers.
public actor TmuxSessionManager {
    public struct PaneInfo: Sendable, Codable {
        public let paneId: String
        public let name: String
        public let command: String
        public let workDir: String?
        public let startedAt: Date
    }

    public let socketName: String
    public let sessionName: String
    private let tmuxPath: String
    /// Exact environment the tmux server (and therefore every pane process) is
    /// spawned with. Required — like `CodingAgentConfig.bashEnvironment` — so
    /// the host's environment (API keys and all) is never silently inherited by
    /// pane commands the model runs.
    private let environment: [String: String]

    private var probed: Bool = false
    private var available: Bool = false
    private var sessionStarted: Bool = false
    private var panes: [String: PaneInfo] = [:]

    /// - Parameters:
    ///   - tmuxPath: Explicit path to the tmux executable.
    ///   - environment: Exact environment for the tmux server and its panes.
    ///     No default: passing the host environment is a deliberate caller
    ///     choice, matching the bash tool's isolation contract.
    ///   - socketName: Defaults to `kw-<pid>` so multiple kw processes
    ///     don't collide on the same socket. Tests override for isolation.
    ///   - sessionName: tmux session name under the socket. Defaults to
    ///     `"kw"`; tests override so parallel suites don't hit
    ///     `duplicate session` errors.
    public init(
        tmuxPath: String,
        environment: [String: String],
        socketName: String? = nil,
        sessionName: String = "kw"
    ) {
        self.socketName = socketName ?? "kw-\(ProcessInfo.processInfo.processIdentifier)"
        self.sessionName = sessionName
        self.tmuxPath = tmuxPath
        self.environment = environment
    }

    public var isAvailable: Bool {
        get async {
            if probed { return available }
            probed = true
            let result = runTmuxSync(args: ["-V"])
            available = result.exitCode == 0
            return available
        }
    }

    // MARK: - Panes

    /// Create a new pane running `command`. Returns the tmux pane id (e.g. `%3`).
    public func startPane(command: String, workDir: String? = nil, name: String? = nil) throws -> PaneInfo {
        try ensureAvailable()
        let wd = workDir.flatMap { URL(fileURLWithPath: $0).path }
        let paneName = sanitizeName(name ?? deriveName(from: command))

        // Don't trust the in-memory `sessionStarted` flag — the tmux session
        // may have been auto-destroyed when its last window was killed, or
        // the server may have been torn down externally. Query tmux directly.
        let hasSession = runTmuxSync(args: ["has-session", "-t", sessionName]).exitCode == 0

        if !hasSession {
            var args: [String] = ["new-session", "-d", "-s", sessionName, "-n", paneName]
            if let wd { args.append(contentsOf: ["-c", wd]) }
            args.append(contentsOf: ["-P", "-F", "#{pane_id}", command])
            let result = runTmuxSync(args: args)
            guard result.exitCode == 0 else {
                throw TmuxError.commandFailed(stderr: result.stderr, exitCode: Int(result.exitCode))
            }
            sessionStarted = true
            let paneId = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return registerPane(paneId: paneId, name: paneName, command: command, workDir: wd)
        }

        // `-a` creates the window *after* the current window; `-t session:`
        // targets the session (the trailing colon disambiguates session vs
        // window). Without `-a`, tmux treats `-t session` as a *window*
        // target and tries to replace window index 0, which fails with
        // "index 0 in use" when a window already exists.
        var args: [String] = ["new-window", "-a", "-t", "\(sessionName):", "-n", paneName]
        if let wd { args.append(contentsOf: ["-c", wd]) }
        args.append(contentsOf: ["-P", "-F", "#{pane_id}", command])
        let result = runTmuxSync(args: args)
        guard result.exitCode == 0 else {
            throw TmuxError.commandFailed(stderr: result.stderr, exitCode: Int(result.exitCode))
        }
        let paneId = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return registerPane(paneId: paneId, name: paneName, command: command, workDir: wd)
    }

    /// Send keystrokes to `paneId`. When `literal` is true, the string is
    /// sent character-by-character (equivalent to typing). Otherwise it's
    /// interpreted as tmux key names (space-separated) like `C-c`, `Enter`,
    /// `Escape`, `Up`, `BSpace`.
    public func sendKeys(_ paneId: String, keys: String, literal: Bool = false) throws {
        try ensureAvailable()
        var args = ["send-keys", "-t", paneId]
        if literal {
            args.append("-l")
            args.append(keys)
        } else {
            // Split on whitespace so each key name is passed as its own arg.
            // Multi-key sequences like "C-a d" work out of the box.
            let keyNames = keys.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if keyNames.isEmpty { return }
            args.append(contentsOf: keyNames)
        }
        let result = runTmuxSync(args: args)
        if result.exitCode != 0 {
            throw TmuxError.commandFailed(stderr: result.stderr, exitCode: Int(result.exitCode))
        }
    }

    /// Read the most recent `lines` of the pane's visible buffer. If `lines`
    /// is nil, the current pane height is used.
    public func capture(_ paneId: String, lines: Int? = nil) throws -> String {
        try ensureAvailable()
        var args: [String] = ["capture-pane", "-p", "-t", paneId]
        if let lines {
            // -S -N: start at line N lines from the bottom of the history.
            args.append("-S")
            args.append("-\(lines)")
        }
        let result = runTmuxSync(args: args)
        if result.exitCode != 0 {
            throw TmuxError.commandFailed(stderr: result.stderr, exitCode: Int(result.exitCode))
        }
        return result.stdout
    }

    /// Redirect all output from `paneId` into `file` via `pipe-pane`.
    /// The file is created if it doesn't exist. Stops automatically when
    /// the pane dies or when `pipePaneStop` is called.
    public func pipePaneOutput(paneId: String, toFile file: URL) throws {
        try ensureAvailable()
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // tmux passes this argument to /bin/sh, so spaces, quotes, and
        // shell metacharacters in `file.path` (temp dirs, project paths
        // with spaces, usernames like "John Smith") would corrupt the
        // redirect target. Single-quote the path and escape any embedded
        // single quotes the POSIX-safe way: `'` → `'\''`.
        let quotedPath = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = "cat >> \(quotedPath)"
        let result = runTmuxSync(args: ["pipe-pane", "-t", paneId, cmd])
        if result.exitCode != 0 {
            throw TmuxError.commandFailed(stderr: result.stderr, exitCode: Int(result.exitCode))
        }
    }

    /// Stop piping pane output (noop if nothing is piped).
    public func pipePaneStop(_ paneId: String) {
        _ = runTmuxSync(args: ["pipe-pane", "-t", paneId])
    }

    /// Returns `true` when the pane has exited (or no longer exists).
    public func isPaneDead(_ paneId: String) -> Bool {
        let result = runTmuxSync(args: ["display-message", "-p", "-t", paneId, "#{pane_dead}"])
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // "1" = dead; "0" = alive. If the pane was killed externally the
        // target may vanish and tmux returns an error — treat that as dead.
        if result.exitCode != 0 { return true }
        return trimmed == "1"
    }

    /// Exit status of the pane's last process, or `nil` if unavailable.
    public func paneExitStatus(_ paneId: String) -> Int? {
        let result = runTmuxSync(args: ["display-message", "-p", "-t", paneId, "#{pane_exit_status}"])
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    /// Close the pane's containing window (and kill the process running in it).
    /// Idempotent: if the pane/window is already gone (or the server has
    /// already shut down), the call succeeds silently.
    public func killPane(_ paneId: String) throws {
        try ensureAvailable()
        pipePaneStop(paneId)
        let result = runTmuxSync(args: ["kill-window", "-t", paneId])
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyGone = stderr.hasPrefix("can't find")
            || stderr.hasPrefix("no server running on")
            || stderr.contains("not found")
            || stderr.contains("no current target")
        if result.exitCode != 0 && !alreadyGone {
            throw TmuxError.commandFailed(stderr: result.stderr, exitCode: Int(result.exitCode))
        }
        panes.removeValue(forKey: paneId)
        // Tmux auto-destroys a session when its last window is killed, and
        // the server when its last session is destroyed. Reset our tracking
        // so the next `startPane` recreates the session.
        if runTmuxSync(args: ["has-session", "-t", sessionName]).exitCode != 0 {
            sessionStarted = false
        }
    }

    /// All panes known to the manager (registered via `startPane`). Does not
    /// query tmux — reflects what kw started, not what the user started
    /// themselves on this socket (which should be empty anyway).
    public func list() -> [PaneInfo] {
        panes.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Kill the tmux server for this socket. Call before process exit to
    /// avoid leaving orphaned tmux servers.
    public func teardown() {
        guard sessionStarted else { return }
        _ = runTmuxSync(args: ["kill-server"])
        sessionStarted = false
        panes.removeAll()
    }

    // MARK: - Private

    private func registerPane(paneId: String, name: String, command: String, workDir: String?) -> PaneInfo {
        let info = PaneInfo(
            paneId: paneId,
            name: name,
            command: command,
            workDir: workDir,
            startedAt: Date()
        )
        panes[paneId] = info
        return info
    }

    private func ensureAvailable() throws {
        if probed, available { return }
        let result = runTmuxSync(args: ["-V"])
        probed = true
        available = result.exitCode == 0
        if !available {
            throw TmuxError.unavailable("tmux unavailable at \(tmuxPath)")
        }
    }

    private func runTmuxSync(args: [String]) -> ProcResult {
        var allArgs = ["-L", socketName]
        allArgs.append(contentsOf: args)
        return TmuxSessionManager.runProcessSync(
            executable: tmuxPath,
            args: allArgs,
            environment: environment
        )
    }

    nonisolated static func runProcessSync(
        executable: String,
        args: [String],
        environment: [String: String]
    ) -> ProcResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Set the tmux server / pane environment explicitly. Without this the
        // server inherits the host's full environment and leaks it into every
        // pane the model drives.
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        do {
            try process.run()
        } catch {
            return ProcResult(exitCode: 127, stdout: "", stderr: "\(error)")
        }
        // Drain both pipes CONCURRENTLY with the wait. Reading only after
        // waitUntilExit deadlocks once tmux writes more than the ~64KB pipe
        // buffer (e.g. `capture-pane` over a long scrollback): tmux blocks in
        // write(2) while we block in wait.
        let outBox = TmuxDataBox()
        let errBox = TmuxDataBox()
        let group = DispatchGroup()
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        group.enter()
        DispatchQueue.global().async {
            outBox.data = outHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errHandle.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return ProcResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }

}

/// `@unchecked Sendable` holder for draining a pipe on a background queue.
/// Written on the read thread, read after `DispatchGroup.wait` synchronizes.
private final class TmuxDataBox: @unchecked Sendable {
    var data = Data()
}

public struct ProcResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum TmuxError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case commandFailed(stderr: String, exitCode: Int)
    case paneNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let msg): return msg
        case .commandFailed(let stderr, let code):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "tmux exited with code \(code)" : "\(trimmed) (exit \(code))"
        case .paneNotFound(let id): return "pane not found: \(id)"
        }
    }
}

// MARK: - Helpers

private func sanitizeName(_ raw: String) -> String {
    // tmux window names can't contain `.` (reserved) or whitespace.
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    var cleaned = ""
    for scalar in raw.unicodeScalars {
        if allowed.contains(scalar) { cleaned.unicodeScalars.append(scalar) }
        else { cleaned.append("_") }
    }
    if cleaned.isEmpty { cleaned = "pane" }
    return String(cleaned.prefix(32))
}

private func deriveName(from command: String) -> String {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "pane"
    let base = (first as NSString).lastPathComponent
    return base
}
