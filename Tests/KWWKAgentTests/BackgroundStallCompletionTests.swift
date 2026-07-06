import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// A stall notification is a non-terminal heads-up: it must NOT suppress the
/// task's eventual completion notification. Regression guard for the bug where
/// the shared `notified` flag let a stall swallow the completion the tool
/// documents ("you will be notified on completion").
@Suite("Stall does not suppress completion", .serialized)
struct BackgroundStallCompletionTests {
    /// Lets the test release the runner once the stall has been observed.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        var isOpen: Bool { lock.withLock { open } }
        func openGate() { lock.withLock { open = true } }
    }

    @Test("a stuck-then-finished task yields both a stall and a completion")
    func stallThenComplete() async {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let stallInterval: UInt64 = ProcessInfo.processInfo.environment["CI"] != nil ? 2 : 1
        await manager.setStallTiming(intervalSeconds: stallInterval, thresholdSeconds: 0.05)

        let received = Received()
        _ = await manager.onNotification { n in await received.add(n) }

        let gate = Gate()
        struct StuckThenDoneRunner: BackgroundTaskRunner {
            let spec = BackgroundTaskSpec(kind: "test", label: "stuck", description: nil, hardTimeoutSeconds: 60)
            let gate: Gate
            func run(
                taskId: String,
                outputFile: URL,
                cancellation: CancellationHandle,
                onDone: @escaping @Sendable (BackgroundTaskOutcome) -> Void
            ) {
                let gate = self.gate
                Task.detached {
                    // Prompt-shaped tail that never grows → looks stalled.
                    _ = try? "waiting...\nContinue?".data(using: .utf8)?.write(to: outputFile)
                    while !gate.isOpen && !cancellation.isCancelled {
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    onDone(BackgroundTaskOutcome(success: true, summary: "exit 0"))
                }
            }
        }
        let (taskId, _) = await manager.spawn(runner: StuckThenDoneRunner(gate: gate), sessionId: "s1")

        // 1) Stall fires first.
        let stalled = await awaitUntil(8000) {
            await received.all().contains { $0.taskId == taskId && $0.stalled }
        }
        #expect(stalled)

        // 2) Release the runner; the completion must still be delivered.
        gate.openGate()
        let completed = await awaitUntil(8000) {
            await received.all().contains { $0.taskId == taskId && !$0.stalled && $0.status == .completed }
        }
        #expect(completed)
    }
}
