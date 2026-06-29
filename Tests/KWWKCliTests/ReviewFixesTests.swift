import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

// Regression tests for the four issues flagged in the Codex review:
//
//   P1  Enter while streaming dropped the typed prompt.
//   P2a `/model` adoptFields kept the OLD model's maxTokens, not the
//       picked model's. Codex needed a `maxTokens == 0` sentinel
//       preserved, but all other providers should adopt the new cap.
//   P2b Notification delivery could interleave across notifications
//       because each one spawned an unstructured Task.
//   P2c `/compact` discarded context about still-running background
//       tasks.

// MARK: - P2a: /model adoptFields maxTokens

@Suite("adoptFields maxTokens")
struct AdoptFieldsMaxTokensTests {

    private func model(
        id: String,
        api: String,
        provider: String,
        maxTokens: Int
    ) -> Model {
        Model(
            id: id,
            name: id,
            api: api,
            provider: provider,
            baseUrl: "https://example",
            reasoning: false,
            input: [.text],
            contextWindow: 0,
            maxTokens: maxTokens
        )
    }

    @Test("Codex sentinel (maxTokens=0) is preserved across swap")
    func codexSentinelPreserved() {
        let current = model(id: "gpt-5.4", api: "chatgpt-codex", provider: "chatgpt-codex", maxTokens: 0)
        let picked  = model(id: "gpt-5.4-mini", api: "openai-responses", provider: "openai-codex", maxTokens: 128_000)
        let result = adoptFields(from: current, into: picked)
        #expect(result.maxTokens == 0, "Codex endpoint rejects max_output_tokens — sentinel must survive swap")
        // Routing fields stay on the live session's provider.
        #expect(result.api == "chatgpt-codex")
        #expect(result.provider == "chatgpt-codex")
        #expect(result.id == "gpt-5.4-mini")
    }

    @Test("Non-sentinel maxTokens adopts the picked model's cap")
    func anthropicAdoptsPickedCap() {
        let current = model(id: "opus", api: "anthropic-messages", provider: "anthropic", maxTokens: 8192)
        let picked  = model(id: "haiku", api: "anthropic-messages", provider: "anthropic", maxTokens: 4096)
        let result = adoptFields(from: current, into: picked)
        #expect(result.maxTokens == 4096, "picked model's cap should win — otherwise a haiku request could claim 8192 or vice versa")
    }
}

@Suite("adoptFields session routing")
struct AdoptFieldsSessionRoutingTests {
    private func model(
        id: String, api: String, provider: String, baseUrl: String, maxTokens: Int = 4096
    ) -> Model {
        Model(
            id: id, name: id, api: api, provider: provider, baseUrl: baseUrl,
            reasoning: false, input: [.text], contextWindow: 0, maxTokens: maxTokens
        )
    }

    @Test("same-provider swap keeps the session's baseUrl")
    func sameProviderPreservesBaseUrl() {
        // Mimics the real bug: user logs in with anthropic-api-key using a
        // custom baseUrl (e.g. a corporate proxy). `/model` switching to
        // another Claude model from the catalog must not drop that host
        // in favor of the catalog's `https://api.anthropic.com`.
        let current = model(
            id: "claude-sonnet-4-5-20250929",
            api: "anthropic-messages",
            provider: "anthropic",
            baseUrl: "https://proxy.example.com"
        )
        let picked = model(
            id: "claude-haiku-4-5",
            api: "anthropic-messages",
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com"
        )
        let result = adoptFields(from: current, into: picked)
        #expect(result.id == "claude-haiku-4-5")
        #expect(result.baseUrl == "https://proxy.example.com",
                "session baseUrl must survive same-provider /model swap")
    }

    @Test("Copilot cross-wire swap adopts picked's api but keeps session baseUrl")
    func copilotCrossWire() {
        // Copilot Business/Enterprise: registerGitHubCopilot stamps the
        // proxy endpoint onto the initial model. Switching from a
        // completions-wire model (gpt-4.1) to an anthropic-messages-wire
        // model (claude-sonnet-4.5) must carry picked.api through, but
        // keep the enterprise baseUrl.
        let current = model(
            id: "gpt-4.1",
            api: "openai-completions",
            provider: "github-copilot",
            baseUrl: "https://api.business.githubcopilot.com"
        )
        let picked = model(
            id: "claude-sonnet-4.5",
            api: "anthropic-messages",
            provider: "github-copilot",
            baseUrl: "https://api.individual.githubcopilot.com"
        )
        let result = adoptFields(from: current, into: picked)
        #expect(result.api == "anthropic-messages",
                "picked's wire format must be used — routing by api key")
        #expect(result.baseUrl == "https://api.business.githubcopilot.com",
                "session (enterprise) baseUrl must survive the cross-wire swap")
    }
}

