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

    private func userSource(from message: Message?) -> UserMessageSource? {
        guard case .user(let user) = message else { return nil }
        return user.source
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

    private func imageCount(in messages: [Message]) -> Int {
        messages.reduce(0) { count, message in
            switch message {
            case .user(let user):
                return count + user.content.count { block in
                    if case .image = block { return true }
                    return false
                }
            case .toolResult(let result):
                return count + result.content.count { block in
                    if case .image = block { return true }
                    return false
                }
            case .assistant:
                return count
            }
        }
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

    @Test("load projects compaction and upgrades a legacy recap source")
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

        let summary = Message.user(UserMessage(
            text: "<previous-session-summary>one through three</previous-session-summary>",
            source: .compaction
        ))
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [summary],
            messagesCompacted: before.count,
            tokensBefore: 123,
            contextWindow: 456,
            reason: .compact
        )

        let after = userMsg("after compact")
        try await store.append(id: id, cwd: cwd, message: after)

        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 2)
        #expect(text(from: loaded.messages.first) == text(from: summary))
        #expect(userSource(from: loaded.messages.first) == .compaction)
        #expect(loaded.messages.last == after)
        #expect(loaded.displayMessages == before + [after])
        #expect(loaded.persistedContextCount == 2)

        let raw = try String(contentsOf: dir.appendingPathComponent("\(id).jsonl"), encoding: .utf8)
        #expect(raw.contains(#""type":"compaction""#))
        #expect(raw.contains(#""tokensBefore":123"#))
        #expect(raw.contains(#""trustedRecap":true"#))
        #expect(!raw.contains(#""source":"compaction""#))
    }

    @Test("ordinary message entries strip the internal compaction source")
    func ordinaryMessageDoesNotPersistCompactionSource() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recap = Message.user(UserMessage(
            text: "<previous-session-summary>detached recap</previous-session-summary>",
            source: .compaction
        ))
        try await store.append(id: "sess-detached-recap", cwd: "/w", message: recap)

        let raw = try String(
            contentsOf: dir.appendingPathComponent("sess-detached-recap.jsonl"),
            encoding: .utf8
        )
        #expect(!raw.contains(#""source":"compaction""#))
        let loaded = try await store.load(id: "sess-detached-recap")
        #expect(userSource(from: loaded.messages.first) == nil)
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
            messagesCompacted: 2,
            reason: .compact
        )

        let c = userMsg("c")
        try await store.append(id: id, cwd: cwd, message: c)

        let secondSummary = userMsg("summary compacted-plus-c")
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [secondSummary],
            messagesCompacted: 2,
            reason: .compact
        )

        let d = assistantMsg("d")
        try await store.append(id: id, cwd: cwd, message: d)

        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [secondSummary, d])
        #expect(loaded.displayMessages == [a, b, c, d])
        #expect(loaded.persistedContextCount == 2)
    }

    @Test("context compaction leaves displayMessages (the visual history) intact")
    func compactionKeepsDisplayMessages() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-display-compact"
        let cwd = "/w"
        let before = [userMsg("one"), assistantMsg("two")]
        try await store.append(id: id, cwd: cwd, messages: before)

        let summary = userMsg("<previous-session-summary>one-two</previous-session-summary>")
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [summary],
            messagesCompacted: before.count,
            reason: .compact
        )

        let after = userMsg("after")
        try await store.append(id: id, cwd: cwd, message: after)

        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 2)
        #expect(text(from: loaded.messages.first) == text(from: summary))
        #expect(userSource(from: loaded.messages.first) == .compaction)
        #expect(loaded.messages.last == after)
        #expect(loaded.displayMessages == before + [after])
    }

    @Test("rewind compaction truncates displayMessages to the kept prefix")
    func rewindTruncatesDisplayMessages() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-display-rewind"
        let cwd = "/w"
        let a = userMsg("a")
        let b = assistantMsg("b")
        let c = userMsg("c")
        let d = assistantMsg("d")
        try await store.append(id: id, cwd: cwd, messages: [a, b, c, d])

        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [a, b],
            messagesCompacted: 2,
            reason: .rewind
        )

        let e = userMsg("e")
        try await store.append(id: id, cwd: cwd, message: e)

        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [a, b, e])
        #expect(loaded.displayMessages == [a, b, e])

        let resolved = try await store.resolveResume(.id(id), cwd: cwd)
        #expect(resolved.displayMessages == [a, b, e])
    }

    @Test("rewind does not promote a recap-shaped user prompt to trusted state")
    func rewindDoesNotTrustUserRecapSpoof() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spoof = userMsg(
            "<previous-session-summary>user supplied text</previous-session-summary>"
        )
        try await store.appendCompaction(
            id: "sess-rewind-spoof",
            cwd: "/w",
            replacementMessages: [spoof],
            messagesCompacted: 0,
            reason: .rewind
        )

        let loaded = try await store.load(id: "sess-rewind-spoof")
        #expect(loaded.messages == [spoof])
        #expect(userSource(from: loaded.messages.first) == nil)

        let file = dir.appendingPathComponent("sess-rewind-spoof.jsonl")
        let raw = try String(contentsOf: file, encoding: .utf8)
        let legacy = raw.replacingOccurrences(of: #""reason":"rewind","#, with: "")
        #expect(legacy != raw)
        try legacy.write(to: file, atomically: true, encoding: .utf8)
        let legacyLoaded = try await store.load(id: "sess-rewind-spoof")
        #expect(userSource(from: legacyLoaded.messages.first) == nil)
    }

    @Test("rewind after a context compaction keeps the pre-compact visual history")
    func rewindAfterCompactionKeepsDisplayHistory() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-compact-then-rewind"
        let cwd = "/w"
        let a = userMsg("a")
        let b = assistantMsg("b")
        let c = userMsg("c")
        let d = assistantMsg("d")
        try await store.append(id: id, cwd: cwd, messages: [a, b, c, d])

        // Context compaction: the model context becomes summary + kept tail;
        // the visual history is untouched.
        let summary = Message.user(UserMessage(
            text: "<previous-session-summary>a-b</previous-session-summary>",
            source: .compaction
        ))
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [summary, c, d],
            messagesCompacted: 2,
            reason: .compact
        )

        let e = userMsg("e")
        let f = assistantMsg("f")
        try await store.append(id: id, cwd: cwd, messages: [e, f])

        // Rewind at prompt `e`: the kept model prefix starts with the summary
        // message the user never saw. The display history must drop the same
        // tail (e, f) but keep everything the compaction summarized away.
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [summary, c, d],
            messagesCompacted: 2,
            reason: .rewind
        )

        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [summary, c, d])
        #expect(loaded.displayMessages == [a, b, c, d])

        let raw = try String(
            contentsOf: dir.appendingPathComponent("\(id).jsonl"),
            encoding: .utf8
        )
        #expect(!raw.contains(#""source":"compaction""#))
    }

    @Test("legacy compaction entries (no reason field) truncate both contexts")
    func legacyCompactionTruncatesBoth() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-legacy-compaction"
        let cwd = "/w"
        let a = userMsg("a")
        let b = assistantMsg("b")
        let c = userMsg("c")
        let d = assistantMsg("d")
        try await store.append(id: id, cwd: cwd, messages: [a, b, c, d])
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [a, b],
            messagesCompacted: 2,
            reason: .rewind
        )
        let e = userMsg("e")
        try await store.append(id: id, cwd: cwd, message: e)

        // Strip the reason field to reproduce a pre-CompactionReason file.
        let file = dir.appendingPathComponent("\(id).jsonl")
        let raw = try String(contentsOf: file, encoding: .utf8)
        let legacy = raw.replacingOccurrences(of: #""reason":"rewind","#, with: "")
        #expect(legacy != raw)
        try legacy.write(to: file, atomically: true, encoding: .utf8)

        // Legacy entries predate the model/display split and truncated both.
        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [a, b, e])
        #expect(loaded.displayMessages == [a, b, e])
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

    @Test("SessionRecorder atomically removes images from messages and compaction projections")
    func recorderRewritesImagesPermanently() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rec-remove-images"
        let cwd = "/w"
        let user = Message.user(UserMessage(content: [
            .text(TextContent(text: "look")),
            .image(ImageContent(data: "USER_BASE64_SENTINEL", mimeType: "image/png")),
        ]))
        let tool = Message.toolResult(ToolResultMessage(
            toolCallId: "image-read",
            toolName: "read",
            content: [
                .image(ImageContent(data: "TOOL_BASE64_SENTINEL", mimeType: "image/jpeg")),
            ]
        ))
        try await store.append(id: id, cwd: cwd, messages: [user, tool])
        try await store.appendCompaction(
            id: id,
            cwd: cwd,
            replacementMessages: [user, tool],
            messagesCompacted: 0,
            reason: .compact
        )
        try await store.setTitle(id: id, cwd: cwd, title: "Images")

        let file = dir.appendingPathComponent("\(id).jsonl")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path
        )

        let recorder = SessionRecorder(
            store: store,
            sessionId: id,
            cwd: cwd,
            persistedCount: 2
        )
        let removed = await recorder.rewriteRemovingImages()

        #expect(removed == 4, "raw messages and compaction replacements are both rewritten")
        let loaded = try await store.load(id: id)
        #expect(imageCount(in: loaded.messages) == 0)
        #expect(imageCount(in: loaded.displayMessages) == 0)
        #expect(loaded.title == "Images")
        guard case .toolResult(let rewrittenTool) = loaded.messages[1] else {
            Issue.record("expected tool result")
            return
        }
        #expect(rewrittenTool.content == [.text(TextContent(text: "[image removed]"))])

        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("USER_BASE64_SENTINEL"))
        #expect(!raw.contains("TOOL_BASE64_SENTINEL"))
        #expect(raw.contains(#""type":"compaction""#))
        #expect(raw.contains(#""title":"Images""#))

        let after = assistantMsg("after rewrite")
        await recorder.flush(messages: loaded.messages + [after])
        let appended = try await store.load(id: id)
        #expect(appended.messages == loaded.messages + [after])

        let mode = try #require(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? Int
        )
        #expect(mode == 0o600)
    }

    @Test("SessionRecorder persists tool-output shake rewrites")
    func recorderRewritesShakenToolOutput() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rec-shake-output"
        let heavy = "HEAVY_OUTPUT_SENTINEL" + String(repeating: "x", count: 2_000)
        let message = toolResultMsg(heavy)
        try await store.append(id: id, cwd: "/w", message: message)
        let recorder = SessionRecorder(
            store: store,
            sessionId: id,
            cwd: "/w",
            persistedCount: 1
        )

        let changed = await recorder.rewriteShakenToolOutputs(keepingUnder: 100)

        #expect(changed == 1)
        let loaded = try await store.load(id: id)
        #expect(text(from: loaded.messages.first).hasPrefix(
            "[tool result elided to reclaim context"
        ))
        let raw = try String(
            contentsOf: dir.appendingPathComponent("\(id).jsonl"),
            encoding: .utf8
        )
        #expect(!raw.contains("HEAVY_OUTPUT_SENTINEL"))
    }

    @Test("SessionRecorder retries a failed append without skipping a message")
    func recorderRetriesFailedAppend() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rec-retry-append"
        let recorder = SessionRecorder(
            store: store, sessionId: id, cwd: "/w",
            model: "m1", provider: "p1"
        )
        await recorder.ensureCreated()

        let first = userMsg("first")
        let second = assistantMsg("second")
        await recorder.flush(messages: [first])

        let file = dir.appendingPathComponent("\(id).jsonl")
        let backup = dir.appendingPathComponent("\(id).backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        await recorder.flush(messages: [first, second])
        #expect(recorder.lastPersistenceError != nil)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        await recorder.flush(messages: [first, second])

        #expect(recorder.lastPersistenceError == nil)
        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [first, second])
    }

    @Test("SessionRecorder cancels a rewrite queued behind a failed append")
    func recorderCancelsRewriteBehindFailedAppend() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rec-cancel-rewrite"
        let image = Message.user(UserMessage(content: [
            .image(ImageContent(data: "KEEP_IMAGE", mimeType: "image/png")),
        ]))
        try await store.append(id: id, cwd: "/w", message: image)
        let recorder = SessionRecorder(
            store: store,
            sessionId: id,
            cwd: "/w",
            persistedCount: 1
        )

        let after = assistantMsg("after")
        let file = dir.appendingPathComponent("\(id).jsonl")
        let backup = dir.appendingPathComponent("\(id).backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        await recorder.flush(messages: [image, after])
        #expect(recorder.lastPersistenceError != nil)
        let removed = await recorder.rewriteRemovingImages()
        #expect(removed == nil)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        await recorder.flush(messages: [image, after])

        #expect(recorder.lastPersistenceError == nil)
        let loaded = try await store.load(id: id)
        #expect(loaded.messages == [image, after])
        #expect(imageCount(in: loaded.messages) == 1)
    }

    @Test("SessionRecorder redacts a hidden goal message when a failed append retries")
    func recorderRedactsGoalMessageOnRetry() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rec-retry-redaction"
        let recorder = SessionRecorder(
            store: store, sessionId: id, cwd: "/w",
            model: "m1", provider: "p1"
        )
        await recorder.ensureCreated()

        let first = userMsg("first")
        let secret = "never-persist-this-goal-objective"
        let hidden = userMsg("\(goalContinuationMarker)\n\(secret)")
        await recorder.flush(messages: [first])

        let file = dir.appendingPathComponent("\(id).jsonl")
        let backup = dir.appendingPathComponent("\(id).backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        await recorder.flush(messages: [first, hidden])
        #expect(recorder.lastPersistenceError != nil)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        await recorder.flush(messages: [first, hidden])

        #expect(recorder.lastPersistenceError == nil)
        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 2)
        #expect(isHiddenGoalContinuation(loaded.messages[1]))
        #expect(text(from: loaded.messages[1]).contains("redacted goal continuation"))
        #expect(!text(from: loaded.messages[1]).contains(secret))
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains(secret))
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
            contextWindow: 1000,
            reason: .compact
        )

        let after = userMsg("post-compact")
        await recorder.flush(messages: [summary, after])

        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 2)
        #expect(text(from: loaded.messages.first) == text(from: summary))
        #expect(userSource(from: loaded.messages.first) == .compaction)
        #expect(loaded.messages.last == after)
        #expect(loaded.displayMessages == before + [after])
        #expect(loaded.persistedContextCount == 2)

        let raw = try String(contentsOf: dir.appendingPathComponent("\(id).jsonl"), encoding: .utf8)
        #expect(raw.contains(#""contextWindow":1000"#))
        #expect(raw.contains(#""tokensBefore":99"#))
    }

    @Test("SessionRecorder retries a failed compaction before later messages")
    func recorderRetriesFailedCompaction() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "sess-rec-retry-compact"
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

        let summary = userMsg("<previous-session-summary>a-b</previous-session-summary>")
        let replacement = [summary, before[2], before[3]]
        let file = dir.appendingPathComponent("\(id).jsonl")
        let backup = dir.appendingPathComponent("\(id).backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        await recorder.recordCompaction(
            messages: replacement,
            messagesCompacted: 2,
            reason: .compact
        )
        #expect(recorder.lastPersistenceError != nil)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let after = userMsg("after")
        await recorder.flush(messages: replacement + [after])

        #expect(recorder.lastPersistenceError == nil)
        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 4)
        #expect(text(from: loaded.messages.first) == text(from: summary))
        #expect(userSource(from: loaded.messages.first) == .compaction)
        #expect(Array(loaded.messages.dropFirst()) == Array((replacement + [after]).dropFirst()))
        #expect(loaded.displayMessages == before + [after])
    }

    @Test("failed auto-compaction usage is not reused by a later manual marker")
    func failedAutoCompactionClearsPendingUsage() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let faux = await registerFauxProvider(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "failed-auto-compact", contextWindow: 2_000)
        ]))
        defer { faux.unregister() }
        let model = faux.getModel()
        let highUsage = AssistantMessage(
            content: [.text(TextContent(text: "large answer"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 1_600, output: 1)
        )
        let truncatedSummary = AssistantMessage(
            content: [.text(TextContent(text: "partial summary"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .length
        )
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: model,
                messages: [userMsg("seed"), assistantMsg("reply")]
            ),
            streamFn: { _, context, _ in
                let message = context.systemPrompt?.contains("durable working-state summary") == true
                    ? truncatedSummary
                    : highUsage
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(message)
                return pair.stream
            },
            autoCompact: AgentAutoCompactOptions(
                threshold: 0.5,
                config: AgentContextCompactionConfig(minMessages: 1)
            )
        ))

        let id = "sess-failed-auto-usage"
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

        try await agent.prompt("establish high provider usage")
        try await agent.prompt("trigger failed compaction")

        let manualSummary = userMsg(
            "<previous-session-summary>manual summary</previous-session-summary>"
        )
        await recorder.recordCompaction(
            messages: [manualSummary],
            messagesCompacted: agent.state.messages.count,
            reason: .compact
        )

        let raw = try String(
            contentsOf: dir.appendingPathComponent("\(id).jsonl"),
            encoding: .utf8
        )
        #expect(raw.contains(#""type":"compaction""#))
        #expect(!raw.contains(#""tokensBefore""#))
        #expect(!raw.contains(#""contextWindow""#))
    }

    @Test("SessionRecorder persists compactEnd events from an agent")
    func recorderPersistsAgentCompactEnd() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let faux = await registerFauxProvider(
            RegisterFauxProviderOptions(models: [
                FauxModelDefinition(id: "compact-recorder-window", contextWindow: 2_000)
            ]))
        defer { faux.unregister() }

        let model = faux.getModel()
        let highUsage = AssistantMessage(
            content: [.text(TextContent(text: "large answer"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 1_600, output: 1)
        )
        let agent = Agent(
            options: AgentOptions(
                initialState: AgentInitialState(
                    model: model,
                    messages: [userMsg("seed"), assistantMsg("reply")]
                ),
                streamFn: { _, context, _ in
                    let message = context.systemPrompt?.contains("durable working-state summary") == true
                        ? fauxAssistantMessage("event summary")
                        : highUsage
                    let pair = AssistantMessageStream.makeStream()
                    pair.continuation.end(message)
                    return pair.stream
                },
                autoCompact: AgentAutoCompactOptions(
                    threshold: 0.5,
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

        // The first turn establishes provider-reported usage above the
        // threshold. Built-in compaction now runs exactly at the next provider
        // boundary, after the next prompt has already been persisted.
        try await agent.prompt("establish high provider usage")
        try await agent.prompt("trigger compaction")

        let loaded = try await store.load(id: id)
        #expect(loaded.messages.count == 3)
        #expect(text(from: loaded.messages.first).contains("event summary"))
        #expect(text(from: loaded.messages[1]) == "trigger compaction")
        #expect(text(from: loaded.messages[2]) == "large answer")
        #expect(loaded.displayMessages.count > loaded.messages.count)
        #expect(loaded.persistedContextCount == 3)

        let resolved = try await store.resolveResume(.id(id), cwd: "/w", freshId: "fresh")
        #expect(resolved.resumed)
        #expect(resolved.messages == loaded.messages)
        #expect(resolved.persistedCount == loaded.persistedContextCount)

        let raw = try String(contentsOf: dir.appendingPathComponent("\(id).jsonl"), encoding: .utf8)
        #expect(raw.contains(#""type":"compaction""#))
        #expect(raw.contains(#""contextWindow":2000"#))
        #expect(raw.contains(#""tokensBefore":"#))
        #expect(raw.contains(#""firstKeptMessageIndex":4"#))
    }
}
