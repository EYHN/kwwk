import Foundation
import Testing
@testable import KWTUI

/// Minimal repro: verify `\r\n` lands the cursor at col 0 of the next row.
@Suite("Debug CRLF handling")
struct CRLFDebug {
    @Test("writing two lines separated by \\r\\n lands them on separate rows")
    func crlfSeparator() {
        let t = VirtualTerminal(width: 40, height: 10)
        t.write("\u{1B}[H")
        t.write("Line 0")
        t.write("\u{1B}[K")
        t.write("\r\n")
        t.write("Line 1")
        t.write("\u{1B}[K")
        let v = t.getViewport()
        print("row0: [\(v[0])]")
        print("row1: [\(v[1])]")
        #expect(v[0].hasPrefix("Line 0"))
        #expect(v[1].hasPrefix("Line 1"))
    }
}
