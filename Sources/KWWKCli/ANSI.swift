import Foundation

/// ANSI escape-aware text utilities. Terminals render ANSI CSI (`ESC[…m`)
/// and DEC private-mode (`ESC[?…`) sequences as zero-width metadata — the
/// bytes occupy buffer room but take no visible column. Treating the raw
/// `String.count` as "width" breaks layout any time we style with color.
enum ANSI {

    /// Number of visible columns the string would occupy, ignoring ANSI CSI
    /// and APC sequences and the zero-width `CURSOR_MARKER`. Handles East
    /// Asian wide characters (CJK, emoji, etc.) as width 2.
    static func visibleWidth(_ s: String) -> Int {
        var width = 0
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x1B {
                i = skipEscape(scalars, from: i)
                continue
            }
            // Skip APC payload (BEL-terminated) + other C0 controls.
            if v < 0x20 || v == 0x7F { i += 1; continue }
            width += columnWidth(of: v)
            i += 1
        }
        return width
    }

    /// Visible column width of a single Unicode scalar. Returns 0 for
    /// combining marks and zero-width controls, 2 for East Asian wide /
    /// fullwidth characters and most emoji, 1 otherwise. Uses UAX-11 ranges
    /// that cover the common cases exercised by the TUI (CJK, Hangul,
    /// hiragana/katakana, wide punctuation, pictographic emoji).
    static func columnWidth(of value: UInt32) -> Int {
        // Zero-width controls + combining marks.
        if value == 0 { return 0 }
        if isInRange(value, [
            (0x0300, 0x036F),   // Combining Diacritical Marks
            (0x0483, 0x0489),
            (0x0591, 0x05BD),
            (0x0610, 0x061A),
            (0x064B, 0x065F),
            (0x0670, 0x0670),
            (0x06D6, 0x06DC),
            (0x06DF, 0x06E4),
            (0x06E7, 0x06E8),
            (0x06EA, 0x06ED),
            (0x200B, 0x200F),   // ZWSP … LRM
            (0x202A, 0x202E),
            (0x2060, 0x206F),
            (0xFE00, 0xFE0F),   // Variation selectors
            (0xFE20, 0xFE2F),
        ]) { return 0 }

        // Wide (width 2) — condensed UAX-11 W/F ranges.
        if isInRange(value, [
            (0x1100, 0x115F),   // Hangul Jamo
            (0x231A, 0x231B),   // Watch / hourglass emoji
            (0x2329, 0x232A),
            (0x23E9, 0x23EC),
            (0x23F0, 0x23F0),
            (0x23F3, 0x23F3),
            (0x25FD, 0x25FE),
            (0x2614, 0x2615),
            (0x2648, 0x2653),
            (0x267F, 0x267F),
            (0x2693, 0x2693),
            (0x26A1, 0x26A1),
            (0x26AA, 0x26AB),
            (0x26BD, 0x26BE),
            (0x26C4, 0x26C5),
            (0x26CE, 0x26CE),
            (0x26D4, 0x26D4),
            (0x26EA, 0x26EA),
            (0x26F2, 0x26F3),
            (0x26F5, 0x26F5),
            (0x26FA, 0x26FA),
            (0x26FD, 0x26FD),
            (0x2705, 0x2705),
            (0x270A, 0x270B),
            (0x2728, 0x2728),
            (0x274C, 0x274C),
            (0x274E, 0x274E),
            (0x2753, 0x2755),
            (0x2757, 0x2757),
            (0x2795, 0x2797),
            (0x27B0, 0x27B0),
            (0x27BF, 0x27BF),
            (0x2B1B, 0x2B1C),
            (0x2B50, 0x2B50),
            (0x2B55, 0x2B55),
            (0x2E80, 0x303E),   // CJK Radicals, punctuation
            (0x3041, 0x33FF),   // Hiragana, Katakana, CJK compatibility
            (0x3400, 0x4DBF),   // CJK Unified Ideographs Ext A
            (0x4E00, 0x9FFF),   // CJK Unified Ideographs
            (0xA000, 0xA4CF),   // Yi Syllables
            (0xA960, 0xA97F),   // Hangul Jamo Extended-A
            (0xAC00, 0xD7A3),   // Hangul Syllables
            (0xF900, 0xFAFF),   // CJK Compatibility Ideographs
            (0xFE10, 0xFE19),
            (0xFE30, 0xFE6F),
            (0xFF00, 0xFF60),   // Fullwidth ASCII + punctuation
            (0xFFE0, 0xFFE6),
            (0x1F300, 0x1F64F), // Misc symbols + emoji
            (0x1F680, 0x1F6FF),
            (0x1F900, 0x1F9FF),
            (0x20000, 0x2FFFD), // CJK Unified Ideographs Ext B..F
            (0x30000, 0x3FFFD),
        ]) { return 2 }

        return 1
    }

    private static func isInRange(_ v: UInt32, _ ranges: [(UInt32, UInt32)]) -> Bool {
        for (lo, hi) in ranges where v >= lo && v <= hi { return true }
        return false
    }

    /// Truncate the string to at most `width` visible columns, preserving
    /// ANSI escape sequences and wide characters. Appends a `\u{1B}[0m` reset
    /// if any styling was opened but not closed at the cut point.
    static func truncate(_ s: String, to width: Int) -> String {
        if width <= 0 { return "" }
        var out = ""
        var visible = 0
        var hadStyle = false
        var hadClose = false
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x1B {
                let end = skipEscape(scalars, from: i)
                for k in i..<end { out.unicodeScalars.append(scalars[k]) }
                if let final = scalars[safe: end - 1]?.value, final == 0x6D {
                    let paramStart = i + 2
                    if paramStart < end {
                        var params = ""
                        for k in paramStart..<(end - 1) {
                            params.unicodeScalars.append(scalars[k])
                        }
                        if params == "0" || params == "" { hadClose = true }
                        else { hadStyle = true }
                    }
                }
                i = end
                continue
            }
            if v < 0x20 || v == 0x7F { i += 1; continue }
            let cw = columnWidth(of: v)
            if visible + cw > width { break }
            out.unicodeScalars.append(scalars[i])
            visible += cw
            i += 1
        }
        if hadStyle && !hadClose {
            out += "\u{1B}[0m"
        }
        return out
    }

    /// Soft-wrap a styled string into rows that fit `width` visible columns.
    /// ANSI SGR sequences are treated as zero-width metadata and are carried
    /// across wrapped rows so foreground/background styling does not leak or
    /// disappear at a line break.
    static func wrap(_ s: String, width: Int) -> [String] {
        guard width > 0 else { return [""] }

        var rows: [String] = []
        var current = ""
        var visible = 0
        var activeSGR = ""

        func finishRow() {
            if !activeSGR.isEmpty, !current.hasSuffix(resetSequence) {
                current += resetSequence
            }
            rows.append(current)
            current = activeSGR
            visible = 0
        }

        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value

            if v == 0x0A {
                finishRow()
                i += 1
                continue
            }

            if v == 0x1B {
                let end = skipEscape(scalars, from: i)
                var escape = ""
                for k in i..<end { escape.unicodeScalars.append(scalars[k]) }
                current += escape
                if isSGR(escape) {
                    if isSGRReset(escape) {
                        activeSGR = ""
                    } else {
                        activeSGR += escape
                    }
                }
                i = end
                continue
            }

            if v < 0x20 || v == 0x7F {
                i += 1
                continue
            }

            let cw = columnWidth(of: v)
            if visible > 0, visible + cw > width {
                finishRow()
            }
            if cw <= width {
                current.unicodeScalars.append(scalars[i])
                visible += cw
            }
            i += 1
        }

        if !activeSGR.isEmpty, !current.hasSuffix(resetSequence) {
            current += resetSequence
        }
        rows.append(current)
        return rows.isEmpty ? [""] : rows
    }

    /// Strip ANSI escape sequences from `s`, returning plain text.
    static func stripEscapes(_ s: String) -> String {
        var out = ""
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i].value == 0x1B {
                i = skipEscape(scalars, from: i)
                continue
            }
            out.unicodeScalars.append(scalars[i])
            i += 1
        }
        return out
    }

    private static let resetSequence = "\u{1B}[0m"

    private static func isSGR(_ escape: String) -> Bool {
        escape.hasPrefix("\u{1B}[") && escape.hasSuffix("m")
    }

    private static func isSGRReset(_ escape: String) -> Bool {
        guard isSGR(escape) else { return false }
        let params = escape
            .dropFirst(2)
            .dropLast()
        return params.isEmpty || params == "0"
    }

    /// Advance past a single ANSI escape sequence starting at `from`, which
    /// points at the ESC (0x1B). Handles CSI (`ESC[…finalByte`) and APC
    /// (`ESC_…BEL`) forms plus short `ESC<char>` fall-throughs.
    static func skipEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        // Expect ESC at `start`.
        guard start + 1 < scalars.count else { return start + 1 }
        let second = scalars[start + 1].value
        if second == 0x5B { // '[' — CSI
            var j = start + 2
            while j < scalars.count {
                let v = scalars[j].value
                // CSI final byte is 0x40…0x7E
                if v >= 0x40 && v <= 0x7E {
                    return j + 1
                }
                j += 1
            }
            return j
        }
        if second == 0x5F { // '_' — APC: terminated by BEL (0x07) or ST (ESC \\)
            var j = start + 2
            while j < scalars.count {
                if scalars[j].value == 0x07 { return j + 1 }
                j += 1
            }
            return j
        }
        // ESC + one byte
        return start + 2
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
