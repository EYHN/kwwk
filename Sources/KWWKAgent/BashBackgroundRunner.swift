import Foundation
import KWWKAI
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// `BackgroundTaskRunner` backed by `Process`. Spawns the command with
/// stdin redirected from `/dev/null` and both stdout/stderr fd-dup'd onto
/// the Manager-allocated output file — bytes go straight from the kernel
/// to disk without entering Swift memory.
public struct BashBackgroundRunner: BackgroundTaskRunner {
    public let spec: BackgroundTaskSpec
    public let command: String
    public let workDir: String?
    public let shellPath: String
    /// Exact base environment passed to the child process.
    public let environment: [String: String]
    /// Optional extra env merged on top of `environment`.
    public let extraEnv: [String: String]

    public init(
        command: String,
        workDir: String? = nil,
        description: String? = nil,
        hardTimeoutSeconds: Int = 1800,
        shellPath: String = kwwkDefaultShellPath,
        label: String? = nil,
        environment: [String: String],
        extraEnv: [String: String] = [:]
    ) {
        self.command = command
        self.workDir = workDir
        self.shellPath = shellPath
        self.environment = environment
        self.extraEnv = extraEnv
        self.spec = BackgroundTaskSpec(
            kind: "bash",
            label: label ?? bashShortLabel(command),
            description: description,
            hardTimeoutSeconds: hardTimeoutSeconds
        )
    }

    public func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    ) {
        let command = self.command
        let workDir = self.workDir
        let shellPath = self.shellPath
        let environment = self.environment
        let extraEnv = self.extraEnv
        // Dispatch, not Task.detached: BashRunnerImpl.run blocks in waitpid for
        // the process's whole lifetime. On the narrow cooperative pool a few
        // long-running tasks would starve every actor in the process (the
        // manager's own kill() included); the dispatch pool grows under
        // blocking.
        DispatchQueue.global().async {
            let outcome = BashRunnerImpl.run(
                command: command,
                workDir: workDir,
                shellPath: shellPath,
                environment: environment,
                extraEnv: extraEnv,
                outputFile: outputFile,
                cancellation: cancellation
            )
            onDone(outcome)
        }
    }
}

/// Shared Process-driven implementation; reused by the bash tool's
/// foreground-maybe-flip-to-background path so `Process` plumbing lives in
/// one place.
enum BashRunnerImpl {
    /// Run a command synchronously in a background thread, redirecting
    /// stdout+stderr to `outputFile`, and return a structured outcome.
    static func run(
        command: String,
        workDir: String?,
        shellPath: String,
        environment: [String: String],
        extraEnv: [String: String],
        outputFile: URL,
        cancellation: CancellationHandle
    ) -> BackgroundTaskOutcome {
        let control = BashProcessControl(pid: 0)
        let effectiveCommand: String
        if let workDir {
            effectiveCommand = "cd \(bashShellQuote(workDir)) && \(command)"
        } else {
            effectiveCommand = command
        }

        let spawned: SpawnedBashProcess
        do {
            spawned = try SpawnedBashProcess.start(
                shellPath: shellPath,
                command: effectiveCommand,
                outputFile: outputFile,
                environment: environment,
                extraEnv: extraEnv
            )
        } catch {
            return BackgroundTaskOutcome(
                success: false,
                summary: "spawn failed",
                details: nil,
                errorMessage: "\(error)"
            )
        }
        control.setPid(spawned.pid)

        cancellation.onCancel { _ in control.terminate() }

        let status = spawned.wait()

        return BashProcessOutcome.from(
            status: status,
            cancelled: control.didCancel || cancellation.isCancelled
        )
    }

}

/// POSIX-quote a single shell argument. Shared by the background runner (cwd
/// prefix) and the bash tool's foreground/legacy paths.
func bashShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Maps a finished process's `ExitStatus` to a `BackgroundTaskOutcome`. Shared
/// between the spawn path (`BashRunnerImpl.run`) and the foreground-adopted path
/// (`ForegroundBashExecution.awaitAdoptedCompletion`) so both produce identical
/// success/summary/details for a given process state.
enum BashProcessOutcome {
    static func from(status: SpawnedBashProcess.ExitStatus, cancelled: Bool) -> BackgroundTaskOutcome {
        let code = status.code
        if cancelled {
            return BackgroundTaskOutcome(
                success: false,
                summary: "aborted",
                details: .object(["exitCode": .int(Int(code))]),
                errorMessage: nil
            )
        }
        if status.signaled {
            return BackgroundTaskOutcome(
                success: false,
                summary: "exit \(code) (signal)",
                details: .object([
                    "exitCode": .int(Int(code)),
                    "terminationReason": .string("signal"),
                ]),
                errorMessage: nil
            )
        }
        return BackgroundTaskOutcome(
            success: code == 0,
            summary: "exit \(code)",
            details: .object(["exitCode": .int(Int(code))]),
            errorMessage: nil
        )
    }
}

