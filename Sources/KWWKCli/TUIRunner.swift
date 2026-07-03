#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// High-level wrapper that plugs `StdoutTerminal` + `RawStdin` into a TUI.
/// Handles signal-based shutdown (Ctrl-C, SIGTERM), input dispatch to the
/// focused component, and keybinding lookup.
///
/// Runs under Swift's async main (`@main struct` / `func main() async throws`).
/// `run()` is itself async and suspends until `exit()` is called or a signal
/// tears the runner down.
final class TUIRunner: @unchecked Sendable {
    typealias EscapeFlushScheduler = @Sendable (_ delayMs: Int, _ work: DispatchWorkItem) -> Void

    let terminal: StdoutTerminal
    let tui: TUI
    let keybindings: KeybindingRegistry
    private let lock = NSLock()
    private var stdin: RawStdin?
    private var stdinBuffer = StdinBuffer()
    private var focused: Component?
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var exitContinuation: CheckedContinuation<Void, Never>?
    private var pendingExitCode: Int32?
    private let escapeFlushScheduler: EscapeFlushScheduler
    /// Pending flush for a buffered standalone ESC. `StdinBuffer` holds a
    /// lone 0x1B byte waiting for a potential CSI continuation (arrow keys,
    /// function keys, etc.). If no continuation arrives we must flush it
    /// manually — otherwise an isolated Escape press is swallowed forever
    /// and keybindings like "cancel" never fire. See the escape-dispatch
    /// scheduling in `ingest`.
    private var pendingEscapeFlush: DispatchWorkItem?
    /// Delay before a buffered ESC is treated as a standalone press. 50ms
    /// is well under a user's key-repeat threshold and safely above the
    /// ~1ms it takes a terminal to deliver the full CSI sequence for arrow
    /// keys / function keys.
    private static let escapeFlushDelayMs: Int = 50

