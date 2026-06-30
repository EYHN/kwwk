import Foundation

/// Build/version surface for the CLI. Bumped by release tooling; rendered
/// on the welcome card and `--help`.
enum KWWKBuild {
    static let version = "0.1.0"
}

/// Truecolor palette + text styling for the redesigned TUI chrome. The
/// legacy `Style` enum (256-color badges) is still used by the transcript
/// renderer; `Theme` layers a calmer, omp-inspired look on top — rounded
/// boxes, a cyan→violet accent gradient, and muted borders — using 24-bit
/// SGR so the colors stay consistent across terminal palettes.
enum Theme {
    static let reset = "\u{1B}[0m"

    // Core palette (24-bit RGB) — green family.
    static let accent      = (r: 80,  g: 210, b: 140)   // headers, prompt glyph (emerald)
    static let accentDim   = (r: 58,  g: 150, b: 104)   // forest
    static let gradFrom    = (r: 72,  g: 196, b: 150)   // logo gradient (teal-green)
    static let gradTo      = (r: 158, g: 230, b: 130)   // logo gradient (lime)
    static let border      = (r: 64,  g: 92,  b: 76)    // box rules (muted forest)
    static let muted       = (r: 140, g: 168, b: 148)   // secondary text (sage)
    static let faint       = (r: 92,  g: 116, b: 100)   // tertiary / hints
    static let text        = (r: 216, g: 224, b: 218)   // primary text
    static let success     = (r: 110, g: 210, b: 140)
    static let warn        = (r: 232, g: 178, b: 96)
    static let userBarBg   = (r: 26,  g: 44,  b: 34)    // user message bar background

    static func fg(_ c: (r: Int, g: Int, b: Int)) -> String {
        "\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m"
    }

    static func paint(_ s: String, _ c: (r: Int, g: Int, b: Int), bold: Bool = false) -> String {
        (bold ? "\u{1B}[1m" : "") + fg(c) + s + reset
    }

    static func bg(_ c: (r: Int, g: Int, b: Int)) -> String {
        "\u{1B}[48;2;\(c.r);\(c.g);\(c.b)m"
    }

    /// omp-style full-width user-message bar: a dark-green background row with
    /// an accent `❯` glyph and the user's text in primary color. Padded to
    /// `width` visible columns so the bar spans the line. Multi-line text is
    /// returned as one bar per line. Committed to scrollback as a block.
    static func userBar(_ text: String, width: Int) -> [String] {
        let inner = max(0, width - 1)            // leave the last column clear
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { i, raw in
            let glyph = i == 0 ? "❯ " : "  "
            let visText = ANSI.visibleWidth(raw) + 2
            let clipped = visText > inner ? ANSI.truncate(raw, to: max(0, inner - 2)) : raw
            let used = 2 + ANSI.visibleWidth(clipped)
            let pad = used < inner ? String(repeating: " ", count: inner - used) : ""
            return bg(userBarBg) + "\u{1B}[1m" + fg(accent) + glyph
                + "\u{1B}[22m" + fg(Theme.text) + clipped + pad + reset
        }
    }

    static func accentText(_ s: String, bold: Bool = true) -> String { paint(s, accent, bold: bold) }
    static func mutedText(_ s: String) -> String { paint(s, muted) }
    static func faintText(_ s: String) -> String { paint(s, faint) }
    static func bodyText(_ s: String) -> String { paint(s, text) }
    static func borderText(_ s: String) -> String { paint(s, border) }

