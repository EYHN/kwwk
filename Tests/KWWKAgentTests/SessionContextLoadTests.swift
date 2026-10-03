import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// `load(scope: .context)` skips every entry before the newest compaction
/// marker. It must project exactly the context, count and metadata a full
/// replay projects; only the visual history differs.
@Suite("SessionStore context load")
struct SessionContextLoadTests {

    @Test("context load matches a full replay across compactions, rewinds and metadata")
    func matchesFullReplay() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "mixed"
        let cwd = "/w"

        try await store.append(id: id, cwd: cwd, messages: [user("a"), assistant("b")], model: "m0", provider: "p0")
        try await store.appendMeta(id: id, model: "m1", thinkingLevel: "high")
        try await store.setTitle(id: id, cwd: cwd, title: "before the marker")
        try await store.append(id: id, cwd: cwd, messages: [user("c"), assistant("d"), user("e")])
        try await store.appendCompaction(
            id: id, cwd: cwd, replacementMessages: [user("summary 1")], messagesCompacted: 5, reason: .compact)
        try await store.append(id: id, cwd: cwd, messages: [assistant("f"), user("g"), assistant("h")])
        try await store.appendCompaction(
            id: id, cwd: cwd, replacementMessages: [user("summary 1"), assistant("f")],
            messagesCompacted: 2, reason: .rewind)
        try await store.appendMeta(id: id, provider: "p2")
        try await store.append(id: id, cwd: cwd, messages: [user("i"), assistant("j")])

        let full = try await store.load(id: id)
        let context = try await store.load(id: id, scope: .context)
        #expect(context.messages == full.messages)
        #expect(context.persistedContextCount == full.persistedContextCount)
        #expect(context.model == "m1")
        #expect(context.provider == "p2")
        #expect(context.thinkingLevel == "high")
        #expect(context.title == "before the marker")
        #expect(context.header == full.header)
        #expect(context.displayMessages == context.messages)
        #expect(full.displayMessages != full.messages)
    }

    @Test("a session without a compaction marker replays every entry")
    func noMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.append(id: "plain", cwd: "/w", messages: [user("a"), assistant("b"), user("c")])

        let full = try await store.load(id: "plain")
        let context = try await store.load(id: "plain", scope: .context)
        #expect(context.messages == full.messages)
        #expect(context.persistedContextCount == 3)
    }

    @Test("legacy markers without a reason still project their replacement")
    func legacyMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "legacy"
        try await store.append(id: id, cwd: "/w", messages: [user("a"), assistant("b"), user("c")])
        try await store.appendCompaction(
            id: id, cwd: "/w", replacementMessages: [user("a")], messagesCompacted: 2, reason: .rewind)
        try await store.append(id: id, cwd: "/w", message: assistant("d"))
        let file = dir.appendingPathComponent("\(id).jsonl")
        let raw = try String(contentsOf: file, encoding: .utf8)
        try raw.replacingOccurrences(of: #""reason":"rewind","#, with: "")
            .write(to: file, atomically: true, encoding: .utf8)

        let full = try await store.load(id: id)
        let context = try await store.load(id: id, scope: .context)
        #expect(context.messages == full.messages)
        #expect(texts(context.messages) == ["a", "d"])
    }

    @Test("marker-shaped text inside a message is not taken for a marker")
    func markerTextInsideMessage() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "lookalike"
        try await store.append(id: id, cwd: "/w", message: user("a"))
        try await store.appendCompaction(
            id: id, cwd: "/w", replacementMessages: [user("summary")], messagesCompacted: 1, reason: .compact)
        try await store.append(id: id, cwd: "/w", messages: [
            user(#"{"type":"compaction"} and "type":"meta" as plain text"#),
            assistant("ok"),
        ])

        let full = try await store.load(id: id)
        let context = try await store.load(id: id, scope: .context)
        #expect(context.messages == full.messages)
        #expect(context.messages.count == 3)
    }

    @Test("an entry before the newest marker is never decoded")
    func skipsEntriesBeforeTheMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "old-corruption"
        try await store.append(id: id, cwd: "/w", message: user("a"))
        try appendRaw(#"{"message":"not-an-object","timestamp":1,"type":"message"}"#, id: id, dir: dir)
        try await store.appendCompaction(
            id: id, cwd: "/w", replacementMessages: [user("summary")], messagesCompacted: 2, reason: .compact)
        try await store.append(id: id, cwd: "/w", message: assistant("b"))

        let context = try await store.load(id: id, scope: .context)
        #expect(texts(context.messages) == ["summary", "b"])
        await #expect(throws: SessionStore.SessionStoreError.self) {
            _ = try await store.load(id: id)
        }
    }

    @Test("an undecodable entry after the newest marker throws with its line")
    func throwsAfterTheMarker() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "new-corruption"
        try await store.append(id: id, cwd: "/w", message: user("a"))
        try await store.appendCompaction(
            id: id, cwd: "/w", replacementMessages: [user("summary")], messagesCompacted: 1, reason: .compact)
        try appendRaw(#"{"message":"not-an-object","timestamp":1,"type":"message"}"#, id: id, dir: dir)

        let url = dir.appendingPathComponent("\(id).jsonl")
        var caught: SessionStore.SessionStoreError?
        do {
            _ = try await store.load(id: id, scope: .context)
        } catch let error as SessionStore.SessionStoreError {
            caught = error
        }
        #expect(caught == .undecodableEntry(path: url.path, line: 4))
    }

    @Test("resolveResume passes the scope through")
    func resolveResumeScope() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "resume"
        try await store.append(id: id, cwd: "/w", messages: [user("a"), assistant("b")])
        try await store.appendCompaction(
            id: id, cwd: "/w", replacementMessages: [user("summary")], messagesCompacted: 2, reason: .compact)
        try await store.append(id: id, cwd: "/w", message: user("c"))

        let resolved = try await store.resolveResume(.id(id), cwd: "/w", scope: .context)
        #expect(resolved.resumed)
        #expect(texts(resolved.messages) == ["summary", "c"])
        #expect(resolved.displayMessages == resolved.messages)
        #expect(resolved.persistedCount == 2)
    }

    private func tempStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwsess-context-\(UUID().uuidString)")
        return (SessionStore(directory: dir), dir)
    }

    private func appendRaw(_ line: String, id: String, dir: URL) throws {
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("\(id).jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(Data((line + "\n").utf8))
    }

    /// Message text only: each constructed message carries its own timestamp.
    private func texts(_ messages: [Message]) -> [String] {
        messages.map { message in
            switch message {
            case .user(let user):
                return user.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined()
            case .assistant(let assistant):
                return assistant.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined()
            default:
                return ""
            }
        }
    }

    private func user(_ text: String) -> Message {
        .user(UserMessage(text: text))
    }

    private func assistant(_ text: String) -> Message {
        .assistant(AssistantMessage(
            content: [.text(TextContent(text: text))],
            api: "anthropic",
            provider: "anthropic",
            model: "claude-test"
        ))
    }
}
