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
        let lines = modal.render()
        // Current (`b`) should get the pre-selection + "· current" tag.
        let bLine = lines.first(where: { $0.contains("b") && !$0.contains("Pick one") })
        #expect(bLine?.contains("current") == true)
        #expect(bLine?.contains("❯") == true)
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
        let lines = modal.render()
        #expect(lines.contains(where: { $0.contains("no models") }))
    }
}

@MainActor
private final class Ref<T> {
    var value: T
    init(_ v: T) { self.value = v }
}
