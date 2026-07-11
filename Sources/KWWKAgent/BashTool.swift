import Foundation
import KWWKAI

/// SDK-safe default shell for command execution. CLI entry points may override
/// this with the user's configured shell after explicitly opting into CLI
/// ambient behavior.
public let kwwkDefaultShellPath = "/bin/sh"

/// Runtime command boundary for shell-enabled coding tools.
///
/// `.buildAndTestOnly` is intentionally conservative: it accepts one direct
/// build/test process and rejects shell composition, redirection, command
/// substitution, and unrelated executables before a process is spawned. It is
/// an accidental-destruction guard for specialist agents, not an OS sandbox;
/// the selected build system still executes trusted project code.
public enum BashCommandPolicy: Sendable, Equatable {
    case unrestricted
    case buildAndTestOnly
}

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
    /// Shell for the `-c <command>` invocation (used by file-based paths;
    /// the `operations` executor may use its own shell).
    public var shellPath: String
    /// Exact environment passed to spawned shell processes.
    public var environment: [String: String]
    /// Optional runtime restriction applied after schema validation and any
    /// `beforeToolCall` argument rewrite, immediately before execution.
    public var commandPolicy: BashCommandPolicy

    public init(
        environment: [String: String],
        operations: BashOperations? = nil,
        defaultTimeoutSeconds: Int = 120,
        maxTimeoutSeconds: Int = 600,
        manager: BackgroundTaskManager? = nil,
        sessionId: String? = nil,
        autoBackgroundOnTimeout: Bool = true,
        hardTimeoutSeconds: Int = 1800,
        shellPath: String = kwwkDefaultShellPath,
        commandPolicy: BashCommandPolicy = .unrestricted
    ) {
        self.operations = operations ?? LocalBashOperations(
            shellPath: shellPath,
            environment: environment
        )
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.maxTimeoutSeconds = maxTimeoutSeconds
        self.manager = manager
        self.sessionId = sessionId
        self.autoBackgroundOnTimeout = autoBackgroundOnTimeout
        self.hardTimeoutSeconds = hardTimeoutSeconds
        self.shellPath = shellPath
        self.environment = environment
        self.commandPolicy = commandPolicy
    }
}

public struct LocalBashOperations: BashOperations {
    public let cwd: String?
    public let shellPath: String
    public let environment: [String: String]

    public init(
        cwd: String? = nil,
        shellPath: String = kwwkDefaultShellPath,
        environment: [String: String]
    ) {
        self.cwd = cwd
        self.shellPath = shellPath
        self.environment = environment
    }

    public func execute(
        command: String,
        timeout: Int?,
        cancellation: CancellationHandle?
    ) async throws -> BashExecutionResult {
        // Spawn via posix_spawn (SpawnedBashProcess) so the child gets its own
        // process group — cancel/timeout then signals the whole group and
        // reaches any grandchildren, not just the direct shell. Foundation's
        // Process leaves the child in our group, so `kill` would miss them.
        let effectiveCommand: String
        if let cwd {
            effectiveCommand = "cd \(bashShellQuote(cwd)) && \(command)"
        } else {
            effectiveCommand = command
        }

        // Isolate stdin from the parent (handled inside SpawnedBashProcess by
        // dup'ing /dev/null onto STDIN): the coding TUI runs its own stdin in
        // raw mode, so a child reading stdin would steal the user's keystrokes
        // and interactive wizards would hang. /dev/null forces EOF on reads.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let control = BashProcessControl(pid: 0)
        let start = Date()

        let spawned: SpawnedBashProcess
        do {
            spawned = try SpawnedBashProcess.start(
                shellPath: shellPath,
                command: effectiveCommand,
                stdoutFd: stdoutPipe.fileHandleForWriting.fileDescriptor,
                stderrFd: stderrPipe.fileHandleForWriting.fileDescriptor,
                environment: environment,
                extraEnv: [:]
            )
        } catch {
            throw CodingToolError.commandFailed(stderr: "\(error)", exitCode: -1)
        }
        // Close our copies of the write ends so the read ends see EOF once the
        // child exits and closes its dup'd copies.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        control.setPid(spawned.pid)
        cancellation?.onCancel { _ in control.terminate() }

        var timeoutTask: Task<Void, Never>?
        if let timeout, timeout > 0 {
            timeoutTask = Task {
                // A cancelled sleep means the process already exited — the
                // deadline never arrived, so it must not count as a timeout.
                guard (try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)) != nil else { return }
                control.timeoutAndTerminate()
            }
        }

