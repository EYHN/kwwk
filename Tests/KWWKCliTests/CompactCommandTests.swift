import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("/compact command")
struct CompactCommandTests {

    @MainActor
    @Test("refuses to run while the agent is streaming")
    func refusesWhenBusy() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let messages: [Message] = (0..<6).map { i -> Message in
            .user(UserMessage(content: [.text(TextContent(text: "msg \(i)"))]))
        }
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: messages
        ))
        // Pretend a real run is in progress — /compact must refuse.
        agent.state.setStreaming(true)

        let notifier = NotifyBox()
        let ctx = SlashContext(
            agent: agent,
            modal: makeStubModalHost(),
            backgroundManager: BackgroundTaskManager(outputDir: makeTempDir()),
            sessionId: "test-session",
            notifyBlock: { lines in for l in lines { notifier.append(l) } },
            commitScrollback: { _ in },
            refreshTranscript: {}
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        let compact = registry.find("compact")
        #expect(compact != nil)
        await compact?.handler(ctx, "")

        #expect(notifier.joined.contains("busy"))
        #expect(agent.state.messages.count == 6)
        // Clean up so the test doesn't leave the agent in a fake-running state.
        agent.state.setStreaming(false)
    }

    @MainActor
    @Test("short-circuits with a helpful note when there's nothing to compact")
    func shortCircuitsWhenTooFewMessages() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: [.user(UserMessage(content: [.text(TextContent(text: "hi"))]))]
        ))

        let notifier = NotifyBox()
        let ctx = SlashContext(
            agent: agent,
            modal: makeStubModalHost(),
            backgroundManager: BackgroundTaskManager(outputDir: makeTempDir()),
            sessionId: "test-session",
            notifyBlock: { lines in for l in lines { notifier.append(l) } },
            commitScrollback: { _ in },
            refreshTranscript: {}
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        await registry.find("compact")?.handler(ctx, "")

        #expect(notifier.joined.contains("nothing to compact"))
        #expect(agent.state.messages.count == 1)
    }

    @MainActor
    @Test("summarizes and replaces the transcript with a single recap message")
    func summarizesAndReplacesTranscript() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        // Pre-queue the summarizer response that /compact's one-shot stream
        // will consume.
        faux.setResponses([
            .message(fauxAssistantMessage("Compressed recap: user asked to add X, we did Y."))
        ])

        let messages: [Message] = [
            .user(UserMessage(content: [.text(TextContent(text: "please add feature X"))])),
            .assistant(fauxAssistantMessage("working on it")),
            .user(UserMessage(content: [.text(TextContent(text: "any update?"))])),
            .assistant(fauxAssistantMessage("step 1 done, moving on")),
            .user(UserMessage(content: [.text(TextContent(text: "great, keep going"))])),
            .assistant(fauxAssistantMessage("step 2 done")),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: messages
        ))

        let notifier = NotifyBox()
        let commits = CommitBox()
        let ctx = SlashContext(
            agent: agent,
            modal: makeStubModalHost(),
            backgroundManager: BackgroundTaskManager(outputDir: makeTempDir()),
            sessionId: "test-session",
            notifyBlock: { lines in for l in lines { notifier.append(l) } },
            commitScrollback: commits.collect(),
            refreshTranscript: {}
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        await registry.find("compact")?.handler(ctx, "")

        #expect(agent.state.messages.count == 1, "transcript should collapse to the recap")
        if case .user(let recap) = agent.state.messages.first {
            let text = recap.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text } else { return nil }
            }.joined()
            #expect(text.contains("<previous-session-summary>"))
            #expect(text.contains("Compressed recap:"))
        } else {
            Issue.record("expected recap message to be a .user block")
        }
        // The durable boundary lives in scrollback now, not in the
        // transient notification area.
        #expect(commits.joined.contains("compacted"))
        // And it's shaped like a horizontal rule so it stands out when
        // the user scrolls back through history.
        #expect(commits.joined.contains("──"))
    }

    @MainActor
    @Test("renderCompactBoundary fills the width with a compacted rule")
    func renderCompactBoundaryShape() {
        let lines = renderCompactBoundary(
            messagesCompacted: 17,
            hasRunningTasksLedger: false,
            width: 60
        )
        // Three-line pattern: blank → rule → blank.
        #expect(lines.count == 3)
        #expect(lines.first == "")
        #expect(lines.last == "")
        let rule = lines[1]
        #expect(rule.contains("compacted"))
        #expect(rule.contains("──"))
    }

    @MainActor
    @Test("renderCompactBoundary notes a running-task ledger when present")
    func renderCompactBoundaryLedger() {
        let lines = renderCompactBoundary(
            messagesCompacted: 4,
            hasRunningTasksLedger: true,
            width: 80
        )
        #expect(lines[1].contains("running-task ledger"))
    }
}

// MARK: - helpers

@MainActor
private func makeStubModalHost() -> ModalHost {
    // ModalHost needs a layout + closures. For compact tests we never open
    // a modal, so a throwaway layout + no-op hooks is enough — the object
    // just has to exist.
    ModalHost(
        layout: CodingLayout(statusRows: 2),
        restoreTranscript: {},
        requestRender: {}
    )
}

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwwk-compact-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private final class NotifyBox {
    private(set) var lines: [String] = []
    func append(_ s: String) { lines.append(s) }
    var joined: String { lines.joined(separator: "\n") }
}

/// Records everything a handler pushed into scrollback via
/// `SlashContext.commitScrollback`. Lets tests assert on durable
/// output separately from transient `notify` lines.
@MainActor
final class CommitBox {
    private(set) var lines: [String] = []
    /// Width handed to the render closure when the handler calls
    /// `commitScrollback`. 80 is a reasonable terminal-default for
    /// test output; callers that care can set a different width.
    let width: Int
    init(width: Int = 80) { self.width = width }

    /// Ready-to-use closure for `SlashContext.commitScrollback`.
    func collect() -> @MainActor ((Int) -> [String]) -> Void {
        return { render in
            let chunk = render(self.width)
            self.lines.append(contentsOf: chunk)
        }
    }

    var joined: String { lines.joined(separator: "\n") }
}
