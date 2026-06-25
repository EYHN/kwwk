#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Real terminal backed by stdout. Reports the current TTY dimensions via
/// `ioctl(TIOCGWINSZ)` and listens for `SIGWINCH`. Writes are funneled through
/// `FileHandle.standardOutput`.
///
/// This type is intentionally minimal — raw-mode switching, the termios
/// save/restore dance, and the Kitty keyboard protocol opt-in live in a
/// higher-level runner that composes this with the stdin parser.
final class StdoutTerminal: Terminal, @unchecked Sendable {
    private let lock = NSLock()
    private var resizeHandlers: [UUID: @Sendable (Int, Int) -> Void] = [:]
    private var signalSource: DispatchSourceSignal?

    init() {
        installSigwinch()
    }

    var width: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 && ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    var height: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 && ws.ws_row > 0 {
            return Int(ws.ws_row)
        }
        return 24
    }

    func write(_ data: String) {
        guard let bytes = data.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(bytes)
    }

    func onResize(_ handler: @escaping @Sendable (Int, Int) -> Void) -> () -> Void {
        let id = UUID()
        lock.withLock { resizeHandlers[id] = handler }
        return { [weak self] in
            guard let self else { return }
            lock.withLock {
                _ = resizeHandlers.removeValue(forKey: id)
            }
        }
    }

    private func installSigwinch() {
        // Block SIGWINCH from interrupting syscalls; handle via DispatchSource.
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let w = self.width
            let h = self.height
            let handlers = self.lock.withLock { Array(self.resizeHandlers.values) }
            for handler in handlers { handler(w, h) }
        }
        source.resume()
        signalSource = source
    }
}

/// Enter raw mode on stdin and restore on deinit. Provides the file descriptor
/// byte pump the stdin parser consumes. Closing the handle cancels the reader.
final class RawStdin: @unchecked Sendable {
    private var savedTermios: termios
    private let fd: Int32
    private let dispatchSource: DispatchSourceRead

    init(handler: @escaping @Sendable (Data) -> Void) throws {
        self.fd = STDIN_FILENO
        var saved = termios()
        if tcgetattr(fd, &saved) != 0 {
            throw RawStdinError.cannotGetAttr
        }
        self.savedTermios = saved

        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | IEXTEN | ISIG)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cflag |= tcflag_t(CS8)
        if tcsetattr(fd, TCSANOW, &raw) != 0 {
            throw RawStdinError.cannotSetAttr
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n > 0 {
                handler(Data(bytes: buffer, count: n))
            }
        }
        source.resume()
        self.dispatchSource = source
    }

    deinit {
        dispatchSource.cancel()
        _ = tcsetattr(fd, TCSANOW, &savedTermios)
    }
}

enum RawStdinError: Error {
    case cannotGetAttr
    case cannotSetAttr
}
#endif