        // Drain both pipes CONCURRENTLY with the wait. Reading only after
        // waitpid would deadlock once the child fills the ~64KB pipe buffer:
        // the child blocks in write(2) while we block in wait.
        let outBox = OutputBox()
        let errBox = OutputBox()
        let statusBox = ExitStatusBox()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
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
            group.enter()
            DispatchQueue.global().async {
                statusBox.status = spawned.wait()
                group.leave()
            }
            group.notify(queue: .global()) { cont.resume() }
        }
        timeoutTask?.cancel()

        let stdout = String(decoding: outBox.data, as: UTF8.self)
        let stderr = String(decoding: errBox.data, as: UTF8.self)
        let duration = Int(Date().timeIntervalSince(start) * 1000)

        if cancellation?.isCancelled == true {
            throw CodingToolError.aborted
        }
        if control.didTimeOut {
            throw CodingToolError.commandFailed(stderr: "Command timed out after \(timeout ?? 0)ms\n" + stderr, exitCode: -1)
        }
        // The wait closure always sets `status` before the group completes.
        let code = statusBox.status!.code
        if code != 0 {
            throw CodingToolError.commandFailed(stderr: stderr.isEmpty ? stdout : stderr, exitCode: code)
        }
        return BashExecutionResult(stdout: stdout, stderr: stderr, exitCode: code, durationMs: duration, timedOut: false)
    }
}

/// `@unchecked Sendable` holders used to return values out of the concurrent
/// pipe-drain closures. Written on dispatch threads, read by the awaiting task
/// after `DispatchGroup.notify` establishes a happens-before edge.
private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

private final class ExitStatusBox: @unchecked Sendable {
    var status: SpawnedBashProcess.ExitStatus?
}

public func createBashTool(cwd: String, options: BashToolOptions) -> AgentTool {
    let hasManager = options.manager != nil
    let ops: BashOperations = {
        if let local = options.operations as? LocalBashOperations, local.cwd == nil {
            return LocalBashOperations(
                cwd: cwd,
                shellPath: local.shellPath,
                environment: options.environment
            )
        }
        return options.operations
    }()

    let defaultTimeoutSec = options.defaultTimeoutSeconds
    let maxTimeoutSec = options.maxTimeoutSeconds
    let manager = options.manager
    let sessionId = options.sessionId
    let autoBg = options.autoBackgroundOnTimeout
    let hardTimeoutSec = options.hardTimeoutSeconds
    let shellPath = options.shellPath
    let environment = options.environment
    let commandPolicy = options.commandPolicy

    var tool = AgentTool(
        name: "bash",
        label: "bash",
        description: bashToolDescription(hasManager: hasManager, cwd: cwd),
        parameters: bashToolParameters(
            hasManager: hasManager,
            defaultTimeoutSec: defaultTimeoutSec,
            maxTimeoutSec: maxTimeoutSec
        ),
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            let input = try BashInput.parse(
                args,
                defaultTimeoutSec: defaultTimeoutSec,
                maxTimeoutSec: maxTimeoutSec
            )
            try validateBashCommand(input.command, policy: commandPolicy)

            // Dispatch: background spawn → foreground-with-auto-flip → legacy pipe.
            // Only the first two paths need a manager; without one we fall
            // through to the pre-background pipe executor so older callers
            // keep working.
            if input.runInBackground, let manager {
                return await runBashInBackground(
                    input: input,
                    manager: manager,
                    sessionId: sessionId,
                    cwd: cwd,
                    shellPath: shellPath,
                    environment: environment,
                    hardTimeoutSeconds: hardTimeoutSec
                )
            }
            if let manager, autoBg {
                return try await runBashForegroundWithFlip(
                    input: input,
                    manager: manager,
                    sessionId: sessionId,
                    cwd: cwd,
                    shellPath: shellPath,
                    environment: environment,
                    hardTimeoutSeconds: hardTimeoutSec,
                    cancellation: cancellation
                )
            }
            return try await runBashLegacy(
                input: input,
                ops: ops,
                cancellation: cancellation
            )
        }
    )
    tool.codingToolCapabilities = .bash
    return tool
}

