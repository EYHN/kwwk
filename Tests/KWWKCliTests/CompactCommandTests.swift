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
        var recordedMessagesCompacted: Int?
        let ctx = SlashContext(
            agent: agent,
            modal: makeStubModalHost(),
            backgroundManager: BackgroundTaskManager(outputDir: makeTempDir()),
            sessionId: "test-session",
            notifyBlock: { lines in for l in lines { notifier.append(l) } },
            commitScrollback: commits.collect(),
            refreshTranscript: {},
            recordCompaction: { n in recordedMessagesCompacted = n }
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
        #expect(recordedMessagesCompacted == messages.count)
        // And it's shaped like a horizontal rule so it stands out when
        // the user scrolls back through history.
        #expect(commits.joined.contains("──"))
    }

    @MainActor
    @Test("compact passes the active session to auth resolution and streaming")
    func compactUsesSessionBoundAuth() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let capture = CompactAuthCapture()
        faux.setResponses([
            .factory { _, options, _, _ in
                capture.recordStream(
                    sessionId: options?.sessionId,
                    token: options?.resolvedAuth?.token
                )
                return fauxAssistantMessage("session-bound recap")
            }
        ])

        let messages: [Message] = [
            .user(UserMessage(content: [.text(TextContent(text: "one"))])),
            .assistant(fauxAssistantMessage("two")),
            .user(UserMessage(content: [.text(TextContent(text: "three"))])),
            .assistant(fauxAssistantMessage("four")),
        ]
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                messages: messages
            ),
            authResolver: { model, sessionId in
                capture.recordResolver(provider: model.provider, sessionId: sessionId)
                return ResolvedProviderAuth(token: "session-token", scheme: .bearer)
            }
        ))

        let outcome = await performCompact(
            agent: agent,
            backgroundManager: BackgroundTaskManager(outputDir: makeTempDir()),
            sessionId: "compact-session"
        )

        if case .compacted = outcome {
            // Expected.
        } else {
            Issue.record("expected compaction to succeed")
        }
        #expect(capture.resolverProvider == faux.provider)
        #expect(capture.resolverSessionId == "compact-session")
        #expect(capture.streamSessionId == "compact-session")
        #expect(capture.streamToken == "session-token")
    }

    @MainActor
    @Test("manual compact uses the agent compaction config")
    func manualCompactUsesAgentCompactionConfig() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let messages: [Message] = [
            .user(UserMessage(text: "one")),
            .assistant(fauxAssistantMessage("two")),
            .user(UserMessage(text: "three")),
            .assistant(fauxAssistantMessage("four")),
        ]
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                messages: messages
            ),
            autoCompact: AgentAutoCompactOptions(
                config: AgentContextCompactionConfig(minMessages: 10)
            )
        ))

        let outcome = await performCompact(
            agent: agent,
            backgroundManager: BackgroundTaskManager(outputDir: makeTempDir()),
            sessionId: "compact-session"
        )

        if case .refusedTooFewMessages(let count) = outcome {
            #expect(count == 4)
        } else {
            Issue.record("expected manual compact to honor minMessages")
        }
        #expect(agent.state.messages.count == 4)
    }

    @MainActor
    @Test("queued prompt is persisted after the manual compaction projection")
    func queuedPromptSettlesAfterCompactionMarker() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let summaryGate = CompactCommandGate()
        faux.setResponses([
            .factory { _, _, _, _ in
                await summaryGate.enterAndWait()
                return fauxAssistantMessage("durable compact summary")
            },
            .message(fauxAssistantMessage("queued prompt reply")),
        ])

        let messages: [Message] = [
            .user(UserMessage(text: "one")),
            .assistant(fauxAssistantMessage("two")),
            .user(UserMessage(text: "three")),
            .assistant(fauxAssistantMessage("four")),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: messages
        ))

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let sessionId = "compact-settlement-order"
        let recorder = SessionRecorder(
            store: store,
            sessionId: sessionId,
            cwd: dir.path,
            model: agent.state.model.id,
            provider: agent.state.model.provider
        )
        await recorder.ensureCreated()
        await recorder.flush(messages: messages)
        let unsubscribe = recorder.attach(to: agent)
        defer { unsubscribe() }

        let ctx = SlashContext(
            agent: agent,
            modal: makeStubModalHost(),
            backgroundManager: BackgroundTaskManager(
                outputDir: dir.appendingPathComponent("background", isDirectory: true)
            ),
            sessionId: sessionId,
            notifyBlock: { _ in },
            commitScrollback: { _ in },
            refreshTranscript: {},
            recordCompaction: { count in
                await recorder.recordCompaction(
                    messages: agent.state.messages,
                    messagesCompacted: count,
                    reason: .compact
                )
            }
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        let command = Task { @MainActor in
            await registry.find("compact")?.handler(ctx, "")
        }
        await summaryGate.waitUntilEntered()
        agent.steer("queued during compact")
        await summaryGate.release()
        await command.value

        // `resumeQueuedWork` is deliberately fire-and-forget. Wait for the
        // queued reply to appear, then for all recorder listeners to settle.
        for _ in 0..<400 {
            if agent.state.messages.contains(where: {
                compactTestText($0).contains("queued prompt reply")
            }) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await agent.waitForIdle()

        let loaded = try await store.load(id: sessionId)
        #expect(loaded.messages.count == 3)
        #expect(compactTestText(loaded.messages[0]).contains("durable compact summary"))
        #expect(compactTestText(loaded.messages[1]) == "queued during compact")
        #expect(compactTestText(loaded.messages[2]).contains("queued prompt reply"))

        let raw = try String(
            contentsOf: dir.appendingPathComponent("\(sessionId).jsonl"),
            encoding: .utf8
        )
        let lines = raw.split(separator: "\n")
        let marker = lines.firstIndex(where: {
            $0.contains(#""type":"compaction""#)
        })
        let queued = lines.firstIndex(where: {
            $0.contains("queued during compact")
        })
        #expect(marker != nil && queued != nil)
        #expect((marker ?? 0) < (queued ?? 0))
    }

    @MainActor
    @Test("shutdown cancels a hung manual compact without replacing or persisting context")
    func shutdownCancelsHungManualCompact() async throws {
        let model = Model(
            id: "cancel-compact-model",
            api: "cancel-compact-api",
            provider: "cancel-compact-provider"
        )
        let streamController = CancelAwareCompactionStream()
        let original: [Message] = [
            .user(UserMessage(text: "one")),
            .assistant(compactAssistant("two", model: model)),
            .user(UserMessage(text: "three")),
            .assistant(compactAssistant("four", model: model)),
        ]
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: model, messages: original),
            streamFn: { model, _, options in
                streamController.makeStream(
                    model: model,
                    cancellation: options?.cancellation
                )
            },
            sessionId: "cancel-compact-session"
        ))

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let recorder = SessionRecorder(
            store: store,
            sessionId: "cancel-compact-session",
            cwd: dir.path,
            model: model.id,
            provider: model.provider
        )
        await recorder.ensureCreated()
        await recorder.flush(messages: original)

        let compact = Task { @MainActor in
            await performCompact(
                agent: agent,
                backgroundManager: BackgroundTaskManager(
                    outputDir: dir.appendingPathComponent("background", isDirectory: true)
                ),
                sessionId: "cancel-compact-session",
                settle: { outcome in
                    // Mirror the production handler: only a successful compact
                    // may append a projection marker.
                    if case .compacted(let count, _) = outcome {
                        await recorder.recordCompaction(
                            messages: agent.state.messages,
                            messagesCompacted: count,
                            reason: .compact
                        )
                    }
                }
            )
        }
        for _ in 0..<200 where !streamController.started {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(streamController.started)

        let shutdownDone = CompactLockedFlag()
        let shutdown = Task {
            await cleanupHeadlessAgent(agent)
            shutdownDone.set()
        }
        for _ in 0..<200 where !shutdownDone.value {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let returnedPromptly = shutdownDone.value
        if !returnedPromptly {
            // Keep a failed regression test from leaving a permanently blocked
            // provider task in the test process.
            streamController.forceAbort()
        }
        await shutdown.value
        let outcome = await compact.value

        #expect(returnedPromptly, "shutdown should not wait indefinitely for compaction")
        if case .failed(let reason) = outcome {
            #expect(reason.contains("cancel"))
        } else {
            Issue.record("cancelled maintenance unexpectedly reported compaction success")
        }
        #expect(agent.state.messages == original)

        let loaded = try await store.load(id: "cancel-compact-session")
        #expect(loaded.messages == original)
        let raw = try String(
            contentsOf: dir.appendingPathComponent("cancel-compact-session.jsonl"),
            encoding: .utf8
        )
        #expect(!raw.contains(#""type":"compaction""#))
    }

    @MainActor
    @Test("Esc and first Ctrl-C cancellation gate aborts manual compact maintenance")
    func interactiveInterruptCancelsManualCompact() async throws {
        let model = Model(
            id: "interactive-cancel-compact-model",
            api: "interactive-cancel-compact-api",
            provider: "interactive-cancel-compact-provider"
        )
        let streamController = CancelAwareCompactionStream()
        let original: [Message] = [
            .user(UserMessage(text: "one")),
            .assistant(compactAssistant("two", model: model)),
            .user(UserMessage(text: "three")),
            .assistant(compactAssistant("four", model: model)),
        ]
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: model, messages: original),
            streamFn: { model, _, options in
                streamController.makeStream(
                    model: model,
                    cancellation: options?.cancellation
                )
            }
        ))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let compact = Task { @MainActor in
            await performCompact(
                agent: agent,
                backgroundManager: BackgroundTaskManager(
                    outputDir: dir.appendingPathComponent("background", isDirectory: true)
                ),
                sessionId: "interactive-cancel-compact-session"
            )
        }
        for _ in 0..<200 where !streamController.started {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(streamController.started)

        // Both key bindings route through this gate. Manual compaction owns a
        // maintenance handle while `isStreaming` deliberately remains false.
        #expect(agent.state.isStreaming == false)
        #expect(abortInteractiveAgentWork(agent: agent, isManualCompacting: true))
        let outcome = await compact.value

        if case .failed(let reason) = outcome {
            #expect(reason.contains("cancel"))
        } else {
            Issue.record("interactive cancellation unexpectedly reported compaction success")
        }
        #expect(agent.state.messages == original)
        #expect(!abortInteractiveAgentWork(agent: agent, isManualCompacting: false))
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
    // ModalHost needs render closures. For compact tests we never open
    // a modal, so no-op hooks are enough — the object just has to exist.
    ModalHost(
        renderModalLines: { _ in },
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

private func compactTestText(_ message: Message) -> String {
    switch message {
    case .user(let user):
        return user.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")
    case .assistant(let assistant):
        return assistant.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")
    case .toolResult:
        return ""
    }
}

private actor CompactCommandGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class CompactLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

private final class CancelAwareCompactionStream: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didFinish = false
    private var continuation: AssistantMessageStream.Continuation?
    private var model: Model?

    var started: Bool { lock.withLock { didStart } }

    func makeStream(
        model: Model,
        cancellation: CancellationHandle?
    ) -> AssistantMessageStream {
        let pair = AssistantMessageStream.makeStream()
        lock.withLock {
            didStart = true
            continuation = pair.continuation
            self.model = model
        }
        _ = cancellation?.onCancel { [weak self] _ in
            self?.finishAborted()
        }
        return pair.stream
    }

    func forceAbort() {
        finishAborted()
    }

    private func finishAborted() {
        let settled: (AssistantMessageStream.Continuation, AssistantMessage)? = lock.withLock {
            guard !didFinish, let continuation, let model else { return nil }
            didFinish = true
            let message = AssistantMessage(
                content: [],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(),
                stopReason: .aborted,
                errorMessage: "compaction cancelled"
            )
            return (continuation, message)
        }
        guard let (continuation, message) = settled else { return }
        continuation.push(.error(reason: .aborted, error: message))
        continuation.end(message)
    }
}

private func compactAssistant(_ text: String, model: Model) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(),
        stopReason: .stop
    )
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

private final class CompactAuthCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var resolverProvider: String?
    private(set) var resolverSessionId: String?
    private(set) var streamSessionId: String?
    private(set) var streamToken: String?

    func recordResolver(provider: String, sessionId: String?) {
        lock.withLock {
            resolverProvider = provider
            resolverSessionId = sessionId
        }
    }

    func recordStream(sessionId: String?, token: String?) {
        lock.withLock {
            streamSessionId = sessionId
            streamToken = token
        }
    }
}
