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

    @Test("default store is disabled and does not touch disk")
    func defaultStoreDisabled() async throws {
        let store = SessionStore()
        #expect(await store.isPersistent == false)
        #expect(await store.list().isEmpty)
        await #expect(throws: SessionStore.SessionStoreError.self) {
            _ = try await store.create(id: "disabled", cwd: "/tmp")
        }
    }

    private func text(from message: Message?) -> String {
        switch message {
        case .user(let user):
            return user.content.compactMap { block in
                guard case .text(let text) = block else { return nil }
                return text.text
            }.joined(separator: "\n")
        case .assistant(let assistant):
            return assistant.content.compactMap { block in
                guard case .text(let text) = block else { return nil }
                return text.text
            }.joined(separator: "\n")
        case .toolResult(let result):
            return result.content.compactMap { block in
                guard case .text(let text) = block else { return nil }
                return text.text
            }.joined(separator: "\n")
        case nil:
            return ""
        }
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

        let resolved = try await store.resolveResume(.id(id), cwd: "/w", freshId: "fresh-session")
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

    @Test("setTitle persists a session title that load and list surface")
    func titleRoundTrip() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-title"
        try await store.append(id: id, cwd: "/w", message: userMsg("hi"))
        try await store.setTitle(id: id, cwd: "/w", title: "My feature work")
        // A later title wins (append-only, latest meta entry).
        try await store.setTitle(id: id, cwd: "/w", title: "Renamed")

        let loaded = try await store.load(id: id)
        #expect(loaded.title == "Renamed")
        // Title meta entries are not transcript messages.
        #expect(loaded.messages.count == 1)

        let info = await store.list().first { $0.id == id }
        #expect(info?.title == "Renamed")
    }

    @Test("load projects the latest compaction entry as resumable context")
    func loadProjectsCompaction() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-compact"
        let cwd = "/w"
        let before = [
            userMsg("one"),
            assistantMsg("two"),
            toolResultMsg("three"),
        ]
        for message in before {
            try await store.append(id: id, cwd: cwd, message: message)
        }

        let summary = userMsg(
            "<previous-session-summary>one through three</previous-session-summary>")
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [summary],
            messagesCompacted: before.count,
            tokensBefore: 123,
            contextWindow: 456
        )

        let after = userMsg("after compact")
        try await store.append(id: id, cwd: cwd, message: after)

        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [summary, after])
        #expect(loaded.transcriptMessages == before + [after])
        #expect(loaded.persistedContextCount == 2)

        let raw = try String(contentsOf: dir.appendingPathComponent("\(id).jsonl"), encoding: .utf8)
        #expect(raw.contains(#""type":"compaction""#))
        #expect(raw.contains(#""tokensBefore":123"#))
    }

    @Test("repeated compactions project from the newest marker")
    func repeatedCompactionsUseNewestProjection() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-repeat-compact"
        let cwd = "/w"
        let a = userMsg("a")
        let b = assistantMsg("b")
        try await store.append(id: id, cwd: cwd, messages: [a, b])

        let firstSummary = userMsg("summary a-b")
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [firstSummary],
            messagesCompacted: 2
        )

        let c = userMsg("c")
        try await store.append(id: id, cwd: cwd, message: c)

        let secondSummary = userMsg("summary compacted-plus-c")
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [secondSummary],
            messagesCompacted: 2
        )

        let d = assistantMsg("d")
        try await store.append(id: id, cwd: cwd, message: d)

        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [secondSummary, d])
        #expect(loaded.transcriptMessages == [a, b, c, d])
        #expect(loaded.persistedContextCount == 2)
    }

    @Test("resolveResume(.latestForCwd) seeds the stored transcript")
    func resolveResumeLatest() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.append(id: "s1", cwd: "/proj", message: userMsg("hello"),
                               model: "m1", provider: "p1")
        try await store.append(id: "s1", cwd: "/proj", message: assistantMsg("world"))

        let resolved = try await store.resolveResume(.latestForCwd, cwd: "/proj")
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

        let resolved = try await store.resolveResume(.none, cwd: "/proj", freshId: "fresh-1")
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

    @Test("SessionRecorder resets its append baseline after compaction")
    func recorderAppendsImmediatelyAfterCompaction() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rec-compact"
        let recorder = SessionRecorder(
            store: store, sessionId: id, cwd: "/w",
            model: "m1", provider: "p1"
        )
        await recorder.ensureCreated()

        let before = [
            userMsg("a"),
            assistantMsg("b"),
            userMsg("c"),
            assistantMsg("d"),
        ]
        await recorder.flush(messages: before)

        let summary = userMsg("<previous-session-summary>a-d</previous-session-summary>")
        await recorder.recordCompaction(
            messages: [summary],
            messagesCompacted: before.count,
            tokensBefore: 99,
            contextWindow: 1000
        )

        let after = userMsg("post-compact")
        await recorder.flush(messages: [summary, after])

        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [summary, after])
        #expect(loaded.transcriptMessages == before + [after])
        #expect(loaded.persistedContextCount == 2)

        let raw = try String(contentsOf: dir.appendingPathComponent("\(id).jsonl"), encoding: .utf8)
        #expect(raw.contains(#""contextWindow":1000"#))
        #expect(raw.contains(#""tokensBefore":99"#))
    }

    @Test("SessionRecorder persists compactEnd events from an agent")
    func recorderPersistsAgentCompactEnd() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let faux = await registerFauxProvider(
            RegisterFauxProviderOptions(models: [
                FauxModelDefinition(id: "compact-recorder-window", contextWindow: 5)
            ]))
        defer { faux.unregister() }

        let model = faux.getModel()
        let highUsage = AssistantMessage(
            content: [.text(TextContent(text: "large answer"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 80, output: 1)
        )
        faux.setResponses([
            .message(highUsage),
            .message(fauxAssistantMessage("event summary")),
        ])

        let agent = Agent(
            options: AgentOptions(
                initialState: AgentInitialState(
                    model: model,
                    messages: [userMsg("seed"), assistantMsg("reply")]
                ),
                autoCompact: AgentAutoCompactOptions(
                    threshold: 0.1,
                    config: AgentContextCompactionConfig(minMessages: 1)
                )
            ))

        let id = "sess-agent-compact"
        let recorder = SessionRecorder(
            store: store,
            sessionId: id,
            cwd: "/w",
            model: model.id,
            provider: model.provider
        )
        await recorder.ensureCreated()
        let unsubscribe = recorder.attach(to: agent)
        defer { unsubscribe() }

        try await agent.prompt("trigger compaction")

        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 1)
        #expect(text(from: loaded.messages.first).contains("event summary"))
        #expect(loaded.transcriptMessages.count > loaded.messages.count)
        #expect(loaded.persistedContextCount == 1)

        let resolved = try await store.resolveResume(.id(id), cwd: "/w", freshId: "fresh")
        #expect(resolved.resumed)
        #expect(resolved.messages == loaded.messages)
        #expect(resolved.persistedCount == loaded.persistedContextCount)

        let raw = try String(contentsOf: dir.appendingPathComponent("\(id).jsonl"), encoding: .utf8)
        #expect(raw.contains(#""type":"compaction""#))
        #expect(raw.contains(#""contextWindow":5"#))
        #expect(raw.contains(#""tokensBefore":"#))
    }
}
