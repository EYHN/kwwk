import Foundation
import Testing
@testable import KWTUI

@Suite("Keys parser")
struct KeysTests {
    @Test("parses plain letters") func letters() {
        #expect(Keys.parse("a")?.name == "a")
        let upper = Keys.parse("A")
        #expect(upper?.name == "a")
        #expect(upper?.shift == true)
    }

    @Test("parses control bindings") func controls() {
        #expect(Keys.parse("\u{01}") == KeyEvent(name: "a", ctrl: true, raw: "\u{01}"))
        #expect(Keys.parse("\u{0C}") == KeyEvent(name: "l", ctrl: true, raw: "\u{0C}"))
    }

    @Test("parses arrow keys") func arrows() {
        #expect(Keys.parse("\u{1B}[A")?.name == "up")
        #expect(Keys.parse("\u{1B}[B")?.name == "down")
        #expect(Keys.parse("\u{1B}[C")?.name == "right")
        #expect(Keys.parse("\u{1B}[D")?.name == "left")
    }

    @Test("parses modifier-prefixed arrows") func modifierArrows() {
        let shiftRight = Keys.parse("\u{1B}[1;2C")
        #expect(shiftRight?.name == "right")
        #expect(shiftRight?.shift == true)
        let ctrlLeft = Keys.parse("\u{1B}[1;5D")
        #expect(ctrlLeft?.ctrl == true)
    }

    @Test("parses function keys via tildes") func functionKeys() {
        #expect(Keys.parse("\u{1B}[15~")?.name == "f5")
        #expect(Keys.parse("\u{1B}[3~")?.name == "delete")
    }

    @Test("parses special keys") func specials() {
        #expect(Keys.parse("\u{0D}")?.name == "enter")
        #expect(Keys.parse("\u{7F}")?.name == "backspace")
        #expect(Keys.parse("\u{1B}")?.name == "escape")
    }
}

@Suite("Keybinding registry")
struct KeybindingRegistryTests {
    @Test("dispatches the first matching binding") func dispatch() {
        let registry = KeybindingRegistry()
        let fired = FireBox()
        registry.bind(.ctrl("c")) { _ in fired.set("ctrl-c") }
        registry.bind(.init("enter")) { _ in fired.set("enter") }
        #expect(registry.dispatch(KeyEvent(name: "c", ctrl: true)) == true)
        #expect(fired.value == "ctrl-c")
        #expect(registry.dispatch(KeyEvent(name: "enter")) == true)
        #expect(fired.value == "enter")
    }

    @Test("returns false when no binding matches") func noMatch() {
        let registry = KeybindingRegistry()
        registry.bind(.ctrl("c")) { _ in }
        #expect(registry.dispatch(KeyEvent(name: "a")) == false)
    }
}

final class FireBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: String = ""
    func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return v }
}
