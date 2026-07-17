import Foundation

/// Resume-exactly-once box around the `ask` tool's suspended continuation.
/// Two paths race to finish a presentation — the modal's own completion and
/// a run abort landing while the modal is still up — and a continuation must
/// never resume twice. `@MainActor` so both paths serialize.
@MainActor
final class AskPresentation {
    private var continuation: CheckedContinuation<AskOutcome, Never>?

    init(_ continuation: CheckedContinuation<AskOutcome, Never>) {
        self.continuation = continuation
    }

    var finished: Bool { continuation == nil }

    func resume(_ outcome: AskOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

/// Selector modal for one `ask` tool question (omp's ask UI ported to kwwk's
/// modal system). Radio behavior for single-select (Enter answers), checkbox
/// behavior for `multi` (Enter toggles, the Done row answers), a synthetic
/// "Other (type your own)" row that switches the modal into inline free-text
/// entry, and ←/→ wizard navigation for multi-question calls.
///
/// The modal never closes itself — it reports exactly one `AskOutcome` through
/// `onComplete` and the TUI wiring closes the host and resumes the suspended
/// tool call.
@MainActor
final class AskModal: Modal {
    enum Entry: Equatable {
        case option(Int)
        case done
        case other
    }

    private enum Mode {
        case list
        case otherInput
    }

    private let prompt: AskPrompt
    private let onComplete: @MainActor (AskOutcome) -> Void
    private var completed = false

    private(set) var entries: [Entry]
    private(set) var selectedIndex: Int
    /// Checked labels for `multi` questions, in option order on submit.
    private(set) var checked: Set<String>
    private var mode: Mode = .list
    private var buffer: String
    /// Top display-line of the visible window (edge-scroll, matches
    /// `ModalListCore` behavior).
    private var scroll = 0

    init(
        prompt: AskPrompt,
        onComplete: @MainActor @escaping (AskOutcome) -> Void
    ) {
        self.prompt = prompt
        self.onComplete = onComplete

        var entries: [Entry] = prompt.question.options.indices.map { .option($0) }
        if prompt.question.multi { entries.append(.done) }
        entries.append(.other)
        self.entries = entries

        let labels = prompt.question.options.map(\.label)
        self.checked = Set(prompt.previousSelection).intersection(labels)
        self.buffer = prompt.previousCustomInput ?? ""

        if prompt.previousCustomInput != nil {
            self.selectedIndex = entries.count - 1
        } else if let first = prompt.previousSelection.first,
                  let idx = labels.firstIndex(of: first) {
            self.selectedIndex = idx
        } else {
            self.selectedIndex = prompt.question.recommended ?? 0
        }
    }

    /// Checked labels in option order — the order the model sees.
    var orderedSelection: [String] {
        prompt.question.options.map(\.label).filter { checked.contains($0) }
    }

    private func finish(_ outcome: AskOutcome) {
        guard !completed else { return }
        completed = true
        onComplete(outcome)
    }

    /// External teardown (run aborted while the modal was up): report
    /// `cancelled` without touching the host — the caller closes it.
    func cancelExternally() {
        finish(.cancelled)
    }

    // MARK: - Modal

    func up() {
        guard mode == .list else { return }
        selectedIndex = (selectedIndex - 1 + entries.count) % entries.count
    }

    func down() {
        guard mode == .list else { return }
        selectedIndex = (selectedIndex + 1) % entries.count
    }

    func confirm() {
        switch mode {
        case .list:
            switch entries[selectedIndex] {
            case .option(let i):
                let label = prompt.question.options[i].label
                if prompt.question.multi {
                    if checked.contains(label) { checked.remove(label) } else { checked.insert(label) }
                } else {
                    finish(.answered(selected: [label], customInput: nil))
                }
            case .done:
                finish(.answered(selected: orderedSelection, customInput: nil))
            case .other:
                mode = .otherInput
            }
        case .otherInput:
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                mode = .list
            } else {
                // multi keeps the checked options alongside the custom input
                // (omp behavior); single-select custom input replaces any
                // previous option answer.
                let selected = prompt.question.multi ? orderedSelection : []
                finish(.answered(selected: selected, customInput: text))
            }
        }
    }

    func cancel() {
        switch mode {
        case .otherInput:
            mode = .list
        case .list:
            finish(.cancelled)
        }
    }

    /// Current answer state for wizard navigation: multi carries the live
    /// checkboxes, single-select carries whatever answer the question already
    /// had (the cursor alone is not a selection). The custom input is the
    /// LIVE "Other" buffer — it starts as the previous custom answer and an
    /// in-progress draft must survive ←/→ exactly like checkbox state does.
    private var navigationState: (selected: [String], customInput: String?) {
        let selected = prompt.question.multi ? orderedSelection : prompt.previousSelection
        let draft = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return (selected, draft.isEmpty ? nil : draft)
    }

    func left() {
        guard mode == .list, prompt.allowBack else { return }
        let state = navigationState
        finish(.back(selected: state.selected, customInput: state.customInput))
    }

    func right() {
        guard mode == .list, prompt.allowForward else { return }
        let state = navigationState
        finish(.answered(selected: state.selected, customInput: state.customInput))
    }

    /// Typed text lands in the "Other" buffer while it is open; in list mode
    /// nothing is consumed (falls through to the prompt editor, like every
    /// list modal). Same filtering as `FormModal`: strip the bracketed-paste
    /// envelope, backspace deletes, escape sequences and control chars drop.
    func handleText(_ data: String) -> Bool {
        guard mode == .otherInput else { return false }
        var text = data
        if text.hasPrefix("\u{1B}[200~") && text.hasSuffix("\u{1B}[201~") {
            text.removeFirst("\u{1B}[200~".count)
            text.removeLast("\u{1B}[201~".count)
        }
        if text == "\u{7F}" || text == "\u{08}" {
            if !buffer.isEmpty { buffer.removeLast() }
            return true
        }
        if text.hasPrefix("\u{1B}") {
            return true
        }
        var appended = ""
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\t" { continue }
            if let ascii = ch.asciiValue, ascii < 0x20 { continue }
            appended.append(ch)
        }
        if !appended.isEmpty {
            buffer.append(appended)
        }
        return true
    }

