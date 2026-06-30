import Foundation

/// Parsed keyboard event. Matches a subset of pi-tui's `keys.ts` — sufficient
/// for the canonical bindings tests exercise.
struct KeyEvent: Sendable, Hashable {
    var name: String       // "a", "enter", "up", "f1", etc.
    var shift: Bool
    var ctrl: Bool
    var alt: Bool
    var raw: String        // The original byte sequence (for paste passthrough).

    init(name: String, shift: Bool = false, ctrl: Bool = false, alt: Bool = false, raw: String = "") {
        self.name = name
        self.shift = shift
        self.ctrl = ctrl
        self.alt = alt
        self.raw = raw
    }
}

enum Keys {

    // MARK: - Byte-level parsing

    /// Parse a single completed key sequence. Returns nil if the sequence is
    /// unrecognized. The parser handles the legacy CSI subset we actually use.
    static func parse(_ data: String) -> KeyEvent? {
        if data.isEmpty { return nil }
        let bytes = Array(data.utf8)
        // Control characters and printable text.
        if bytes.count == 1 {
            let b = bytes[0]
            switch b {
            case 0x0D: return KeyEvent(name: "enter", raw: data)
            // 0x0A (LF) is ASCII Ctrl+J. Historically some terminals
            // ship it when the user presses Enter, but modern *nix
            // terminals always send CR (0x0D) for Enter; a raw LF on
            // stdin today means the user actually hit Ctrl+J (or
            // Return was interpreted by a keyboard protocol that
            // distinguishes newline from carriage return). Surface it
            // as Ctrl+J so multi-line editors can pick it up as
            // "insert newline" while plain Enter stays free for submit.
            case 0x0A: return KeyEvent(name: "j", ctrl: true, raw: data)
            case 0x09: return KeyEvent(name: "tab", raw: data)
            case 0x7F: return KeyEvent(name: "backspace", raw: data)
            case 0x20: return KeyEvent(name: "space", raw: data)
            case 0x1B: return KeyEvent(name: "escape", raw: data)
            case 0x01...0x1A:
                // Ctrl+letter
                let letter = Character(UnicodeScalar(b + 0x60))
                return KeyEvent(name: String(letter), ctrl: true, raw: data)
            case 0x1F:
                // Ctrl+_ (US, unit separator). Also emitted by Ctrl+/ on many
                // terminals. Surfaced as a named control so the editor can
                // bind it to undo.
                return KeyEvent(name: "_", ctrl: true, raw: data)
            default:
                let scalar = UnicodeScalar(b)
                let char = Character(scalar)
                return KeyEvent(
                    name: String(char).lowercased(),
                    shift: String(char) != String(char).lowercased(),
                    raw: data
                )
            }
        }
        // ESC-prefixed sequences — CSI, SS3, or alt+<x>.
        if bytes[0] == 0x1B {
            // Meta-prefixed sequence: `ESC ESC …` (Option+Arrow on terminals
            // using "Option as Meta"). Parse the inner sequence and flag it
            // alt-modified.
            if bytes.count >= 3, bytes[1] == 0x1B {
                let inner = String(decoding: bytes[1...], as: UTF8.self)
                guard var ev = parse(inner) else { return nil }
                ev.alt = true
                ev.raw = data
                return ev
            }
            if bytes.count == 2 {
                // ESC + single-byte keypress = Alt-modified version of
                // that key. Translate common control bytes to their
                // logical names before falling back to the raw char.
                switch bytes[1] {
                case 0x0D, 0x0A:
                    return KeyEvent(name: "enter", alt: true, raw: data)
                case 0x09:
                    return KeyEvent(name: "tab", alt: true, raw: data)
                case 0x7F:
                    return KeyEvent(name: "backspace", alt: true, raw: data)
                default:
                    let scalar = UnicodeScalar(bytes[1])
                    return KeyEvent(
                        name: String(Character(scalar)).lowercased(),
                        alt: true,
                        raw: data
                    )
                }
            }
            if bytes[1] == 0x5B {  // '['
                let tail = String(data.dropFirst(2))
                return parseCSI(tail, raw: data)
            }
            if bytes[1] == 0x4F {  // 'O' (SS3)
                let code = String(data.dropFirst(2))
                switch code {
                case "A": return KeyEvent(name: "up", raw: data)
                case "B": return KeyEvent(name: "down", raw: data)
                case "C": return KeyEvent(name: "right", raw: data)
                case "D": return KeyEvent(name: "left", raw: data)
                default: return nil
                }
            }
        }
        return nil
    }

