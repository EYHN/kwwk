import Foundation
import KWAI

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
/// Availability is probed lazily via `tmux -V`. If tmux isn't on PATH, the
/// manager still constructs but `isAvailable` returns false and
/// `createTmuxTool` returns nil — existing bash / background flows stay fully
/// functional.
public actor TmuxSessionManager {
    public static let shared = TmuxSessionManager()

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

    private var probed: Bool = false
    private var available: Bool = false
    private var sessionStarted: Bool = false
    private var panes: [String: PaneInfo] = [:]

    public init(tmuxPath: String = "tmux") {
        self.socketName = "kw-\(ProcessInfo.processInfo.processIdentifier)"
        self.sessionName = "kw"
        self.tmuxPath = tmuxPath
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

        if !sessionStarted {
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

        var args: [String] = ["new-window", "-t", sessionName, "-n", paneName]
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

    /// Close the pane's containing window (and kill the process running in it).
    public func killPane(_ paneId: String) throws {
        try ensureAvailable()
        let result = runTmuxSync(args: ["kill-window", "-t", paneId])
        if result.exitCode != 0 {
            throw TmuxError.commandFailed(stderr: result.stderr, exitCode: Int(result.exitCode))
        }
        panes.removeValue(forKey: paneId)
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
            throw TmuxError.unavailable("tmux not found on PATH. Install with `brew install tmux` or `apt install tmux`.")
        }
    }

    private func runTmuxSync(args: [String]) -> ProcResult {
        var allArgs = ["-L", socketName]
        allArgs.append(contentsOf: args)
        return TmuxSessionManager.runProcessSync(executable: tmuxPath, args: allArgs)
    }

    nonisolated static func runProcessSync(executable: String, args: [String]) -> ProcResult {
        // `Process` resolves bare executable names via the PATH env when
        // `launchPath` is set; using the resolved path URL is more robust.
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
        } else {
            // Find the binary on PATH.
            if let resolved = Self.whichOnPath(executable) {
                process.executableURL = URL(fileURLWithPath: resolved)
            } else {
                return ProcResult(exitCode: 127, stdout: "", stderr: "\(executable) not found")
            }
        }
        process.arguments = args
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
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func whichOnPath(_ executable: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = "\(dir)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
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
