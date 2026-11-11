import Foundation
import KWWKAI

/// Append-only JSONL session persistence. `SessionStore()` is disabled and
/// does not touch disk; the CLI opts into `~/.kwwk/sessions` via
/// `defaultDirectory()`.
///
/// Mirrors pi's `packages/agent/src/harness/session` storage in spirit but
/// keeps a flat append-oriented log instead of pi's branching entry tree: each
/// session file is a versioned header line followed by one JSON entry per
/// line. Entries are transcript messages (`user` / `assistant` /
/// `toolResult`), sparse metadata updates (model / thinking-level changes),
/// or compaction markers that describe the projected resumable context.
///
/// Ordinary persistence is append-only, so recording each message is cheap.
/// Explicit transcript maintenance such as `/shake` atomically rewrites the
/// existing entries so removed payloads do not remain buried in older JSONL
/// lines. Loading replays the log to reconstruct the projected context plus
/// the latest metadata.
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
        // 0700: session transcripts carry the full conversation plus every tool
        // result (bash output, file contents). Lock the directory to the owner
        // at creation, mirroring BackgroundTaskManager's 0700 output dir — no
        // chmod-after-create race.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Stable key order keeps the JSONL human-diffable.
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    struct MessageRewrite: Sendable {
        let messages: [Message]
        let changedCount: Int
    }

    // MARK: - Create / append

    /// Create a new session file with a versioned header. Overwrites any
    /// existing file for the same id — use `createIfMissing` to preserve a
    /// resumed transcript. Returns the written header.
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
        let url = try path(for: id)
        // Create with 0600 at write time (no chmod-after-write window): the
        // transcript is the same class of sensitive data the 0600 task logs
        // protect. createFile truncates an existing file, matching this
        // method's overwrite contract.
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionStoreError.writeFailed(path: url.path)
        }
        return header
    }

    /// Create the session file (header only) only when it does not already
    /// exist. Never truncates an existing transcript, so resuming a session
    /// and then calling this is a safe no-op. Backs `SessionRecorder.ensureCreated`.
    public func createIfMissing(
        id: String,
        cwd: String,
        model: String? = nil,
        provider: String? = nil
    ) throws {
        let url = try path(for: id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try create(id: id, cwd: cwd, model: model, provider: provider)
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
        try appendEntry(
            id: id,
            .message(
                timestamp: Timestamp.now(),
                message: Self.removingInternalMessageSource(message)
            )
        )
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
        reason: CompactionReason,
        usage: Usage? = nil,
        model: String? = nil,
        provider: String? = nil
    ) throws {
        let url = try path(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try create(id: id, cwd: cwd, model: model, provider: provider)
        }
        let trustedRecap = replacementMessages.first.flatMap {
            CompactionPlanner.summaryText(from: $0)
        } == nil ? nil : true
        let persistableMessages = replacementMessages.map(Self.removingInternalMessageSource)
        try appendEntry(
            id: id,
            .compaction(
                timestamp: Timestamp.now(),
                compaction: Compaction(
                    replacementMessages: persistableMessages,
                    messagesCompacted: messagesCompacted,
                    firstKeptMessageIndex: firstKeptMessageIndex,
                    tokensBefore: tokensBefore,
                    contextWindow: contextWindow,
                    trustedRecap: trustedRecap,
                    reason: reason,
                    usage: usage
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

    /// Atomically rewrite every persisted transcript-bearing entry with one
    /// canonical message transformation. Both ordinary message lines and the
    /// replacement context inside compaction markers are rewritten; headers,
    /// metadata, timestamps, and compaction bookkeeping remain unchanged.
    ///
    /// Returns the number of transformed payloads across the physical JSONL
    /// entries. A zero result leaves the file untouched.
    func rewriteMessages(
        id: String,
        using transform: @Sendable ([Message]) -> MessageRewrite
    ) throws -> Int {
        let url = try path(for: id)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SessionStoreError.notFound(id)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw SessionStoreError.missingHeader(url.path)
        }
        _ = try parseHeader(String(first), path: url.path)

        var rewrittenEntries: [Entry] = []
        rewrittenEntries.reserveCapacity(max(0, lines.count - 1))
        var changedCount = 0

        for (offset, line) in lines.dropFirst().enumerated() {
            let lineNumber = offset + 2
            guard let data = String(line).data(using: .utf8) else {
                throw SessionStoreError.undecodableEntry(path: url.path, line: lineNumber)
            }
            let entry: Entry
            do {
                entry = try Self.decoder.decode(Entry.self, from: data)
            } catch {
                throw SessionStoreError.undecodableEntry(path: url.path, line: lineNumber)
            }

            switch entry {
            case .message(let timestamp, let message):
                let rewrite = transform([message])
                changedCount += rewrite.changedCount
                rewrittenEntries.append(.message(
                    timestamp: timestamp,
                    message: rewrite.messages[0]
                ))

            case .compaction(let timestamp, var compaction):
                let rewrite = transform(compaction.replacementMessages)
                changedCount += rewrite.changedCount
                compaction.replacementMessages = rewrite.messages
                rewrittenEntries.append(.compaction(
                    timestamp: timestamp,
                    compaction: compaction
                ))

            case .meta:
                rewrittenEntries.append(entry)
            }
        }

        guard changedCount > 0 else { return 0 }

        var data = Data()
        data.append(contentsOf: first.utf8)
        data.append(0x0A)
        for entry in rewrittenEntries {
            data.append(try Self.encoder.encode(entry))
            data.append(0x0A)
        }
        try replaceAtomically(url: url, data: data)
        return changedCount
    }

    private func replaceAtomically(url: URL, data: Data) throws {
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionStoreError.writeFailed(path: url.path)
        }
        // POSIX rename(2) atomically replaces the destination on macOS and
        // Linux alike. FileManager.replaceItemAt is not usable here: on
        // swift-corelibs-foundation it can leave the destination missing.
        guard rename(temporaryURL.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw SessionStoreError.writeFailed(path: url.path)
        }
    }

    // MARK: - Load

    /// How much of a session file `load` replays.
    public enum LoadScope: Sendable, Hashable {
        /// Every entry: the model-facing context plus the full visual
        /// history (`displayMessages`) a terminal recap shows.
        case full
        /// The model-facing context only. Every compaction marker replaces
        /// the context wholesale, so nothing before the newest marker can
        /// reach it: those entries are skipped without being decoded, apart
        /// from the small `meta` lines. `displayMessages` then equals
        /// `messages`. A long-lived session's file keeps every message it
        /// ever recorded, embedded images included, so this is what keeps
        /// resuming one proportional to its live context rather than to its
        /// age.
        case context
    }

    /// Replay a session file into its header, projected resumable context, raw
    /// transcript message entries, and latest metadata. Throws on a
    /// missing/invalid header or unsupported version.
    public func load(id: String, scope: LoadScope = .full) throws -> LoadedSession {
        try load(at: try path(for: id), scope: scope)
    }

    public func load(at url: URL, scope: LoadScope = .full) throws -> LoadedSession {
        switch scope {
        case .full: return try loadFull(at: url)
        case .context: return try loadContext(at: url)
        }
    }

    private func loadFull(at url: URL) throws -> LoadedSession {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw SessionStoreError.missingHeader(url.path)
        }
        var replay = Replay(header: try parseHeader(String(first), path: url.path), tracksDisplay: true)

        // Line 1 is the header; entries start at line 2. An entry that fails
        // to decode (schema drift after an up/downgrade, mid-file corruption)
        // is an error — throwing with the exact line keeps a resumed context
        // from silently losing messages out of the middle of a conversation.
        for (offset, line) in lines.dropFirst().enumerated() {
            guard let data = String(line).data(using: .utf8) else {
                throw SessionStoreError.undecodableEntry(path: url.path, line: offset + 2)
            }
            replay.apply(try Self.decodeEntry(data, path: url.path, line: offset + 2))
        }
        return replay.loaded
    }

    private func loadContext(at url: URL) throws -> LoadedSession {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw SessionStoreError.notFound(url.lastPathComponent)
        }
        let lines = Self.lineRanges(in: data)
        guard let first = lines.first else {
            throw SessionStoreError.missingHeader(url.path)
        }
        guard let headerLine = String(data: data.subdata(in: first), encoding: .utf8) else {
            throw SessionStoreError.invalidHeader(url.path)
        }
        var replay = Replay(header: try parseHeader(headerLine, path: url.path), tracksDisplay: false)

        // The newest compaction marker, searched from the end. A raw
        // `"type":"compaction"` (unescaped quotes) only occurs as an entry's
        // own discriminator: inside a message it would be string content,
        // where the quotes are escaped. The decode confirms it all the same.
        var start = 1
        var index = lines.count - 1
        while index >= 1 {
            if Self.contains(data, lines[index], Self.compactionDiscriminator),
               case .compaction? = try? Self.decodeEntry(
                    data.subdata(in: lines[index]), path: url.path, line: index + 1) {
                start = index
                break
            }
            index -= 1
        }
        // Metadata is sparse and may predate the marker; nothing else before
        // it can reach the projected context.
        for index in lines.indices.dropFirst().prefix(while: { $0 < start })
        where Self.contains(data, lines[index], Self.metaDiscriminator) {
            replay.apply(try Self.decodeEntry(data.subdata(in: lines[index]), path: url.path, line: index + 1))
        }
        for index in lines.indices.dropFirst(start) {
            replay.apply(try Self.decodeEntry(data.subdata(in: lines[index]), path: url.path, line: index + 1))
        }
        return replay.loaded
    }

    private static let compactionDiscriminator = Array(#""type":"compaction""#.utf8)
    private static let metaDiscriminator = Array(#""type":"meta""#.utf8)

    private static func decodeEntry(_ data: Data, path: String, line: Int) throws -> Entry {
        do {
            return try decoder.decode(Entry.self, from: data)
        } catch {
            throw SessionStoreError.undecodableEntry(path: path, line: line)
        }
    }

    /// The non-empty lines of `data`, numbered like
    /// `split(separator: "\n", omittingEmptySubsequences: true)` numbers them.
    private static func lineRanges(in data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Range<Int>] in
            var ranges: [Range<Int>] = []
            var lineStart = 0
            for offset in 0..<bytes.count where bytes[offset] == 0x0A {
                if offset > lineStart { ranges.append(lineStart..<offset) }
                lineStart = offset + 1
            }
            if bytes.count > lineStart { ranges.append(lineStart..<bytes.count) }
            return ranges
        }
    }

    /// Whether `needle` occurs inside `data[range]`, without copying the line.
    private static func contains(_ data: Data, _ range: Range<Int>, _ needle: [UInt8]) -> Bool {
        guard let head = needle.first, range.count >= needle.count else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var offset = range.lowerBound
            let last = range.upperBound - needle.count
            while offset <= last {
                if bytes[offset] == head {
                    var matched = 1
                    while matched < needle.count, bytes[offset + matched] == needle[matched] { matched += 1 }
                    if matched == needle.count { return true }
                }
                offset += 1
            }
            return false
        }
    }

    /// Replays entries in file order into a `LoadedSession`. The one place
    /// that says what each entry kind does to the projected context.
    private struct Replay {
        let header: Header
        let tracksDisplay: Bool
        var messages: [Message] = []
        var displayMessages: [Message] = []
        var model: String?
        var provider: String?
        var thinkingLevel: String?
        var title: String?

        init(header: Header, tracksDisplay: Bool) {
            self.header = header
            self.tracksDisplay = tracksDisplay
            self.model = header.model
            self.provider = header.provider
        }

        mutating func apply(_ entry: Entry) {
            switch entry {
            case .message(_, let message):
                messages.append(message)
                if tracksDisplay { displayMessages.append(message) }
            case .meta(_, let m, let p, let t, let ti):
                if let m { model = m }
                if let p { provider = p }
                if let t { thinkingLevel = t }
                if let ti { title = ti }
            case .compaction(_, let compaction):
                messages = SessionStore.upgradingLegacyRecapSource(
                    in: compaction.replacementMessages,
                    reason: compaction.reason,
                    trustedRecap: compaction.trustedRecap
                )
                guard tracksDisplay else { return }
                switch compaction.reason {
                case .compact:
                    // Context compaction shrinks the model-facing context
                    // only; the on-screen history is untouched.
                    break
                case .rewind:
                    // Rewind cut the conversation at a prompt: drop the same
                    // tail from the visual history that was cut from the
                    // model context. The kept prefix cannot simply replace
                    // the display — after a compaction it starts with a
                    // summary message the display never contained.
                    displayMessages = Array(
                        displayMessages.dropLast(compaction.messagesCompacted))
                case nil:
                    // Legacy entries predate the reason split and truncated
                    // both the model and the display context.
                    displayMessages = compaction.replacementMessages
                }
            }
        }

        var loaded: LoadedSession {
            LoadedSession(
                header: header,
                messages: messages,
                displayMessages: tracksDisplay ? displayMessages : messages,
                persistedContextCount: messages.count,
                model: model,
                provider: provider,
                thinkingLevel: thinkingLevel,
                title: title
            )
        }
    }

    private static func upgradingLegacyRecapSource(
        in replacementMessages: [Message],
        reason: CompactionReason?,
        trustedRecap: Bool?
    ) -> [Message] {
        // Fail closed for pre-reason markers: they may have represented a
        // rewind of a recap-shaped user prompt. A typed compact marker is
        // authoritative; a rewind must carry the explicit trust bit.
        let markerEstablishesTrust = reason == .compact || trustedRecap == true
        guard markerEstablishesTrust,
              let first = replacementMessages.first,
              case .user(var user) = first,
              user.source == nil,
              CompactionPlanner.isLegacyRecapEnvelope(first) else {
            return replacementMessages
        }

        user.source = .compaction
        var upgraded = replacementMessages
        upgraded[0] = .user(user)
        return upgraded
    }

    /// `.compaction` is an in-memory trust marker introduced after session
    /// schema v1 shipped. Persisting the enum case would make that otherwise
    /// compatible file undecodable by older binaries. The typed compaction
    /// entry restores the marker on load.
    private static func removingInternalMessageSource(_ message: Message) -> Message {
        guard case .user(var user) = message, user.source == .compaction else {
            return message
        }
        user.source = nil
        return .user(user)
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
            // Listing only needs a message count plus the latest meta values, so
            // never JSON-decode the message bodies (full transcripts, embedded
            // base64 images) — that is what made `--continue` startup pay for
            // the entire on-disk history. The encoder writes `.sortedKeys`, so a
            // transcript-message entry is always `{"message":{…`; classify by
            // that prefix and skip the decode. Only the small/rare `meta` lines
            // are decoded (compaction markers are irrelevant to listing).
            if line.hasPrefix("{\"message\":") {
                messageCount += 1
                continue
            }
            guard line.contains("\"type\":\"meta\""),
                  let data = String(line).data(using: .utf8),
                  case .meta(_, let m, let p, _, let ti)? =
                    try? Self.decoder.decode(Entry.self, from: data) else { continue }
            if let m { model = m }
            if let p { provider = p }
            if let ti { title = ti }
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
