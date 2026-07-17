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

    init(prompt: AskPrompt, onComplete: @MainActor @escaping (AskOutcome) -> Void) {
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
    /// had (the cursor alone is not a selection).
    private var navigationState: (selected: [String], customInput: String?) {
        let selected = prompt.question.multi ? orderedSelection : prompt.previousSelection
        return (selected, prompt.previousCustomInput)
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

    func render(maxRows: Int) -> [String] {
        var title = "  ? \(prompt.question.question)"
        if let progress = prompt.progressText {
            title += " " + Style.dimmed("(\(progress))")
        }

        if mode == .otherInput {
            var out: [String] = []
            let roomy = maxRows >= 7
            if roomy { out.append("") }
            out.append(Style.header(title))
            if roomy { out.append("") }
            let display = buffer.isEmpty ? Style.dimmed("(type your answer)") : Style.prompt(buffer)
            out.append(Style.prompt("  ❯ ") + display)
            if roomy { out.append("") }
            out.append(Style.dimmed("  Enter: submit   Esc: back to options"))
            return out
        }

        // Display lines: one line per entry plus an optional description
        // sub-line, tracking each entry's first line for the scroll window.
        var lines: [String] = []
        var selectedLine = 0
        for (entryIndex, entry) in entries.enumerated() {
            let isCursor = entryIndex == selectedIndex
            if isCursor { selectedLine = lines.count }
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
                lines.append("\(prefix)\(marker) \(label)")
                if let description = option.description {
                    lines.append(Theme.faintText("        ↳ \(description)"))
                }
            case .done:
                let count = checked.count
                let base = isCursor ? Style.prompt("Done") : "Done"
                let suffix = count > 0 ? Style.dimmed(" (\(count) selected)") : ""
                lines.append(prefix + "  " + base + suffix)
            case .other:
                let label = Ask.otherOptionLabel
                lines.append(prefix + "  " + (isCursor ? Style.prompt(label) : Style.dimmed(label)))
            }
        }

        var hints = ["↑/↓: move", prompt.question.multi ? "Enter: toggle" : "Enter: select"]
        if prompt.allowBack || prompt.allowForward { hints.append("←/→: question") }
        hints.append("Esc: cancel")
        let footer = Style.dimmed("  " + hints.joined(separator: "   "))

        let roomy = maxRows >= lines.count + 5
        var out: [String] = []
        if roomy { out.append("") }
        out.append(Style.header(title))
        if roomy { out.append("") }

        let chrome = (roomy ? 5 : 2)
        let bodyBudget = max(1, maxRows - chrome)
        scroll = edgeScrollOffset(
            selection: selectedLine, count: lines.count,
            windowSize: bodyBudget, previous: scroll
        )
        out.append(contentsOf: lines[scroll ..< min(lines.count, scroll + bodyBudget)])

        if roomy { out.append("") }
        out.append(footer)
        return out
    }
}
