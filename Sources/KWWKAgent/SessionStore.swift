import Foundation
import KWWKAI

/// Append-only JSONL session persistence. `SessionStore()` is disabled and
/// does not touch disk; the CLI opts into `~/.kwwk/sessions` via
/// `defaultDirectory()`.
///
/// Mirrors pi's `packages/agent/src/harness/session` storage in spirit but
/// keeps a flat append-only log instead of pi's branching entry tree: each
/// session file is a versioned header line followed by one JSON entry per
/// line. Entries are transcript messages (`user` / `assistant` /
/// `toolResult`), sparse metadata updates (model / thinking-level changes),
/// or compaction markers that describe the projected resumable context.
///
/// The store never rewrites the file — every `append(...)` is an `O(1)` write
/// to the end of the file, so persisting on every message is cheap. Loading
/// replays the log to reconstruct the projected context plus the latest
/// metadata.
///
/// File layout (one JSON object per line):
/// ```
/// {"type":"session","version":1,"id":"…","cwd":"…","createdAt":…,"model":"…","provider":"…"}
/// {"type":"message","timestamp":…,"message":{ …Message… }}
/// {"type":"meta","timestamp":…,"model":"…","provider":"…","thinkingLevel":"…"}
/// {"type":"compaction","timestamp":…,"replacementMessages":[{ …Message… }],"messagesCompacted":42}
/// ```
public actor SessionStore {

    /// On-disk JSONL schema version. Bump when the entry shapes change in a
    /// non-backward-compatible way; `load` rejects unknown versions.
    public static let version = 1

    /// Directory holding `<id>.jsonl` files when persistence is enabled.
    public let directory: URL
    public let isPersistent: Bool

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
            self.isPersistent = true
        } else {
            self.directory = URL(fileURLWithPath: "/dev/null")
            self.isPersistent = false
        }
    }

    /// CLI-compatible session directory: `~/.kwwk/sessions`.
    public static func defaultDirectory() -> URL {
        let home: URL = {
            #if targetEnvironment(macCatalyst) || os(iOS)
            return URL(fileURLWithPath: NSHomeDirectory())
            #else
            return FileManager.default.homeDirectoryForCurrentUser
            #endif
        }()
        return home
            .appendingPathComponent(".kwwk")
            .appendingPathComponent("sessions")
    }

    // MARK: - Entry model

    /// Header line written once at session creation.
    public struct Header: Codable, Sendable, Hashable {
        public var type: String
        public var version: Int
        public var id: String
        public var cwd: String
        /// Unix milliseconds at creation, matching `Timestamp.now()`.
        public var createdAt: Int64
        public var model: String?
        public var provider: String?

        public init(
            id: String,
            cwd: String,
            createdAt: Int64 = Timestamp.now(),
            model: String? = nil,
            provider: String? = nil
        ) {
            self.type = "session"
            self.version = SessionStore.version
            self.id = id
            self.cwd = cwd
            self.createdAt = createdAt
            self.model = model
            self.provider = provider
        }
    }

    /// Append-only marker written when the live agent context is compacted.
    /// `replacementMessages` is the model-facing context that should replace
    /// prior projected messages when the session is resumed.
    public struct Compaction: Codable, Sendable, Hashable {
        public var replacementMessages: [Message]
        public var messagesCompacted: Int
        public var firstKeptMessageIndex: Int?
        public var tokensBefore: Int?
        public var contextWindow: Int?

        public init(
            replacementMessages: [Message],
            messagesCompacted: Int,
            firstKeptMessageIndex: Int? = nil,
            tokensBefore: Int? = nil,
            contextWindow: Int? = nil
        ) {
            self.replacementMessages = replacementMessages
            self.messagesCompacted = messagesCompacted
            self.firstKeptMessageIndex = firstKeptMessageIndex
            self.tokensBefore = tokensBefore
            self.contextWindow = contextWindow
        }
    }

    /// One appended log line after the header. Either a transcript message,
    /// a metadata update, or a context compaction marker.
    public enum Entry: Codable, Sendable, Hashable {
        case message(timestamp: Int64, message: Message)
        case meta(timestamp: Int64, model: String?, provider: String?, thinkingLevel: String?, title: String?)
        case compaction(timestamp: Int64, compaction: Compaction)

        private enum CodingKeys: String, CodingKey {
            case type, timestamp, message, model, provider, thinkingLevel, title
            case replacementMessages, messagesCompacted, firstKeptMessageIndex
            case tokensBefore, contextWindow
        }
        private enum Kind: String, Codable { case message, meta, compaction }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let timestamp = try c.decodeIfPresent(Int64.self, forKey: .timestamp) ?? 0
            switch try c.decode(Kind.self, forKey: .type) {
            case .message:
                self = .message(timestamp: timestamp, message: try c.decode(Message.self, forKey: .message))
            case .meta:
                self = .meta(
                    timestamp: timestamp,
                    model: try c.decodeIfPresent(String.self, forKey: .model),
                    provider: try c.decodeIfPresent(String.self, forKey: .provider),
                    thinkingLevel: try c.decodeIfPresent(String.self, forKey: .thinkingLevel),
                    title: try c.decodeIfPresent(String.self, forKey: .title)
                )
            case .compaction:
                self = .compaction(
                    timestamp: timestamp,
                    compaction: Compaction(
                        replacementMessages: try c.decode(
                            [Message].self, forKey: .replacementMessages),
                        messagesCompacted: try c.decode(Int.self, forKey: .messagesCompacted),
                        firstKeptMessageIndex: try c.decodeIfPresent(
                            Int.self, forKey: .firstKeptMessageIndex),
                        tokensBefore: try c.decodeIfPresent(Int.self, forKey: .tokensBefore),
                        contextWindow: try c.decodeIfPresent(Int.self, forKey: .contextWindow)
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .message(let timestamp, let message):
                try c.encode(Kind.message, forKey: .type)
                try c.encode(timestamp, forKey: .timestamp)
                try c.encode(message, forKey: .message)
            case .meta(let timestamp, let model, let provider, let thinkingLevel, let title):
                try c.encode(Kind.meta, forKey: .type)
                try c.encode(timestamp, forKey: .timestamp)
                try c.encodeIfPresent(model, forKey: .model)
                try c.encodeIfPresent(provider, forKey: .provider)
                try c.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
                try c.encodeIfPresent(title, forKey: .title)
            case .compaction(let timestamp, let compaction):
                try c.encode(Kind.compaction, forKey: .type)
                try c.encode(timestamp, forKey: .timestamp)
                try c.encode(compaction.replacementMessages, forKey: .replacementMessages)
                try c.encode(compaction.messagesCompacted, forKey: .messagesCompacted)
                try c.encodeIfPresent(
                    compaction.firstKeptMessageIndex, forKey: .firstKeptMessageIndex)
                try c.encodeIfPresent(compaction.tokensBefore, forKey: .tokensBefore)
                try c.encodeIfPresent(compaction.contextWindow, forKey: .contextWindow)
            }
        }
    }

    /// Metadata + projected resumable context returned by `load`.
    public struct LoadedSession: Sendable, Hashable {
        public var header: Header
        /// Model-facing context after replaying any compaction markers.
        public var messages: [Message]
        /// Raw transcript message entries, excluding compaction replacements.
        public var transcriptMessages: [Message]
        /// Number of messages in `messages` already represented on disk.
        public var persistedContextCount: Int
        /// Latest model id seen (from the header or a later `meta` entry).
        public var model: String?
        /// Latest provider id seen.
        public var provider: String?
        /// Latest thinking level seen, if any `meta` entry recorded one.
        public var thinkingLevel: String?
        /// Latest user-set session title, if any `meta` entry recorded one.
        public var title: String?

        public init(
            header: Header,
            messages: [Message],
            transcriptMessages: [Message]? = nil,
            persistedContextCount: Int? = nil,
            model: String?,
            provider: String?,
            thinkingLevel: String?,
            title: String? = nil
        ) {
            self.header = header
            self.messages = messages
            self.transcriptMessages = transcriptMessages ?? messages
            self.persistedContextCount = persistedContextCount ?? messages.count
            self.model = model
            self.provider = provider
            self.thinkingLevel = thinkingLevel
            self.title = title
        }
    }

    /// Lightweight summary returned by `list` — does not replay the full
    /// transcript, only reads the header and counts message lines.
    public struct SessionInfo: Sendable, Hashable {
        public var id: String
        public var cwd: String
        public var createdAt: Int64
        public var model: String?
        public var provider: String?
        /// Last-modified time of the file in Unix milliseconds; used to sort
        /// "most recently active" sessions.
        public var updatedAt: Int64
        public var messageCount: Int
        /// Latest user-set session title, if any `meta` entry recorded one.
        public var title: String?
        public var path: URL

        public init(
            id: String,
            cwd: String,
            createdAt: Int64,
            model: String?,
            provider: String?,
            updatedAt: Int64,
            messageCount: Int,
            title: String? = nil,
            path: URL
        ) {
            self.id = id
            self.cwd = cwd
            self.createdAt = createdAt
            self.model = model
            self.provider = provider
            self.updatedAt = updatedAt
            self.messageCount = messageCount
            self.title = title
            self.path = path
        }
    }

    public enum SessionStoreError: Error, Equatable, Sendable {
        case missingHeader(String)
        case invalidHeader(String)
        case unsupportedVersion(found: Int, expected: Int)
        case notFound(String)
        case invalidId(String)
        case storageDisabled
    }

    // MARK: - Paths

    public static func isValidSessionId(_ id: String) -> Bool {
        guard let first = id.first, let last = id.last,
              first.isLetter || first.isNumber,
              last.isLetter || last.isNumber else { return false }
        return id.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "."
        }
    }

    private func path(for id: String) throws -> URL {
        guard isPersistent else { throw SessionStoreError.storageDisabled }
        guard Self.isValidSessionId(id) else { throw SessionStoreError.invalidId(id) }
        return directory.appendingPathComponent("\(id).jsonl")
    }

    private func ensureDirectory() throws {
        guard isPersistent else { throw SessionStoreError.storageDisabled }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Stable key order keeps the JSONL human-diffable.
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    // MARK: - Create / append

    /// Create a new session file with a versioned header. Overwrites any
    /// existing file for the same id. Returns the written header.
    @discardableResult
    public func create(
        id: String,
        cwd: String,
        model: String? = nil,
        provider: String? = nil
    ) throws -> Header {
        try ensureDirectory()
        let header = Header(id: id, cwd: cwd, model: model, provider: provider)
        let line = try Self.encoder.encode(header)
        var data = line
        data.append(0x0A)  // newline
        try data.write(to: try path(for: id), options: .atomic)
        return header
    }

    /// Append a single transcript message to a session, creating the file
    /// (with a header) on demand if it does not yet exist.
    public func append(
        id: String,
        cwd: String,
        message: Message,
        model: String? = nil,
        provider: String? = nil
    ) throws {
        let url = try path(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try create(id: id, cwd: cwd, model: model, provider: provider)
        }
        try appendEntry(id: id, .message(timestamp: Timestamp.now(), message: message))
    }

    /// Append all `messages` in order. Persists each as its own JSONL line.
    public func append(
        id: String,
        cwd: String,
        messages: [Message],
        model: String? = nil,
        provider: String? = nil
    ) throws {
        for message in messages {
            try append(id: id, cwd: cwd, message: message, model: model, provider: provider)
        }
    }

    /// Record a metadata change (model / provider / thinking level) without a
    /// transcript message.
    public func appendMeta(
        id: String,
        model: String? = nil,
        provider: String? = nil,
        thinkingLevel: String? = nil,
        title: String? = nil
    ) throws {
        try appendEntry(id: id, .meta(
            timestamp: Timestamp.now(),
            model: model,
            provider: provider,
            thinkingLevel: thinkingLevel,
            title: title
        ))
    }

    /// Record a user-set session title as an append-only `meta` entry,
    /// creating the file (with a header) on demand. Backs `/rename`.
    public func setTitle(id: String, cwd: String, title: String) throws {
        let url = try path(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try create(id: id, cwd: cwd)
        }
        try appendMeta(id: id, title: title)
    }

    /// Record a context compaction without rewriting prior message entries.
    /// Loading the session will project `replacementMessages` first, followed
    /// by message entries appended after this marker.
    public func appendCompaction(
        id: String,
        cwd: String,
        replacementMessages: [Message],
        messagesCompacted: Int,
        firstKeptMessageIndex: Int? = nil,
        tokensBefore: Int? = nil,
        contextWindow: Int? = nil,
        model: String? = nil,
        provider: String? = nil
    ) throws {
        let url = try path(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try create(id: id, cwd: cwd, model: model, provider: provider)
        }
        try appendEntry(
            id: id,
            .compaction(
                timestamp: Timestamp.now(),
                compaction: Compaction(
                    replacementMessages: replacementMessages,
                    messagesCompacted: messagesCompacted,
                    firstKeptMessageIndex: firstKeptMessageIndex,
                    tokensBefore: tokensBefore,
                    contextWindow: contextWindow
                )
            ))
    }

    private func appendEntry(id: String, _ entry: Entry) throws {
        let url = try path(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionStoreError.notFound(id)
        }
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(line)
    }

    // MARK: - Load

    /// Replay a session file into its header, projected resumable context, raw
    /// transcript message entries, and latest metadata. Throws on a
    /// missing/invalid header or unsupported version.
    public func load(id: String) throws -> LoadedSession {
        try load(at: try path(for: id))
    }

    public func load(at url: URL) throws -> LoadedSession {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw SessionStoreError.missingHeader(url.path)
        }
        let header = try parseHeader(String(first), path: url.path)

        var messages: [Message] = []
        var transcriptMessages: [Message] = []
        var model = header.model
        var provider = header.provider
        var thinkingLevel: String?
        var title: String?

        for line in lines.dropFirst() {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? Self.decoder.decode(Entry.self, from: data) else {
                // Skip malformed/partial trailing lines (e.g. a crash mid-write)
                // rather than failing the whole load.
                continue
            }
            switch entry {
            case .message(_, let message):
                transcriptMessages.append(message)
                messages.append(message)
            case .meta(_, let m, let p, let t, let ti):
                if let m { model = m }
                if let p { provider = p }
                if let t { thinkingLevel = t }
                if let ti { title = ti }
            case .compaction(_, let compaction):
                messages = compaction.replacementMessages
            }
        }

        return LoadedSession(
            header: header,
            messages: messages,
            transcriptMessages: transcriptMessages,
            persistedContextCount: messages.count,
            model: model,
            provider: provider,
            thinkingLevel: thinkingLevel,
            title: title
        )
    }

    private func parseHeader(_ line: String, path: String) throws -> Header {
        guard let data = line.data(using: .utf8),
              let header = try? Self.decoder.decode(Header.self, from: data) else {
            throw SessionStoreError.invalidHeader(path)
        }
        guard header.type == "session" else {
            throw SessionStoreError.invalidHeader(path)
        }
        guard header.version == Self.version else {
            throw SessionStoreError.unsupportedVersion(found: header.version, expected: Self.version)
        }
        return header
    }

    // MARK: - Listing

    /// All sessions on disk, newest activity first. Unreadable / malformed
    /// files are skipped rather than aborting the listing.
    public func list() -> [SessionInfo] {
        guard isPersistent else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var infos: [SessionInfo] = []
        for url in entries where url.pathExtension == "jsonl" {
            guard let info = try? info(at: url) else { continue }
            infos.append(info)
        }
        // Sort by updatedAt (mtime) descending. Filesystem mtime resolution
        // can tie two sessions written in the same tick, so break ties with
        // createdAt (millisecond, set at header creation) to keep ordering
        // deterministic — otherwise "most recent for cwd" is non-deterministic.
        infos.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.createdAt > $1.createdAt
        }
        return infos
    }

    private func info(at url: URL) throws -> SessionInfo {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw SessionStoreError.missingHeader(url.path)
        }
        let header = try parseHeader(String(first), path: url.path)

        var model = header.model
        var provider = header.provider
        var title: String?
        var messageCount = 0
        for line in lines.dropFirst() {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? Self.decoder.decode(Entry.self, from: data) else { continue }
            switch entry {
            case .message:
                messageCount += 1
            case .meta(_, let m, let p, _, let ti):
                if let m { model = m }
                if let p { provider = p }
                if let ti { title = ti }
            case .compaction:
                continue
            }
        }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let updatedAt = mtime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? header.createdAt

        return SessionInfo(
            id: header.id,
            cwd: header.cwd,
            createdAt: header.createdAt,
            model: model,
            provider: provider,
            updatedAt: updatedAt,
            messageCount: messageCount,
            title: title,
            path: url
        )
    }

    /// Most recently active session whose header `cwd` matches `cwd`, or nil
    /// if none exist. Backs the `--resume` / `--continue` CLI flags.
    public func latestForCwd(_ cwd: String) -> SessionInfo? {
        let target = Self.normalize(cwd)
        return list().first { Self.normalize($0.cwd) == target }
    }

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
