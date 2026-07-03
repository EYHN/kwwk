import Foundation
import Testing
@testable import KWWKCli

/// Regression: a standalone Escape press was being swallowed. `StdinBuffer`
/// correctly holds a lone 0x1B byte waiting for a potential CSI continuation,
/// but `TUIRunner` never invoked `flushOnTimeout`, so Esc-bound handlers
/// (cancel generation, stop bg tasks) never fired. Fix: schedule a
/// short-delay flush after every `ingest` and cancel it on the next input.
@Suite("TUIRunner escape-flush")
struct EscapeKeyFlushTests {

    @Test("standalone ESC reaches a keybinding after the flush delay")
    func escDeliveredAfterDelay() async {
        let scheduler = ManualEscapeFlushScheduler()
        let runner = TUIRunner(
            escapeFlushScheduler: scheduler.schedule
        )
        let fired = FiredBox()
        runner.bind(.init("escape")) { _ in fired.set() }

        runner.ingest(Data([0x1B]))

        // Immediately after ingest the ESC should still be buffered —
        // otherwise real CSI sequences (arrows, function keys) would get
        // split in half.
        #expect(fired.get() == false)

        scheduler.runPending()
        #expect(fired.get() == true, "standalone ESC was never delivered")
    }

    @Test("ESC that prefixes a CSI sequence is NOT flushed as a standalone")
    func csiSequenceNotSplit() async {
        let scheduler = ManualEscapeFlushScheduler()
        let runner = TUIRunner(
            escapeFlushScheduler: scheduler.schedule
        )
        let escCount = FiredCounter()
        let upCount = FiredCounter()
        runner.bind(.init("escape")) { _ in escCount.bump() }
        runner.bind(.init("up")) { _ in upCount.bump() }

        // Split arrow-key delivery across two feeds: first the ESC, then
        // the CSI tail. This is how real terminals sometimes chunk it.
        runner.ingest(Data([0x1B]))
        runner.ingest(Data([0x5B, 0x41])) // [A → up

        scheduler.runPending()

        #expect(escCount.get() == 0, "standalone ESC fired even though a CSI tail followed")
        #expect(upCount.get() == 1)
    }

    @Test("two consecutive ESC presses both fire") func doubleEsc() async {
        let scheduler = ManualEscapeFlushScheduler()
        let runner = TUIRunner(
            escapeFlushScheduler: scheduler.schedule
        )
        let count = FiredCounter()
        runner.bind(.init("escape")) { _ in count.bump() }

        runner.ingest(Data([0x1B]))
        scheduler.runPending()
        runner.ingest(Data([0x1B]))
        scheduler.runPending()

        #expect(count.get() == 2)
    }
}

// MARK: - Thread-safe test bookkeeping

private final class ManualEscapeFlushScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    func schedule(_: Int, _ work: DispatchWorkItem) {
        lock.withLock { pending = work }
    }

    func runPending() {
        let work: DispatchWorkItem? = lock.withLock {
            let work = pending
            pending = nil
            return work
        }
        guard let work, !work.isCancelled else { return }
        work.perform()
    }
}

private final class FiredBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func set() { lock.withLock { fired = true } }
    func get() -> Bool { lock.withLock { fired } }
}

private final class FiredCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    func get() -> Int { lock.withLock { n } }
}
