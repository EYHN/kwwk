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

    private func stubAssistant(blocks: [AssistantBlock], stop: StopReason = .stop) -> AssistantMessage {
        AssistantMessage(
            content: blocks,
            api: "faux",
            provider: "faux",
            model: "faux",
            stopReason: stop
        )
    }

    private func toolResult(_ text: String) -> AgentToolResult {
        AgentToolResult(content: [.text(TextContent(text: text))])
    }

    private func toolDisplay(_ text: String) -> AgentToolResult {
        AgentToolResult(
            content: [.text(TextContent(text: text))],
            uiDisplay: [text]
        )
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
        // User message renders as a full-width bar: ❯ glyph then the text,
        // separated by SGR runs. Assert on the stripped plain text.
        let bar = ANSI.stripEscapes(commits[1])
        #expect(bar.hasPrefix("❯ hi"))
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("assistant partial text streams live and commits on messageEnd")
    func assistantPartialTextStreamsLive() {
        let r = TranscriptRenderer()

        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("hello")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "hello", partial: partial)
        ))

        // Mid-stream without a stable segment boundary: nothing is committed,
        // but the token tail is visible in the live zone — with the same
        // leading blank its committed form will carry.
        #expect(r.drainCommits().isEmpty)
        #expect(r.liveLines == ["", "hello"])

        // On end: the buffered tail moves to the commit buffer with a leading
        // blank (no trailing one), live empties.
        r.apply(.messageEnd(message: .assistant(stubAssistant("hello"))))
        let commits = r.drainCommits()
        #expect(commits == ["", "hello"])
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("live tail after a committed line carries no extra leading blank")
    func liveTailAfterCommittedLineHasNoBlank() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("line1\nline2")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "line1\nline2", partial: partial)
        ))

        // "line1" settled into scrollback; the tail "line2" continues the
        // same block, so live shows it without another separator row.
        #expect(r.drainCommits() == ["", "line1"])
        #expect(r.liveLines == ["line2"])
    }

    @MainActor
    @Test("streamRewind clears the live tail")
    func streamRewindClearsLiveTail() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("doomed tail")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "doomed tail", partial: partial)
        ))
        #expect(r.liveLines.contains(where: { $0.contains("doomed tail") }))

        r.apply(.streamRewind)
        #expect(!r.liveLines.contains(where: { $0.contains("doomed tail") }))
        #expect(r.drainCommits().isEmpty, "an uncommitted tail leaves no trace after rewind")
    }

    @MainActor
    @Test("assistant streaming commits complete hard lines")
    func assistantStreamingCommitsCompleteHardLines() {
        let r = TranscriptRenderer()

        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("line1\nline2")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "line1\nline2", partial: partial)
        ))

        #expect(r.drainCommits() == ["", "line1"])
        // The unsettled tail stays visible in the live zone until it commits.
        #expect(r.liveLines == ["line2"])

        r.apply(.messageEnd(message: .assistant(stubAssistant("line1\nline2"))))
        #expect(r.drainCommits() == ["line2"])
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("assistant segment commits do not duplicate across updates")
    func assistantSegmentCommitsDoNotDuplicate() {
        let r = TranscriptRenderer()

        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let first = stubAssistant("line1\nline2")
        r.apply(.messageUpdate(
            message: first,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "line1\nline2", partial: first)
        ))
        #expect(r.drainCommits() == ["", "line1"])

        let second = stubAssistant("line1\nline2\nline3")
        r.apply(.messageUpdate(
            message: second,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "\nline3", partial: second)
        ))
        #expect(r.drainCommits() == ["line2"])

        r.apply(.messageEnd(message: .assistant(stubAssistant("line1\nline2\nline3"))))
        #expect(r.drainCommits() == ["line3"])
    }

    @MainActor
    @Test("assistant preserves blank separators between text blocks")
    func assistantPreservesBlankSeparatorsBetweenTextBlocks() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))

        let first = stubAssistant(blocks: [.text(TextContent(text: "line1\n"))])
        r.apply(.messageUpdate(
            message: first,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "line1\n", partial: first)
        ))
        #expect(r.drainCommits() == ["", "line1"])

        let second = stubAssistant(blocks: [
            .text(TextContent(text: "line1\n")),
            .text(TextContent(text: "line2"))
        ])
        r.apply(.messageUpdate(
            message: second,
            assistantMessageEvent: .textStart(contentIndex: 1, partial: second)
        ))
        #expect(r.drainCommits() == [""])

        r.apply(.messageEnd(message: .assistant(second)))
        #expect(r.drainCommits() == ["line2"])
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

        // Calling tool sits in live (leading blank + header + calling…),
        // nothing committed yet. The leading blank is the "every block
        // opens with a separator" rule applied to the live view so
        // parallel tools and streaming body don't stack.
        #expect(r.drainCommits().isEmpty)
        #expect(r.liveLines.count >= 3)
        #expect(r.liveLines.first == "")
        #expect(r.liveLines.dropFirst().first?.contains("bash") == true)
        #expect(r.liveLines.contains(where: { $0.contains("calling") }))

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
    @Test("tool execution updates render partial ui display while running")
    func toolExecutionUpdateRendersPartialDisplay() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(toolCallId: "1", toolName: "agent", args: .object([:])))
        r.apply(.toolExecutionUpdate(
            toolCallId: "1",
            toolName: "agent",
            args: .object([:]),
            partialResult: toolDisplay("agent explore running · 128 tokens")
        ))

        #expect(r.drainCommits().isEmpty)
        #expect(r.liveLines.contains(where: { $0.contains("128 tokens") }))
        #expect(!r.liveLines.contains(where: { $0.contains("calling…") }))

        r.apply(.toolExecutionEnd(
            toolCallId: "1",
            toolName: "agent",
            result: toolDisplay("agent explore completed · 256 tokens"),
            isError: false
        ))
        let commits = r.drainCommits()
        #expect(commits.contains(where: { $0.contains("256 tokens") }))
        #expect(!commits.contains(where: { $0.contains("128 tokens") }))
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
    @Test("a lone successful read folds to a one-row group, sealed by assistant text")
    func readFoldsToOneLine() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(
            toolCallId: "1", toolName: "read",
            args: .object(["path": .string("src/foo.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "1", toolName: "read",
            result: toolResult("line1\nline2\nline3"),
            isError: false
        ))

        // The read joins the pending run: nothing committed yet, but the
        // stable group form (header + one tree row) is visible live.
        #expect(r.drainCommits().isEmpty)
        let live = r.liveLines.map(ANSI.stripEscapes)
        #expect(live.contains(where: { $0.contains("● read 1 file") }))
        #expect(live.contains(where: { $0.contains("└ read src/foo.swift · 3 lines") }))
        #expect(!live.contains(where: { $0.contains("line1") }))

        // Assistant text entering scrollback seals the run ahead of it.
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        r.apply(.messageEnd(message: .assistant(stubAssistant("done"))))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        let readIdx = commits.firstIndex(where: { $0.contains("└ read src/foo.swift · 3 lines") })
        let textIdx = commits.firstIndex(where: { $0 == "done" })
        #expect(readIdx != nil && textIdx != nil)
        #expect((readIdx ?? 0) < (textIdx ?? 0))
        // No content preview lines in scrollback.
        #expect(!commits.contains(where: { $0.contains("line1") }))
    }

    @MainActor
    @Test("consecutive reads merge into a tools (N) tree")
    func consecutiveReadsMergeIntoTree() {
        let r = TranscriptRenderer()
        for (id, path) in [("1", "a.swift"), ("2", "b.swift"), ("3", "c.swift")] {
            r.apply(.toolExecutionStart(
                toolCallId: id, toolName: "read",
                args: .object(["path": .string(path)])
            ))
            r.apply(.toolExecutionEnd(
                toolCallId: id, toolName: "read",
                result: toolResult("x\ny"),
                isError: false
            ))
        }

        #expect(r.drainCommits().isEmpty)
        let live = r.liveLines.map(ANSI.stripEscapes)
        #expect(live.contains(where: { $0.contains("● read 3 files") }))
        #expect(live.contains(where: { $0.contains("├ read a.swift") }))
        #expect(live.contains(where: { $0.contains("└ read c.swift") }))

        // A non-folded tool block seals the run before its own output.
        r.apply(.toolExecutionStart(toolCallId: "4", toolName: "bash", args: .object([:])))
        r.apply(.toolExecutionEnd(
            toolCallId: "4", toolName: "bash",
            result: toolResult("ok"), isError: false
        ))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        let treeIdx = commits.firstIndex(where: { $0.contains("● read 3 files") })
        let bashIdx = commits.firstIndex(where: { $0.contains("bash") })
        #expect(treeIdx != nil && bashIdx != nil)
        #expect((treeIdx ?? 0) < (bashIdx ?? 0))
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("mixed read/grep/ls calls merge into one tools (N) tree")
    func mixedReadOnlyToolsMergeIntoOneTree() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(toolCallId: "1", toolName: "ls", args: .object([:])))
        r.apply(.toolExecutionEnd(
            toolCallId: "1", toolName: "ls",
            result: AgentToolResult(
                content: [.text(TextContent(text: "a\nb"))],
                details: .object(["entries": .array([
                    .object(["name": .string("a"), "kind": .string("file"), "size": .int(0)]),
                    .object(["name": .string("b"), "kind": .string("file"), "size": .int(0)]),
                ])])
            ),
            isError: false
        ))
        r.apply(.toolExecutionStart(
            toolCallId: "2", toolName: "read",
            args: .object(["path": .string("README.md")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "2", toolName: "read",
            result: toolResult("x\ny\nz"), isError: false
        ))
        r.apply(.toolExecutionStart(
            toolCallId: "3", toolName: "grep",
            args: .object(["pattern": .string("foo")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "3", toolName: "grep",
            result: AgentToolResult(
                content: [.text(TextContent(text: "a.swift:1:foo"))],
                details: .object(["matches": .array([
                    .object(["file": .string("a.swift"), "line": .int(1), "text": .string("foo")]),
                ])])
            ),
            isError: false
        ))

        // All three sit in one live group with no per-call blank rows, and
        // the header counts each tool type in first-appearance order.
        let live = r.liveLines.map(ANSI.stripEscapes)
        #expect(live.contains(where: { $0.contains("● ls 1 time, read 1 file, grep 1 time") }))
        #expect(live.contains(where: { $0.contains("├ ls . · 2 entries") }))
        #expect(live.contains(where: { $0.contains("├ read README.md · 3 lines") }))
        #expect(live.contains(where: { $0.contains("└ grep \"foo\" · 1 match") }))
        // Exactly one leading blank for the whole group — no blank between rows.
        #expect(live.first == "")
        #expect(!live.dropFirst().contains(""))

        r.apply(.agentEnd(messages: [], summary: AgentRunSummary()))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(commits.contains(where: { $0.contains("● ls 1 time, read 1 file, grep 1 time") }))
        #expect(commits.contains(where: { $0.contains("├ ls . · 2 entries") }))
        #expect(commits.contains(where: { $0.contains("└ grep \"foo\" · 1 match") }))
    }

    @MainActor
    @Test("in-flight read-only calls render inside the group while running")
    func runningCallsRenderInsideGroup() {
        let r = TranscriptRenderer()
        // First read finishes; second is still running.
        r.apply(.toolExecutionStart(
            toolCallId: "1", toolName: "read",
            args: .object(["path": .string("done.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "1", toolName: "read",
            result: toolResult("x\ny"), isError: false
        ))
        r.apply(.toolExecutionStart(
            toolCallId: "2", toolName: "grep",
            args: .object(["pattern": .string("wip")])
        ))

        let live = r.liveLines.map(ANSI.stripEscapes)
        // One group, header counts both the finished read and the running
        // grep — the in-flight call is not a separate block.
        #expect(live.contains(where: { $0.contains("● read 1 file, grep 1 time") }))
        #expect(live.contains(where: { $0.contains("├ read done.swift · 2 lines") }))
        // Running grep shows its target, no count yet, and no "calling…".
        #expect(live.contains(where: { $0.contains("└ grep \"wip\"") }))
        #expect(!live.contains(where: { $0.contains("calling") }))
        #expect(!live.contains(where: { $0.contains("grep(pattern") }))

        // When it resolves the row fills in its count in place.
        r.apply(.toolExecutionEnd(
            toolCallId: "2", toolName: "grep",
            result: AgentToolResult(
                content: [.text(TextContent(text: "a:1:wip"))],
                details: .object(["matches": .array([
                    .object(["file": .string("a"), "line": .int(1), "text": .string("wip")]),
                ])])
            ),
            isError: false
        ))
        let live2 = r.liveLines.map(ANSI.stripEscapes)
        #expect(live2.contains(where: { $0.contains("└ grep \"wip\" · 1 match") }))
    }

    @MainActor
    @Test("a folded read resolving behind a running non-folded tool renders as a tree, not a standalone line")
    func blockedFoldableRendersAsTree() {
        let r = TranscriptRenderer()
        // A non-folded tool starts first and stays running, blocking the
        // queue; a read starts after it and resolves while still blocked.
        r.apply(.toolExecutionStart(toolCallId: "b", toolName: "bash", args: .object(["cmd": .string("sleep")])))
        r.apply(.toolExecutionStart(
            toolCallId: "r", toolName: "read",
            args: .object(["path": .string("a.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "r", toolName: "read",
            result: toolResult("x\ny"), isError: false
        ))

        // Live: the blocked read must render as its own one-row tree (header +
        // row), byte-identical to the form it will settle into — never a
        // standalone `● read a.swift` line that would reflow on commit.
        let live = r.liveLines.map(ANSI.stripEscapes)
        #expect(live.contains(where: { $0.contains("● read 1 file") }))
        #expect(live.contains(where: { $0.contains("└ read a.swift · 2 lines") }))

        // When bash resolves, the read joins the pending fold run (still open
        // so later read/grep calls can merge into the same tree); the turn end
        // seals it into scrollback in the exact same tree form — no reflow.
        r.apply(.toolExecutionEnd(
            toolCallId: "b", toolName: "bash",
            result: toolResult("done"), isError: false
        ))
        r.apply(.agentEnd(messages: [], summary: AgentRunSummary()))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(commits.contains(where: { $0.contains("● read 1 file") }))
        #expect(commits.contains(where: { $0.contains("└ read a.swift · 2 lines") }))
    }

    @MainActor
    @Test("agentEnd seals a pending fold run")
    func agentEndSealsReadRun() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(
            toolCallId: "1", toolName: "read",
            args: .object(["path": .string("a.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "1", toolName: "read",
            result: toolResult("x"), isError: false
        ))
        r.apply(.agentEnd(messages: [], summary: AgentRunSummary()))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(commits.contains(where: { $0.contains("● read 1 file") }))
        #expect(commits.contains(where: { $0.contains("└ read a.swift · 1 line") }))
        #expect(r.liveLines.isEmpty)
    }

    @MainActor
    @Test("a lone grep folds to a one-line summary with match counts")
    func grepFoldsToSummaryLine() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(
            toolCallId: "1", toolName: "grep",
            args: .object(["pattern": .string("needle")])
        ))
        let result = AgentToolResult(
            content: [.text(TextContent(text: "a.swift:1:needle\nb.swift:2:needle\nb.swift:9:needle"))],
            details: .object(["matches": .array([
                .object(["file": .string("a.swift"), "line": .int(1), "text": .string("needle")]),
                .object(["file": .string("b.swift"), "line": .int(2), "text": .string("needle")]),
                .object(["file": .string("b.swift"), "line": .int(9), "text": .string("needle")]),
            ])])
        )
        r.apply(.toolExecutionEnd(toolCallId: "1", toolName: "grep", result: result, isError: false))
        // A lone read-only call is held in the fold run; agentEnd seals it
        // as a single `● grep …` line (no tree).
        r.apply(.agentEnd(messages: [], summary: AgentRunSummary()))

        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(commits.contains(where: { $0.contains("● grep 1 time") }))
        #expect(commits.contains(where: { $0.contains("└ grep \"needle\" · 3 matches · 2 files") }))
        // Match content lines never reach scrollback.
        #expect(!commits.contains(where: { $0.contains("a.swift:1:needle") }))
    }

    @MainActor
    @Test("read errors keep the full unfolded error block")
    func readErrorKeepsFullBlock() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(
            toolCallId: "1", toolName: "read",
            args: .object(["path": .string("missing.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "1", toolName: "read",
            result: toolResult("file not found: missing.swift"),
            isError: true
        ))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(commits.contains(where: { $0.contains("● read(path: \"missing.swift\")") }))
        #expect(commits.contains(where: { $0.contains("file not found") }))
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
    @Test("incomplete assistant text stays out of scrollback but shows live")
    func incompleteAssistantTextDoesNotSpill() {
        let r = TranscriptRenderer()
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("unfinished text")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "unfinished text", partial: partial)
        ))

        #expect(r.drainCommits().isEmpty)
        #expect(r.liveLines.contains(where: { $0.contains("unfinished text") }))
    }

    @MainActor
    @Test("live tail renders below a pending read run, matching commit order")
    func liveTailOrdersAfterReadRun() {
        let r = TranscriptRenderer()
        r.apply(.toolExecutionStart(
            toolCallId: "1", toolName: "read",
            args: .object(["path": .string("a.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "1", toolName: "read",
            result: toolResult("x"), isError: false
        ))
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("summarizing")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "summarizing", partial: partial)
        ))

        let live = r.liveLines.map(ANSI.stripEscapes)
        let readIdx = live.firstIndex(where: { $0.contains("└ read a.swift") })
        let tailIdx = live.firstIndex(where: { $0.contains("summarizing") })
        #expect(readIdx != nil && tailIdx != nil)
        #expect((readIdx ?? 0) < (tailIdx ?? 0))

        // When the tail settles, the run seals above it — same order.
        r.apply(.messageEnd(message: .assistant(stubAssistant("summarizing"))))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        let cReadIdx = commits.firstIndex(where: { $0.contains("└ read a.swift") })
        let cTextIdx = commits.firstIndex(where: { $0.contains("summarizing") })
        #expect(cReadIdx != nil && cTextIdx != nil)
        #expect((cReadIdx ?? 0) < (cTextIdx ?? 0))
    }

    @MainActor
    @Test("collapsed thinking stays live until turn end commits its timing row")
    func collapsedThinkingLabel() {
        let r = TranscriptRenderer()
        // Show reasoning of any length so the synchronous test doesn't have
        // to burn 3s of wall clock to cross the visibility threshold.
        r.collapsedThinkingMinSeconds = 0
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingDelta(contentIndex: 0, delta: "pondering deeply", partial: partial)
        ))

        let live = r.liveLines.map(ANSI.stripEscapes)
        #expect(live.contains(where: { $0.hasPrefix("[thinking ") }))
        // Collapsed mode: the body never renders.
        #expect(!live.contains(where: { $0.contains("pondering deeply") }))
        #expect(r.hasActiveThinking)

        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "pondering deeply", partial: partial)
        ))
        // `thinkingEnd` alone is not a settlement boundary in collapsed mode:
        // another adjacent thinking block may follow and join this duration.
        #expect(r.drainCommits().isEmpty)
        #expect(r.liveLines.map(ANSI.stripEscapes).contains(where: {
            $0.hasPrefix("[thinking ")
        }))
        r.apply(.turnEnd(message: .assistant(partial), toolResults: []))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(commits.contains(where: { $0.hasPrefix("[thought for ") }))
        #expect(!commits.contains(where: { $0.contains("pondering deeply") }))
        #expect(!r.hasActiveThinking)
        #expect(!r.liveLines.contains(where: { $0.contains("[thinking") }))
    }

    @MainActor
    @Test("adjacent collapsed thinking blocks commit once with summed active duration")
    func collapsedThinkingSumsAdjacentBlocks() {
        let r = TranscriptRenderer()
        let partial = stubAssistant("")
        r.apply(.messageStart(message: .assistant(partial)))

        // Two 2-second blocks separated by an 7-second inactive gap. The
        // visible duration must be 4s (active time), not 11s wall time, and
        // the default 3s threshold applies to that aggregate.
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 3_000_000_000)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "first", partial: partial)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 10_000_000_000)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 1, partial: partial)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 12_000_000_000)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 1, content: "second", partial: partial)
        ))

        #expect(r.drainCommits().isEmpty)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textStart(contentIndex: 2, partial: partial)
        ))
        let thoughts = r.drainCommits().map(ANSI.stripEscapes).filter {
            $0.hasPrefix("[thought for ")
        }
        #expect(thoughts == ["[thought for 4.0s]"])
    }

    @MainActor
    @Test("snapshot-only text at thinkingStart splits collapsed thinking in order")
    func thinkingStartSnapshotTextSplitsCollapsedRuns() {
        let r = TranscriptRenderer()
        r.collapsedThinkingMinSeconds = 0
        let empty = stubAssistant("")
        r.apply(.messageStart(message: .assistant(empty)))

        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        r.apply(.messageUpdate(
            message: empty,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: empty)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 2_000_000_000)
        r.apply(.messageUpdate(
            message: empty,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "first", partial: empty)
        ))

        // No text event arrives. The next thinking boundary is the first
        // snapshot that exposes the intervening text block.
        let secondPartial = stubAssistant(blocks: [
            .thinking(ThinkingContent(thinking: "first")),
            .text(TextContent(text: "middle")),
            .thinking(ThinkingContent(thinking: "second")),
        ])
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 3_000_000_000)
        r.apply(.messageUpdate(
            message: secondPartial,
            assistantMessageEvent: .thinkingStart(contentIndex: 2, partial: secondPartial)
        ))

        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 4_000_000_000)
        r.apply(.messageUpdate(
            message: secondPartial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 2, content: "second", partial: secondPartial)
        ))
        r.apply(.turnEnd(message: .assistant(secondPartial), toolResults: []))

        let commits = r.drainCommits().map(ANSI.stripEscapes)
        let firstThought = commits.firstIndex(of: "[thought for 1.0s]")
        let text = commits.firstIndex(of: "middle")
        let secondThought = commits.lastIndex(of: "[thought for 1.0s]")
        #expect(firstThought != nil && text != nil && secondThought != nil)
        #expect((firstThought ?? 0) < (text ?? 0))
        #expect((text ?? 0) < (secondThought ?? 0))
        #expect(!commits.contains("[thought for 2.0s]"))
    }

    @MainActor
    @Test("snapshot-only text at thinkingEnd splits collapsed thinking in order")
    func thinkingEndSnapshotTextSplitsCollapsedRuns() {
        let r = TranscriptRenderer()
        r.collapsedThinkingMinSeconds = 0
        let empty = stubAssistant("")
        r.apply(.messageStart(message: .assistant(empty)))

        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        r.apply(.messageUpdate(
            message: empty,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: empty)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 2_000_000_000)
        r.apply(.messageUpdate(
            message: empty,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "first", partial: empty)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 3_000_000_000)
        r.apply(.messageUpdate(
            message: empty,
            assistantMessageEvent: .thinkingStart(contentIndex: 2, partial: empty)
        ))

        let final = stubAssistant(blocks: [
            .thinking(ThinkingContent(thinking: "first")),
            .text(TextContent(text: "middle")),
            .thinking(ThinkingContent(thinking: "second")),
        ])
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 4_000_000_000)
        r.apply(.messageUpdate(
            message: final,
            assistantMessageEvent: .thinkingEnd(contentIndex: 2, content: "second", partial: final)
        ))
        r.apply(.turnEnd(message: .assistant(final), toolResults: []))

        let commits = r.drainCommits().map(ANSI.stripEscapes)
        let firstThought = commits.firstIndex(of: "[thought for 1.0s]")
        let text = commits.firstIndex(of: "middle")
        let secondThought = commits.lastIndex(of: "[thought for 1.0s]")
        #expect(firstThought != nil && text != nil && secondThought != nil)
        #expect((firstThought ?? 0) < (text ?? 0))
        #expect((text ?? 0) < (secondThought ?? 0))
        #expect(!commits.contains("[thought for 2.0s]"))
    }

    @MainActor
    @Test("stream rewind marks committed collapsed and expanded thoughts as discarded")
    func thinkingCommitsAreMarkedDiscardedOnRewind() {
        let partial = stubAssistant("")

        let collapsed = TranscriptRenderer()
        collapsed.collapsedThinkingMinSeconds = 0
        collapsed.apply(.messageStart(message: .assistant(partial)))
        collapsed.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        collapsed.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        collapsed.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 2_000_000_000)
        collapsed.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(
                contentIndex: 0,
                content: "failed collapsed thought",
                partial: partial
            )
        ))
        collapsed.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .textStart(contentIndex: 1, partial: partial)
        ))
        collapsed.apply(.streamRewind)

        let collapsedCommits = collapsed.drainCommits().map(ANSI.stripEscapes)
        let collapsedThought = collapsedCommits.firstIndex(of: "[thought for 1.0s]")
        let collapsedDiscard = collapsedCommits.firstIndex(where: { $0.contains("discarded") })
        #expect(collapsedThought != nil && collapsedDiscard != nil)
        #expect((collapsedThought ?? 0) < (collapsedDiscard ?? 0))

        let expanded = TranscriptRenderer()
        expanded.setThinkingDisplay(.expanded)
        expanded.apply(.messageStart(message: .assistant(partial)))
        expanded.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 3_000_000_000)
        expanded.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        expanded.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 4_000_000_000)
        expanded.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(
                contentIndex: 0,
                content: "failed expanded thought",
                partial: partial
            )
        ))
        expanded.apply(.streamRewind)

        let expandedCommits = expanded.drainCommits().map(ANSI.stripEscapes)
        let expandedThought = expandedCommits.firstIndex(of: "[thought for 1.0s]")
        let expandedDiscard = expandedCommits.firstIndex(where: { $0.contains("discarded") })
        #expect(expandedThought != nil && expandedDiscard != nil)
        #expect((expandedThought ?? 0) < (expandedDiscard ?? 0))
    }

    @MainActor
    @Test("tool call splits collapsed thinking runs")
    func toolCallSplitsCollapsedThinking() {
        let r = TranscriptRenderer()
        r.collapsedThinkingMinSeconds = 0
        let partial = stubAssistant("")
        r.apply(.messageStart(message: .assistant(partial)))

        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 3_000_000_000)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "before tool", partial: partial)
        ))
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .toolCallStart(contentIndex: 1, partial: partial)
        ))
        let beforeTool = r.drainCommits().map(ANSI.stripEscapes)
        #expect(beforeTool.contains("[thought for 2.0s]"))

        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 4_000_000_000)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 2, partial: partial)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 7_000_000_000)
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 2, content: "after tool", partial: partial)
        ))
        r.apply(.turnEnd(message: .assistant(partial), toolResults: []))
        let afterTool = r.drainCommits().map(ANSI.stripEscapes)
        #expect(afterTool.contains("[thought for 3.0s]"))
        #expect(!afterTool.contains("[thought for 5.0s]"))
    }

    @MainActor
    @Test("collapsed thought cannot overtake preceding assistant text")
    func collapsedThinkingKeepsTextOrder() {
        let r = TranscriptRenderer()
        r.collapsedThinkingMinSeconds = 0
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))

        let textPartial = stubAssistant("before")
        r.apply(.messageUpdate(
            message: textPartial,
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "before", partial: textPartial)
        ))
        let thinkingPartial = stubAssistant(blocks: [
            .text(TextContent(text: "before")),
            .thinking(ThinkingContent(thinking: "reason")),
        ])
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        r.apply(.messageUpdate(
            message: thinkingPartial,
            assistantMessageEvent: .thinkingStart(contentIndex: 1, partial: thinkingPartial)
        ))
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 2_000_000_000)
        r.apply(.messageUpdate(
            message: thinkingPartial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 1, content: "reason", partial: thinkingPartial)
        ))
        r.apply(.messageUpdate(
            message: thinkingPartial,
            assistantMessageEvent: .toolCallStart(contentIndex: 2, partial: thinkingPartial)
        ))

        let commits = r.drainCommits().map(ANSI.stripEscapes)
        let text = commits.firstIndex(of: "before")
        let thought = commits.firstIndex(of: "[thought for 1.0s]")
        #expect(text != nil && thought != nil)
        #expect((text ?? 0) < (thought ?? 0))
    }

    @MainActor
    @Test("final snapshot only preserves text before thinking order")
    func finalSnapshotThinkingKeepsTextOrder() {
        let r = TranscriptRenderer()
        r.collapsedThinkingMinSeconds = 0
        let empty = stubAssistant("")
        r.apply(.messageStart(message: .assistant(empty)))

        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        r.apply(.messageUpdate(
            message: empty,
            assistantMessageEvent: .thinkingStart(contentIndex: 1, partial: empty)
        ))

        let final = stubAssistant(blocks: [
            .text(TextContent(text: "before")),
            .thinking(ThinkingContent(thinking: "reason")),
        ])
        r.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 2_000_000_000)
        r.apply(.messageEnd(message: .assistant(final)))

        let commits = r.drainCommits().map(ANSI.stripEscapes)
        let text = commits.firstIndex(of: "before")
        let thought = commits.firstIndex(of: "[thought for 1.0s]")
        #expect(text != nil && thought != nil)
        #expect((text ?? 0) < (thought ?? 0))
    }

    @MainActor
    @Test("human and runtime-sourced messages flush staged collapsed thinking")
    func userAndRuntimeFlushCollapsedThinking() {
        let runtimeRenderer = TranscriptRenderer()
        runtimeRenderer.collapsedThinkingMinSeconds = 0
        let partial = stubAssistant("")
        runtimeRenderer.apply(.messageStart(message: .assistant(partial)))
        runtimeRenderer.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        runtimeRenderer.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        runtimeRenderer.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 2_000_000_000)
        runtimeRenderer.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "runtime boundary", partial: partial)
        ))
        runtimeRenderer.apply(.messageStart(message: .user(UserMessage(
            text: "runtime aside",
            source: .runtime
        ))))
        #expect(runtimeRenderer.drainCommits().map(ANSI.stripEscapes).contains("[thought for 1.0s]"))

        let userRenderer = TranscriptRenderer()
        userRenderer.collapsedThinkingMinSeconds = 0
        userRenderer.apply(.messageStart(message: .assistant(partial)))
        userRenderer.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 3_000_000_000)
        userRenderer.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        userRenderer.thinkingNowOverride = DispatchTime(uptimeNanoseconds: 4_000_000_000)
        userRenderer.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "user boundary", partial: partial)
        ))
        userRenderer.apply(.messageStart(message: .user(UserMessage(text: "steer"))))
        let commits = userRenderer.drainCommits().map(ANSI.stripEscapes)
        let thought = commits.firstIndex(of: "[thought for 1.0s]")
        let user = commits.firstIndex(where: { $0.hasPrefix("❯ steer") })
        #expect(thought != nil && user != nil)
        #expect((thought ?? 0) < (user ?? 0))
    }

    @MainActor
    @Test("expanded thinking streams its body live and commits it on end")
    func expandedThinkingStreamsBody() {
        let r = TranscriptRenderer()
        r.setThinkingDisplay(.expanded)
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingDelta(contentIndex: 0, delta: "step one\nstep two", partial: partial)
        ))

        let live = r.liveLines.map(ANSI.stripEscapes)
        #expect(live.contains(where: { $0.contains("step one") }))
        #expect(live.contains(where: { $0.contains("step two") }))

        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "step one\nstep two", partial: partial)
        ))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(commits.contains(where: { $0.hasPrefix("[thought for ") }))
        #expect(commits.contains(where: { $0.contains("step one") }))
        #expect(commits.contains(where: { $0.contains("step two") }))
    }

    @MainActor
    @Test("aborted mid-thought commits the sealed thinking block on messageEnd")
    func abortedThinkingCommitsOnEnd() {
        let r = TranscriptRenderer()
        r.collapsedThinkingMinSeconds = 0
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingDelta(contentIndex: 0, delta: "interrupted thought", partial: partial)
        ))

        // No thinkingEnd — the turn aborts.
        r.apply(.messageEnd(message: .assistant(stubAssistant("", stop: .aborted))))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(commits.contains(where: { $0.hasPrefix("[thought for ") }))
        #expect(!r.hasActiveThinking)
    }

    @MainActor
    @Test("collapsed thinking under the threshold shows nothing, live or committed")
    func shortCollapsedThinkingHidden() {
        let r = TranscriptRenderer()
        // Default 3s threshold; a synchronous think elapses ~0s.
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingDelta(contentIndex: 0, delta: "quick idea", partial: partial)
        ))
        // Not shown live while under threshold.
        #expect(!r.liveLines.contains(where: { $0.contains("[thinking") }))

        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "quick idea", partial: partial)
        ))
        r.apply(.messageEnd(message: .assistant(stubAssistant("done"))))
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(!commits.contains(where: { $0.contains("[thought for") }))
        #expect(commits.contains(where: { $0 == "done" }))
    }

    @MainActor
    @Test("a short think between read-only calls does not split the fold group")
    func shortThinkKeepsFoldGroupIntact() {
        let r = TranscriptRenderer()
        // Two reads with a brief (sub-threshold) think wedged between them.
        r.apply(.toolExecutionStart(
            toolCallId: "1", toolName: "read",
            args: .object(["path": .string("a.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "1", toolName: "read",
            result: toolResult("x"), isError: false
        ))
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "hm", partial: partial)
        ))
        r.apply(.toolExecutionStart(
            toolCallId: "2", toolName: "read",
            args: .object(["path": .string("b.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "2", toolName: "read",
            result: toolResult("y"), isError: false
        ))
        r.apply(.agentEnd(messages: [], summary: AgentRunSummary()))

        // The sub-threshold think never committed, so it never sealed the
        // run — both reads land in one group with no `[thought]` between.
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        #expect(!commits.contains(where: { $0.contains("[thought for") }))
        #expect(commits.contains(where: { $0.contains("● read 2 files") }))
        #expect(commits.contains(where: { $0.contains("├ read a.swift") }))
        #expect(commits.contains(where: { $0.contains("└ read b.swift") }))
    }

    @MainActor
    @Test("a shown (long) think seals the fold group like any other block")
    func longThinkSealsFoldGroup() {
        let r = TranscriptRenderer()
        r.collapsedThinkingMinSeconds = 0  // make the think count as "shown"
        r.apply(.toolExecutionStart(
            toolCallId: "1", toolName: "read",
            args: .object(["path": .string("a.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "1", toolName: "read",
            result: toolResult("x"), isError: false
        ))
        r.apply(.messageStart(message: .assistant(stubAssistant(""))))
        let partial = stubAssistant("")
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingStart(contentIndex: 0, partial: partial)
        ))
        r.apply(.messageUpdate(
            message: partial,
            assistantMessageEvent: .thinkingEnd(contentIndex: 0, content: "deliberating", partial: partial)
        ))
        r.apply(.toolExecutionStart(
            toolCallId: "2", toolName: "read",
            args: .object(["path": .string("b.swift")])
        ))
        r.apply(.toolExecutionEnd(
            toolCallId: "2", toolName: "read",
            result: toolResult("y"), isError: false
        ))
        r.apply(.agentEnd(messages: [], summary: AgentRunSummary()))

        // The shown think sits between two separate single-read groups,
        // in chronological order.
        let commits = r.drainCommits().map(ANSI.stripEscapes)
        let firstRead = commits.firstIndex(where: { $0.contains("└ read a.swift") })
        let thought = commits.firstIndex(where: { $0.contains("[thought for") })
        let secondRead = commits.firstIndex(where: { $0.contains("└ read b.swift") })
        #expect(firstRead != nil && thought != nil && secondRead != nil)
        #expect((firstRead ?? 0) < (thought ?? 0))
        #expect((thought ?? 0) < (secondRead ?? 0))
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

    @Test("committed long lines are written raw for terminal autowrap")
    func committedLongLinesWriteRaw() async {
        let terminal = VirtualTerminal(width: 10, height: 20)
        let tui = TUI(terminal: terminal)
        let live = TestLinesComponent(["LIVE"])
        tui.addChild(live)
        tui.start()
        await terminal.waitForRender()
        terminal.clearWrites()

        let long = "12345678901234567890"
        tui.commit([long])
        tui.requestRender()
        await terminal.waitForRender()

        let writes = terminal.getWrites()
        #expect(writes.contains(long))
        if let longRange = writes.range(of: long) {
            let enable = "\u{1B}[?7h"
            let disable = "\u{1B}[?7l"
            let enableBeforeCommit = writes.range(
                of: enable,
                options: .backwards,
                range: writes.startIndex..<longRange.lowerBound
            )
            let disableAfterCommit = writes.range(
                of: disable,
                range: longRange.upperBound..<writes.endIndex
            )

            #expect(enableBeforeCommit != nil)
            #expect(disableAfterCommit != nil)
        }
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
