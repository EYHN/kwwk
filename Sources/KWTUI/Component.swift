import Foundation

/// Base component protocol. All components render themselves into fixed-width
/// lines and optionally consume keyboard input while focused. Mirrors pi-tui's
/// `Component` interface.
public protocol Component: AnyObject, Sendable {
    /// Render to line strings for the given viewport width. Each returned
    /// string MUST have a visible width ≤ `width`.
    func render(width: Int) -> [String]

    /// Handle raw input when this component is focused. Default: no-op.
    func handleInput(_ data: String)

    /// Drop any cached render state so the next render recomputes.
    func invalidate()

    /// When true, key-release events are delivered (Kitty keyboard protocol).
    var wantsKeyRelease: Bool { get }
}

public extension Component {
    func handleInput(_ data: String) {}
    func invalidate() {}
    var wantsKeyRelease: Bool { false }
}

/// Components that render the hardware cursor must conform to this and emit
/// the zero-width `CURSOR_MARKER` sequence at the cursor position. TUI strips
/// the marker and positions the hardware cursor for IME support.
public protocol Focusable: AnyObject, Sendable {
    var focused: Bool { get set }
}

/// Zero-width APC escape sequence used to mark the hardware cursor position
/// in a component's rendered output.
public let CURSOR_MARKER = "\u{1b}_pi:c\u{7}"

/// Simple container that stacks child components vertically.
///
/// All UI components in this framework mutate only from the main dispatch
/// queue (where stdin/resize handlers land). We conform to `Sendable` via
/// `@unchecked` so they can be captured freely from `@Sendable` closures
/// (runner callbacks, keybinding handlers). Callers should respect the
/// main-thread contract — do not mutate from background tasks.
public final class Container: Component, @unchecked Sendable {
    public private(set) var children: [Component] = []

    public init() {}

    public func addChild(_ component: Component) {
        children.append(component)
    }

    public func removeChild(_ component: Component) {
        children.removeAll { $0 === component }
    }

    public func clear() {
        children.removeAll()
    }

    public func render(width: Int) -> [String] {
        var lines: [String] = []
        for child in children {
            lines.append(contentsOf: child.render(width: width))
        }
        return lines
    }

    public func invalidate() {
        for child in children { child.invalidate() }
    }
}

/// Simple text component — renders its lines directly, truncating to the
/// viewport width (ANSI-aware) and caching results per (text, width,
/// maxLines). When `maxLines` is set, only the last N lines are rendered —
/// useful for scrollback panes that should always show the tail.
public final class TextComponent: Component, @unchecked Sendable {
    public var lines: [String]
    /// If non-nil, clip output to the last `maxLines` entries.
    public var maxLines: Int?

    private var cachedWidth: Int?
    private var cachedMaxLines: Int?
    private var cachedOutput: [String]?
    private var cachedSource: [String]?

    public init(_ lines: [String] = [], maxLines: Int? = nil) {
        self.lines = lines
        self.maxLines = maxLines
    }

    public convenience init(_ line: String) {
        self.init([line])
    }

    public func render(width: Int) -> [String] {
        if let cachedOutput,
           cachedWidth == width,
           cachedMaxLines == maxLines,
           cachedSource == lines {
            return cachedOutput
        }
        let slice: [String] = {
            guard let n = maxLines, lines.count > n else { return lines }
            return Array(lines.suffix(n))
        }()
        let output = slice.map { ANSI.truncate($0, to: width) }
        cachedOutput = output
        cachedWidth = width
        cachedMaxLines = maxLines
        cachedSource = lines
        return output
    }

    public func invalidate() {
        cachedOutput = nil
        cachedWidth = nil
        cachedMaxLines = nil
        cachedSource = nil
    }
}

/// Horizontal rule — renders as a single line made of `character` repeated to
/// the viewport width. Reacts automatically to resize.
public final class HorizontalRule: Component, @unchecked Sendable {
    public var character: Character
    public init(_ character: Character = "─") {
        self.character = character
    }
    public func render(width: Int) -> [String] {
        [String(repeating: String(character), count: max(0, width))]
    }
    public func invalidate() {}
}
