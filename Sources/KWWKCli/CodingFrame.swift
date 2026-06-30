import Foundation

/// Full-screen retained coding surface. The terminal is treated as a dumb
/// viewport: transcript, live tool cards, status, modal content, and the
/// prompt are all rendered from in-memory state on every frame.
///
/// This avoids the inline-anchor failure mode where old retained rows reflow
/// in native scrollback after a narrow resize. Frame rows are wrapped and
/// clipped before they are written, and no row is padded out with spaces.
final class CodingFrame: Component, @unchecked Sendable {
    let input: InputComponent
    let promptRow: PromptRow

    var metadataLine: String = ""
    var stateLine: String = ""

    private let cwd: String
    private let resumedLine: String?
    private var historyLines: [String] = []
    private var liveLines: [String] = []
    private var modalLines: [String]?
    private var viewportHeight: Int
    private var spinnerIndex: Int = 0

    private let maxHistoryLines = 4_000
    private static let spinnerFrames = ["◐", "◓", "◑", "◒"]

    init(cwd: String, resumedLine: String? = nil, viewportHeight: Int = 20) {
        self.input = InputComponent()
        self.promptRow = PromptRow(prompt: Style.prompt("❯ "), input: input)
        self.cwd = cwd
        self.resumedLine = resumedLine
        self.viewportHeight = max(1, viewportHeight)
    }

    var spinner: String {
        Self.spinnerFrames[spinnerIndex % Self.spinnerFrames.count]
    }

    func setViewport(height: Int) {
        viewportHeight = max(1, height)
    }

    func tick() {
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerFrames.count
    }

    func appendHistory(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        for raw in lines {
            let split = raw.components(separatedBy: "\n")
            historyLines.append(contentsOf: split)
        }
        if historyLines.count > maxHistoryLines {
            historyLines.removeFirst(historyLines.count - maxHistoryLines)
        }
    }

    func setLiveLines(_ lines: [String]) {
        liveLines = lines
    }

    func setModalLines(_ lines: [String]?) {
        modalLines = lines
    }

    func render(width: Int) -> [String] {
        let safeWidth = max(0, width)
        let height = max(1, viewportHeight)
        guard safeWidth > 0 else {
            return Array(repeating: "", count: height)
        }

        let header = renderHeader(width: safeWidth)
        let footer = renderFooter(width: safeWidth)
        let bodyHeight = max(0, height - header.count - footer.count)
        let body = renderBody(width: safeWidth, height: bodyHeight)

        var lines = header + body + footer
        if lines.count > height {
            lines = Array(lines.prefix(height))
        }
        while lines.count < height {
            lines.append("")
        }
        return lines.map { ANSI.truncate($0, to: safeWidth) }
    }

    func invalidate() {}

    private func renderHeader(width: Int) -> [String] {
        var lines: [String] = []

        var title = Style.badge("kwwk", bg: 99)
        title += Style.badge("fullscreen", bg: 24)
        if !metadataLine.isEmpty {
            title += metadataLine
        }
        lines.append(ANSI.truncate(title, to: width))

        let cwdLine = Style.dimmed("  \(shortened(cwd, to: max(8, width - 2)))")
        lines.append(ANSI.truncate(cwdLine, to: width))

        if let resumedLine, !resumedLine.isEmpty {
            lines.append(ANSI.truncate(Style.dimmed("  \(resumedLine)"), to: width))
        }

        return lines
    }

    private func renderBody(width: Int, height: Int) -> [String] {
        guard height > 0 else { return [] }

        let source: [String]
        if let modalLines {
            source = modalLines
        } else {
            source = historyLines + liveLines
        }

        var wrapped: [String] = []
        if source.isEmpty {
            wrapped.append(Style.dimmed("  ready"))
        } else {
            for line in source {
                if line.isEmpty {
                    wrapped.append("")
                } else {
                    wrapped.append(contentsOf: ANSI.wrap(line, width: width))
                }
            }
        }

        let clipped = wrapped.count > height ? Array(wrapped.suffix(height)) : wrapped
        if clipped.count < height {
            return Array(repeating: "", count: height - clipped.count) + clipped
        }
        return clipped
    }

    private func renderFooter(width: Int) -> [String] {
        let promptLines = promptRow.render(width: width)
        let state = stateLine.isEmpty ? Style.badge("ready", bg: 238) : stateLine
        return [ANSI.truncate(state, to: width)] + promptLines.map { ANSI.truncate($0, to: width) }
    }

    private func shortened(_ path: String, to maxLen: Int) -> String {
        guard path.count > maxLen, maxLen > 8 else { return path }
        let headCount = max(1, maxLen / 2 - 1)
        let tailCount = max(1, maxLen - headCount - 1)
        return "\(path.prefix(headCount))…\(path.suffix(tailCount))"
    }
}
