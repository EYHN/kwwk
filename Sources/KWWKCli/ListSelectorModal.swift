import Foundation

/// Edge-scroll for a windowed list: the top offset of the visible window,
/// given the current `selection`, the total row `count`, the `windowSize`,
/// and the `previous` offset. Keeps `previous` unless the selection crossed
/// the window's top or bottom edge, then shifts by the minimum — so up/down
/// move the highlight within the window first and only scroll at an edge —
/// and clamps to the valid range (covering a shrunken window or a selection
/// jump). Shared by `ModalListCore` and the slash popup so the formula is
/// written once.
func edgeScrollOffset(selection: Int, count: Int, windowSize: Int, previous: Int) -> Int {
    var scroll = previous
    if selection < scroll {
        scroll = selection
    } else if selection >= scroll + windowSize {
        scroll = selection - windowSize + 1
    }
    return max(0, min(scroll, max(0, count - windowSize)))
}

/// Selection + windowing + render engine shared by list-style modals.
/// `ModelSelectorModal` builds on it for `/model`; `ListSelectorModal` wraps
/// it for plain string-row pickers (e.g. the `/login` provider list) so new
/// selectors never re-implement the scroll math.
///
/// Owns: wraparound up/down selection, edge-scrolling so the selection stays
/// visible without re-centering on every keypress, interleaved group headers
/// (with a synthetic context header when the window opens mid-group), the
/// `· current` tag, and the height-budgeted render (title + optional header
/// line + windowed body + footer, all within `maxRows`).
@MainActor
final class ModalListCore {
    /// One selectable row. `label` is the primary text (accent-highlighted
    /// when selected), `detail` a dim suffix, `group` an optional section
    /// header rendered when it differs from the previous row's, and
    /// `isCurrent` tags the row `· current`.
    struct Row {
        let label: String
        let detail: String?
        let group: String?
        let isCurrent: Bool

        init(label: String, detail: String? = nil, group: String? = nil, isCurrent: Bool = false) {
            self.label = label
            self.detail = detail
            self.group = group
            self.isCurrent = isCurrent
        }
    }

    private(set) var rows: [Row]
    private(set) var selectedIndex: Int
    /// Message body rendered when `rows` is empty (already sans styling; the
    /// core dims it).
    var emptyMessage: String
    /// Top display-line of the visible window. Persistent so the list scrolls
    /// only when the selection crosses an edge (rather than re-centering on
    /// every keypress).
    private var scroll = 0

    init(rows: [Row], selectedIndex: Int = 0, emptyMessage: String = "(nothing to select)") {
        self.rows = rows
        self.selectedIndex = rows.isEmpty ? 0 : min(max(0, selectedIndex), rows.count - 1)
        self.emptyMessage = emptyMessage
    }

    var isEmpty: Bool { rows.isEmpty }

