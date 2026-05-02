import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

/// These tests lock in the commit/live split that TranscriptRenderer
/// adopted so the TUI can stream "settled" lines into native terminal
/// scrollback. Changes to settlement semantics (when something moves
/// from live → committed) should fail here first.

@Suite("TranscriptRenderer commit/live split")
struct TranscriptCommitTests {

    private func stubAssistant(_ text: String, stop: StopReason = .stop) -> AssistantMessage {
        AssistantMessage(
            content: text.isEmpty ? [] : [.text(TextContent(text: text))],
            api: "faux",
            provider: "faux",
            model: "faux",
            stopReason: stop
        )
    }

    private func toolResult(_ text: String) -> AgentToolResult {
        AgentToolResult(content: [.text(TextContent(text: text))])
    }

    @MainActor
    @Test("user message commits immediately with leading blank + prompt marker")
    func userCommitsImmediately() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .user(UserMessage(text: "hi"))))

        let commits = r.drainCommits()
        // Leading blank then the ❯ prompt — and nothing live. Matches
        // the "every scrollback block opens with a blank, never closes
        // with one" convention.
        #expect(commits.count == 2)
        #expect(commits[0] == "")
        #expect(commits[1].contains("❯ hi"))
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("assistant streaming stays live; commit fires on messageEnd")
    func assistantSettlesOnEnd() {
        let r = TranscriptRenderer()

        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("hello")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "hello", partial: partial)
        ))

        // Mid-stream: still in the live zone, nothing committed yet.
        #expect(r.drainCommits().isEmpty)
        #expect(r.liveLines.contains(where: { $0.contains("hello") }))

        // On end: body moves to the commit buffer with a leading blank
        // (no trailing one), live goes empty.
        r.apply(.messageEnd(message: .assistant(stubAssistant("hello"))))
        let commits = r.drainCommits()
        #expect(commits.first == "")
        #expect(commits.contains(where: { $0.contains("hello") }))
        #expect(commits.last != "")
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("aborted turn appends '⋯ aborted' then commits")
    func abortedTurnCommitsWithMarker() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        r.apply(.messageEnd(message: .assistant(stubAssistant("partial", stop: .aborted))))

        let commits = r.drainCommits()
        #expect(commits.contains(where: { $0.contains("partial") }))
        #expect(commits.contains(where: { $0.contains("aborted") }))
    }

    @MainActor
    @Test("streamRetry commits a dimmed retry line immediately")
    func streamRetryCommits() {
        let r = TranscriptRenderer()
        r.apply(.streamRetry(attempt: 0, delayMs: 1000, reason: "HTTP 429: rate limit"))
        let commits = r.drainCommits()
        #expect(commits.count == 1)
        #expect(commits[0].contains("retrying"))
        #expect(commits[0].contains("1s"))
        // The reason is intentionally suppressed in the transcript — users
        // only see the final error if every retry is exhausted.
        #expect(!commits[0].contains("429"))

        // Sub-second delay renders as `Nms` — so short test-time delays
        // don't round down to `0s` and lose their meaning.
        r.apply(.streamRetry(attempt: 1, delayMs: 50, reason: "connection reset"))
        let fast = r.drainCommits()
        #expect(fast.count == 1)
        #expect(fast[0].contains("50ms"))
    }

    @MainActor
    @Test("verbose events queue while assistant output is streaming")
    func verboseQueuesDuringStreaming() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        r.apply(.verbose(VerboseEvent(
            source: "openai.responses.websocket",
            message: "connected",
            metadata: ["input_count": .int(1)]
        )))

        #expect(r.drainCommits().isEmpty)
        #expect(!r.liveLines.contains(where: { $0.contains("connected") }))

        r.apply(.messageEnd(message: .assistant(stubAssistant("hello"))))
        let commits = r.drainCommits()
        let assistantIdx = commits.firstIndex(where: { $0.contains("hello") })
        let verboseIdx = commits.firstIndex(where: { $0.contains("verbose [openai.responses.websocket]: connected") })

        #expect(assistantIdx != nil)
        #expect(verboseIdx != nil)
        if let assistantIdx, let verboseIdx {
            #expect(assistantIdx < verboseIdx)
        }
        #expect(commits.contains(where: { $0.contains("input_count=1") }))
    }

    @MainActor
    @Test("streamRewind drops verbose events queued for the failed attempt")
    func streamRewindDropsQueuedVerbose() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        r.apply(.verbose(VerboseEvent(
            source: "openai.responses.websocket",
            message: "failed attempt log",
            metadata: [:]
        )))

        r.apply(.streamRewind)
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        r.apply(.verbose(VerboseEvent(
            source: "openai.responses.websocket",
            message: "retry attempt log",
            metadata: [:]
        )))
        r.apply(.messageEnd(message: .assistant(stubAssistant("hello"))))

        let commits = r.drainCommits()
        #expect(!commits.contains(where: { $0.contains("failed attempt log") }))
        #expect(commits.contains(where: { $0.contains("retry attempt log") }))
    }

    @MainActor
    @Test("agentEnd flushes queued verbose even if streaming did not close cleanly")
    func agentEndFlushesQueuedVerboseWhileStreaming() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        r.apply(.verbose(VerboseEvent(
            source: "openai.responses.websocket",
            message: "stream teardown log",
            metadata: [:]
        )))

        r.apply(.agentEnd(messages: [], summary: AgentRunSummary()))

        let commits = r.drainCommits()
        #expect(commits.contains(where: { $0.contains("stream teardown log") }))
    }

    @MainActor
    @Test("tool execution commits on end with header + result preview")
    func toolCommitsOnEnd() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(toolCallId: "1", toolName: "bash", args: .object(["cmd": .string("ls")])))

        // Running tool sits in live (leading blank + header + running…),
        // nothing committed yet. The leading blank is the "every block
        // opens with a separator" rule applied to the live view so
        // parallel tools and streaming body don't stack.
        #expect(r.drainCommits().isEmpty)
        #expect(r.liveLines.count >= 3)
        #expect(r.liveLines.first == "")
        #expect(r.liveLines.dropFirst().first?.contains("bash") == true)

        r.apply(.toolExecutionEnd(
            toolCallId: "1",
            toolName: "bash",
            result: toolResult("file1\nfile2"),
            isError: false
        ))
        let commits = r.drainCommits()
        // Leading blank, header, body; no trailing blank.
        #expect(commits.first == "")
        #expect(commits.dropFirst().first?.contains("bash") == true)
        #expect(commits.contains(where: { $0.contains("file1") }))
        #expect(commits.last != "")
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("out-of-order completion preserves start order in the commit stream")
    func outOfOrderCompletionBlocksUntilFrontResolves() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(toolCallId: "a", toolName: "first", args: .object([:])))
        r.apply(.toolExecutionStart(toolCallId: "b", toolName: "second", args: .object([:])))

        // Complete B before A. B cannot commit yet — A is still running
        // in front of it, and committing B first would put it above A
        // in scrollback (wrong visual order).
        r.apply(.toolExecutionEnd(
            toolCallId: "b",
            toolName: "second",
            result: toolResult("B done"),
            isError: false
        ))
        #expect(r.drainCommits().isEmpty,
                "B must wait for A to settle before anything can flush")

        // A completes → A then B flush together, in start order.
        r.apply(.toolExecutionEnd(
            toolCallId: "a",
            toolName: "first",
            result: toolResult("A done"),
            isError: false
        ))
        let commits = r.drainCommits()
        let firstIdx = commits.firstIndex(where: { $0.contains("first") })
        let secondIdx = commits.firstIndex(where: { $0.contains("second") })
        #expect(firstIdx != nil && secondIdx != nil)
        #expect((firstIdx ?? 0) < (secondIdx ?? 0))
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("drainCommits yields each batch exactly once")
    func drainIsIdempotent() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .user(UserMessage(text: "hi"))))

        let first = r.drainCommits()
        #expect(!first.isEmpty)
        let second = r.drainCommits()
        #expect(second.isEmpty, "a second drain before new events should be empty")
    }

    @MainActor
    @Test("streaming body spills overflow into commits while staying live at the tail")
    func streamingSpillsOverflow() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))

        // 20-line streaming body, budget of 5. The assistant block also
        // carries a leading blank (convention), so `full` is 21 rows —
        // overflow 16: the leading blank + line1…line15.
        let body = (1...20).map { "line\($0)" }.joined(separator: "\n")
        let partial = stubAssistant(body)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: body, partial: partial)
        ))
        r.applyLiveBudget(5, reserved: 0)

        let commits = r.drainCommits()
        #expect(commits.count == 16)
        #expect(commits.first == "")
        #expect(commits[1] == "line1")
        #expect(commits.last == "line15")
        #expect(r.liveLines.count == 5)
        #expect(r.liveLines.first == "line16")
        #expect(r.liveLines.last == "line20")

        // Calling spill again with the same budget is a no-op — already
        // fits, so no extra commits leak out.
        r.applyLiveBudget(5, reserved: 0)
        #expect(r.drainCommits().isEmpty)
    }

    @MainActor
    @Test("successive messageUpdates + spills don't re-commit the same lines")
    func successiveSpillsDoNotDuplicate() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))

        // Simulate the streaming stream arriving in two chunks. Each
        // chunk is the FULL accumulated body so far (that's what
        // renderAssistantLines produces). After each chunk we apply the
        // same budget.
        let chunk1 = (1...15).map { "line\($0)" }.joined(separator: "\n")
        let m1 = stubAssistant(chunk1)
        r.apply(.messageUpdate(
            message: m1,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: chunk1, partial: m1)
        ))
        r.applyLiveBudget(5, reserved: 0)
        let firstCommits = r.drainCommits()
        // First spill carries the leading blank + lines 1-10 (11 rows).
        #expect(firstCommits == [""] + (1...10).map { "line\($0)" })

        let chunk2 = (1...20).map { "line\($0)" }.joined(separator: "\n")
        let m2 = stubAssistant(chunk2)
        r.apply(.messageUpdate(
            message: m2,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "\nline16\nline17\nline18\nline19\nline20", partial: m2)
        ))
        r.applyLiveBudget(5, reserved: 0)
        let secondCommits = r.drainCommits()
        // Only the NEW overflow (lines 11-15) should spill now. The
        // leading blank + lines 1-10 must NOT show up again in scrollback.
        #expect(secondCommits == (11...15).map { "line\($0)" },
                "regression: the already-spilled prefix must not re-commit on every update")
        #expect(r.liveLines.count == 5)
        #expect(r.liveLines.first == "line16")
        #expect(r.liveLines.last == "line20")

        // messageEnd should commit just the remaining tail (lines 16-20).
        // No trailing blank under the new convention.
        r.apply(.messageEnd(message: .assistant(stubAssistant(chunk2))))
        let endCommits = r.drainCommits()
        let expected = (16...20).map { "line\($0)" }
        #expect(endCommits == expected)
    }

    @MainActor
    @Test("streaming spill reserves room for the caller (e.g. notifications)")
    func streamingSpillRespectsReserved() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let body = (1...10).map { "line\($0)" }.joined(separator: "\n")
        let partial = stubAssistant(body)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: body, partial: partial)
        ))
        // Budget 8, caller reserves 3 rows → streaming budget = 5.
        // Body has leading blank + 10 lines = 11 rows; overflow = 6.
        r.applyLiveBudget(8, reserved: 3)
        #expect(r.liveLines.count == 5)
        let commits = r.drainCommits()
        #expect(commits.count == 6)
        #expect(commits.first == "")
        #expect(commits.last == "line5")
    }

    @MainActor
    @Test("<attachments> XML block is stripped from the committed user line")
    func attachmentsBlockHiddenFromTranscript() {
        let r = TranscriptRenderer()
        let body = "look at this <attachments>\n<file path=\"a.txt\">x</file>\n</attachments>"
        r.apply(.messageStart(message: .user(UserMessage(text: body))))
        let commits = r.drainCommits()
        let joined = commits.joined(separator: "\n")
        #expect(joined.contains("look at this"))
        #expect(!joined.contains("<attachments>"))
        #expect(!joined.contains("<file path"))
    }
}

