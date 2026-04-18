import Foundation
import KWWKAI

/// Arrow-key list for picking a `Model` from a fixed menu. Stays visually
/// minimal — one line per model, current selection flagged with `❯` +
/// accent color, the already-active model tagged `(current)`.
@MainActor
final class ModelSelectorModal: Modal {
    private let title: String
    private let models: [Model]
    private let currentModelId: String?
    private var selectedIndex: Int
    private let onSelect: @MainActor (Model) -> Void
    private let onCancel: @MainActor () -> Void

    init(
        title: String,
        models: [Model],
        currentModelId: String?,
        onSelect: @MainActor @escaping (Model) -> Void,
        onCancel: @MainActor @escaping () -> Void
    ) {
        self.title = title
        self.models = models
        self.currentModelId = currentModelId
        // Start on the current model if it's in the list; otherwise top.
        self.selectedIndex = models.firstIndex(where: { $0.id == currentModelId }) ?? 0
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
            for (i, model) in models.enumerated() {
                let prefix = i == selectedIndex ? Style.prompt("  ❯ ") : "    "
                let currentTag = model.id == currentModelId ? Style.dimmed("  · current") : ""
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
