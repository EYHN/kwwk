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
public final class TUIRunner: @unchecked Sendable {
    public let terminal: StdoutTerminal
    public let tui: TUI
    public let keybindings: KeybindingRegistry
    private let lock = NSLock()
    private var stdin: RawStdin?
    private var stdinBuffer = StdinBuffer()
    private var focused: Component?
    private var onExit: (@Sendable () -> Void)?
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var exitContinuation: CheckedContinuation<Void, Never>?
    private var pendingExitCode: Int32?

    public init(useAlternateScreen: Bool = true, hideCursor: Bool = false) {
        self.terminal = StdoutTerminal()
        self.tui = TUI(terminal: terminal)
        self.keybindings = KeybindingRegistry()
        tui.setUseAlternateScreen(useAlternateScreen)
        tui.setHideCursor(hideCursor)
    }

    public func focus(_ component: Component) {
        lock.withLock { focused = component }
        if let f = component as? Focusable {
            f.focused = true
        }
    }

    public func bind(_ binding: KeyBinding, _ handler: @escaping @Sendable (KeyEvent) -> Void) {
        keybindings.bind(binding, handler)
    }

    public func setOnExit(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onExit = handler }
    }

    /// Start the TUI and suspend until `exit()` runs. Designed to be called
    /// from an async main.
    public func run() async throws {
        try installSignalHandlers()
        tui.start()
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
    public func exit(code: Int32 = 0) {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            pendingExitCode = code
            let c = exitContinuation
            exitContinuation = nil
            return c
        }
        cont?.resume()
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
        tui.stop()
        lock.withLock {
            sigintSource?.cancel()
            sigtermSource?.cancel()
            sigintSource = nil
            sigtermSource = nil
            stdin = nil     // triggers RawStdin deinit → restores termios
            onExit?()
        }
    }

    // MARK: - Input routing

    private func ingest(_ data: Data) {
        let sequences = stdinBuffer.feed(data)
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
}
#endif
