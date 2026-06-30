import Foundation

/// Composes `prompt + input` as a (possibly multi-row) block. The first
/// visual row carries the `❯ ` prefix; continuation rows (from soft-
/// wrapping or explicit `\n`s) are indented by the prompt's visible
/// width so the body reads as one aligned paragraph.
///
///   ❯ this line is long enough that it wraps
///     onto a second continuation row
///     with a literal newline in between
///     and keeps going
final class PromptRow: Component, Focusable, @unchecked Sendable {
    let prompt: String
    let input: InputComponent
    var wantsKeyRelease: Bool { input.wantsKeyRelease }
    var ghostHintProvider: ((String) -> String?)?

    init(prompt: String, input: InputComponent) {
        self.prompt = prompt
        self.input = input
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        let promptWidth = ANSI.visibleWidth(prompt)
        if width <= promptWidth {
            return [ANSI.truncate(prompt, to: width)]
        }
        let innerWidth = max(1, width - promptWidth)
        let inner = renderInputRows(width: innerWidth)
        guard !inner.isEmpty else { return [prompt] }
        let indent = String(repeating: " ", count: promptWidth)
        var out: [String] = []
        for (i, row) in inner.enumerated() {
            out.append(i == 0 ? prompt + row : indent + row)
        }
        return out
    }

    func handleInput(_ data: String) { input.handleInput(data) }
    func invalidate() { input.invalidate() }

    var focused: Bool {
        get { input.focused }
        set { input.focused = newValue }
    }

    private func renderInputRows(width: Int) -> [String] {
        var rows = input.render(width: width)
        guard focused,
              input.cursor == input.value.count,
              let hint = ghostHintProvider?(input.value),
              !hint.isEmpty,
              var last = rows.popLast()
        else { return rows }

        let available = max(0, width - ANSI.visibleWidth(last))
        guard available > 0 else {
            rows.append(last)
            return rows
        }
        let visibleHint = ANSI.truncate(hint, to: available)
        guard !visibleHint.isEmpty else {
            rows.append(last)
            return rows
        }
        last += Style.dimmed(visibleHint)
        rows.append(last)
        return rows
    }
}
