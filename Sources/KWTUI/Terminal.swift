import Foundation

/// Thin abstraction over a terminal-like sink. Real runs connect this to
/// stdout; tests connect it to `VirtualTerminal`.
public protocol Terminal: AnyObject, Sendable {
    var width: Int { get }
    var height: Int { get }
    /// Write raw bytes (ANSI-escaped) to the terminal.
    func write(_ data: String)
    /// Register a listener for resize events. Returns an unsubscribe closure.
    func onResize(_ handler: @escaping @Sendable (Int, Int) -> Void) -> () -> Void
}