// MARK: - Schema

private func bashToolDescription(hasManager: Bool, cwd: String) -> String {
    let outputGuidance = "Inline output is already bounded. Do not append `head` or `tail` merely to truncate output; use them only when they are part of the command's actual intent."
    if hasManager {
        return """
        Execute a shell command. Runs in \(cwd) by default. Stdout and stderr are returned on completion.

        \(outputGuidance)

        Long-running commands (installs, builds, test suites) should be started with run_in_background=true so the agent isn't blocked. The tool returns a task ID immediately; you will receive an internal runtime completion notification when the task finishes. Use task(list:true) for bounded live status and task(read:{task_id,offset,limit}) for manager-authorized stdout/stderr inspection — do NOT poll or sleep merely to retrieve output.

        Foreground commands that exceed the `timeout` are automatically moved to the background (the process keeps running — no work is lost) and you are notified on completion.
        """
    }
    return "Execute a shell command and return its output. \(outputGuidance)"
}

private func bashToolParameters(
    hasManager: Bool,
    defaultTimeoutSec: Int,
    maxTimeoutSec: Int
) -> JSONValue {
    var props: [String: JSONValue] = [
        "command": ["type": "string"],
        "timeout": .object([
            "type": .string("number"),
            "description": .string("Seconds before the foreground soft timeout. When a background manager is attached, the command auto-moves to background at this point. Default \(defaultTimeoutSec), max \(maxTimeoutSec)."),
            "minimum": .int(1),
            "maximum": .int(maxTimeoutSec),
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
}

// MARK: - Input parsing

/// Validated view of the `bash` tool arguments. Centralizes the JSONValue
/// unpacking so the dispatch code reads like business logic.
private struct BashInput {
    let command: String
    let description: String?
    /// Seconds, already clamped to `[1, maxTimeoutSec]`.
    let timeoutSeconds: Int
    let runInBackground: Bool

    static func parse(
        _ args: JSONValue,
        defaultTimeoutSec: Int,
        maxTimeoutSec: Int
    ) throws -> BashInput {
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
        return BashInput(
            command: command,
            description: description,
            timeoutSeconds: timeoutSec,
            runInBackground: runInBg
        )
    }
}

private func validateBashCommand(
    _ command: String,
    policy: BashCommandPolicy
) throws {
    guard policy == .buildAndTestOnly else { return }
    do {
        let words = try restrictedShellWords(command)
        try validateBuildAndTestWords(words)
    } catch let error as RestrictedBashCommandError {
        throw CodingToolError.invalidArgument(
            "bash: command rejected by build-and-test policy: \(error.message). "
                + "Run one direct build/test command per call; bash already runs in the "
                + "workspace and captures bounded stdout/stderr without pipes or redirection."
        )
    }
}

private struct RestrictedBashCommandError: Error {
    var message: String
}

/// Parse one shell command into words while rejecting composition before the
/// shell sees it. Quotes and backslash escapes remain available for ordinary
/// arguments, but operators capable of adding a second process or writing an
/// arbitrary path are forbidden. This is deliberately smaller than a shell
/// grammar so unsupported syntax fails closed.
private func restrictedShellWords(_ command: String) throws -> [String] {
    enum Quote: Equatable {
        case none
        case single
        case double
    }

    let characters = Array(command)
    var quote = Quote.none
    var escaped = false
    var word = ""
    var words: [String] = []

    func reject(_ syntax: Character) throws -> Never {
        throw RestrictedBashCommandError(
            message: "shell operator '\(syntax)' is not allowed"
        )
    }

    func finishWord() {
        guard !word.isEmpty else { return }
        words.append(word)
        word = ""
    }

    var index = 0
    while index < characters.count {
        let character = characters[index]
        if escaped {
            word.append(character)
            escaped = false
            index += 1
            continue
        }

        switch quote {
        case .single:
            if character == "'" { quote = .none }
            else { word.append(character) }

        case .double:
            if character == "\"" {
                quote = .none
            } else if character == "\\" {
                escaped = true
            } else if character == "`"
                || (character == "$"
                    && index + 1 < characters.count
                    && characters[index + 1] == "(") {
                throw RestrictedBashCommandError(
                    message: "command substitution is not allowed"
                )
            } else {
                word.append(character)
            }

        case .none:
            if character == "'" {
                quote = .single
            } else if character == "\"" {
                quote = .double
            } else if character == "\\" {
                escaped = true
            } else if character.isWhitespace {
                finishWord()
            } else if character == "`"
                || (character == "$"
                    && index + 1 < characters.count
                    && characters[index + 1] == "(") {
                throw RestrictedBashCommandError(
                    message: "command substitution is not allowed"
                )
            } else if [";", "|", "&", ">", "<", "(", ")", "{", "}"].contains(character) {
                try reject(character)
            } else {
                word.append(character)
            }
        }
        index += 1
    }

    guard quote == .none, !escaped else {
        throw RestrictedBashCommandError(message: "unterminated quote or escape")
    }
    finishWord()
    guard !words.isEmpty else {
        throw RestrictedBashCommandError(message: "command is empty")
    }
    return words
}

private func validateBuildAndTestWords(_ originalWords: [String]) throws {
    var words = originalWords
    while let first = words.first, isShellEnvironmentAssignment(first) {
        words.removeFirst()
    }
    if words.first == "env" {
        words.removeFirst()
        while let first = words.first,
              first.hasPrefix("-") || isShellEnvironmentAssignment(first) {
            words.removeFirst()
        }
    }
    if words.first == "time" { words.removeFirst() }
    guard !words.isEmpty else {
        throw RestrictedBashCommandError(message: "missing build/test executable")
    }

    if words.first == "xcrun" {
        words.removeFirst()
        while let first = words.first, first.hasPrefix("-") {
            words.removeFirst()
        }
    }
    if words.starts(with: ["bundle", "exec"])
        || words.starts(with: ["poetry", "run"])
        || words.starts(with: ["uv", "run"]) {
        words.removeFirst(2)
    }
    guard let executableWord = words.first else {
        throw RestrictedBashCommandError(message: "missing build/test executable")
    }
    let executable = URL(fileURLWithPath: executableWord).lastPathComponent.lowercased()
    let arguments = Array(words.dropFirst())
    let loweredArguments = arguments.map { $0.lowercased() }

    let destructiveWords = [
        "clean", "distclean", "clobber", "purge", "reset", "install", "uninstall",
    ]
    if let destructive = loweredArguments.first(where: { argument in
        destructiveWords.contains(argument)
            || destructiveWords.contains { argument.contains("--\($0)") }
    }) {
        throw RestrictedBashCommandError(
            message: "destructive build argument '\(destructive)' is not allowed"
        )
    }

    let accepted: Bool
    switch executable {
    case "swift":
        accepted = loweredArguments.first.map { ["build", "test"].contains($0) } ?? false
    case "python", "python3":
        accepted = loweredArguments.count >= 2
            && loweredArguments[0] == "-m"
            && ["pytest", "unittest", "tox", "nox"].contains(loweredArguments[1])
    case "npm", "pnpm", "yarn", "bun":
        accepted = packageManagerArgumentsAreBuildOrTest(loweredArguments)
    case "cargo":
        accepted = loweredArguments.first.map {
            ["build", "test", "check", "clippy", "bench"].contains($0)
        } ?? false
    case "go":
        accepted = loweredArguments.first.map {
            ["build", "test", "vet"].contains($0)
        } ?? false
    case "dotnet":
        accepted = loweredArguments.first.map { ["build", "test"].contains($0) } ?? false
    case "mix":
        accepted = loweredArguments.first.map { ["compile", "test"].contains($0) } ?? false
    case "cmake":
        accepted = loweredArguments.contains("--build") || loweredArguments.contains("--workflow")
    case "make", "gmake", "ninja":
        accepted = makeLikeArgumentsAreBuildOrTest(loweredArguments)
    case "xcodebuild":
        accepted = !loweredArguments.contains("clean")
    case "gradle", "gradlew", "mvn", "mvnw", "bazel", "buck", "buck2":
        accepted = loweredArguments.contains { buildOrTestToken($0) }
    case "pytest", "py.test", "tox", "nox", "rspec", "rake", "jest", "vitest", "mocha", "ctest":
        accepted = true
    default:
        accepted = false
    }

    guard accepted else {
        throw RestrictedBashCommandError(
            message: "executable '\(executable)' is not an allowed build/test invocation"
        )
    }
}

private func isShellEnvironmentAssignment(_ word: String) -> Bool {
    guard let equal = word.firstIndex(of: "=") else { return false }
    let name = word[..<equal]
    guard let first = name.first,
          first == "_" || first.isLetter else { return false }
    return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
}

private func packageManagerArgumentsAreBuildOrTest(_ arguments: [String]) -> Bool {
    guard let first = arguments.first else { return false }
    if ["test", "build", "check", "lint", "typecheck"].contains(first) { return true }
    guard first == "run", arguments.count >= 2 else { return false }
    return buildOrTestToken(arguments[1])
}

private func makeLikeArgumentsAreBuildOrTest(_ arguments: [String]) -> Bool {
    let targets = arguments.filter { !$0.hasPrefix("-") && !$0.contains("=") }
    return targets.isEmpty || targets.allSatisfy(buildOrTestToken)
}

private func buildOrTestToken(_ token: String) -> Bool {
    let normalized = token.lowercased()
    return ["build", "test", "check", "lint", "verify", "typecheck", "compile", "bench"]
        .contains { normalized.contains($0) }
}

// MARK: - Path 1: explicit background

private func runBashInBackground(
    input: BashInput,
    manager: BackgroundTaskManager,
    sessionId: String?,
    cwd: String,
    shellPath: String,
    environment: [String: String],
    hardTimeoutSeconds: Int
) async -> AgentToolResult {
    let runner = BashBackgroundRunner(
        command: input.command,
        workDir: cwd,
        description: input.description,
        hardTimeoutSeconds: hardTimeoutSeconds,
        shellPath: shellPath,
        label: input.description ?? bashShortLabel(input.command),
        environment: environment
    )
    let (taskId, outputFile) = await manager.spawn(
        runner: runner,
        sessionId: sessionId
    )
    let msg = "Command started in background with task id \(taskId). You will receive an internal runtime completion notification when it completes. Use task(read:{task_id:\"\(taskId)\",offset,limit}) to inspect stdout/stderr in the meantime; do NOT poll or sleep. (Raw output file, outside the workspace: \(outputFile.path).)"
    return AgentToolResult(
        content: [.text(TextContent(text: msg))],
        details: .object([
            "status": .string("background_started"),
            "taskId": .string(taskId),
            "outputFile": .string(outputFile.path),
        ])
    )
}

// MARK: - Path 2: foreground with auto-flip-to-background on timeout

/// Run the command in the foreground with stdout/stderr fd-dup'd onto a file.
/// If it exceeds `input.timeoutSeconds`, hand the still-running process off
/// to the background manager (adopt) and return an `auto_backgrounded`
/// result — the process is NOT killed, bytes already on disk are preserved,
/// and the completion notification fires via the Manager.
private func runBashForegroundWithFlip(
    input: BashInput,
    manager: BackgroundTaskManager,
    sessionId: String?,
    cwd: String,
    shellPath: String,
    environment: [String: String],
    hardTimeoutSeconds: Int,
    cancellation: CancellationHandle?
) async throws -> AgentToolResult {
    let outputFile = await manager.allocateForegroundOutputFile()

    // posix_spawn onto the output file (own process group, stdout+stderr → file,
    // stdin ← /dev/null). `cd`-prefix the command since posix_spawn has no cwd
    // file action — same convention as the background runner.
    let effectiveCommand = "cd \(bashShellQuote(cwd)) && \(input.command)"
    let control = BashProcessControl(pid: 0)
    let start = Date()

    let spawned: SpawnedBashProcess
    do {
        spawned = try SpawnedBashProcess.start(
            shellPath: shellPath,
            command: effectiveCommand,
            outputFile: outputFile,
            environment: environment,
            extraEnv: [:]
        )
    } catch {
        try? FileManager.default.removeItem(at: outputFile)
        throw CodingToolError.commandFailed(stderr: "\(error)", exitCode: -1)
    }
    control.setPid(spawned.pid)
    cancellation?.onCancel { _ in control.terminate() }

    let bundle = ForegroundBashExecution(
        spawned: spawned,
        outputFile: outputFile,
        control: control,
        startedAt: start
    )

    let exit = await bundle.waitUpTo(seconds: input.timeoutSeconds)

    if let status = exit {
        // Completed within soft timeout.
        let text = bundle.readOutput()
        try? FileManager.default.removeItem(at: outputFile)
        if cancellation?.isCancelled == true {
            throw CodingToolError.aborted
        }
        let code = status.code
        if code != 0 {
            throw CodingToolError.commandFailed(stderr: text.isEmpty ? "command exited with code \(code)" : text, exitCode: code)
        }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        return AgentToolResult(
            content: [.text(TextContent(text: text))],
            details: .object([
                "exitCode": .int(Int(code)),
                "durationMs": .int(durationMs),
            ])
        )
    }

    // Soft timeout fired. Flip to background — the process keeps running,
    // its fds keep writing to outputFile, and the manager owns completion.
    let spec = BackgroundTaskSpec(
        kind: "bash",
        label: input.description ?? bashShortLabel(input.command),
        description: input.description,
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
    let msg = "Command exceeded the foreground soft timeout of \(input.timeoutSeconds)s and has been moved to the background with task id \(taskId). The process is still running — no work was lost. You will receive an internal runtime completion notification when it completes. Use task(read:{task_id:\"\(taskId)\",offset,limit}) to inspect stdout/stderr; do NOT poll or sleep. For commands you know will take long, set run_in_background=true from the start. (Raw output file, outside the workspace: \(adoptedFile.path).)"
    return AgentToolResult(
        content: [.text(TextContent(text: msg))],
        details: .object([
            "status": .string("auto_backgrounded"),
            "taskId": .string(taskId),
            "outputFile": .string(adoptedFile.path),
            "softTimeoutSeconds": .int(input.timeoutSeconds),
        ])
    )
}

// MARK: - Path 3: legacy pipe-based foreground (no manager attached)

private func runBashLegacy(
    input: BashInput,
    ops: BashOperations,
    cancellation: CancellationHandle?
) async throws -> AgentToolResult {
    let result = try await ops.execute(
        command: input.command,
        timeout: input.timeoutSeconds * 1000,
        cancellation: cancellation
    )
    let body = boundBashOutput(
        [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    )
    return AgentToolResult(
        content: [.text(TextContent(text: body))],
        details: .object([
            "exitCode": .int(Int(result.exitCode)),
            "durationMs": .int(result.durationMs),
        ])
    )
}

/// Bound bash output before it enters the transcript. Command output is most
/// useful at the tail (errors and summaries land at the end), so keep the last
/// lines/bytes within the read tool's budget. Callers that keep a full copy on
/// disk (the flip/background paths) still expose it via the output file; this
/// only bounds what the model sees inline, and is not duplicated into `details`.
func boundBashOutput(_ text: String) -> String {
    let result = Truncate.truncateTail(text)
    guard result.truncated else { return result.content }
    let omitted = result.totalLines - result.outputLines
    let notice = "[output truncated: \(omitted) earlier line(s) omitted; showing last "
        + "\(result.outputLines) of \(result.totalLines) lines, "
        + "\(Truncate.formatSize(result.totalBytes)) total]\n"
    return notice + result.content
}

// MARK: - Foreground/adopted process wrapper

/// Sendable wrapper over a `SpawnedBashProcess`. Two roles:
///   * Race the soft timeout against process termination via `waitUpTo`.
///   * If the timeout wins, let the Manager's adopt closure await the same
///     cached termination result and map it to a `BackgroundTaskOutcome`.
///
/// A single background thread runs the blocking `waitpid`; its cached result
/// fans out to every registered `onExit` callback, so the soft-timeout race and
/// a later adopted wait share one reap.
private final class ForegroundBashExecution: @unchecked Sendable {
    let spawned: SpawnedBashProcess
    let outputFile: URL
    let control: BashProcessControl
    let startedAt: Date
    private let lock = NSLock()
    private var exitWaiterStarted = false
    private var exitStatus: SpawnedBashProcess.ExitStatus?
    private var exitCallbacks: [@Sendable (SpawnedBashProcess.ExitStatus) -> Void] = []

    init(
        spawned: SpawnedBashProcess,
        outputFile: URL,
        control: BashProcessControl,
        startedAt: Date
    ) {
        self.spawned = spawned
        self.outputFile = outputFile
        self.control = control
        self.startedAt = startedAt
    }

    func waitUpTo(seconds: Int) async -> SpawnedBashProcess.ExitStatus? {
        return await withCheckedContinuation { (cont: CheckedContinuation<SpawnedBashProcess.ExitStatus?, Never>) in
            let oneShot = OneShotContinuation(cont)
            self.onExit { status in
                oneShot.resume(returning: status)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) {
                oneShot.resume(returning: nil)
            }
        }
    }

    func awaitAdoptedCompletion(cancellation: CancellationHandle) async -> BackgroundTaskOutcome {
        cancellation.onCancel { [control] _ in control.terminate() }
        let status = await awaitExitStatus()
        return BashProcessOutcome.from(
            status: status,
            cancelled: control.didCancel || cancellation.isCancelled
        )
    }

    /// Read the completed command's output, bounded to the read tool's budget.
    /// Reads only the tail window of the file so a multi-GB log never lands in
    /// memory; the full output stays on disk at `outputFile`.
    func readOutput() -> String {
        guard let handle = try? FileHandle(forReadingFrom: outputFile) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size == 0 { return "" }
        // Read a generous tail window, then apply the line/byte budget on top.
        let window: UInt64 = 4 * 1024 * 1024
        let startOffset = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: startOffset)) != nil,
              let data = try? handle.read(upToCount: Int(size - startOffset)) else {
            return ""
        }
        return boundBashOutput(String(decoding: data, as: UTF8.self))
    }

    private func awaitExitStatus() async -> SpawnedBashProcess.ExitStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SpawnedBashProcess.ExitStatus, Never>) in
            onExit { status in cont.resume(returning: status) }
        }
    }

    private func onExit(_ callback: @escaping @Sendable (SpawnedBashProcess.ExitStatus) -> Void) {
        startExitWaiterIfNeeded()
        let status: SpawnedBashProcess.ExitStatus? = lock.withLock {
            if let exitStatus { return exitStatus }
            exitCallbacks.append(callback)
            return nil
        }
        if let status {
            callback(status)
        }
    }

    private func startExitWaiterIfNeeded() {
        let shouldStart: Bool = lock.withLock {
            if exitWaiterStarted { return false }
            exitWaiterStarted = true
            return true
        }
        guard shouldStart else { return }

        let spawned = self.spawned
        DispatchQueue.global().async { [weak self] in
            let status = spawned.wait()
            self?.finishExit(status: status)
        }
    }

    private func finishExit(status: SpawnedBashProcess.ExitStatus) {
        let callbacks: [@Sendable (SpawnedBashProcess.ExitStatus) -> Void] = lock.withLock {
            if exitStatus != nil { return [] }
            exitStatus = status
            let callbacks = exitCallbacks
            exitCallbacks.removeAll()
            return callbacks
        }
        for callback in callbacks {
            callback(status)
        }
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let continuation: CheckedContinuation<Value, Never>? = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }
}

// MARK: - Manager helper

extension BackgroundTaskManager {
    /// Allocate an output file inside the manager's output dir without
    /// registering a task. Used by the foreground-with-flip path so the
    /// adopted file lives under the same directory as spawned ones.
    fileprivate func allocateForegroundOutputFile() -> URL {
        try? FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let id = "fg_\(UUID().uuidString.prefix(8))"
        let url = outputDir.appendingPathComponent("\(id).log")
        FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        return url
    }
}