struct SpawnedBashProcess: Sendable {
    struct ExitStatus: Sendable {
        var code: Int32
        var signaled: Bool
    }

    enum SpawnError: Error, CustomStringConvertible {
        case openOutput(String)
        case openDevNull
        case fileAction(String)
        case spawn(String)

        var description: String {
            switch self {
            case .openOutput(let path): return "could not open output file \(path)"
            case .openDevNull: return "could not open /dev/null"
            case .fileAction(let message): return "could not prepare process file actions: \(message)"
            case .spawn(let message): return message
            }
        }
    }

    let pid: pid_t

    /// Enable pipeline failure propagation for Bourne-style shells without
    /// breaking shells that do not implement `pipefail`. Some `/bin/sh`
    /// implementations (notably dash) terminate the current shell when an
    /// unknown `set -o` option is used, even when followed by `|| true`, so the
    /// capability probe must run in a subshell. Non-Bourne/unknown shells keep
    /// the original command byte-for-byte because this prelude would not be
    /// valid in their command language.
    static func commandEnablingPipefailIfSupported(
        shellPath: String,
        command: String
    ) -> String {
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent.lowercased()
        let bourneShellNames: Set<String> = [
            "sh", "ash", "bash", "dash", "ksh", "ksh93", "mksh", "pdksh", "zsh",
        ]
        guard bourneShellNames.contains(shellName) else { return command }

        return """
        if (set -o pipefail) >/dev/null 2>&1; then
            set -o pipefail
        fi
        \(command)
        """
    }

    /// Spawn a shell redirecting stdout+stderr into `outputFile` (truncated).
    /// Bytes go straight from the kernel to disk without entering Swift memory.
    static func start(
        shellPath: String,
        command: String,
        outputFile: URL,
        environment: [String: String],
        extraEnv: [String: String]
    ) throws -> SpawnedBashProcess {
        let outputFd = open(outputFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard outputFd >= 0 else { throw SpawnError.openOutput(outputFile.path) }
        defer { close(outputFd) }
        return try start(
            shellPath: shellPath,
            command: command,
            stdoutFd: outputFd,
            stderrFd: outputFd,
            environment: environment,
            extraEnv: extraEnv
        )
    }

    /// Spawn a shell with stdin from /dev/null and stdout/stderr dup'd onto the
    /// caller-owned `stdoutFd`/`stderrFd` (which may be the same fd — a file —
    /// or distinct pipe write ends). The child is placed in its own process
    /// group (`POSIX_SPAWN_SETPGROUP`, pgid 0) so signalling the group reaches
    /// grandchildren. The caller retains ownership of the passed fds and must
    /// close its own copies after this returns.
    static func start(
        shellPath: String,
        command: String,
        stdoutFd: Int32,
        stderrFd: Int32,
        environment: [String: String],
        extraEnv: [String: String]
    ) throws -> SpawnedBashProcess {
        let inputFd = open("/dev/null", O_RDONLY)
        guard inputFd >= 0 else { throw SpawnError.openDevNull }
        defer { close(inputFd) }

        // Glibc imports these spawn handles as concrete structs, Darwin as
        // optional opaque pointers — declare each per-platform so `&handle`
        // matches the C function's pointee on both.
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        try checkFileAction(posix_spawn_file_actions_adddup2(&actions, inputFd, STDIN_FILENO))
        try checkFileAction(posix_spawn_file_actions_adddup2(&actions, stdoutFd, STDOUT_FILENO))
        try checkFileAction(posix_spawn_file_actions_adddup2(&actions, stderrFd, STDERR_FILENO))
        try checkFileAction(posix_spawn_file_actions_addclose(&actions, inputFd))
        // Close the child's leftover copies of the source fds after dup2. Guard
        // against closing a std fd, and against closing the same fd twice when
        // stdout and stderr share it (the file case).
        if stdoutFd > STDERR_FILENO {
            try checkFileAction(posix_spawn_file_actions_addclose(&actions, stdoutFd))
        }
        if stderrFd > STDERR_FILENO && stderrFd != stdoutFd {
            try checkFileAction(posix_spawn_file_actions_addclose(&actions, stderrFd))
        }

        #if os(Linux)
        var attr = posix_spawnattr_t()
        #else
        var attr: posix_spawnattr_t? = nil
        #endif
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        let effectiveCommand = commandEnablingPipefailIfSupported(
            shellPath: shellPath,
            command: command
        )
        let argvStrings = [shellPath, "-c", effectiveCommand]
        var argv = argvStrings.map { strdup($0) }
        argv.append(nil)
        defer { argv.compactMap { $0 }.forEach { free($0) } }

        var environment = environment
        for (key, value) in extraEnv { environment[key] = value }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { envp.compactMap { $0 }.forEach { free($0) } }

        var pid: pid_t = 0
        let result = shellPath.withCString { path in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(
                        &pid,
                        path,
                        &actions,
                        &attr,
                        // Non-optional on Glibc; both arrays always hold at
                        // least their nil terminator, so the unwrap is safe.
                        argvBuffer.baseAddress!,
                        envBuffer.baseAddress!
                    )
                }
            }
        }
        guard result == 0 else { throw SpawnError.spawn(String(cString: strerror(result))) }
        return SpawnedBashProcess(pid: pid)
    }

    func wait() -> ExitStatus {
        var rawStatus: Int32 = 0
        while waitpid(pid, &rawStatus, 0) == -1 {
            if errno == EINTR { continue }
            return ExitStatus(code: 1, signaled: false)
        }
        let signal = rawStatus & 0x7f
        if signal != 0 {
            return ExitStatus(code: signal, signaled: true)
        }
        return ExitStatus(code: (rawStatus >> 8) & 0xff, signaled: false)
    }

    private static func checkFileAction(_ result: Int32) throws {
        guard result == 0 else {
            throw SpawnError.fileAction(String(cString: strerror(result)))
        }
    }
}

