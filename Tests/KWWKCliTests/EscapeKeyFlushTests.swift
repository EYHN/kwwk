import Foundation
import Testing
@testable import KWWKCli

/// Regression: a standalone Escape press was being swallowed. `StdinBuffer`
/// correctly holds a lone 0x1B byte waiting for a potential CSI continuation,
/// but `TUIRunner` never invoked `flushOnTimeout`, so Esc-bound handlers
/// (cancel generation, stop bg tasks) never fired. Fix: schedule a
/// short-delay flush after every `ingest` and cancel it on the next input.
@Suite("TUIRunner escape-flush", .serialized)
struct EscapeKeyFlushTests {

    @Test("standalone ESC reaches a keybinding after the flush delay")
    func escDeliveredAfterDelay() async {
        let runner = TUIRunner(useAlternateScreen: false, hideCursor: false)
        let fired = FiredBox()
        runner.bind(.init("escape")) { _ in fired.set() }

        runner.ingest(Data([0x1B]))

        // Immediately after ingest the ESC should still be buffered —
        // otherwise real CSI sequences (arrows, function keys) would get
        // split in half.
        #expect(fired.get() == false)

        // Wait past the flush timer + scheduler jitter. 250ms is generous.
        _ = await waitUntil { fired.get() == true }
        #expect(fired.get() == true, "standalone ESC was never delivered")
    }

    @Test("ESC that prefixes a CSI sequence is NOT flushed as a standalone")
    func csiSequenceNotSplit() async {
        let runner = TUIRunner(useAlternateScreen: false, hideCursor: false)
        let escCount = FiredCounter()
        let upCount = FiredCounter()
        runner.bind(.init("escape")) { _ in escCount.bump() }
        runner.bind(.init("up")) { _ in upCount.bump() }

        // Split arrow-key delivery across two feeds: first the ESC, then
        // the CSI tail. This is how real terminals sometimes chunk it.
        runner.ingest(Data([0x1B]))
        runner.ingest(Data([0x5B, 0x41])) // [A → up

        try? await Task.sleep(nanoseconds: 250_000_000)

        #expect(escCount.get() == 0, "standalone ESC fired even though a CSI tail followed")
        #expect(upCount.get() == 1)
    }

    @Test("two consecutive ESC presses both fire") func doubleEsc() async {
        let runner = TUIRunner(useAlternateScreen: false, hideCursor: false)
        let count = FiredCounter()
        runner.bind(.init("escape")) { _ in count.bump() }

        runner.ingest(Data([0x1B]))
        _ = await waitUntil { count.get() == 1 }
        runner.ingest(Data([0x1B]))
        _ = await waitUntil { count.get() == 2 }

        #expect(count.get() == 2)
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 20_000_000,
    _ predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return predicate()
}

// MARK: - Thread-safe test bookkeeping

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
