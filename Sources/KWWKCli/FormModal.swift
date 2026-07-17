import Foundation

/// A single text field in a credential form (`FormModal`).
///
/// `required` entries block submission when empty; optional ones pass through
/// empty or fall back to `default`. `hint` is rendered dimmed beside the
/// label (e.g. "(optional)") and `placeholder` shows in the input row while
/// the field is empty.
struct APIKeyFormField: Sendable {
    let key: String
    let label: String
    let hint: String?
    let placeholder: String?
    let `default`: String?
    let required: Bool

    init(
        key: String,
        label: String,
        hint: String? = nil,
        placeholder: String? = nil,
        default: String? = nil,
        required: Bool = true
    ) {
        self.key = key
        self.label = label
        self.hint = hint
        self.placeholder = placeholder
        self.default = `default`
        self.required = required
    }
}

/// In-session form modal: an arrow-key form over `fields` rendered in the
/// transcript area — the `/login` API-key flow runs on it. Up/Down/Tab move
/// field focus, typed input lands in the focused field via `handleText`, Enter
/// validates and calls `onSubmit` with a `[key: value]` snapshot (or shows an
/// inline error when a required field is empty), Esc calls `onCancel`.
///
/// Values are trimmed; an empty non-required field falls back to its
/// `default` (or ""). Render mirrors the existing form: a label row + input
/// row + blank per field, `❯` on the focused field, dim placeholder while a
/// field is empty. Intentionally no password masking — the credential file is
/// 0600 and we want paste confirmation.
@MainActor
final class FormModal: Modal {
    private let title: String
    private let fields: [APIKeyFormField]
    private var buffers: [String]
    private var focusedIndex = 0
    private var errorLine: String?
    private let onSubmit: @MainActor ([String: String]) -> Void
    private let onCancel: @MainActor () -> Void