    init(
        escapeFlushScheduler: EscapeFlushScheduler? = nil
    ) {
        self.terminal = StdoutTerminal()
        self.tui = TUI(terminal: terminal)
        self.keybindings = KeybindingRegistry()
        // Main-confinement invariant: all rendering happens on the main
        // queue. The stdin read source, SIGWINCH, and the spinner tick are
        // already main-confined, so the escape flush must be too — its work
        // item runs handleSequences → requestRender → terminal.write, which
        // would corrupt the frame if it raced a main-thread render. `main`
        // (not `global`) keeps every render path serialized on one queue.
        // `asyncAfter` is non-blocking, so scheduling from the main queue
        // introduces no reentrancy or deadlock. The scheduler stays injectable
        // so tests can drive the timer synchronously.
        self.escapeFlushScheduler = escapeFlushScheduler ?? { delayMs, work in
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delayMs),
                execute: work
            )
        }
    }

    func focus(_ component: Component) {
        lock.withLock { focused = component }
        if let f = component as? Focusable {
            f.focused = true
        }
    }

    func bind(_ binding: KeyBinding, _ handler: @escaping @Sendable (KeyEvent) -> Void) {
        keybindings.bind(binding, handler)
    }

    /// Start the TUI and suspend until `exit()` runs. Designed to be called
    /// from an async main.
    func run() async throws {
        try installSignalHandlers()
        tui.start()
        // Enable DECSET 2004 — bracketed paste mode. The terminal now
        // wraps every paste in `ESC[200~ … ESC[201~` so we can tell a
        // 200-byte paste apart from 200 individual keypresses. Disabled
        // again in `tearDown()` so the user's shell isn't left in an
        // unexpected mode after `kwwk` exits.
        terminal.write("\u{1B}[?2004h")
        // Opt into the Kitty keyboard protocol so modified Enter arrives
        // as CSI-u (`ESC [ 13 ; <mod> u`). Without this, most terminals
        // collapse Shift+Enter into plain Enter, which means the input box
        // can only rely on raw LF / Ctrl+J for newline insertion.
        terminal.write("\u{1B}[>1u")
        try installStdin()
        await waitForExit()
        tearDown()
        let code = lock.withLock { pendingExitCode } ?? 0
        if code != 0 {
            Foundation.exit(code)
        }
    }

    /// Request a clean shutdown. Safe from signal handlers and keybinding
    /// closures; the actual terminal restore happens when `run()` resumes
    /// from its suspension point.
    func exit(code: Int32 = 0) {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            pendingExitCode = code
            let c = exitContinuation
            exitContinuation = nil
            return c
        }
        cont?.resume()
    }

    /// Hand the terminal back for a sub-flow that runs on a cooked terminal
    /// (the `/login` OAuth handoff: stderr progress plus a cbreak `RawStdin`
    /// watcher that maps Esc/Ctrl-C to cancellation — see `runOAuthFlow`).
    /// Drops raw stdin (restoring cooked termios via `RawStdin.deinit`),
    /// leaves the input modes, stops the frame, and cancels this runner's
    /// signal sources. SIGINT stays SIG_IGN for the whole suspension — no
    /// other runner takes it over; cancellation comes from the sub-flow's
    /// stdin watcher. Pair with `resume()`.
    func suspend() {
        terminal.write("\u{1B}[?2004l")
        terminal.write("\u{1B}[<u")
        // Erase the live zone (input box + status) before handing over: the
        // sub-flow renders where the frame stood, and `resume()` repaints a
        // fresh frame below its output. Leaving the old frame on screen would
        // freeze it into scrollback as a duplicate input box.
        tui.clearFrame()
        tui.stop()
        lock.withLock {
            sigintSource?.cancel()
            sigtermSource?.cancel()
            sigintSource = nil
            sigtermSource = nil
            pendingEscapeFlush?.cancel()
            pendingEscapeFlush = nil
            stdin = nil     // triggers RawStdin deinit → restores termios
        }
    }

    /// Re-acquire the terminal after `suspend()`: reinstall signal handling
    /// and raw stdin, re-enable bracketed paste + Kitty keyboard modes, and
    /// repaint the frame with a fresh anchor. The geometry reset MUST happen
    /// before `start()` (whose own render would otherwise rewind over the
    /// sub-flow's output using the stale pre-suspend live-zone height).
    func resume() throws {
        try installSignalHandlers()
        tui.resetFrameGeometryForResume()
        tui.start()
        terminal.write("\u{1B}[?2004h")
        terminal.write("\u{1B}[>1u")
        try installStdin()
        tui.requestRender()
    }

    // MARK: - Lifecycle helpers

    private func installSignalHandlers() throws {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in self?.exit(code: 130) }
        sigint.resume()
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in self?.exit(code: 143) }
        sigterm.resume()
        lock.withLock {
            sigintSource = sigint
            sigtermSource = sigterm
        }
    }

    private func installStdin() throws {
        let stdin = try RawStdin { [weak self] data in
            self?.ingest(data)
        }
        lock.withLock { self.stdin = stdin }
    }

    private func waitForExit() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResume: Bool = lock.withLock {
                if pendingExitCode != nil { return true }
                exitContinuation = cont
                return false
            }
            if shouldResume { cont.resume() }
        }
    }

    private func tearDown() {
        // Disable bracketed paste mode before we give the terminal back
        // to the shell; otherwise iTerm / Ghostty keep wrapping pastes
        // and the shell prompt sees the 200~/201~ bytes as literal
        // text.
        terminal.write("\u{1B}[?2004l")
        // Leave Kitty keyboard protocol mode so the parent shell / app
        // regains its default Enter handling.
        terminal.write("\u{1B}[<u")
        tui.stop()
        lock.withLock {
            sigintSource?.cancel()
            sigtermSource?.cancel()
            sigintSource = nil
            sigtermSource = nil
            stdin = nil     // triggers RawStdin deinit → restores termios
        }
    }

    // MARK: - Input routing

    /// Feed a raw stdin chunk into the input pipeline. Normally invoked by
    /// `RawStdin`'s callback, but made internal so tests can drive the
    /// escape-flush timer without setting up real termios.
    func ingest(_ data: Data) {
        // Cancel any pending ESC flush — new data arrived, so the ESC is
        // either part of a CSI sequence (handled by `takeOne`) or irrelevant
        // (user kept typing). Either way, don't flush it as a standalone.
        lock.withLock {
            pendingEscapeFlush?.cancel()
            pendingEscapeFlush = nil
        }
        handleSequences(stdinBuffer.feed(data))
        scheduleEscapeFlushIfNeeded()
    }

    private func handleSequences(_ sequences: [String]) {
        for seq in sequences {
            if let event = Keys.parse(seq), keybindings.dispatch(event) {
                tui.requestRender()
                continue
            }
            let target: Component? = lock.withLock { focused }
            target?.handleInput(seq)
            tui.requestRender()
        }
    }

    /// If the stdin buffer currently holds an undelivered byte stream
    /// (e.g. a standalone ESC waiting to see whether it starts a CSI
    /// sequence), schedule a short-delay flush. Cancelled on the next
    /// `ingest` so real escape sequences aren't split.
    private func scheduleEscapeFlushIfNeeded() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let flushed = self.stdinBuffer.flushOnTimeout()
            if !flushed.isEmpty {
                self.handleSequences(flushed)
            }
        }
        lock.withLock { pendingEscapeFlush = work }
        escapeFlushScheduler(Self.escapeFlushDelayMs, work)
    }
}
#endif
