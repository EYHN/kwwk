import Foundation
import KWWKAI

/// Arrow-key list for picking a `Model` from a fixed menu. Stays visually
/// minimal — one line per model, current selection flagged with `❯` +
/// accent color, the already-active model tagged `(current)`.
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
    private var selectedIndex: Int
    /// Top display-line of the visible window. Persistent so the list scrolls
    /// only when the selection crosses an edge (rather than re-centering on
    /// every keypress).
    private var scroll = 0
    private let onSelect: @MainActor (Model) -> Void
    private let onCancel: @MainActor () -> Void

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
        self.groupLabels = (groupLabels?.count == models.count) ? groupLabels : nil
        self.currentModelId = currentModelId
        self.currentIndex = currentIndex
        // Start on the current row: an explicit index wins, else the first
        // model matching currentModelId, else the top.
        self.selectedIndex = currentIndex
            ?? models.firstIndex(where: { $0.id == currentModelId })
            ?? 0
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    // MARK: - Modal

    func up() {
        guard !models.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + models.count) % models.count
    }

    func down() {
        guard !models.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % models.count
    }

    func confirm() {
        guard !models.isEmpty, models.indices.contains(selectedIndex) else { return }
        onSelect(models[selectedIndex])
    }

    func cancel() {
        onCancel()
    }

    func render(maxRows: Int) -> [String] {
        var out: [String] = []
        out.append("")
        out.append(Style.header("  \(title)"))
        guard !models.isEmpty else {
            out.append("")
            out.append(Style.dimmed("  (no models available for this provider)"))
            out.append("")
            out.append(Style.dimmed("  ↑/↓: move   Enter: confirm   Esc: cancel"))
            return out
        }

        // Expand to display lines (group headers interleaved with rows),
        // tracking where the selected row lands so the window keeps it in view.
        var lines: [(text: String, isHeader: Bool, group: String?)] = []
        var selectedLine = 0
        var lastGroup: String?
        for (i, model) in models.enumerated() {
            if let group = groupLabels?[i], group != lastGroup {
                lines.append((Style.dimmed("  ── \(group) ──"), true, group))
                lastGroup = group
            }
            let selected = i == selectedIndex
            if selected { selectedLine = lines.count }
            let prefix = selected ? Style.prompt("  ❯ ") : "    "
            // Ids repeat across providers, so tag only the exact active row.
            let isCurrent = currentIndex != nil ? (i == currentIndex) : (model.id == currentModelId)
            let currentTag = isCurrent ? Style.dimmed("  · current") : ""
            let body = selected
                ? Style.prompt(model.id) + "  " + Style.dimmed(model.name)
                : model.id + "  " + Style.dimmed(model.name)
            lines.append((prefix + body + currentTag, false, groupLabels?[i]))
        }

        // Body height budget = total minus chrome (blank + title + blank +
        // blank + footer = 5). Window the list so the prompt box is never
        // pushed off-screen and the selection stays reachable.
        let bodyBudget = max(3, maxRows - 5)
        let windowed = lines.count > bodyBudget
        // Reserve one line for the synthetic context header we may prepend when
        // the window opens mid-group, so the scroll window (and therefore the
        // selected row) is never squeezed out by it.
        let windowRows = windowed ? max(1, bodyBudget - 1) : bodyBudget

        // Scroll only at the edges.
        if selectedLine < scroll { scroll = selectedLine }
        else if selectedLine >= scroll + windowRows { scroll = selectedLine - windowRows + 1 }
        scroll = max(0, min(scroll, max(0, lines.count - windowRows)))

        var visible = Array(lines[scroll ..< min(lines.count, scroll + windowRows)])
        // If the window opens mid-group (its header scrolled off), prepend the
        // active group header for context. The reserved row above keeps this
        // within budget without dropping the selected row.
        if windowed, let first = visible.first, !first.isHeader, let group = first.group {
            visible.insert((Style.dimmed("  ── \(group) ──"), true, group), at: 0)
        }

        out.append("")
        for line in visible { out.append(line.text) }
        out.append("")
        let move = "↑/↓: move   Enter: confirm   Esc: cancel"
        out.append(Style.dimmed(windowed ? "  \(selectedIndex + 1)/\(models.count)   \(move)" : "  \(move)"))
        return out
    }
}