    init(
        title: String,
        fields: [APIKeyFormField],
        onSubmit: @MainActor @escaping ([String: String]) -> Void,
        onCancel: @MainActor @escaping () -> Void
    ) {
        precondition(!fields.isEmpty, "FormModal needs at least one field")
        self.title = title
        self.fields = fields
        self.buffers = fields.map { $0.default ?? "" }
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    /// Current buffer contents, keyed by field. Exposed for tests.
    var values: [String: String] {
        var out: [String: String] = [:]
        for (i, field) in fields.enumerated() { out[field.key] = buffers[i] }
        return out
    }

    // MARK: - Modal

    func up() { moveFocus(-1) }
    func down() { moveFocus(+1) }
    func tab() { moveFocus(+1) }

    /// Validate that required fields are filled, then call `onSubmit` with
    /// the trimmed values (empty optional fields fall back to `default`).
    /// A missing required field re-focuses that field and shows an inline
    /// error instead.
    func confirm() {
        for (i, field) in fields.enumerated() {
            let value = buffers[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if field.required && value.isEmpty {
                focusedIndex = i
                errorLine = "  \(field.label) is required"
                return
            }
        }
        var out: [String: String] = [:]
        for (i, field) in fields.enumerated() {
            let raw = buffers[i].trimmingCharacters(in: .whitespacesAndNewlines)
            out[field.key] = raw.isEmpty ? (field.default ?? "") : raw
        }
        onSubmit(out)
    }

    func cancel() {
        onCancel()
    }

    /// Typing always lands in the focused field: strip the bracketed-paste
    /// envelope, backspace deletes, unrecognized escape sequences are
    /// dropped, control characters (and tabs/newlines inside a paste) are
    /// filtered out. Always returns true: while a form is up, no keystroke
    /// falls through to the prompt box.
    func handleText(_ data: String) -> Bool {
        errorLine = nil
        // Bracketed-paste wrapper: strip the CSI 200~/201~ envelope and
        // flatten newlines (keys typically shouldn't span lines).
        var text = data
        if text.hasPrefix("\u{1B}[200~") && text.hasSuffix("\u{1B}[201~") {
            text.removeFirst("\u{1B}[200~".count)
            text.removeLast("\u{1B}[201~".count)
        }
        // Single-byte control characters we care about here: backspace.
        // Enter / Tab / Esc / arrows are keybound and never reach here;
        // anything else that looks like an ANSI escape (CSI tails) is
        // dropped rather than typed into the buffer.
        if text == "\u{7F}" || text == "\u{08}" {
            if !buffers[focusedIndex].isEmpty { buffers[focusedIndex].removeLast() }
            return true
        }
        if text.hasPrefix("\u{1B}") {
            return true // unrecognized escape sequence — swallow it
        }
        // Filter out control characters; accept printable text (including
        // multi-byte UTF-8). Tabs/newlines inside a pasted value become
        // nothing.
        var appended = ""
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\t" { continue }
            if let ascii = ch.asciiValue, ascii < 0x20 { continue }
            appended.append(ch)
        }
        if !appended.isEmpty {
            buffers[focusedIndex].append(appended)
        }
        return true
    }

    func render(maxRows: Int, width: Int) -> [String] {
        // Per-field blank spacers are cosmetic; drop them (with the outer
        // spacer) when the terminal is too short so the render fits maxRows.
        // Chrome: title + footer (+ error block when set — itself dropped on
        // degenerate heights where it would push the focused field out).
        let showError = errorLine != nil && maxRows >= 6
        let errorRows = showError ? 2 : 0
        let roomy = maxRows >= 2 + fields.count * 3 + errorRows + 2
        var out: [String] = []
        out.append(ANSI.fit(Style.header("  \(title)"), to: width))
        if roomy { out.append("") }

        // Window whole field blocks when even the compact layout overflows,
        // keeping the focused field visible.
        let linesPerField = roomy ? 3 : 2
        let bodyBudget = max(linesPerField, maxRows - 2 - errorRows - (roomy ? 1 : 0))
        let fieldsPerWindow = max(1, bodyBudget / linesPerField)
        var start = 0
        if focusedIndex >= fieldsPerWindow { start = focusedIndex - fieldsPerWindow + 1 }
        start = min(start, max(0, fields.count - fieldsPerWindow))

        for i in start ..< min(fields.count, start + fieldsPerWindow) {
            let field = fields[i]
            let active = i == focusedIndex
            // Label row: always unmarked. Keep width identical across frames
            // (leading indent only) so re-renders don't churn.
            var labelLine = "    " + field.label
            if let hint = field.hint, !hint.isEmpty {
                labelLine += "  " + Style.dimmed(hint)
            }
            out.append(ANSI.fit(labelLine, to: width))
            let buf = buffers[i]
            // Input row: `  ❯ ` vs `    ` swaps on focus change; both are 4
            // visible cols. The value never soft-wraps: a value too wide for
            // the row shows its TAIL when focused (that's where typing lands;
            // the caret must stay visible) and is tail-truncated when not.
            // The focused row carries the zero-width CURSOR_MARKER at the
            // caret so the hardware cursor blinks in the form, not in the
            // prompt box below the modal.
            let prefix = active ? Style.prompt("  ❯ ") : "    "
            let avail = max(4, width - 4)
            let display: String
            if buf.isEmpty {
                let placeholder = field.placeholder ?? ""
                let dim = Style.dimmed(placeholder.isEmpty ? "(empty)" : placeholder)
                display = (active ? CURSOR_MARKER : "") + ANSI.fit(dim, to: avail)
            } else if active {
                display = Style.prompt(ANSI.fitTail(buf, to: avail)) + CURSOR_MARKER
            } else {
                display = ANSI.fit(buf, to: avail)
            }
            out.append(prefix + display)
            if roomy { out.append("") }
        }
        if showError, let errorLine {
            out.append(ANSI.fit(Style.error(errorLine), to: width))
            out.append("")
        }
        out.append(ANSI.fit(Style.dimmed("  Tab/↑/↓: next field   Enter: submit   Esc: cancel"), to: width))
        return out
    }

    // MARK: - Internals

    private func moveFocus(_ delta: Int) {
        focusedIndex = (focusedIndex + delta + fields.count) % fields.count
        errorLine = nil
    }
}
