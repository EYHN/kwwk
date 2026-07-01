import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli

@MainActor
private func model(_ id: String, provider: String = "anthropic") -> Model {
    Model(
        id: id,
        name: id,
        api: "anthropic-messages",
        provider: provider,
        baseUrl: "https://api.anthropic.com",
        reasoning: false,
        input: [.text],
        contextWindow: 0,
        maxTokens: 0
    )
}

@Suite("ModelSelectorModal")
struct ModelSelectorModalTests {

    @MainActor
    @Test("current model is pre-selected")
    func preselectCurrent() {
        let models = [model("opus-4"), model("sonnet-4"), model("haiku-4")]
        let picked = Ref<String?>(nil)
        let cancelled = Ref<Bool>(false)
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "sonnet-4",
            onSelect: { picked.value = $0.id },
            onCancel: { cancelled.value = true }
        )
        modal.confirm()
        #expect(picked.value == "sonnet-4")
        #expect(cancelled.value == false)
    }

    @MainActor
    @Test("down / up wraps around the list")
    func wrapAround() {
        let models = [model("a"), model("b"), model("c")]
        let picked = Ref<String?>(nil)
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "a",
            onSelect: { picked.value = $0.id },
            onCancel: {}
        )
        modal.down(); modal.down(); modal.down() // a → b → c → a
        modal.confirm()
        #expect(picked.value == "a")

        let modal2 = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "a",
            onSelect: { picked.value = $0.id },
            onCancel: {}
        )
        modal2.up() // a → c (wraps)
        modal2.confirm()
        #expect(picked.value == "c")
    }

    @MainActor
    @Test("cancel fires the cancel callback, not select")
    func cancelDoesNotSelect() {
        let picked = Ref<String?>(nil)
        let cancelled = Ref<Bool>(false)
        let modal = ModelSelectorModal(
            title: "t",
            models: [model("a"), model("b")],
            currentModelId: "a",
            onSelect: { picked.value = $0.id },
            onCancel: { cancelled.value = true }
        )
        modal.cancel()
        #expect(cancelled.value == true)
        #expect(picked.value == nil)
    }

    @MainActor
    @Test("render marks current + selected rows")
    func renderMarkers() {
        let models = [model("a"), model("b"), model("c")]
        let modal = ModelSelectorModal(
            title: "Pick one",
            models: models,
            currentModelId: "b",
            onSelect: { _ in },
            onCancel: {}
        )
        let lines = modal.render(maxRows: 40)
        // Current (`b`) should get the pre-selection + "· current" tag.
        let bLine = lines.first(where: { $0.contains("b") && !$0.contains("Pick one") })
        #expect(bLine?.contains("current") == true)
        #expect(bLine?.contains("❯") == true)
    }

    @MainActor
    @Test("long list windows to maxRows and keeps the selection visible")
    func windowsToHeight() {
        let models = (0..<50).map { model("m\($0)") }
        let modal = ModelSelectorModal(
            title: "Pick one",
            models: models,
            currentModelId: nil,
            onSelect: { _ in },
            onCancel: {}
        )
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }
        // At every scroll position, and across a range of terminal heights
        // (including tiny ones), the render must fit the budget AND keep the
        // selected row visible — including mid-list, where a context header
        // may be prepended.
        for maxRows in [4, 6, 9, 12, 40] {
            // 50 downs on a 50-item list wraps back to selection 0, so each
            // outer iteration starts from the top.
            for step in 0..<50 {
                let lines = modal.render(maxRows: maxRows).map(strip)
                #expect(lines.count <= maxRows, "overflow at maxRows \(maxRows), selection \(step)")
                #expect(lines.contains(where: { $0.contains("❯ m\(step)  ") }),
                        "selected row m\(step) must be within the window at maxRows \(maxRows)")
                modal.down()
            }
        }
        // Position indicator shows while windowed.
        #expect(modal.render(maxRows: 12).contains(where: { $0.contains("/50") }))
    }

    @MainActor
    @Test("empty models list renders a helpful message, doesn't crash")
    func emptyModels() {
        let picked = Ref<String?>(nil)
        let cancelled = Ref<Bool>(false)
        let modal = ModelSelectorModal(
            title: "t",
            models: [],
            currentModelId: nil,
            onSelect: { picked.value = $0.id },
            onCancel: { cancelled.value = true }
        )
        // Safe to call navigation/confirm on an empty list.
        modal.up(); modal.down(); modal.confirm()
        #expect(picked.value == nil)
        let lines = modal.render(maxRows: 40)
        #expect(lines.contains(where: { $0.contains("no models") }))
    }
}

@MainActor
private final class Ref<T> {
    var value: T
    init(_ v: T) { self.value = v }
}