@Suite("TUI.commit writes above the live zone")
struct TUICommitTests {

    @Test("pending commits emit committed text before the live zone")
    func commitsRenderBeforeLive() async {
        let terminal = VirtualTerminal(width: 40, height: 20)
        let tui = TUI(terminal: terminal)
        let live = TestLinesComponent(["LIVE"])
        tui.addChild(live)
        tui.start()
        await terminal.waitForRender()
        // Clear the initial render's output so we measure just the
        // commit-driven frame.
        terminal.clearWrites()

        tui.commit(["COMMITTED A", "COMMITTED B"])
        tui.requestRender()
        await terminal.waitForRender()

        // A, then B, then LIVE — the committed → live ordering.
        let writes = terminal.getWrites()
        let aIdx = writes.range(of: "COMMITTED A")?.lowerBound
        let bIdx = writes.range(of: "COMMITTED B")?.lowerBound
        let lIdx = writes.range(of: "LIVE")?.lowerBound
        #expect(aIdx != nil && bIdx != nil && lIdx != nil)
        if let aIdx, let bIdx, let lIdx {
            #expect(aIdx < bIdx)
            #expect(bIdx < lIdx)
        }
        tui.stop()
    }

    @Test("commit buffer drains after render and does not repeat next frame")
    func commitsDrainOnce() async {
        let terminal = VirtualTerminal(width: 40, height: 20)
        let tui = TUI(terminal: terminal)
        let live = TestLinesComponent(["LIVE"])
        tui.addChild(live)
        tui.start()
        tui.commit(["ONCE"])
        tui.requestRender()
        await terminal.waitForRender()

        terminal.clearWrites()

        // Second render with no new commits — "ONCE" must NOT appear
        // in the write stream again.
        tui.requestRender()
        await terminal.waitForRender()
        let writes2 = terminal.getWrites()
        #expect(!writes2.contains("ONCE"))
        tui.stop()
    }

    @Test("mid-session commit lands above the previously-drawn live zone")
    func commitMidSessionReanchorsLive() async {
        let terminal = VirtualTerminal(width: 40, height: 20)
        let tui = TUI(terminal: terminal)
        let live = TestLinesComponent(["LIVE-V1"])
        tui.addChild(live)
        tui.start()
        tui.requestRender()
        await terminal.waitForRender()

        terminal.clearWrites()

        live.lines = ["LIVE-V2"]
        tui.commit(["HISTORY-ITEM"])
        tui.requestRender()
        await terminal.waitForRender()

        // After the render, stdout should contain the committed line
        // BEFORE the new live text — so LIVE-V2 is anchored below the
        // newly-printed history item.
        let writes = terminal.getWrites()
        let hIdx = writes.range(of: "HISTORY-ITEM")?.lowerBound
        let vIdx = writes.range(of: "LIVE-V2")?.lowerBound
        #expect(hIdx != nil && vIdx != nil)
        if let hIdx, let vIdx {
            #expect(hIdx < vIdx)
        }
        tui.stop()
    }
}