@Suite("catalogProviderKey")
struct CatalogProviderKeyTests {
    @Test("chatgpt-codex maps to openai-codex; others pass through")
    func mapping() {
        #expect(catalogProviderKey(forAgentProvider: "chatgpt-codex") == "openai-codex")
        #expect(catalogProviderKey(forAgentProvider: "anthropic") == "anthropic")
        #expect(catalogProviderKey(forAgentProvider: "openai") == "openai")
    }
}

// MARK: - P2b: notification delivery order

@Suite("BackgroundTaskManager serial delivery")
struct NotificationOrderingTests {

    /// Spawn three tasks back-to-back with artificial per-task sleeps so
    /// their completion notifications queue up and the listener is
    /// forced to observe ordering. A listener that inserts an `await`
    /// between notifications (as the Agent bridge does) must still see
    /// them in FIFO order.
    @Test("listener sees notifications in the order they were enqueued")
    func fifoOrder() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-notif-order-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let manager = BackgroundTaskManager(outputDir: outputDir)
        let recorder = OrderRecorder()

        let listener = await manager.onNotification { notif in
            // A real bridge steers + calls `agent.continue()`. We simulate
            // its "small async hop" with a yield so the test would have
            // caught the old `Task { ... }` fan-out (which could reorder
            // under this pattern).
            await Task.yield()
            await recorder.append(notif.taskId)
        }

        // Spawn three tasks with staged delays so completion order is
        // deterministic: "one" finishes first (100ms), "two" second
        // (200ms), "three" third (300ms). The delays dwarf scheduling
        // jitter, so the three notifications enter `enqueueNotification`
        // in a known order. The invariant under test is: the listener
        // sees them in that same order — even with a `Task.yield()` in
        // the listener body.
        let stages: [(String, UInt64)] = [
            ("one", 100),
            ("two", 200),
            ("three", 300),
        ]
        var ids: [String] = []
        for (tag, delay) in stages {
            let runner = DelayedRunner(tag: tag, delayMs: delay)
            let (taskId, _) = await manager.spawn(runner: runner)
            ids.append(taskId)
        }

        // Wait for all three to drain. 300ms for the last task to finish
        // + generous delivery slack.
        let deadline = Date().addingTimeInterval(5)
        while await recorder.count < 3, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await listener.unsubscribe()

        let observed = await recorder.ids
        #expect(observed == ids, "expected FIFO order \(ids), got \(observed)")
    }
}

private actor OrderRecorder {
    private(set) var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
    var count: Int { ids.count }
}

/// Runner that completes after `delayMs`. Different delays per-spawn
/// make completion order deterministic (task with the smallest delay
/// finishes first), so the ordering test actually pins the invariant
/// we care about: "if enqueueNotification was called in order A, B, C,
/// the listener sees A, B, C" — independent of how the fan-out into
/// Task-spawning scheduling happens.
private struct DelayedRunner: BackgroundTaskRunner {
    let spec: BackgroundTaskSpec
    let tag: String
    let delayMs: UInt64

    init(tag: String, delayMs: UInt64) {
        self.tag = tag
        self.delayMs = delayMs
        self.spec = BackgroundTaskSpec(
            kind: "echo",
            label: tag,
            description: nil,
            hardTimeoutSeconds: 60
        )
    }

    func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    ) {
        let tag = self.tag
        let delay = delayMs
        Task.detached {
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            try? tag.write(to: outputFile, atomically: true, encoding: .utf8)
            onDone(BackgroundTaskOutcome(
                success: true,
                summary: "echo \(tag)",
                details: nil,
                errorMessage: nil
            ))
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self {
            out.append(try await transform(element))
        }
        return out
    }
}

// MARK: - P2c: /compact preserves running bg-task ledger

