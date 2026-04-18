import Foundation
import KWAI
import KWAgent

public struct BashToolOptions: Sendable {
    /// Legacy pipe-based executor used when `manager` is nil. Tests can
    /// inject a fake here.
    public var operations: BashOperations
    /// Soft foreground timeout. When a `BackgroundTaskManager` is attached
    /// and `autoBackgroundOnTimeout` is true, the command flips to
    /// background on this deadline instead of erroring.
    public var defaultTimeoutSeconds: Int
    /// Maximum allowed user-supplied `timeout` (seconds).
    public var maxTimeoutSeconds: Int
    /// Opt-in background support. When set, the tool exposes
    /// `run_in_background` + auto-backgrounds foreground runs that exceed
    /// `timeout`.
    public var manager: BackgroundTaskManager?
    public var sessionId: String?
    public var autoBackgroundOnTimeout: Bool
    /// Hard ceiling for background-task runtime (seconds). Passed to the
    /// Manager so even runaway processes eventually get cancelled.
    public var hardTimeoutSeconds: Int
    /// Shell for the `-lc <command>` invocation (used by file-based paths;
    /// the `operations` executor may use its own shell).
    public var shellPath: String

    public init(
        operations: BashOperations = LocalBashOperations(),
        defaultTimeoutSeconds: Int = 120,
        maxTimeoutSeconds: Int = 600,
        manager: BackgroundTaskManager? = nil,
        sessionId: String? = nil,
        autoBackgroundOnTimeout: Bool = true,
        hardTimeoutSeconds: Int = 1800,
        shellPath: String = "/bin/zsh"
    ) {
        self.operations = operations
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.maxTimeoutSeconds = maxTimeoutSeconds
        self.manager = manager
        self.sessionId = sessionId
        self.autoBackgroundOnTimeout = autoBackgroundOnTimeout
        self.hardTimeoutSeconds = hardTimeoutSeconds
        self.shellPath = shellPath
    }
}

public struct LocalBashOperations: BashOperations {
    public let cwd: String?
    public let shellPath: String

    public init(cwd: String? = nil, shellPath: String = "/bin/zsh") {
        self.cwd = cwd
        self.shellPath = shellPath
    }

    public func execute(
        command: String,
        timeout: Int?,
        cancellation: CancellationHandle?
    ) async throws -> BashExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", command]
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Isolate stdin from the parent. The coding TUI runs its own stdin in
        // raw mode — if we don't override, npm/prompting commands will read
        // the user's keystrokes and the TUI will lose them, and interactive
        // wizards (e.g. `npm create vite`) hang waiting for input that will
        // never come. Attaching /dev/null forces EOF on any read.
        if let devNull = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = devNull
        }

        let start = Date()
        try process.run()

        let control = BashProcessControl(pid: process.processIdentifier)

        cancellation?.onCancel { _ in control.terminate() }

        if let timeout, timeout > 0 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                control.timeoutAndTerminate()
            }
        }

        // Wait for completion off the executor.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                process.waitUntilExit()
                cont.resume()
            }
        }

        let stdout = readAll(stdoutPipe.fileHandleForReading)
        let stderr = readAll(stderrPipe.fileHandleForReading)
        let duration = Int(Date().timeIntervalSince(start) * 1000)
        let timedOut = control.didTimeOut

        if cancellation?.isCancelled == true {
            throw CodingToolError.aborted
        }
        if timedOut {
            throw CodingToolError.commandFailed(stderr: "Command timed out after \(timeout ?? 0)ms\n" + stderr, exitCode: -1)
        }
        let status = process.terminationStatus
        if status != 0 {
            throw CodingToolError.commandFailed(stderr: stderr.isEmpty ? stdout : stderr, exitCode: status)
        }
        return BashExecutionResult(stdout: stdout, stderr: stderr, exitCode: status, durationMs: duration, timedOut: false)
    }
}

