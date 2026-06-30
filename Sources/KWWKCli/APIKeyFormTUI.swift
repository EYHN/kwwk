import Foundation

/// A single text field in an `APIKeyFormTUI` form.
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

/// Run an arrow-key form over `fields`. Returns a `[key: value]` dictionary
/// once the user hits Enter (all required fields non-empty), or throws
/// `LoginError.cancelled` on Esc / Ctrl-C. Values are the field's `default`
/// when the user left a non-required field empty.
///
/// Intentionally minimal — one line per field, no password masking
/// (the credential file is 0600 and we want paste confirmation).
@MainActor
func runAPIKeyForm(
    title: String,
    fields: [APIKeyFormField]
) async throws -> [String: String] {
    precondition(!fields.isEmpty, "APIKeyFormTUI needs at least one field")
    // Hide the hardware cursor: focus is surfaced via the `❯` prefix, and
    // emitting our own CURSOR_MARKER on a focus-varying row caused
    // spurious re-layout on some terminals ("按上下破版").
    let runner = TUIRunner(hideCursor: true)
    let form = APIKeyFormComponent(title: title, fields: fields)

    let header = TextComponent([
        Style.header("✻ \(title)"),
        Style.dimmed("  fill in credentials — Tab/↑↓ to move between fields"),
        "",
    ])
    let footer = TextComponent([
        "",
        Style.dimmed("  Tab/↑/↓: next field   Enter: submit   Esc/Ctrl-C: cancel"),
    ])

    runner.tui.addChild(header)
    runner.tui.addChild(form)
    runner.tui.addChild(footer)
    runner.focus(form)

    runner.bind(.init("tab")) { _ in
        Task { @MainActor in
            form.moveFocus(+1)
            runner.tui.requestRender()
        }
    }
    runner.bind(.init("down")) { _ in
        Task { @MainActor in
            form.moveFocus(+1)
            runner.tui.requestRender()
        }
    }
    runner.bind(.init("up")) { _ in
        Task { @MainActor in
            form.moveFocus(-1)
            runner.tui.requestRender()
        }
    }
    runner.bind(.init("enter")) { _ in
        Task { @MainActor in
            if form.trySubmit() {
                runner.exit()
            } else {
                runner.tui.requestRender()
            }
        }
    }
    runner.bind(.init("escape")) { _ in
        Task { @MainActor in
            form.cancel()
            runner.exit()
        }
    }
    runner.bind(.ctrl("c")) { _ in
        Task { @MainActor in
            form.cancel()
            runner.exit()
        }
    }

    try await runner.run()

    guard let values = form.submittedValues else { throw LoginError.cancelled }
    return values
}

// MARK: - FormComponent

/// Custom component that renders all fields stacked, owns the focused-field
/// buffer, and exposes `submittedValues` once the user hits Enter with all
/// required fields populated.
final class APIKeyFormComponent: Component, Focusable, @unchecked Sendable {
    private let title: String
    private let fields: [APIKeyFormField]
    private var buffers: [String]
    private var focusedIndex: Int = 0
    private var errorLine: String?
    var submittedValues: [String: String]?
    var focused: Bool = false
    var wantsKeyRelease: Bool { false }

    init(title: String, fields: [APIKeyFormField]) {
        self.title = title
        self.fields = fields
        self.buffers = fields.map { $0.default ?? "" }
    }

    // MARK: public control

    func moveFocus(_ delta: Int) {
        guard !fields.isEmpty else { return }
        focusedIndex = (focusedIndex + delta + fields.count) % fields.count
        errorLine = nil
        invalidate()
    }

    /// Validate required fields are filled, then snapshot values to
    /// `submittedValues` and return true. Returns false (and sets
    /// `errorLine` + focus) when a required field is empty.
    func trySubmit() -> Bool {
        for (i, field) in fields.enumerated() {
            let value = buffers[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if field.required && value.isEmpty {
                focusedIndex = i
                errorLine = "  \(field.label) is required"
                invalidate()
                return false
            }
        }
        var out: [String: String] = [:]
        for (i, field) in fields.enumerated() {
            let raw = buffers[i].trimmingCharacters(in: .whitespacesAndNewlines)
            out[field.key] = raw.isEmpty ? (field.default ?? "") : raw
        }
        submittedValues = out
        return true
    }

    func cancel() {
        submittedValues = nil
    }

    // MARK: Component

    private var cachedWidth: Int?
    private var cachedOutput: [String]?
    private var cachedSignature: String?

    func invalidate() {
        cachedOutput = nil
        cachedWidth = nil
        cachedSignature = nil
    }

    func render(width: Int) -> [String] {
        let signature = "\(focusedIndex)|\(errorLine ?? "")|" + buffers.joined(separator: "\u{1f}")
        if let cachedOutput, cachedWidth == width, cachedSignature == signature {
            return cachedOutput
        }
        var out: [String] = []
        for (i, field) in fields.enumerated() {
            let active = i == focusedIndex
            // Label row: always unmarked. Keep width identical across
            // frames (leading indent only) so re-renders don't churn.
            var labelLine = "    " + field.label
            if let hint = field.hint, !hint.isEmpty {
                labelLine += "  " + Style.dimmed(hint)
            }
            out.append(labelLine)
            let buf = buffers[i]
            let display: String
            if buf.isEmpty {
                let placeholder = field.placeholder ?? ""
                display = Style.dimmed(placeholder.isEmpty ? "(empty)" : placeholder)
            } else {
                display = active ? Style.prompt(buf) : buf
            }
            // Input row: `  ❯ ` vs `    ` swaps on focus change. Both are
            // 4 visible cols; widths across frames match so a long buffer
            // that soft-wraps on focus also wraps when unfocused — no
            // stale wrapped rows leaking into the next frame.
            let prefix = active ? Style.prompt("  ❯ ") : "    "
            out.append(prefix + display)
            out.append("")
        }
        if let errorLine {
            out.append(Style.error(errorLine))
            out.append("")
        }
        cachedOutput = out
        cachedWidth = width
        cachedSignature = signature
        return out
    }

    // MARK: Input

    func handleInput(_ data: String) {
        guard !fields.isEmpty else { return }
        errorLine = nil
        // Bracketed-paste wrapper: strip the CSI 200~/201~ envelope and
        // flatten newlines (keys typically shouldn't span lines).
        var text = data
        if text.hasPrefix("\u{1B}[200~") && text.hasSuffix("\u{1B}[201~") {
            text.removeFirst("\u{1B}[200~".count)
            text.removeLast("\u{1B}[201~".count)
        }
        // Single-byte control characters we care about here: backspace.
        // Enter / Tab / Esc / arrows are handled by keybindings above and
        // never reach here; anything else that looks like an ANSI escape
        // (CSI arrow-key tails) is dropped rather than typed into the buf.
        if text == "\u{7F}" || text == "\u{08}" {
            if !buffers[focusedIndex].isEmpty { buffers[focusedIndex].removeLast() }
            invalidate()
            return
        }
        if text.hasPrefix("\u{1B}") {
            return // unrecognized escape sequence
        }
        // Filter out control characters; accept printable text (including
        // multi-byte UTF-8). Tabs/newlines inside a pasted value become
        // spaces.
        var appended = ""
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\t" { continue }
            if let ascii = ch.asciiValue, ascii < 0x20 { continue }
            appended.append(ch)
        }
        if !appended.isEmpty {
            buffers[focusedIndex].append(appended)
            invalidate()
        }
    }
}