@Suite("/compact preserves running-task ledger")
struct CompactPreservesRunningTasksTests {

    @MainActor
    @Test("recap message includes a <running-background-tasks> block when tasks are live")
    func recapIncludesRunningTasks() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("summary of work"))])

        let messages: [Message] = (0..<6).map { i in
            if i.isMultiple(of: 2) {
                return .user(UserMessage(content: [.text(TextContent(text: "q\(i)"))]))
            } else {
                return .assistant(fauxAssistantMessage("a\(i)"))
            }
        }
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: messages
        ))

        // Spin up a bg manager with a sleep-based task so it's actually
        // running when /compact fires.
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-compact-bg-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let bgManager = BackgroundTaskManager(outputDir: outputDir)

        let sleeper = LongLivedRunner(label: "simulate build")
        let (taskId, _) = await bgManager.spawn(runner: sleeper, sessionId: "sess")
        defer { Task { await bgManager.killAll(sessionId: "sess") } }
        // Give spawn a tick so the entry is in the dictionary.
        try await Task.sleep(nanoseconds: 50_000_000)

        let notifier = NotifierBox()
        let commits = CommitBox()
        let ctx = SlashContext(
            agent: agent,
            modal: ModalHost(
                layout: CodingLayout(statusRows: 1),
                restoreTranscript: {},
                requestRender: {}
            ),
            backgroundManager: bgManager,
            sessionId: "sess",
            notifyBlock: { lines in for l in lines { notifier.append(l) } },
            commitScrollback: commits.collect(),
            refreshTranscript: {}
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        await registry.find("compact")?.handler(ctx, "")

        #expect(agent.state.messages.count == 1)
        guard case .user(let recap) = agent.state.messages.first else {
            Issue.record("expected a recap user message")
            return
        }
        let text = recap.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined()
        #expect(text.contains("<previous-session-summary>"))
        #expect(text.contains("<running-background-tasks>"),
                "a task is still running — its id + output path should be in the recap")
        #expect(text.contains(taskId), "task id should appear in the ledger so the next turn can Read its output")
        // The ledger suffix shows up in the scrollback boundary so
        // users can spot compacts that carried running-task state.
        #expect(commits.joined.contains("running-task ledger"))
    }

    @MainActor
    @Test("no ledger section when nothing is running")
    func noLedgerWhenIdle() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("recap"))])

        let messages: [Message] = (0..<4).map { i in
            .user(UserMessage(content: [.text(TextContent(text: "m\(i)"))]))
        }
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            messages: messages
        ))

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-compact-idle-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let bgManager = BackgroundTaskManager(outputDir: outputDir)

        let notifier = NotifierBox()
        let ctx = SlashContext(
            agent: agent,
            modal: ModalHost(
                layout: CodingLayout(statusRows: 1),
                restoreTranscript: {},
                requestRender: {}
            ),
            backgroundManager: bgManager,
            sessionId: "sess",
            notifyBlock: { lines in for l in lines { notifier.append(l) } },
            commitScrollback: { _ in },
            refreshTranscript: {}
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        await registry.find("compact")?.handler(ctx, "")

        guard case .user(let recap) = agent.state.messages.first else {
            Issue.record("expected recap")
            return
        }
        let text = recap.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text } else { return nil }
        }.joined()
        #expect(!text.contains("<running-background-tasks>"),
                "no tasks running — shouldn't bolt on an empty ledger section")
    }
}

@MainActor
private final class NotifierBox {
    private(set) var lines: [String] = []
    func append(_ s: String) { lines.append(s) }
    var joined: String { lines.joined(separator: "\n") }
}

/// Runner that "runs forever" until explicitly killed. Used to keep a
/// bg task in .running state while /compact reads the ledger.
private struct LongLivedRunner: BackgroundTaskRunner {
    let spec: BackgroundTaskSpec

    init(label: String) {
        self.spec = BackgroundTaskSpec(
            kind: "bash",
            label: label,
            description: nil,
            hardTimeoutSeconds: 600
        )
    }

    func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    ) {
        Task.detached {
            // Park until cancelled. No output written; `runningTasksSummary`
            // only needs the task's metadata.
            while !cancellation.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            onDone(BackgroundTaskOutcome(
                success: false,
                summary: "aborted",
                details: nil,
                errorMessage: nil
            ))
        }
    }
}
