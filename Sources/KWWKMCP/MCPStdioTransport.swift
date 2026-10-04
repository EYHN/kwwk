import Foundation
import KWWKAI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Spawns an MCP server and exchanges newline-delimited JSON-RPC messages
/// over its stdin/stdout. Stderr is drained continuously; its tail is kept
/// for error messages (`diagnostics`).
///
/// Only available on macOS and Linux; elsewhere `start()` throws
/// `MCPError.unsupportedTransport`.
public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    /// Bytes of stderr kept for error messages.
    public static let stderrTailLimit = 4_000
    /// Grace period between SIGTERM and SIGKILL on close.
    public static let terminateGraceSeconds: Double = 2

    public let command: String
    public let args: [String]
    public let env: [String: String]
    public let cwd: String?
    public let workingDirectory: String

    private let lock = NSLock()
    private var stderrBuffer = Data()
    private var continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?
    private var closing = false
    private var started = false
    #if os(macOS) || os(Linux)
    private var process: Process?
    private var stdinHandle: FileHandle?
    private let writeLock = NSLock()
    #endif

    /// - Parameters:
    ///   - env: Added to the inherited environment.
    ///   - cwd: Server working directory; relative paths resolve against
    ///     `workingDirectory`. `~/` names the home directory.
    ///   - workingDirectory: Session directory, also the default `cwd`.
    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        cwd: String? = nil,
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.workingDirectory = workingDirectory
    }

    public var diagnostics: String? {
        let tail = lock.withLock { stderrBuffer }
        let text = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    #if os(macOS) || os(Linux)

    public func start() async throws -> AsyncThrowingStream<JSONRPCMessage, Error> {
        try lock.withLock {
            guard !started else { throw MCPError.protocolError("transport already started") }
            started = true
        }
        Self.ignoreSIGPIPEOnce

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }

        let directory = Self.resolvePath(Self.expandHome(cwd ?? "."), relativeTo: workingDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPError.spawnFailed("working directory does not exist: \(directory)")
        }
        let expandedCommand = Self.expandHome(command)
        guard let executable = Self.findExecutable(
            expandedCommand, path: environment["PATH"], relativeTo: directory
        ) else {
            throw MCPError.spawnFailed("command not found: \(command)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args.map(Self.expandHome)
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let (stream, continuation) = AsyncThrowingStream<JSONRPCMessage, Error>.makeStream()
        lock.withLock {
            self.continuation = continuation
            self.process = process
            self.stdinHandle = stdin.fileHandleForWriting
        }
        process.terminationHandler = { [weak self] _ in
            // stdout EOF normally finishes the stream first. A grandchild that
            // inherited stdout can keep it open, so finish after a grace period
            // regardless.
            guard let transport = self else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                transport.finishAfterExit()
            }
        }
        do {
            try process.run()
        } catch {
            lock.withLock {
                self.continuation = nil
                self.process = nil
                self.stdinHandle = nil
            }
            continuation.finish()
            throw MCPError.spawnFailed("\(command): \(error.localizedDescription)")
        }
        #if canImport(Darwin)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif

        let stdoutReader = stdout.fileHandleForReading
        let stderrReader = stderr.fileHandleForReading
        Thread.detachNewThread { [self] in
            var framer = NewlineFramer()
            while true {
                let data = stdoutReader.availableData
                if data.isEmpty { break }
                for line in framer.append(data) { deliver(line: line) }
            }
            if let rest = framer.finish() { deliver(line: rest) }
            // Wait briefly for the exit status so the close error can name it.
            for _ in 0..<20 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.05)
            }
            finishAfterExit()
        }
        Thread.detachNewThread { [self] in
            while true {
                let data = stderrReader.availableData
                if data.isEmpty { break }
                appendStderr(data)
            }
        }
        return stream
    }

    public func send(_ message: JSONRPCMessage) async throws {
        var data = try message.encoded()
        data.append(UInt8(ascii: "\n"))
        guard let handle = lock.withLock({ closing ? nil : stdinHandle }) else {
            throw MCPError.connectionClosed(details: diagnostics)
        }
        do {
            try writeLock.withLock { try handle.write(contentsOf: data) }
        } catch {
            throw MCPError.connectionClosed(details: diagnostics ?? error.localizedDescription)
        }
    }

    public func close() async {
        let (process, stdin, continuation): (Process?, FileHandle?, AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?) =
            lock.withLock {
                if closing { return (nil, nil, nil) }
                closing = true
                let result = (self.process, stdinHandle, self.continuation)
                stdinHandle = nil
                self.continuation = nil
                return result
            }
        continuation?.finish()
        try? stdin?.close()
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(Self.terminateGraceSeconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func deliver(line: Data) {
        let messages: [JSONRPCMessage]
        do {
            messages = try JSONRPCMessage.decodeAll(line)
        } catch {
            // Servers sometimes log to stdout; keep the line for diagnostics
            // instead of failing the connection.
            appendStderr(line + Data("\n".utf8))
            return
        }
        guard let continuation = lock.withLock({ self.continuation }) else { return }
        for message in messages { continuation.yield(message) }
    }

    private func appendStderr(_ data: Data) {
        lock.withLock {
            stderrBuffer.append(data)
            if stderrBuffer.count > Self.stderrTailLimit {
                stderrBuffer = Data(stderrBuffer.suffix(Self.stderrTailLimit))
            }
        }
    }

    private func finishAfterExit() {
        let (continuation, process) = lock.withLock { () -> (AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?, Process?) in
            let result = (self.continuation, self.process)
            self.continuation = nil
            return result
        }
        guard let continuation else { return }
        var details: [String] = []
        if let process, !process.isRunning {
            details.append("server exited with status \(process.terminationStatus)")
        }
        if let tail = diagnostics { details.append(tail) }
        continuation.finish(throwing: MCPError.connectionClosed(details: details.isEmpty ? nil : details.joined(separator: "\n")))
    }

    /// Ignore SIGPIPE on Linux, where a pipe cannot opt out per descriptor;
    /// writing to a server that exited must fail with EPIPE, not kill kwwk.
    private static let ignoreSIGPIPEOnce: Void = {
        #if os(Linux)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
    }()

    #else

    public func start() async throws -> AsyncThrowingStream<JSONRPCMessage, Error> {
        throw MCPError.unsupportedTransport("The stdio MCP transport is not supported on this platform")
    }

    public func send(_ message: JSONRPCMessage) async throws {
        throw MCPError.unsupportedTransport("The stdio MCP transport is not supported on this platform")
    }

    public func close() async {}

    #endif

    // MARK: - Paths

    static func expandHome(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home + String(value.dropFirst(1)) }
        return value
    }

    static func resolvePath(_ path: String, relativeTo base: String) -> String {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        return URL(fileURLWithPath: base).appendingPathComponent(path).standardizedFileURL.path
    }

    /// Resolve `command` like a shell would: paths containing `/` are used
    /// as-is (relative to `relativeTo`), bare names are looked up on `PATH`.
    static func findExecutable(_ command: String, path: String?, relativeTo base: String) -> String? {
        let fileManager = FileManager.default
        if command.contains("/") {
            let resolved = resolvePath(command, relativeTo: base)
            return fileManager.isExecutableFile(atPath: resolved) ? resolved : nil
        }
        let searchPath = path ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