/// Sendable-safe controller over a running `Process`. Lets detached cancel
/// listeners and timeouts signal the process without directly capturing it.
final class BashProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t
    private var _terminated = false
    private var _didCancel = false
    private var _didTimeOut = false

    init(pid: pid_t) { self.pid = pid }

    func setPid(_ pid: pid_t) { lock.withLock { self.pid = pid } }

    var didCancel: Bool { lock.withLock { _didCancel } }
    var didTimeOut: Bool { lock.withLock { _didTimeOut } }

    func terminate() {
        let pid: pid_t = lock.withLock {
            if _terminated { return 0 }
            _terminated = true
            _didCancel = true
            return self.pid
        }
        escalate(pid)
    }

    func timeoutAndTerminate() {
        let pid: pid_t = lock.withLock {
            if _terminated { return 0 }
            _terminated = true
            _didTimeOut = true
            return self.pid
        }
        escalate(pid)
    }

    /// Signal the whole process group, then escalate to SIGKILL if anything
    /// survives. `SpawnedBashProcess` puts the child in a fresh group whose id
    /// equals the shell pid (`POSIX_SPAWN_SETPGROUP` with pgid 0), so signalling
    /// that group also reaches backgrounded grandchildren.
    private func escalate(_ pid: pid_t) {
        guard pid > 0 else { return }
        // Decide once, while the leader is alive, whether the child is its own
        // group leader; if setpgroup didn't take, fall back to the single pid.
        let isGroupLeader = getpgid(pid) == pid
        Self.signal(pid, SIGTERM, group: isGroupLeader)
        // Grace period, then SIGKILL survivors. A process-group id is not reused
        // while the group still has members, so a delayed `killpg` is safe even
        // after the leader was reaped; the `sig 0` existence check skips it once
        // the group is empty (also avoids signalling a recycled id).
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if Self.signal(pid, 0, group: isGroupLeader) == 0 {
                Self.signal(pid, SIGKILL, group: isGroupLeader)
            }
        }
    }

    /// Send `sig` to the process group (`killpg`) or the single pid (`kill`).
    /// Returns the syscall result (0 on success, used with `sig == 0` as an
    /// existence probe).
    @discardableResult
    private static func signal(_ pid: pid_t, _ sig: Int32, group: Bool) -> Int32 {
        guard pid > 0 else { return -1 }
        return group ? killpg(pid, sig) : kill(pid, sig)
    }
}

/// Trim whitespace and cap at `max` chars for UI labels (background task
/// lists, TUI spinners). Shared between BashBackgroundRunner (bg task label)
/// and BashTool (adopt-path label).
func bashShortLabel(_ command: String, max: Int = 80) -> String {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= max { return trimmed }
    return String(trimmed.prefix(max)) + "…"
}
