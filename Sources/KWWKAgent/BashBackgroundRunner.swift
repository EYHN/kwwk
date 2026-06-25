import Foundation
import KWWKAI

/// `BackgroundTaskRunner` backed by `Process`. Spawns the command with
/// stdin redirected from `/dev/null` and both stdout/stderr fd-dup'd onto
/// the Manager-allocated output file — bytes go straight from the kernel
/// to disk without entering Swift memory.
public struct BashBackgroundRunner: BackgroundTaskRunner {
    public let spec: BackgroundTaskSpec
    public let command: String
    public let workDir: String?
    public let shellPath: String
    /// Optional extra env merged on top of the inherited process env.
    public let extraEnv: [String: String]

    public init(
        command: String,
        workDir: String? = nil,
        description: String? = nil,
        hardTimeoutSeconds: Int = 1800,
        shellPath: String = kwwkDefaultShellPath,
        label: String? = nil,
        extraEnv: [String: String] = [:]
    ) {
        self.command = command
        self.workDir = workDir
        self.shellPath = shellPath
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
        let extraEnv = self.extraEnv
        Task.detached {
            let outcome = BashRunnerImpl.run(
                command: command,
                workDir: workDir,
                shellPath: shellPath,
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
        extraEnv: [String: String],
        outputFile: URL,
        cancellation: CancellationHandle
    ) -> BackgroundTaskOutcome {
        let control = BashProcessControl(pid: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", command]
        if let workDir {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            process.environment = env
        }

        // Redirect stdout + stderr to the output file at the fd level.
        guard let writeHandle = try? FileHandle(forWritingTo: outputFile) else {
            return BackgroundTaskOutcome(
                success: false,
                summary: "outputfile not writable",
                details: nil,
                errorMessage: "could not open output file \(outputFile.path)"
            )
        }
        defer { try? writeHandle.close() }
        process.standardOutput = writeHandle
        process.standardError = writeHandle
        if let devNull = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = devNull
        }

        do {
            try process.run()
        } catch {
            return BackgroundTaskOutcome(
                success: false,
                summary: "spawn failed",
                details: nil,
                errorMessage: "\(error)"
            )
        }
        control.setPid(process.processIdentifier)

        cancellation.onCancel { _ in control.terminate() }

        process.waitUntilExit()

        return BashProcessOutcome.from(
            process: process,
            cancelled: control.didCancel || cancellation.isCancelled
        )
    }
}

/// Maps a finished `Process` to a `BackgroundTaskOutcome`. Shared between the
/// spawn path (`BashRunnerImpl.run`) and the foreground-adopted path
/// (`ForegroundBashExecution.awaitAdoptedCompletion`) so both produce
/// identical success/summary/details for a given process state.
enum BashProcessOutcome {
    static func from(process: Process, cancelled: Bool) -> BackgroundTaskOutcome {
        let code = process.terminationStatus
        let reason = process.terminationReason
        if cancelled {
            return BackgroundTaskOutcome(
                success: false,
                summary: "aborted",
                details: .object(["exitCode": .int(Int(code))]),
                errorMessage: nil
            )
        }
        if reason == .uncaughtSignal && code != 0 {
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
        Self.killTreeWithEscalation(pid)
    }

    func timeoutAndTerminate() {
        let pid: pid_t = lock.withLock {
            if _terminated { return 0 }
            _terminated = true
            _didTimeOut = true
            return self.pid
        }
        Self.killTreeWithEscalation(pid)
    }

    /// Signal the whole process tree, then escalate to SIGKILL if it survives.
    /// The spawned shell is its own process-group leader (Foundation `Process`
    /// starts children in a fresh group), so signaling the group reaches every
    /// descendant — `npm test` workers, background jobs — not just the shell.
    /// Previously only the shell pid was signaled, orphaning grandchildren.
    private static func killTreeWithEscalation(_ pid: pid_t) {
        guard pid > 0 else { return }
        killTree(pid, SIGTERM)
        // Grace period, then SIGKILL anything still alive (harmless if gone).
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            killTree(pid, SIGKILL)
        }
    }

    /// Send `sig` to the process group when the pid is its own group leader
    /// (safe: only descendants are hit); otherwise fall back to the single pid
    /// so we never accidentally signal our own/parent's group.
    private static func killTree(_ pid: pid_t, _ sig: Int32) {
        guard pid > 0 else { return }
        if getpgid(pid) == pid {
            killpg(pid, sig)
        } else {
            kill(pid, sig)
        }
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