    private static func parseCSI(_ tail: String, raw: String) -> KeyEvent? {
        guard let final = tail.last else { return nil }
        let params = String(tail.dropLast())
        // Final byte determines the base key.
        let base: String?
        switch final {
        case "A": base = "up"
        case "B": base = "down"
        case "C": base = "right"
        case "D": base = "left"
        case "H": base = "home"
        case "F": base = "end"
        case "P": base = "f1"
        case "Q": base = "f2"
        case "R": base = "f3"
        case "S": base = "f4"
        case "Z": base = "tab"
        case "u":
            // Kitty keyboard protocol: CSI <keycode> ; <mod> u
            let parts = params.split(separator: ";")
            guard let code = Int(parts.first.map(String.init) ?? "") else {
                return nil
            }
            base = kittyKeyName(for: code)
            if base == nil { return nil }
        case "~":
            base = Keys.tildeKey(params)
        default: base = nil
        }
        guard let name = base else { return nil }
        // Modifiers come through `1;<mod>` encoding (xterm). Also CSI Z = shift+tab.
        var ctrl = false, alt = false, shift = false
        if final == "Z" { shift = true }
        let parts = params.split(separator: ";")
        if parts.count >= 2, let mod = Int(parts[1]) {
            // 1-based modifier encoding: 2 shift, 3 alt, 4 alt+shift, 5 ctrl, etc.
            let m = mod - 1
            shift = shift || (m & 1) != 0
            alt = alt || (m & 2) != 0
            ctrl = ctrl || (m & 4) != 0
        }
        return KeyEvent(name: name, shift: shift, ctrl: ctrl, alt: alt, raw: raw)
    }

    private static func kittyKeyName(for code: Int) -> String? {
        switch code {
        case 9: return "tab"
        case 13: return "enter"
        case 27: return "escape"
        case 32: return "space"
        case 127: return "backspace"
        case 97...122:
            return String(UnicodeScalar(code)!)
        case 65...90:
            return String(UnicodeScalar(code)!).lowercased()
        default:
            return nil
        }
    }

    private static func tildeKey(_ params: String) -> String? {
        let code = Int(params.split(separator: ";").first.map(String.init) ?? params)
        switch code {
        case 1, 7: return "home"
        case 2: return "insert"
        case 3: return "delete"
        case 4, 8: return "end"
        case 5: return "pageup"
        case 6: return "pagedown"
        case 11: return "f1"
        case 12: return "f2"
        case 13: return "f3"
        case 14: return "f4"
        case 15: return "f5"
        case 17: return "f6"
        case 18: return "f7"
        case 19: return "f8"
        case 20: return "f9"
        case 21: return "f10"
        case 23: return "f11"
        case 24: return "f12"
        default: return nil
        }
    }
}

// MARK: - Keybinding API

/// A chorded keybinding specification. `KeyBinding.match(...)` returns true
/// when the given KeyEvent satisfies every required modifier + name.
struct KeyBinding: Sendable, Hashable {
    var name: String
    var ctrl: Bool
    var alt: Bool
    var shift: Bool

    init(_ name: String, ctrl: Bool = false, alt: Bool = false, shift: Bool = false) {
        self.name = name
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
    }

    static func ctrl(_ name: String) -> KeyBinding { .init(name, ctrl: true) }
    static func alt(_ name: String) -> KeyBinding { .init(name, alt: true) }
    static func shift(_ name: String) -> KeyBinding { .init(name, shift: true) }

    func matches(_ event: KeyEvent) -> Bool {
        event.name == name
            && event.ctrl == ctrl
            && event.alt == alt
            && event.shift == shift
    }
}

/// Registry mapping a binding to a handler. Handlers run in registration
/// order; the first handler whose binding matches wins. Returns true if any
/// handler fired — callers use this to short-circuit input propagation.
final class KeybindingRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(binding: KeyBinding, handler: @Sendable (KeyEvent) -> Void)] = []

    init() {}

    func bind(_ binding: KeyBinding, _ handler: @escaping @Sendable (KeyEvent) -> Void) {
        lock.withLock { entries.append((binding, handler)) }
    }

    @discardableResult
    func dispatch(_ event: KeyEvent) -> Bool {
        let snapshot = lock.withLock { entries }
        for entry in snapshot where entry.binding.matches(event) {
            entry.handler(event)
            return true
        }
        return false
    }
}
