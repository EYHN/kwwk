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

    func render() -> [String] {
        var out: [String] = []
        out.append("")
        out.append(Style.header("  \(title)"))
        out.append("")
        if models.isEmpty {
            out.append(Style.dimmed("  (no models available for this provider)"))
        } else {
            var lastGroup: String?
            for (i, model) in models.enumerated() {
                if let group = groupLabels?[i], group != lastGroup {
                    if lastGroup != nil { out.append("") }
                    out.append(Style.dimmed("  ── \(group) ──"))
                    lastGroup = group
                }
                let prefix = i == selectedIndex ? Style.prompt("  ❯ ") : "    "
                // The active row is pinned by index (ids repeat across
                // providers); tag only that exact row as current.
                let isCurrent = currentIndex != nil ? (i == currentIndex) : (model.id == currentModelId)
                let currentTag = isCurrent ? Style.dimmed("  · current") : ""
                let body = i == selectedIndex
                    ? Style.prompt(model.id) + "  " + Style.dimmed(model.name)
                    : model.id + "  " + Style.dimmed(model.name)
                out.append(prefix + body + currentTag)
            }
        }
        out.append("")
        out.append(Style.dimmed("  ↑/↓: move   Enter: confirm   Esc: cancel"))
        return out
    }
}