    /// Wrap a styled line into physical rows: the first row carries `first`
    /// (prefix + marker), continuations get a hanging indent of the same
    /// visible width so wrapped content stays aligned under its own column.
    private func wrapHanging(first: String, content: String, width: Int) -> [String] {
        let indentWidth = ANSI.visibleWidth(first)
        let pieces = ANSI.wrap(content, width: max(8, width - indentWidth))
        let indent = String(repeating: " ", count: indentWidth)
        return [first + (pieces.first ?? "")] + pieces.dropFirst().map { indent + $0 }
    }

    /// Edge-scroll for a windowed list of physical rows where the selection
    /// spans a row RANGE (a wrapped entry): keep the whole entry visible,
    /// preferring its first row when it is taller than the window.
    private func rangeScrollOffset(
        start: Int, end: Int, count: Int, windowSize: Int, previous: Int
    ) -> Int {
        var scroll = previous
        if end >= scroll + windowSize { scroll = end - windowSize + 1 }
        if start < scroll { scroll = start }
        return max(0, min(scroll, max(0, count - windowSize)))
    }

    /// Every emitted line is pre-wrapped to `width`: the frame wraps overlong
    /// modal lines into extra physical rows and then keeps only the bottom
    /// of an overflowing modal, so one emitted line MUST be one terminal row
    /// for the `maxRows` windowing contract to hold. Content is never
    /// truncated — long labels and descriptions wrap with a hanging indent
    /// and the window scrolls over physical rows.
    func render(maxRows: Int, width: Int) -> [String] {
        // No local floor: lines wider than the host's width would soft-wrap
        // in the frame and break the one-line-one-row windowing contract.
        let width = max(1, width)
        // The question is content — wrap it (charged against `maxRows` as
        // chrome) rather than cutting it off.
        var title = "  ? \(prompt.question.question)"
        if let progress = prompt.progressText {
            title += " " + Style.dimmed("(\(progress))")
        }
        let titleLines = ANSI.wrap(Style.header(title), width: width)

        if mode == .otherInput {
            let footer = Style.dimmed("  Enter: submit   Esc: back to options")
            let footerLines = ANSI.wrap(footer, width: width)
            // The zero-width CURSOR_MARKER rides at the caret (end of the
            // typed text, or before the placeholder) so the hardware cursor
            // blinks here instead of in the prompt box below the modal.
            let display = buffer.isEmpty
                ? CURSOR_MARKER + Style.dimmed("(type your answer)")
                : Style.prompt(buffer) + CURSOR_MARKER
            var inputLines = wrapHanging(first: Style.prompt("  ❯ "), content: display, width: width)
            let roomy = maxRows >= titleLines.count + inputLines.count + footerLines.count + 3
            // A very long pasted answer overflows the viewport: keep the
            // TAIL rows — that's where the cursor is.
            let inputBudget = max(1, maxRows - titleLines.count - footerLines.count - (roomy ? 3 : 0))
            if inputLines.count > inputBudget {
                inputLines = Array(inputLines.suffix(inputBudget))
            }
            var out: [String] = []
            if roomy { out.append("") }
            out.append(contentsOf: titleLines)
            if roomy { out.append("") }
            out.append(contentsOf: inputLines)
            if roomy { out.append("") }
            out.append(contentsOf: footerLines)
            return out
        }

        // Physical display rows, one row array per entry: each entry wraps
        // into one or more rows with a hanging indent. Content is only ever
        // cut when a SINGLE entry is taller than the whole scroll window —
        // wrapping handles everything below that, and an over-tall entry
        // could never be scrolled through anyway (↑/↓ move entry to entry).
        var entryRows: [[String]] = []
        for (entryIndex, entry) in entries.enumerated() {
            let isCursor = entryIndex == selectedIndex
            var rows: [String] = []
            let prefix = isCursor ? Style.prompt("  ❯ ") : "    "
            switch entry {
            case .option(let i):
                let option = prompt.question.options[i]
                let marker: String
                if prompt.question.multi {
                    let isChecked = checked.contains(option.label)
                    marker = isChecked ? Theme.paint("◼", Theme.success) : Style.dimmed("◻")
                } else {
                    let isPrevious = prompt.previousSelection.first == option.label
                    marker = isPrevious ? Theme.paint("●", Theme.success) : Style.dimmed("○")
                }
                var label = isCursor ? Style.prompt(option.label) : option.label
                if i == prompt.question.recommended {
                    label += Style.dimmed(Ask.recommendedSuffix)
                }
                rows.append(contentsOf: wrapHanging(
                    first: "\(prefix)\(marker) ", content: label, width: width
                ))
                if let description = option.description {
                    // Style row-by-row: wrap the plain text, then paint each
                    // row faint including its indent.
                    let descIndent = "        ↳ "
                    let pieces = ANSI.wrap(description, width: max(8, width - ANSI.visibleWidth(descIndent)))
                    rows.append(Theme.faintText(descIndent + (pieces.first ?? "")))
                    let indent = String(repeating: " ", count: ANSI.visibleWidth(descIndent))
                    rows.append(contentsOf: pieces.dropFirst().map { Theme.faintText(indent + $0) })
                }
            case .done:
                let count = checked.count
                let base = isCursor ? Style.prompt("Done") : "Done"
                let suffix = count > 0 ? Style.dimmed(" (\(count) selected)") : ""
                rows.append(contentsOf: wrapHanging(
                    first: prefix + "  ", content: base + suffix, width: width
                ))
            case .other:
                let label = Ask.otherOptionLabel
                rows.append(contentsOf: wrapHanging(
                    first: prefix + "  ",
                    content: isCursor ? Style.prompt(label) : Style.dimmed(label),
                    width: width
                ))
            }
            entryRows.append(rows)
        }

        var hints = ["↑/↓: move", prompt.question.multi ? "Enter: toggle" : "Enter: select"]
        if prompt.allowBack || prompt.allowForward { hints.append("←/→: question") }
        hints.append("Esc: cancel")

        // Cosmetic blank spacers are dropped on short terminals; chrome is
        // the wrapped title + footer (+ 3 spacers when roomy), everything
        // else is the windowed body. Whether the list is windowed is probed
        // with a one-row footer estimate — the `n/m` indicator only needs to
        // appear whenever rows are actually hidden.
        let totalRows = entryRows.reduce(0) { $0 + $1.count }
        let windowedProbe = totalRows + titleLines.count + 1 > maxRows
        let position = windowedProbe ? "\(selectedIndex + 1)/\(entries.count)   " : ""
        let footer = Style.dimmed("  " + position + hints.joined(separator: "   "))
        let footerLines = ANSI.wrap(footer, width: width)

        let roomy = maxRows >= totalRows + titleLines.count + footerLines.count + 3
        let chrome = titleLines.count + footerLines.count + (roomy ? 3 : 0)
        let bodyBudget = max(1, maxRows - chrome)

        // Flatten, clamping any entry taller than the window to the window
        // height with a dim `… +N lines` marker as its last visible row.
        var lines: [String] = []
        var selectedRange = 0...0
        for (entryIndex, rows) in entryRows.enumerated() {
            let rangeStart = lines.count
            if rows.count > bodyBudget, bodyBudget >= 2 {
                let hidden = rows.count - (bodyBudget - 1)
                lines.append(contentsOf: rows.prefix(bodyBudget - 1))
                lines.append(Style.dimmed("      … +\(hidden) more lines"))
            } else if rows.count > bodyBudget {
                // Degenerate one-row window: the entry's first row stands in
                // for the whole entry.
                lines.append(rows[0])
            } else {
                lines.append(contentsOf: rows)
            }
            if entryIndex == selectedIndex { selectedRange = rangeStart...(lines.count - 1) }
        }
        scroll = rangeScrollOffset(
            start: selectedRange.lowerBound, end: selectedRange.upperBound,
            count: lines.count, windowSize: bodyBudget, previous: scroll
        )

        var out: [String] = []
        if roomy { out.append("") }
        out.append(contentsOf: titleLines)
        if roomy { out.append("") }
        out.append(contentsOf: lines[scroll ..< min(lines.count, scroll + bodyBudget)])
        if roomy { out.append("") }
        out.append(contentsOf: footerLines)
        return out
    }
}
