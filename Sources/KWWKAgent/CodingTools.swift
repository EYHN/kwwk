import Foundation
import KWWKAI

public enum CodingToolError: Error, Equatable, LocalizedError {
    case notImplemented
    case fileNotFound(String)
    case invalidArgument(String)
    case runtime(String)
    case textNotFound(String)
    case multipleMatches(count: Int)
    case offsetOutOfRange(offset: Int, totalLines: Int)
    case aborted
    case commandFailed(stderr: String, exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "not implemented"
        case .fileNotFound(let path):
            return "file not found: \(path)"
        case .invalidArgument(let message):
            return message
        case .runtime(let message):
            return message
        case .textNotFound(let message):
            return message
        case .multipleMatches(let count):
            return "found \(count) occurrences; text must be unique"
        case .offsetOutOfRange(let offset, let total):
            return "offset \(offset) is beyond end of file (\(total) lines total)"
        case .aborted:
            return "aborted by user"
        case .commandFailed(let stderr, let exitCode):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "command exited with code \(exitCode)"
            }
            return "\(trimmed) (exit \(exitCode))"
        }
    }
}

// MARK: - Pluggable operations

public protocol ReadOperations: Sendable {
    func readFile(_ absolutePath: String) async throws -> Data
    func access(_ absolutePath: String) async throws
    func detectImageMimeType(_ absolutePath: String) async throws -> String?
}

public protocol WriteOperations: Sendable {
    func writeFile(_ absolutePath: String, content: Data) async throws
    func createParentDirectories(_ absolutePath: String) async throws
}

public protocol EditOperations: Sendable {
    func readFile(_ absolutePath: String) async throws -> Data
    func writeFile(_ absolutePath: String, content: Data) async throws
}

public protocol BashOperations: Sendable {
    func execute(command: String, timeout: Int?, cancellation: CancellationHandle?) async throws -> BashExecutionResult
}

public protocol GrepOperations: Sendable {
    func grep(params: GrepParams) async throws -> [GrepMatch]
}

public protocol FindOperations: Sendable {
    func find(pattern: String, cwd: String, limit: Int?) async throws -> [String]
}

public protocol LSOperations: Sendable {
    func list(path: String) async throws -> [LSEntry]
}

// MARK: - Tool result structures

public struct BashExecutionResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var durationMs: Int
    public var timedOut: Bool

    public init(stdout: String, stderr: String, exitCode: Int32, durationMs: Int = 0, timedOut: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.timedOut = timedOut
    }
}

public struct GrepParams: Sendable {
    public var pattern: String
    public var path: String
    public var glob: String?
    public var ignoreCase: Bool
    public var literal: Bool
    public var context: Int
    public var limit: Int?

    public init(pattern: String, path: String, glob: String? = nil, ignoreCase: Bool = false, literal: Bool = false, context: Int = 0, limit: Int? = nil) {
        self.pattern = pattern
        self.path = path
        self.glob = glob
        self.ignoreCase = ignoreCase
        self.literal = literal
        self.context = context
        self.limit = limit
    }
}

public struct GrepMatch: Sendable, Equatable {
    public var file: String
    public var line: Int
    public var text: String
    public init(file: String, line: Int, text: String) {
        self.file = file
        self.line = line
        self.text = text
    }
}

public struct LSEntry: Sendable, Equatable {
    public enum Kind: Sendable { case file, directory, symlink }
    public var name: String
    public var kind: Kind
    public var size: Int64
    public init(name: String, kind: Kind, size: Int64) {
        self.name = name
        self.kind = kind
        self.size = size
    }
}

// MARK: - Tool detail payloads (mirroring pi-coding-agent details shapes)

public struct ReadToolDetails: Sendable, Codable, Equatable {
    public struct Truncation: Sendable, Codable, Equatable {
        public var truncated: Bool
        public var truncatedBy: String           // "lines" | "bytes"
        public var totalLines: Int
        public var outputLines: Int
        public var maxLines: Int?
        public var maxBytes: Int?
        public var firstLineExceedsLimit: Bool

        public init(truncated: Bool, truncatedBy: String, totalLines: Int, outputLines: Int, maxLines: Int? = nil, maxBytes: Int? = nil, firstLineExceedsLimit: Bool = false) {
            self.truncated = truncated
            self.truncatedBy = truncatedBy
            self.totalLines = totalLines
            self.outputLines = outputLines
            self.maxLines = maxLines
            self.maxBytes = maxBytes
            self.firstLineExceedsLimit = firstLineExceedsLimit
        }
    }
    public var truncation: Truncation?
    public init(truncation: Truncation? = nil) { self.truncation = truncation }
}

public struct EditToolDetails: Sendable, Codable, Equatable {
    public var diff: String
    public init(diff: String) { self.diff = diff }
}
