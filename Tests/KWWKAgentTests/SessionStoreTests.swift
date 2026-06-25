import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("SessionStore")
struct SessionStoreTests {

    /// Each test gets its own throwaway sessions directory.
    private func tempStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwsess-\(UUID().uuidString)")
        return (SessionStore(directory: dir), dir)
    }

    private func userMsg(_ text: String) -> Message {
        .user(UserMessage(text: text))
    }

    private func assistantMsg(_ text: String) -> Message {
        .assistant(AssistantMessage(
            content: [.text(TextContent(text: text))],
            api: "anthropic",
            provider: "anthropic",
            model: "claude-test"
        ))
    }

    private func toolResultMsg(_ text: String) -> Message {
        .toolResult(ToolResultMessage(
            toolCallId: "call_1",
            toolName: "bash",
            content: [.text(TextContent(text: text))]
        ))
    }

    @Test("round-trip: append then load preserves order and content")
    func roundTrip() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rt"
        let cwd = "/tmp/project"
        try await store.append(id: id, cwd: cwd, message: userMsg("hello"),
                                model: "claude-test", provider: "anthropic")
        try await store.append(id: id, cwd: cwd, message: assistantMsg("hi there"))
        try await store.append(id: id, cwd: cwd, message: toolResultMsg("exit 0"))

        let loaded = try await store.load(id: id)
        #expect(loaded.header.id == id)
        #expect(loaded.header.cwd == cwd)
        #expect(loaded.model == "claude-test")
        #expect(loaded.provider == "anthropic")
        #expect(loaded.messages.count == 3)

        guard case .user(let u) = loaded.messages[0] else {
            Issue.record("expected user message"); return
        }
        #expect(u.content == [.text(TextContent(text: "hello"))])

        guard case .assistant(let a) = loaded.messages[1] else {
            Issue.record("expected assistant message"); return
        }
        #expect(a.content == [.text(TextContent(text: "hi there"))])

        guard case .toolResult(let t) = loaded.messages[2] else {
            Issue.record("expected toolResult message"); return
        }
        #expect(t.toolName == "bash")
        #expect(t.content == [.text(TextContent(text: "exit 0"))])
    }

    @Test("version header is written and round-trips at the current version")
    func versionHeader() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-version"
        try await store.append(id: id, cwd: "/w", message: userMsg("x"))

        // First physical line must be the versioned session header.
        let file = dir.appendingPathComponent("\(id).jsonl")
        let raw = try String(contentsOf: file, encoding: .utf8)
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? ""
        let headerData = firstLine.data(using: .utf8)!
        let header = try JSONDecoder().decode(SessionStore.Header.self, from: headerData)
        #expect(header.type == "session")
        #expect(header.version == SessionStore.version)
        #expect(header.id == id)

        let loaded = try await store.load(id: id)
        #expect(loaded.header.version == SessionStore.version)
    }

    @Test("load rejects an unsupported version header")
    func unsupportedVersion() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let id = "sess-badver"
        let file = dir.appendingPathComponent("\(id).jsonl")
        let bogus = #"{"type":"session","version":999,"id":"sess-badver","cwd":"/w","createdAt":1}"#
        try (bogus + "\n").data(using: .utf8)!.write(to: file)

        await #expect(throws: SessionStore.SessionStoreError.self) {
            _ = try await store.load(id: id)
        }
    }

    @Test("session ids are validated before touching the filesystem")
    func invalidSessionId() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(SessionStore.isValidSessionId("sess-ok_1.2"))
        #expect(!SessionStore.isValidSessionId("../escape"))
        #expect(!SessionStore.isValidSessionId("-leading"))
        #expect(!SessionStore.isValidSessionId("trailing-"))

        await #expect(throws: SessionStore.SessionStoreError.self) {
            try await store.append(id: "../escape", cwd: "/w", message: userMsg("x"))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape.jsonl").path))
    }

    @Test("resolveResume(.id) does not reuse or overwrite a corrupt target")
    func corruptExplicitResumeFallsBackToFresh() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let id = "sess-corrupt"
        let file = dir.appendingPathComponent("\(id).jsonl")
        let raw = #"{"type":"session","version":999,"id":"sess-corrupt","cwd":"/w","createdAt":1}"# + "\n"
        try raw.data(using: .utf8)!.write(to: file)

        let resolved = await store.resolveResume(.id(id), cwd: "/w", freshId: "fresh-session")
        #expect(!resolved.resumed)
        #expect(resolved.sessionId == "fresh-session")
        #expect((try? String(contentsOf: file, encoding: .utf8)) == raw)
    }

    @Test("list returns one info per session, newest activity first")
    func list() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.append(id: "a", cwd: "/x", message: userMsg("one"),
                               model: "m1", provider: "p1")
        try await store.append(id: "a", cwd: "/x", message: assistantMsg("reply"))
        // Nudge mtimes apart so ordering is deterministic.
        try await store.append(id: "b", cwd: "/y", message: userMsg("two"))

        let infos = await store.list()
        #expect(infos.count == 2)
        #expect(Set(infos.map(\.id)) == ["a", "b"])

        let a = try #require(infos.first { $0.id == "a" })
        #expect(a.cwd == "/x")
        #expect(a.model == "m1")
        #expect(a.messageCount == 2)

        // Sorted by updatedAt descending.
        #expect(infos[0].updatedAt >= infos[1].updatedAt)
    }

    @Test("latestForCwd returns the most-recent session matching the cwd")
    func latestForCwd() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.append(id: "old", cwd: "/proj", message: userMsg("old"))
        try await store.append(id: "other", cwd: "/elsewhere", message: userMsg("nope"))
        try await store.append(id: "new", cwd: "/proj", message: userMsg("new"))

        let latest = await store.latestForCwd("/proj")
        let info = try #require(latest)
        #expect(info.id == "new")

        // Trailing-slash normalization.
        let latestSlash = await store.latestForCwd("/proj/")
        #expect(latestSlash?.id == "new")

        // No match → nil.
        let none = await store.latestForCwd("/does/not/exist")
        #expect(none == nil)
    }

    @Test("appendMeta updates latest metadata on load")
    func metaUpdate() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-meta"
        try await store.append(id: id, cwd: "/w", message: userMsg("hi"),
                               model: "m1", provider: "p1")
        try await store.appendMeta(id: id, model: "m2", thinkingLevel: "high")

        let loaded = try await store.load(id: id)
        #expect(loaded.model == "m2")
        #expect(loaded.provider == "p1")
        #expect(loaded.thinkingLevel == "high")
        // Meta entries do not count as transcript messages.
        #expect(loaded.messages.count == 1)
    }

    @Test("resolveResume(.latestForCwd) seeds the stored transcript")
    func resolveResumeLatest() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.append(id: "s1", cwd: "/proj", message: userMsg("hello"),
                               model: "m1", provider: "p1")
        try await store.append(id: "s1", cwd: "/proj", message: assistantMsg("world"))

        let resolved = await store.resolveResume(.latestForCwd, cwd: "/proj")
        #expect(resolved.resumed)
        #expect(resolved.sessionId == "s1")
        #expect(resolved.messages.count == 2)
        #expect(resolved.persistedCount == 2)
        #expect(resolved.model == "m1")
    }

    @Test("resolveResume(.none) mints a fresh empty session")
    func resolveResumeNone() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = await store.resolveResume(.none, cwd: "/proj", freshId: "fresh-1")
        #expect(!resolved.resumed)
        #expect(resolved.sessionId == "fresh-1")
        #expect(resolved.messages.isEmpty)
        #expect(resolved.persistedCount == 0)
    }

    @Test("SessionRecorder appends only the new transcript tail")
    func recorderAppendsTail() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rec"
        let recorder = SessionRecorder(
            store: store, sessionId: id, cwd: "/w",
            model: "m1", provider: "p1"
        )
        await recorder.ensureCreated()

        await recorder.flush(messages: [userMsg("a")])
        await recorder.flush(messages: [userMsg("a"), assistantMsg("b")])
        // Re-flushing the same prefix is a no-op (no duplicate writes).
        await recorder.flush(messages: [userMsg("a"), assistantMsg("b")])

        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 2)
    }
}