private func readAll(_ handle: FileHandle) -> String {
    let data = handle.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

public func createBashTool(cwd: String, options: BashToolOptions = .init()) -> AgentTool {
    // Dynamic description — so the model learns about run_in_background only
    // when a manager is actually attached.
    let hasManager = options.manager != nil
    let descText: String
    if hasManager {
        descText = """
        Execute a shell command. Runs in \(cwd) by default. Stdout and stderr are returned on completion.

        Long-running commands (installs, builds, test suites) should be started with run_in_background=true so the agent isn't blocked. The tool returns a task ID and output file path immediately; you will receive a <task-notification> user message when the task finishes. Use the Read tool on the output file path to inspect stdout/stderr in the meantime — do NOT poll or sleep.

        Foreground commands that exceed the `timeout` are automatically moved to the background (the process keeps running — no work is lost) and you are notified on completion.
        """
    } else {
        descText = "Execute a shell command and return its output."
    }

    let parameters: JSONValue = {
        var props: [String: JSONValue] = [
            "command": ["type": "string"],
            "timeout": .object([
                "type": .string("number"),
                "description": .string("Seconds before the foreground soft timeout. When a background manager is attached, the command auto-moves to background at this point. Default \(options.defaultTimeoutSeconds), max \(options.maxTimeoutSeconds)."),
                "minimum": .int(1),
                "maximum": .int(options.maxTimeoutSeconds),
            ]),
        ]
        if hasManager {
            props["description"] = [
                "type": "string",
                "description": "Short active-voice description of what this command does (e.g. \"Install deps\", \"Run tests\"). Shown to the user; helps identify background tasks.",
            ]
            props["run_in_background"] = [
                "type": "boolean",
                "description": "If true, start the command in the background and return immediately with a task id. You will be notified on completion. Do NOT use '&' at the end of the command.",
            ]
        }
        return .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array([.string("command")]),
        ])
    }()

    let ops: BashOperations = {
        if let local = options.operations as? LocalBashOperations, local.cwd == nil {
            return LocalBashOperations(cwd: cwd, shellPath: local.shellPath)
        }
        return options.operations
    }()
    let resolvedShell: String = options.shellPath
    let defaultTimeoutSec = options.defaultTimeoutSeconds
    let maxTimeoutSec = options.maxTimeoutSeconds
    let manager = options.manager
    let sessionId = options.sessionId
    let autoBg = options.autoBackgroundOnTimeout
    let hardTimeoutSec = options.hardTimeoutSeconds

    return AgentTool(
        name: "bash",
        label: "bash",
        description: descText,
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let command) = obj["command"] ?? .null else {
                throw CodingToolError.invalidArgument("bash: `command` is required")
            }
            let description: String? = {
                if case .string(let s) = obj["description"] ?? .null { return s }
                return nil
            }()
            let timeoutSec: Int = {
                let raw: Int
                if case .int(let v) = obj["timeout"] ?? .null { raw = v }
                else if case .double(let v) = obj["timeout"] ?? .null { raw = Int(v) }
                else { raw = defaultTimeoutSec }
                return min(max(raw, 1), maxTimeoutSec)
            }()
            let runInBg: Bool = {
                if case .bool(let b) = obj["run_in_background"] ?? .null { return b }
                return false
            }()

            // Path 1: explicit background.
            if runInBg, let manager = manager {
                let runner = BashBackgroundRunner(
                    command: command,
                    workDir: cwd,
                    description: description,
                    hardTimeoutSeconds: hardTimeoutSec,
                    shellPath: resolvedShell,
                    label: description ?? shortLabel(command)
                )
                let (taskId, outputFile) = await manager.spawn(
                    runner: runner,
                    sessionId: sessionId
                )
                let msg = "Command started in background with task id \(taskId). You will receive a <task-notification> user message when it completes. Output is being written to: \(outputFile.path). Use the Read tool on that file to inspect stdout/stderr in the meantime; do NOT poll or sleep."
                return AgentToolResult(
                    content: [.text(TextContent(text: msg))],
                    details: .object([
                        "status": .string("background_started"),
                        "taskId": .string(taskId),
                        "outputFile": .string(outputFile.path),
                    ])
                )
            }

            // Path 2: foreground with possible auto-background-on-timeout.
            if let manager = manager, autoBg {
                return try await runForegroundWithFlip(
                    command: command,
                    description: description,
                    cwd: cwd,
                    shellPath: resolvedShell,
                    timeoutSeconds: timeoutSec,
                    hardTimeoutSeconds: hardTimeoutSec,
                    cancellation: cancellation,
                    manager: manager,
                    sessionId: sessionId
                )
            }

            // Path 3: legacy pipe-based foreground (no manager attached).
            let result = try await ops.execute(
                command: command,
                timeout: timeoutSec * 1000,
                cancellation: cancellation
            )
            let body = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            return AgentToolResult(
                content: [.text(TextContent(text: body))],
                details: .object([
                    "stdout": .string(result.stdout),
                    "stderr": .string(result.stderr),
                    "exitCode": .int(Int(result.exitCode)),
                    "durationMs": .int(result.durationMs),
                ])
            )
        }
    )
}

// MARK: - Foreground-with-flip path

