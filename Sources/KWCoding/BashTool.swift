import Foundation
import KWAI
import KWAgent

public struct BashToolOptions: Sendable {
    public var operations: BashOperations
    public var defaultTimeoutMs: Int
    public init(
        operations: BashOperations = LocalBashOperations(),
        defaultTimeoutMs: Int = 120_000
    ) {
        self.operations = operations
        self.defaultTimeoutMs = defaultTimeoutMs
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

/// Thread-safe shared control for a running `Process` so Sendable-typed
/// closures (cancellation listener, timeout task) can terminate and mark
/// state without directly capturing the non-Sendable `Process`.
final class BashProcessControl: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var terminated = false
    private var _didTimeOut = false

    init(pid: pid_t) { self.pid = pid }

    var didTimeOut: Bool { lock.withLock { _didTimeOut } }

    func terminate() {
        lock.lock()
        if terminated { lock.unlock(); return }
        terminated = true
        lock.unlock()
        kill(pid, SIGTERM)
    }

    func timeoutAndTerminate() {
        lock.lock()
        if terminated { lock.unlock(); return }
        terminated = true
        _didTimeOut = true
        lock.unlock()
        kill(pid, SIGTERM)
    }
}

public func createBashTool(cwd: String, options: BashToolOptions = .init()) -> AgentTool {
    let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "command": ["type": "string"],
            "timeout": ["type": "number", "description": "Timeout in milliseconds."],
        ],
        "required": ["command"],
    ]
    let ops: BashOperations = {
        if let local = options.operations as? LocalBashOperations, local.cwd == nil {
            return LocalBashOperations(cwd: cwd, shellPath: local.shellPath)
        }
        return options.operations
    }()
    let defaultTimeout = options.defaultTimeoutMs
    return AgentTool(
        name: "bash",
        label: "bash",
        description: "Execute a shell command and return its output.",
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let command) = obj["command"] ?? .null else {
                throw CodingToolError.invalidArgument("bash: `command` is required")
            }
            let timeout: Int = {
                if case .int(let v) = obj["timeout"] ?? .null { return v }
                if case .double(let v) = obj["timeout"] ?? .null { return Int(v) }
                return defaultTimeout
            }()
            let result = try await ops.execute(command: command, timeout: timeout, cancellation: cancellation)
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