    /// Per-character linear interpolation between two RGB stops across the
    /// visible glyphs of `s`. ANSI control bytes are skipped so a pre-styled
    /// string is left untouched. Used for the logo + wordmark.
    static func gradient(
        _ s: String,
        from: (r: Int, g: Int, b: Int) = gradFrom,
        to: (r: Int, g: Int, b: Int) = gradTo,
        bold: Bool = true
    ) -> String {
        let glyphs = Array(s)
        let n = max(1, glyphs.count - 1)
        var out = bold ? "\u{1B}[1m" : ""
        for (i, ch) in glyphs.enumerated() {
            if ch == " " { out.append(" "); continue }
            let t = Double(i) / Double(n)
            let r = Int((Double(from.r) + (Double(to.r) - Double(from.r)) * t).rounded())
            let g = Int((Double(from.g) + (Double(to.g) - Double(from.g)) * t).rounded())
            let b = Int((Double(from.b) + (Double(to.b) - Double(from.b)) * t).rounded())
            out += "\u{1B}[38;2;\(r);\(g);\(b)m\(ch)"
        }
        out += reset
        return out
    }
}

/// ANSI-aware rounded-box drawing. Every helper returns a single styled
/// line whose visible width is exactly `width` (or `≤ width` after a
/// truncate), so the retained full-screen frame can stack them without
/// jitter. Borders are drawn in `Theme.border`; callers own the interior
/// styling.
enum Box {
    static let tl = "╭", tr = "╮", bl = "╰", br = "╯"
    static let h = "─", v = "│"

    /// Pad a styled string with trailing spaces to exactly `width` visible
    /// columns (truncating if it is already wider). Trailing spaces carry no
    /// active SGR, so they are safe at any row position.
    static func pad(_ s: String, to width: Int) -> String {
        let vis = ANSI.visibleWidth(s)
        if vis >= width { return ANSI.truncate(s, to: width) }
        return s + String(repeating: " ", count: width - vis)
    }

    /// Center a styled string inside `width` visible columns.
    static func center(_ s: String, to width: Int) -> String {
        let vis = ANSI.visibleWidth(s)
        guard vis < width else { return ANSI.truncate(s, to: width) }
        let left = (width - vis) / 2
        let right = width - vis - left
        return String(repeating: " ", count: left) + s + String(repeating: " ", count: right)
    }

    /// Top border with an optional inset label: `╭─ label ──────────╮`.
    static func top(width: Int, label: String? = nil) -> String {
        guard width >= 2 else { return ANSI.truncate(Theme.borderText(tl), to: width) }
        let inner = width - 2
        var mid: String
        if let label, !label.isEmpty {
            let tag = " \(label) "
            let tagWidth = ANSI.visibleWidth(tag)
            let lead = 1
            let rest = max(0, inner - lead - tagWidth)
            mid = Theme.borderText(String(repeating: h, count: lead))
                + tag
                + Theme.borderText(String(repeating: h, count: rest))
        } else {
            mid = Theme.borderText(String(repeating: h, count: inner))
        }
        return Theme.borderText(tl) + mid + Theme.borderText(tr)
    }

    /// Bottom border with an optional right-aligned label:
    /// `╰──────────── label ─╯`.
    static func bottom(width: Int, rightLabel: String? = nil) -> String {
        guard width >= 2 else { return ANSI.truncate(Theme.borderText(bl), to: width) }
        let inner = width - 2
        var mid: String
        if let rightLabel, !rightLabel.isEmpty {
            let tag = " \(rightLabel) "
            let tagWidth = ANSI.visibleWidth(tag)
            let trail = 1
            let rest = max(0, inner - trail - tagWidth)
            mid = Theme.borderText(String(repeating: h, count: rest))
                + tag
                + Theme.borderText(String(repeating: h, count: trail))
        } else {
            mid = Theme.borderText(String(repeating: h, count: inner))
        }
        return Theme.borderText(bl) + mid + Theme.borderText(br)
    }

    /// Interior row: `│ <content padded to inner> │`.
    static func row(_ content: String, width: Int) -> String {
        guard width >= 4 else { return ANSI.truncate(Theme.borderText(v), to: width) }
        let inner = width - 4   // leading + trailing border + one space each side
        let body = pad(content, to: inner)
        return Theme.borderText(v) + " " + body + " " + Theme.borderText(v)
    }
}
