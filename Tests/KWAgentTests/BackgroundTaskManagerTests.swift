import Foundation
import Testing
@testable import KWAgent
@testable import KWAI

// MARK: - Test runner

/// Test double that fulfils `BackgroundTaskRunner`. Runs `delayMs` in a
/// detached Task, optionally writes `writeToFile` into the output path
/// before finishing, and then calls `onDone` with the configured outcome
/// (or an "aborted" outcome if cancellation fired first).
struct FauxRunner: BackgroundTaskRunner {
    let spec: BackgroundTaskSpec
    let outcome: BackgroundTaskOutcome
    let delayMs: Int
    let writeToFile: String?

    init(
        kind: String = "faux",
        label: String = "faux-task",
        description: String? = nil,
        hardTimeoutSeconds: Int = 60,
        outcome: BackgroundTaskOutcome = BackgroundTaskOutcome(success: true, summary: "ok"),
        delayMs: Int = 20,
        writeToFile: String? = nil
    ) {
        self.spec = BackgroundTaskSpec(
            kind: kind,
            label: label,
            description: description,
            hardTimeoutSeconds: hardTimeoutSeconds
        )
        self.outcome = outcome
        self.delayMs = delayMs
        self.writeToFile = writeToFile
    }

    func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    ) {
        let outcome = self.outcome
        let delayMs = self.delayMs
        let writeText = self.writeToFile
        Task.detached {
            if let text = writeText {
                _ = try? text.data(using: .utf8)?.write(to: outputFile)
            }
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            if cancellation.isCancelled {
                onDone(BackgroundTaskOutcome(
                    success: false,
                    summary: "aborted",
                    details: nil,
                    errorMessage: nil
                ))
            } else {
                onDone(outcome)
            }
        }
    }
}

/// Runner that loops forever until cancelled. Used for kill / stall tests.
struct ForeverRunner: BackgroundTaskRunner {
    let spec: BackgroundTaskSpec

    init(kind: String = "forever", label: String = "forever") {
        self.spec = BackgroundTaskSpec(kind: kind, label: label, description: nil, hardTimeoutSeconds: 3600)
    }

    func run(
        taskId: String,
        outputFile: URL,
        cancellation: CancellationHandle,
        onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
    ) {
        Task.detached {
            while !cancellation.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            onDone(BackgroundTaskOutcome(success: false, summary: "cancelled"))
        }
    }
}

// MARK: - Test helpers