    func up() {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + rows.count) % rows.count
    }

    func down() {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % rows.count
    }

    /// Replace the rows (a filter change) and reset the scroll window; the
    /// next render re-derives the window around the new selection.
    func setRows(_ rows: [Row], selectedIndex: Int) {
        self.rows = rows
        self.selectedIndex = rows.isEmpty ? 0 : min(max(0, selectedIndex), rows.count - 1)
        self.scroll = 0
    }

    /// Render the full modal surface. `headerLines`, when present, are extra
    /// chrome lines between the title and the list (e.g. a provider tab bar
    /// or a filter line) and are charged against the `maxRows` budget so
    /// windowing never overflows.
    func render(title: String, headerLines: [String] = [], maxRows: Int) -> [String] {
        // Cosmetic blank spacers (above the list and above the footer) are
        // dropped on short terminals so the render stays within `maxRows` —
        // title + headers + body + footer is the irreducible minimum.
        let headerRows = headerLines.count
        let roomy = maxRows >= 9 + headerRows
        var out: [String] = []
        if roomy { out.append("") }
        out.append(Style.header("  \(title)"))
        out.append(contentsOf: headerLines)
        guard !rows.isEmpty else {
            if roomy { out.append("") }
            out.append(Style.dimmed("  \(emptyMessage)"))
            if roomy { out.append("") }
            out.append(Style.dimmed("  ↑/↓: move   Enter: confirm   Esc: cancel"))
            return out
        }

        // Expand to display lines (group headers interleaved with rows),
        // tracking where the selected row lands so the window keeps it in view.
        var lines: [(text: String, isHeader: Bool, group: String?)] = []
        var selectedLine = 0
        var lastGroup: String?
        for (i, row) in rows.enumerated() {
            if let group = row.group, group != lastGroup {
                lines.append((Style.dimmed("  ── \(group) ──"), true, group))
                lastGroup = group
            }
            let selected = i == selectedIndex
            if selected { selectedLine = lines.count }
            let prefix = selected ? Style.prompt("  ❯ ") : "    "
            let currentTag = row.isCurrent ? Style.dimmed("  · current") : ""
            let detail = row.detail.map { "  " + Style.dimmed($0) } ?? ""
            let body = (selected ? Style.prompt(row.label) : row.label) + detail
            lines.append((prefix + body + currentTag, false, row.group))
        }

        // Body height budget = total minus chrome. Chrome is title + footer
        // (2), plus the optional header line, plus the three blank spacers
        // when roomy. Window the list so the prompt box is never pushed
        // off-screen and the selection stays reachable — and the whole render
        // stays within `maxRows`.
        let chrome = (roomy ? 5 : 2) + headerRows
        let bodyBudget = max(1, maxRows - chrome)
        let windowed = lines.count > bodyBudget
        // Reserve one line for the synthetic context header we may prepend
        // when the window opens mid-group, so the scroll window (and therefore
        // the selected row) is never squeezed out by it. Ungrouped rows can
        // never trigger that prepend, so they keep the full budget.
        let hasGroups = lines.contains { $0.group != nil }
        let windowRows = (windowed && hasGroups) ? max(1, bodyBudget - 1) : bodyBudget

        // Scroll only at the edges.
        scroll = edgeScrollOffset(
            selection: selectedLine, count: lines.count,
            windowSize: windowRows, previous: scroll
        )

        var visible = Array(lines[scroll ..< min(lines.count, scroll + windowRows)])
        // If the window opens mid-group (its header scrolled off), prepend the
        // active group header for context — but only when the reserved row
        // actually exists (degenerate heights clamp `windowRows` back up to 1,
        // eating the reserve), so the render never exceeds `maxRows`.
        if windowed, windowRows < bodyBudget,
           let first = visible.first, !first.isHeader, let group = first.group {
            visible.insert((Style.dimmed("  ── \(group) ──"), true, group), at: 0)
        }

        if roomy { out.append("") }
        for line in visible { out.append(line.text) }
        if roomy { out.append("") }
        let move = "↑/↓: move   Enter: confirm   Esc: cancel"
        out.append(Style.dimmed(windowed ? "  \(selectedIndex + 1)/\(rows.count)   \(move)" : "  \(move)"))
        return out
    }
}

/// Plain string-row selector modal: a title, rows with a label + optional dim
/// detail, arrow-key selection, `onSelect(index)` / `onCancel`. Reuses
/// `ModalListCore`, so windowing/scroll behavior matches `/model` without
/// duplicating it. `/login`'s provider picker is built on this.
@MainActor
final class ListSelectorModal: Modal {
    /// One pickable row: primary `label` plus an optional dim `detail`.
    struct Item {
        let label: String
        let detail: String?

        init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    private let title: String
    private let core: ModalListCore
    private let onSelect: @MainActor (Int) -> Void
    private let onCancel: @MainActor () -> Void

    init(
        title: String,
        items: [Item],
        selectedIndex: Int = 0,
        emptyMessage: String = "(nothing to select)",
        onSelect: @MainActor @escaping (Int) -> Void,
        onCancel: @MainActor @escaping () -> Void
    ) {
        self.title = title
        self.core = ModalListCore(
            rows: items.map { ModalListCore.Row(label: $0.label, detail: $0.detail) },
            selectedIndex: selectedIndex,
            emptyMessage: emptyMessage
        )
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    func up() { core.up() }
    func down() { core.down() }

    func confirm() {
        guard !core.isEmpty else { return }
        onSelect(core.selectedIndex)
    }

    func cancel() { onCancel() }

    func render(maxRows: Int) -> [String] {
        core.render(title: title, maxRows: maxRows)
    }
}
