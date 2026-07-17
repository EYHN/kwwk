import Foundation
import KWWKAI

/// Arrow-key list for picking a `Model` from a fixed menu. Stays visually
/// minimal — one line per model, current selection flagged with `❯` +
/// accent color, the already-active model tagged `(current)`. Selection,
/// windowing, and rendering live in `ModalListCore`.
///
/// With more than one provider group a tab bar renders above the list —
/// "All" plus one tab per provider — and Tab / ←→ filter the list to a
/// single provider. With a single provider the tab bar is omitted and the
/// render is identical to the ungrouped selector.
///
/// Typing filters the list by model id (case-insensitive substring),
/// composed with the active provider tab. Backspace edits the query; Esc
/// clears a non-empty query first and only closes the modal once empty.
@MainActor
final class ModelSelectorModal: Modal {
    private let title: String
    private let models: [Model]
    /// Optional per-model group label (e.g. provider display name). When
    /// present and it changes between adjacent rows, a dim header is rendered
    /// above the row so the same model id under different providers is
    /// distinguishable. Must be the same length as `models` when non-nil.
    private let groupLabels: [String]?
    private let currentModelId: String?
    /// When the same model id appears under several providers, `currentModelId`
    /// alone is ambiguous; this pins the initially-selected row.
    private let currentIndex: Int?
    private let onSelect: @MainActor (Model) -> Void
    private let onCancel: @MainActor () -> Void

    /// Provider tabs: "All" first, then one tab per unique group label in
    /// first-occurrence (slot) order. Empty when there are fewer than two
    /// provider groups — the tab bar renders only when it disambiguates.
    private let tabs: [String]
    /// Index into `tabs`; 0 is "All".
    private var activeTab = 0
    /// Typed filter query, matched case-insensitively against model ids.
    private var query = ""
    /// Indices into `models` currently listed (filtered by the active tab
    /// and the typed query).
    private var visible: [Int]
    private let core: ModalListCore

    init(
        title: String,
        models: [Model],
        currentModelId: String?,
        groupLabels: [String]? = nil,
        currentIndex: Int? = nil,
        onSelect: @MainActor @escaping (Model) -> Void,
        onCancel: @MainActor @escaping () -> Void
    ) {
        self.title = title
        self.models = models
        let labels = (groupLabels?.count == models.count) ? groupLabels : nil
        self.groupLabels = labels
        self.currentModelId = currentModelId
        self.currentIndex = currentIndex
        self.onSelect = onSelect
        self.onCancel = onCancel

        // Unique group labels, first occurrence wins, slot order preserved.
        var unique: [String] = []
        for label in labels ?? [] where !unique.contains(label) {
            unique.append(label)
        }
        self.tabs = unique.count > 1 ? ["All"] + unique : []

        self.visible = Array(models.indices)
        // Start on the current row: an explicit index wins, else the first
        // model matching currentModelId, else the top.
        let initial = currentIndex
            ?? models.firstIndex(where: { $0.id == currentModelId })
            ?? 0
        self.core = ModalListCore(
            rows: [],
            selectedIndex: initial,
            emptyMessage: "(no models available for this provider)"
        )
        core.setRows(rows(for: visible), selectedIndex: initial)
    }

    // MARK: - Filtering

    /// Index of the active model in `models`, or nil when it isn't listed.
    private var activeModelIndex: Int? {
        currentIndex ?? models.firstIndex(where: { $0.id == currentModelId })
    }

    private func rows(for indices: [Int]) -> [ModalListCore.Row] {
        let active = activeModelIndex
        return indices.map { i in
            ModalListCore.Row(
                label: models[i].id,
                detail: models[i].name,
                // Group headers only make sense on the unfiltered list; a
                // provider tab already names the single group it shows.
                group: activeTab == 0 ? groupLabels?[i] : nil,
                isCurrent: active != nil ? i == active : models[i].id == currentModelId
            )
        }
    }

    /// Re-derive the visible rows for `activeTab` + `query` (intersection).
    /// The active model's row stays selected when it is visible under the
    /// filters; otherwise selection falls back to the first row. Scroll
    /// resets with the new row set.
    private func applyFilters() {
        var indices: [Int]
        if activeTab == 0 {
            indices = Array(models.indices)
        } else {
            let label = tabs[activeTab]
            indices = models.indices.filter { groupLabels?[$0] == label }
        }
        if !query.isEmpty {
            let q = query.lowercased()
            indices = indices.filter { models[$0].id.lowercased().contains(q) }
        }
        visible = indices
        core.emptyMessage = query.isEmpty
            ? "(no models available for this provider)"
            : "(no models match \"\(query)\")"
        let selected = activeModelIndex.flatMap { indices.firstIndex(of: $0) } ?? 0
        core.setRows(rows(for: indices), selectedIndex: selected)
    }

    private func moveTab(_ delta: Int) {
        guard tabs.count > 1 else { return }
        activeTab = (activeTab + delta + tabs.count) % tabs.count
        applyFilters()
    }

    // MARK: - Modal

    func up() { core.up() }
    func down() { core.down() }
    func tab() { moveTab(+1) }
    func left() { moveTab(-1) }
    func right() { moveTab(+1) }

    func confirm() {
        guard !core.isEmpty, visible.indices.contains(core.selectedIndex) else { return }
        onSelect(models[visible[core.selectedIndex]])
    }

    /// Esc clears a non-empty filter query first; a second Esc (or Esc with
    /// no query) closes the modal.
    func cancel() {
        guard query.isEmpty else {
            query = ""
            applyFilters()
            return
        }
        onCancel()
    }

