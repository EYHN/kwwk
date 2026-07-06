import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// Covers the session-persistence review findings: ensureCreated must not
/// truncate a resumed transcript, load must surface (not swallow) an
/// undecodable entry, listing must count without decoding message bodies, and
/// transcripts land 0600 in a 0700 directory.
@Suite("Session hardening")
struct SessionHardeningTests {

    private func tempStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwsess-hardening-\(UUID().uuidString)")
        return (SessionStore(directory: dir), dir)
    }

    private func userMsg(_ text: String) -> Message { .user(UserMessage(text: text)) }
    private func assistantMsg(_ text: String) -> Message {
        .assistant(AssistantMessage(
            content: [.text(TextContent(text: text))],
            api: "anthropic", provider: "anthropic", model: "claude-test"
        ))
    }

    // H9: the recorder's ensureCreated used to unconditionally overwrite the
    // file, wiping a resumed transcript to a header-only stub.
    @Test("ensureCreated after resume preserves the persisted transcript")
    func ensureCreatedNeverTruncates() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "resume-preserve"
        try await store.append(id: id, cwd: "/w", message: userMsg("a"),
                               model: "m1", provider: "p1")
        try await store.append(id: id, cwd: "/w", message: assistantMsg("b"))

        // Simulate a resuming SDK caller who (wrongly) calls ensureCreated on a
        // recorder seeded with the already-persisted count.
        let recorder = SessionRecorder(
            store: store, sessionId: id, cwd: "/w",
            model: "m1", provider: "p1", persistedCount: 2
        )
        await recorder.ensureCreated()

        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 2)
    }

    @Test("createIfMissing creates a fresh file but leaves an existing one intact")
    func createIfMissingIsIdempotent() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "if-missing"
        try await store.createIfMissing(id: id, cwd: "/w")
        try await store.append(id: id, cwd: "/w", message: userMsg("only"))
        // Second call must be a no-op, not an overwrite.
        try await store.createIfMissing(id: id, cwd: "/w")

        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 1)
    }

    // M24: a mid-file entry that fails to decode must throw with a line number
    // rather than silently dropping messages out of the conversation.
    @Test("load throws on an undecodable mid-file entry")
    func loadThrowsOnCorruptEntry() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "corrupt-mid"
        try await store.append(id: id, cwd: "/w", message: userMsg("good"))
        // Header = line 1, the good message = line 2. Append a line 3 whose
        // `message` is a string, not a Message object → decode fails.
        let url = dir.appendingPathComponent("\(id).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data(#"{"message":"not-an-object","timestamp":1,"type":"message"}"# .utf8))
        handle.write(Data("\n".utf8))
        try handle.close()

        var caught: SessionStore.SessionStoreError?
        do {
            _ = try await store.load(id: id)
        } catch let error as SessionStore.SessionStoreError {
            caught = error
        }
        #expect(caught == .undecodableEntry(path: url.path, line: 3))
    }

    // M25: listing counts message lines and reads the latest meta without
    // decoding the (potentially huge) message bodies.
    @Test("listing counts messages and picks up meta without full decode")
    func listingCountsCheaply() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "count-me"
        try await store.append(id: id, cwd: "/w", message: userMsg("one"),
                               model: "m1", provider: "p1")
        try await store.append(id: id, cwd: "/w", message: assistantMsg("two"))
        try await store.append(id: id, cwd: "/w", message: userMsg("three"))
        try await store.setTitle(id: id, cwd: "/w", title: "My Session")

        let infos = await store.list()
        let info = try #require(infos.first { $0.id == id })
        #expect(info.messageCount == 3)
        #expect(info.title == "My Session")
        #expect(info.model == "m1")
    }

    // L18: transcripts carry the full conversation + tool output, so they get
    // the same 0600 file / 0700 dir treatment as background task logs.
    @Test("session file is 0600 inside a 0700 directory")
    func transcriptPermissionsLockedDown() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "locked"
        try await store.create(id: id, cwd: "/w")

        let fm = FileManager.default
        let dirMode = try #require(
            (try fm.attributesOfItem(atPath: dir.path)[.posixPermissions]) as? Int)
        let fileMode = try #require(
            (try fm.attributesOfItem(atPath: dir.appendingPathComponent("\(id).jsonl").path)[.posixPermissions]) as? Int)
        #expect(dirMode == 0o700)
        #expect(fileMode == 0o600)
    }
}