private func makeOutputDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwbg-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Await a condition, polling every 10ms. Returns true if it held within
/// the budget; false on timeout.
private func awaitUntil(
    _ budgetMs: Int,
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) * 1000 < Double(budgetMs) {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

// MARK: - Suites

@Suite("BackgroundTaskManager")
struct BackgroundTaskManagerTests {

    @Test("spawn + complete enqueues a notification")
    func spawnAndComplete() async {
        let outputDir = makeOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = FauxRunner(
            outcome: BackgroundTaskOutcome(
                success: true,
                summary: "exit 0",
                details: .object(["exitCode": .int(0)]),
                errorMessage: nil
            ),
            delayMs: 20,
            writeToFile: "hello bg\n"
        )
        let (taskId, file) = await manager.spawn(runner: runner, sessionId: "s1")
        _ = file

        let ok = await awaitUntil(2000) { await manager.hasNotifications(sessionId: "s1") }
        #expect(ok)
        let notifs = await manager.drainNotifications(sessionId: "s1")
        #expect(notifs.count == 1)
        let notif = notifs[0]
        #expect(notif.taskId == taskId)
        #expect(notif.status == .completed)
        #expect(notif.stalled == false)
        #expect(notif.outputTail.contains("hello bg"))
        #expect(notif.outputFile?.hasSuffix("\(taskId).log") == true)
        #expect(notif.messageText().contains("<task-notification>"))
    }

    @Test("kill cancels a running task and emits a killed notification")
    func killFlowsThrough() async {
        let outputDir = makeOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let (taskId, _) = await manager.spawn(runner: ForeverRunner(), sessionId: "s1")

        // Let it establish running state.
        try? await Task.sleep(nanoseconds: 30_000_000)
        let snap1 = await manager.get(taskId)
        #expect(snap1?.status == .running)

        try? await manager.kill(taskId)

        let snap2 = await manager.get(taskId)
        #expect(snap2?.status == .killed)

        let ok = await awaitUntil(1000) { await manager.hasNotifications(sessionId: "s1") }
        #expect(ok)
        let notifs = await manager.drainNotifications(sessionId: "s1")
        #expect(notifs.contains { $0.status == .killed && $0.taskId == taskId })
    }

    @Test("list returns snapshots scoped by session")
    func listBySession() async {
        let outputDir = makeOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)

        let (idA, _) = await manager.spawn(runner: FauxRunner(label: "task-a"), sessionId: "sA")
        let (idB, _) = await manager.spawn(runner: FauxRunner(label: "task-b"), sessionId: "sB")

        let allA = await manager.list(sessionId: "sA")
        let allB = await manager.list(sessionId: "sB")
        #expect(allA.map(\.id).contains(idA))
        #expect(!allA.map(\.id).contains(idB))
        #expect(allB.map(\.id).contains(idB))
        #expect(!allB.map(\.id).contains(idA))

        let all = await manager.list(sessionId: nil)
        #expect(all.count >= 2)
    }

    @Test("drainNotifications filters by sessionId")
    func drainFilter() async {
        let outputDir = makeOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)

        _ = await manager.spawn(runner: FauxRunner(label: "a"), sessionId: "alpha")
        _ = await manager.spawn(runner: FauxRunner(label: "b"), sessionId: "beta")

        _ = await awaitUntil(2000) {
            let hasAlpha = await manager.hasNotifications(sessionId: "alpha")
            let hasBeta = await manager.hasNotifications(sessionId: "beta")
            return hasAlpha && hasBeta
        }

        let alpha = await manager.drainNotifications(sessionId: "alpha")
        #expect(alpha.count == 1)
        #expect(alpha[0].label == "a")

        // Alpha drain should not have touched beta.
        let beta = await manager.drainNotifications(sessionId: "beta")
        #expect(beta.count == 1)
        #expect(beta[0].label == "b")
    }

    @Test("subscriber receives notifications")
    func subscriber() async {
        let outputDir = makeOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)

        let received = Received()
        let handle = await manager.onNotification { notif in
            await received.add(notif)
        }
        _ = await manager.spawn(runner: FauxRunner(label: "sub"), sessionId: "s1")

        _ = await awaitUntil(2000) {
            await received.count() >= 1
        }
        let all = await received.all()
        #expect(all.count == 1)
        #expect(all[0].label == "sub")

        await handle.unsubscribe()
    }

    @Test("runningTasksSummary lists only running tasks")
    func runningSummary() async {
        let outputDir = makeOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)

        _ = await manager.spawn(runner: ForeverRunner(label: "long"), sessionId: "s1")
        try? await Task.sleep(nanoseconds: 30_000_000)

        let summary = await manager.runningTasksSummary(sessionId: "s1")
        #expect(summary.contains("long"))
        #expect(summary.contains("bg_"))

        let noneSummary = await manager.runningTasksSummary(sessionId: "other")
        #expect(noneSummary.isEmpty)
    }

    @Test("stall watchdog fires when output stops growing and tail looks like a prompt")
    func stallWatchdog() async {
        let outputDir = makeOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        // Squeeze the watchdog timing so the test runs in under a second.
        await manager.setStallTiming(intervalSeconds: 1, thresholdSeconds: 0.05)

        // Runner writes a prompt-shaped tail, then holds the pane forever so
        // no new output arrives — simulating a command stuck on interactive
        // input.
        struct PromptRunner: BackgroundTaskRunner {
            let spec = BackgroundTaskSpec(kind: "test", label: "prompt", description: nil, hardTimeoutSeconds: 60)
            func run(
                taskId: String,
                outputFile: URL,
                cancellation: CancellationHandle,
                onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
            ) {
                Task.detached {
                    _ = try? "waiting...\nContinue?".data(using: .utf8)?.write(to: outputFile)
                    while !cancellation.isCancelled {
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    onDone(BackgroundTaskOutcome(success: false, summary: "cancelled"))
                }
            }
        }
        let (taskId, _) = await manager.spawn(runner: PromptRunner(), sessionId: "s1")

        let ok = await awaitUntil(3000) {
            await manager.hasNotifications(sessionId: "s1")
        }
        #expect(ok)
        let notifs = await manager.drainNotifications(sessionId: "s1")
        #expect(notifs.contains { $0.stalled && $0.taskId == taskId })

        try? await manager.kill(taskId)
    }

    @Test("looksLikePrompt matches common prompt shapes")
    func promptRegex() {
        #expect(BackgroundTaskManager.looksLikePrompt("blah (y/n) "))
        #expect(BackgroundTaskManager.looksLikePrompt("Are you sure?"))
        #expect(BackgroundTaskManager.looksLikePrompt("Press any key to continue"))
        #expect(BackgroundTaskManager.looksLikePrompt("Password: "))
        #expect(BackgroundTaskManager.looksLikePrompt("building foo\nContinue?"))
        #expect(BackgroundTaskManager.looksLikePrompt("foo\nbar\nOverwrite?"))
        #expect(!BackgroundTaskManager.looksLikePrompt("just some output"))
        #expect(!BackgroundTaskManager.looksLikePrompt("compile error: cannot find symbol"))
    }

    @Test("notification messageText includes output-file and kind")
    func messageTextShape() async {
        let outputDir = makeOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let runner = FauxRunner(
            kind: "bash",
            label: "echo hi",
            outcome: BackgroundTaskOutcome(
                success: true,
                summary: "exit 0",
                details: .object(["exitCode": .int(0)]),
                errorMessage: nil
            ),
            delayMs: 10,
            writeToFile: "hi\n"
        )
        _ = await manager.spawn(runner: runner, sessionId: "s1")
        _ = await awaitUntil(1000) { await manager.hasNotifications(sessionId: "s1") }
        let n = await manager.drainNotifications(sessionId: "s1").first!
        let text = n.messageText()
        #expect(text.contains("<task-notification>"))
        #expect(text.contains("<kind>bash</kind>"))
        #expect(text.contains("<label>echo hi</label>"))
        #expect(text.contains("<output-file>"))
        #expect(text.contains("<exit-code>0</exit-code>"))
        #expect(text.contains("<hint>"))
    }
}

// MARK: - Internal test helpers

/// Expose a timing override so the stall watchdog can be squeezed to run in
/// under a second during tests.
extension BackgroundTaskManager {
    func setStallTiming(intervalSeconds: UInt64, thresholdSeconds: Double) {
        self.stallCheckIntervalSeconds = intervalSeconds
        self.stallThresholdSeconds = thresholdSeconds
    }
}

actor Received {
    private var items: [BackgroundTaskNotification] = []
    func add(_ n: BackgroundTaskNotification) { items.append(n) }
    func count() -> Int { items.count }
    func all() -> [BackgroundTaskNotification] { items }
}