    /// Typed input edits the filter query: printable characters append,
    /// backspace deletes, pasted text is unwrapped, and everything else is
    /// swallowed so keystrokes never leak into the prompt box while the
    /// selector is open. Enter / Esc / Tab / arrows are keybound upstream
    /// and never reach here.
    func handleText(_ data: String) -> Bool {
        var text = data
        if text.hasPrefix("\u{1B}[200~") && text.hasSuffix("\u{1B}[201~") {
            text.removeFirst("\u{1B}[200~".count)
            text.removeLast("\u{1B}[201~".count)
        }
        if text == "\u{7F}" || text == "\u{08}" {
            if !query.isEmpty {
                query.removeLast()
                applyFilters()
            }
            return true
        }
        if text.hasPrefix("\u{1B}") {
            return true // unrecognized escape sequence — swallow it
        }
        var appended = ""
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\t" { continue }
            if let ascii = ch.asciiValue, ascii < 0x20 { continue }
            appended.append(ch)
        }
        if !appended.isEmpty {
            query.append(appended)
            applyFilters()
        }
        return true
    }

    func render(maxRows: Int, width: Int) -> [String] {
        var headers = [tabBarLine(width: width), filterLine(width: width)].compactMap { $0 }
        // Irreducible chrome is title + footer + one body row; when the
        // header lines would push the render past maxRows, drop one. With a
        // typed query the filter line must survive (it shows the query and
        // hosts the cursor), so the tab bar goes; with no query the filter
        // line is just a placeholder, and the tab bar — the only indicator
        // of the active provider filter — is the one worth keeping.
        while headers.count > 1, maxRows < 3 + headers.count {
            if query.isEmpty { headers.removeLast() } else { headers.removeFirst() }
        }
        return core.render(title: title, headerLines: headers, maxRows: maxRows, width: width)
    }

    /// One-line filter status. Typed input lands here, so the line always
    /// renders and carries the zero-width `CURSOR_MARKER` right after the
    /// query — the TUI parks the hardware cursor on the marker, putting the
    /// blinking cursor where the typing happens instead of the prompt box.
    /// While the query is empty the marker sits before a dim placeholder
    /// hint; a query too long for the row shows its tail (the cursor end).
    private func filterLine(width: Int) -> String {
        let label = Style.dimmed("filter: ")
        guard !query.isEmpty else {
            return "  " + label + CURSOR_MARKER + Style.dimmed("type a model id")
        }
        // The query owns the row: the dim match-count suffix renders only
        // while the query still gets a comfortable share of the width —
        // otherwise a truncated suffix fragment would crowd out the very
        // text the user is typing. An overlong query shows its TAIL (where
        // the cursor is).
        let suffixText = "   \(visible.count) match\(visible.count == 1 ? "" : "es")   Esc: clear"
        let labelCols = ANSI.visibleWidth("  ") + ANSI.visibleWidth(label)
        var suffix = Style.dimmed(suffixText)
        var budget = width - labelCols - ANSI.visibleWidth(suffixText)
        if budget < 16 {
            suffix = ""
            budget = width - labelCols
        }
        // No floor: a floored budget on a sub-14-column terminal would push
        // the row past `width` and the host's fit backstop would drop the
        // cursor marker along with the overflow.
        let shown = ANSI.fitTail(query, to: max(0, budget))
        return "  " + label + Theme.accentText(shown, bold: true) + CURSOR_MARKER + suffix
    }

    /// One-line provider tab bar (nil when a single provider makes it noise).
    /// Selected tab in bold accent, the rest dim, plus a dim key hint. Fitted
    /// to `width` in stages: full bar + hint → bar without the hint → a
    /// window of tabs that always contains the active one, with `…` marking
    /// hidden neighbors on either side.
    private func tabBarLine(width: Int) -> String? {
        guard tabs.count > 1 else { return nil }
        func paint(_ i: Int) -> String {
            i == activeTab ? Theme.accentText(tabs[i], bold: true) : Style.dimmed(tabs[i])
        }
        let fullBar = "  " + tabs.indices.map(paint).joined(separator: Style.dimmed(" · "))
        let withHint = fullBar + "   " + Style.dimmed("tab / ←→: filter provider")
        if ANSI.visibleWidth(withHint) <= width { return withHint }
        if ANSI.visibleWidth(fullBar) <= width { return fullBar }

        // Window the tabs around the active one: grow right first (reading
        // order), then left, stopping when the next tab no longer fits.
        let sep = " · "
        func cols(_ range: ClosedRange<Int>) -> Int {
            var w = 2 // leading indent
            for i in range {
                if i > range.lowerBound { w += sep.count }
                w += ANSI.visibleWidth(tabs[i])
            }
            // A hidden-neighbor "…" joins like a tab: 1 col + the separator.
            if range.lowerBound > 0 { w += 1 + sep.count }
            if range.upperBound < tabs.count - 1 { w += 1 + sep.count }
            return w
        }
        var lo = activeTab, hi = activeTab
        while true {
            if hi + 1 < tabs.count, cols(lo...(hi + 1)) <= width { hi += 1; continue }
            if lo > 0, cols((lo - 1)...hi) <= width { lo -= 1; continue }
            break
        }
        var parts: [String] = []
        if lo > 0 { parts.append(Style.dimmed("…")) }
        parts.append(contentsOf: (lo...hi).map(paint))
        if hi < tabs.count - 1 { parts.append(Style.dimmed("…")) }
        return "  " + parts.joined(separator: Style.dimmed(sep))
    }
}
