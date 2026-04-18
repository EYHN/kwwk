import Foundation

/// Minimal markdown renderer for the TUI: headings, bullet lists, fenced code
/// blocks, inline `code`, *emphasis* and **bold**. Non-goal: full CommonMark.
///
/// This is intentionally a single-pass, line-oriented renderer — enough for
/// agent output, prompts, and docs pages.
public final class MarkdownComponent: Component, @unchecked Sendable {
    public var source: String {
        didSet { if source != oldValue { invalidate() } }
    }

    private var cachedWidth: Int?
    private var cachedSource: String?
    private var cachedLines: [String]?

    public init(_ source: String = "") {
        self.source = source
    }

    public func render(width: Int) -> [String] {
        if let cachedLines, cachedWidth == width, cachedSource == source {
            return cachedLines
        }
        let lines = MarkdownComponent.render(source: source, width: width)
        cachedLines = lines
        cachedWidth = width
        cachedSource = source
        return lines
    }

    public func invalidate() {
        cachedLines = nil
        cachedWidth = nil
        cachedSource = nil
    }

    // MARK: - Rendering

    static func render(source: String, width: Int) -> [String] {
        let width = max(1, width)
        var out: [String] = []
        var inCode = false
        for raw in source.components(separatedBy: "\n") {
            if raw.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                out.append(String(raw.prefix(width)))
                continue
            }
            if raw.hasPrefix("######") { out.append(heading(raw, level: 6, width: width)); continue }
            if raw.hasPrefix("#####") { out.append(heading(raw, level: 5, width: width)); continue }
            if raw.hasPrefix("####") { out.append(heading(raw, level: 4, width: width)); continue }
            if raw.hasPrefix("###") { out.append(heading(raw, level: 3, width: width)); continue }
            if raw.hasPrefix("##") { out.append(heading(raw, level: 2, width: width)); continue }
            if raw.hasPrefix("#") { out.append(heading(raw, level: 1, width: width)); continue }
            if let bullet = bulletItem(raw, width: width) {
                out.append(contentsOf: bullet)
                continue
            }
            out.append(contentsOf: wrap(inline(raw), width: width))
        }
        return out
    }

    private static func heading(_ raw: String, level: Int, width: Int) -> String {
        var text = raw
        text.removeFirst(level)
        while text.hasPrefix(" ") { text.removeFirst() }
        let decorated: String
        switch level {
        case 1: decorated = "# \(text.uppercased())"
        case 2: decorated = "## \(text)"
        default: decorated = String(repeating: "#", count: level) + " " + text
        }
        return String(decorated.prefix(width))
    }

    private static func bulletItem(_ raw: String, width: Int) -> [String]? {
        let trimmed = raw.drop(while: { $0 == " " })
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let indent = raw.count - trimmed.count
            let content = trimmed.dropFirst(2)
            let prefix = String(repeating: " ", count: indent) + "• "
            let wrapped = wrap(inline(String(content)), width: max(1, width - prefix.count))
            return wrapped.enumerated().map { idx, line in
                if idx == 0 { return prefix + line }
                return String(repeating: " ", count: prefix.count) + line
            }
        }
        return nil
    }

    /// Strip `*bold*`, `**bold**`, and `` `code` `` markers; leave the text.
    /// The TUI builds on this to apply ANSI styling — but the plain reduction
    /// is enough for the tests that assert on visible text.
    static func inline(_ raw: String) -> String {
        var out = raw
        // Replace triple-/double-star bold with the inner text.
        out = regexReplace(out, pattern: #"\*\*(.+?)\*\*"#, template: "$1")
        out = regexReplace(out, pattern: #"\*(.+?)\*"#, template: "$1")
        out = regexReplace(out, pattern: #"`([^`]+)`"#, template: "$1")
        return out
    }

    private static func regexReplace(_ s: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    private static func wrap(_ text: String, width: Int) -> [String] {
        if width <= 0 { return [text] }
        if text.count <= width { return [text] }
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let segment = String(word)
            if current.isEmpty {
                current = segment
            } else if current.count + 1 + segment.count <= width {
                current += " " + segment
            } else {
                out.append(current)
                current = segment
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
