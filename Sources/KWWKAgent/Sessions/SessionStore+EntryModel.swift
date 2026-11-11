import Foundation
import KWWKAI

extension SessionStore {

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
    /// Why a projection-replacement entry was written. `.compact` = context
    /// compaction (auto or `/compact`): only the model-facing context shrinks;
    /// the visual transcript is unaffected. `.rewind` = the user cut the
    /// conversation at a prompt: the visual transcript truncates too.
    public enum CompactionReason: String, Codable, Sendable {
        case compact
        case rewind
    }

    public struct Compaction: Codable, Sendable, Hashable {
        public var replacementMessages: [Message]
        public var messagesCompacted: Int
        public var firstKeptMessageIndex: Int?
        public var tokensBefore: Int?
        public var contextWindow: Int?
        /// Persists trust across a rewind that keeps an in-memory compaction
        /// recap. Older readers ignore this additive field.
        public var trustedRecap: Bool?
        /// Nil when decoding pre-`CompactionReason` session files.
        public var reason: CompactionReason?
        /// Provider-reported usage of the summary requests this compaction
        /// (and any failed attempts since the previous marker) made. Their
        /// replies never enter the transcript, so this is the only record of
        /// those tokens. Nil when nothing was billed (native or non-LLM
        /// compaction) and in older session files; older readers ignore it.
        public var usage: Usage?

        public init(
            replacementMessages: [Message],
            messagesCompacted: Int,
            firstKeptMessageIndex: Int? = nil,
            tokensBefore: Int? = nil,
            contextWindow: Int? = nil,
            trustedRecap: Bool? = nil,
            reason: CompactionReason?,
            usage: Usage? = nil
        ) {
            self.replacementMessages = replacementMessages
            self.messagesCompacted = messagesCompacted
            self.firstKeptMessageIndex = firstKeptMessageIndex
            self.tokensBefore = tokensBefore
            self.contextWindow = contextWindow
            self.trustedRecap = trustedRecap
            self.reason = reason
            self.usage = usage
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
            case tokensBefore, contextWindow, trustedRecap, reason, usage
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
                        replacementMessages: try c.decode([Message].self, forKey: .replacementMessages),
                        messagesCompacted: try c.decode(Int.self, forKey: .messagesCompacted),
                        firstKeptMessageIndex: try c.decodeIfPresent(Int.self, forKey: .firstKeptMessageIndex),
                        tokensBefore: try c.decodeIfPresent(Int.self, forKey: .tokensBefore),
                        contextWindow: try c.decodeIfPresent(Int.self, forKey: .contextWindow),
                        trustedRecap: try c.decodeIfPresent(Bool.self, forKey: .trustedRecap),
                        reason: try c.decodeIfPresent(CompactionReason.self, forKey: .reason),
                        usage: try c.decodeIfPresent(Usage.self, forKey: .usage)
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
                try c.encodeIfPresent(compaction.firstKeptMessageIndex, forKey: .firstKeptMessageIndex)
                try c.encodeIfPresent(compaction.tokensBefore, forKey: .tokensBefore)
                try c.encodeIfPresent(compaction.contextWindow, forKey: .contextWindow)
                try c.encodeIfPresent(compaction.trustedRecap, forKey: .trustedRecap)
                try c.encodeIfPresent(compaction.reason, forKey: .reason)
                try c.encodeIfPresent(compaction.usage, forKey: .usage)
            }
        }
    }

    /// Metadata + projected resumable context returned by `load`.
    public struct LoadedSession: Sendable, Hashable {
        public var header: Header
        /// Model-facing context after replaying any compaction markers.
        public var messages: [Message]
        /// What the user actually saw, replayed for visual recaps: every raw
        /// message, truncated by rewind markers but NOT by context compaction
        /// (compaction shrinks the model-facing context, not the on-screen
        /// history).
        public var displayMessages: [Message]
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
            displayMessages: [Message]? = nil,
            persistedContextCount: Int? = nil,
            model: String?,
            provider: String?,
            thinkingLevel: String?,
            title: String? = nil
        ) {
            self.header = header
            self.messages = messages
            self.displayMessages = displayMessages ?? messages
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
        /// A transcript line failed to decode. Carries the file path and the
        /// 1-based line number so schema drift / corruption is diagnosable
        /// instead of silently dropping messages.
        case undecodableEntry(path: String, line: Int)
        case writeFailed(path: String)
    }
}
