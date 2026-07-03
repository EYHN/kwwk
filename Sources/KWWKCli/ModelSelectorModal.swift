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
    /// Indices into `models` currently listed (filtered by the active tab).
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

    /// Re-derive the visible rows for `activeTab`. The active model's row
    /// stays selected when it is visible under the tab; otherwise selection
    /// falls back to the first row. Scroll resets with the new row set.
    private func applyTabFilter() {
        let indices: [Int]
        if activeTab == 0 {
            indices = Array(models.indices)
        } else {
            let label = tabs[activeTab]
            indices = models.indices.filter { groupLabels?[$0] == label }
        }
        visible = indices
        let selected = activeModelIndex.flatMap { indices.firstIndex(of: $0) } ?? 0
        core.setRows(rows(for: indices), selectedIndex: selected)
    }

    private func moveTab(_ delta: Int) {
        guard tabs.count > 1 else { return }
        activeTab = (activeTab + delta + tabs.count) % tabs.count
        applyTabFilter()
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

    func cancel() {
        onCancel()
    }

    func render(maxRows: Int) -> [String] {
        core.render(title: title, header: tabBarLine(), maxRows: maxRows)
    }

    /// One-line provider tab bar (nil when a single provider makes it noise).
    /// Selected tab in bold accent, the rest dim, plus a dim key hint.
    private func tabBarLine() -> String? {
        guard tabs.count > 1 else { return nil }
        let rendered = tabs.enumerated().map { i, label in
            i == activeTab ? Theme.accentText(label, bold: true) : Style.dimmed(label)
        }
        return "  " + rendered.joined(separator: Style.dimmed(" · "))
            + "   " + Style.dimmed("tab / ←→: filter provider")
    }
}