/// Run a command in the foreground with stdout/stderr fd-dup'd onto a file.
/// If the command exceeds `timeoutSeconds`, hand the still-running process
/// off to the background manager (adopt) and return an `auto_backgrounded`
/// result — the process is NOT killed.
private func runForegroundWithFlip(
    command: String,
    description: String?,
    cwd: String,
    shellPath: String,
    timeoutSeconds: Int,
    hardTimeoutSeconds: Int,
    cancellation: CancellationHandle?,
    manager: BackgroundTaskManager,
    sessionId: String?
) async throws -> AgentToolResult {
    let outputFile = await manager.allocateForegroundOutputFile()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shellPath)
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    guard let writeHandle = try? FileHandle(forWritingTo: outputFile) else {
        throw CodingToolError.commandFailed(
            stderr: "could not open output file \(outputFile.path)",
            exitCode: -1
        )
    }
    process.standardOutput = writeHandle
    process.standardError = writeHandle
    if let devNull = FileHandle(forReadingAtPath: "/dev/null") {
        process.standardInput = devNull
    }

    let control = BashProcessControl(pid: 0)
    let start = Date()
    do {
        try process.run()
    } catch {
        try? writeHandle.close()
        try? FileManager.default.removeItem(at: outputFile)
        throw CodingToolError.commandFailed(stderr: "\(error)", exitCode: -1)
    }
    control.setPid(process.processIdentifier)
    cancellation?.onCancel { _ in control.terminate() }

    let bundle = ForegroundBashExecution(
        process: process,
        writeHandle: writeHandle,
        outputFile: outputFile,
        control: control,
        startedAt: start
    )

    let exit = await bundle.waitUpTo(seconds: timeoutSeconds)

    if let code = exit {
        // Completed within soft timeout.
        try? bundle.writeHandle.close()
        let text = bundle.readOutput()
        try? FileManager.default.removeItem(at: outputFile)
        if cancellation?.isCancelled == true {
            throw CodingToolError.aborted
        }
        if code != 0 {
            throw CodingToolError.commandFailed(stderr: text.isEmpty ? "command exited with code \(code)" : text, exitCode: code)
        }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        return AgentToolResult(
            content: [.text(TextContent(text: text))],
            details: .object([
                "stdout": .string(text),
                "stderr": .string(""),
                "exitCode": .int(Int(code)),
                "durationMs": .int(durationMs),
            ])
        )
    }

    // Soft timeout fired. Flip to background — process keeps running.
    let spec = BackgroundTaskSpec(
        kind: "bash",
        label: description ?? shortLabel(command),
        description: description,
        hardTimeoutSeconds: hardTimeoutSeconds
    )
    let (taskId, adoptedFile) = await manager.adopt(
        spec: spec,
        outputFile: outputFile,
        sessionId: sessionId,
        waitForCompletion: { bgCancel in
            await bundle.awaitAdoptedCompletion(cancellation: bgCancel)
        }
    )
    let msg = "Command exceeded the foreground soft timeout of \(timeoutSeconds)s and has been moved to the background with task id \(taskId). The process is still running — no work was lost. You will receive a <task-notification> user message when it completes. Full output is being written to: \(adoptedFile.path). Use the Read tool on that path to inspect stdout/stderr; do NOT poll or sleep. For commands you know will take long, set run_in_background=true from the start."
    return AgentToolResult(
        content: [.text(TextContent(text: msg))],
        details: .object([
            "status": .string("auto_backgrounded"),
            "taskId": .string(taskId),
            "outputFile": .string(adoptedFile.path),
            "softTimeoutSeconds": .int(timeoutSeconds),
        ])
    )
}

/// Sendable wrapper over the non-Sendable `Process` + `FileHandle` so the
/// adopt closure can capture them.
private final class ForegroundBashExecution: @unchecked Sendable {
    let process: Process
    let writeHandle: FileHandle
    let outputFile: URL
    let control: BashProcessControl
    let startedAt: Date
    private let lock = NSLock()
    private var done = false

    init(
        process: Process,
        writeHandle: FileHandle,
        outputFile: URL,
        control: BashProcessControl,
        startedAt: Date
    ) {
        self.process = process
        self.writeHandle = writeHandle
        self.outputFile = outputFile
        self.control = control
        self.startedAt = startedAt
    }

    func waitUpTo(seconds: Int) async -> Int32? {
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            DispatchQueue.global().async {
                self.process.waitUntilExit()
                let shouldResume: Bool = self.lock.withLock {
                    if self.done { return false }
                    self.done = true
                    return true
                }
                if shouldResume {
                    cont.resume(returning: self.process.terminationStatus)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) {
                let shouldResume: Bool = self.lock.withLock {
                    if self.done { return false }
                    self.done = true
                    return true
                }
                if shouldResume {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    func awaitAdoptedCompletion(cancellation: CancellationHandle) async -> BackgroundTaskOutcome {
        cancellation.onCancel { [control] _ in control.terminate() }
        // Process already running and fd-dup'd to outputFile. Just wait.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.process.waitUntilExit()
                cont.resume()
            }
        }
        try? writeHandle.close()
        let code = process.terminationStatus
        if control.didCancel || cancellation.isCancelled {
            return BackgroundTaskOutcome(
                success: false,
                summary: "aborted",
                details: .object(["exitCode": .int(Int(code))]),
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

    func readOutput() -> String {
        guard let data = try? Data(contentsOf: outputFile) else { return "" }
        // Cap at 1MB to avoid context bombs on small-looking commands that
        // spewed output before finishing.
        let capped = data.prefix(1_000_000)
        return String(data: capped, encoding: .utf8) ?? ""
    }
}

// MARK: - Helpers

extension BackgroundTaskManager {
    /// Allocate an output file inside the manager's output dir without
    /// registering a task. Used by the foreground-with-flip path so the
    /// adopted file lives under the same directory as spawned ones.
    fileprivate func allocateForegroundOutputFile() -> URL {
        try? FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
        let id = "fg_\(UUID().uuidString.prefix(8))"
        let url = outputDir.appendingPathComponent("\(id).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }
}

private func shortLabel(_ command: String, max: Int = 80) -> String {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= max { return trimmed }
    return String(trimmed.prefix(max)) + "…"
}
