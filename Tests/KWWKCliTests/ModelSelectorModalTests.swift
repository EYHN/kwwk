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
        baseURL: "https://api.anthropic.com",
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
        let lines = modal.render(maxRows: 40, width: 80).map(strip)
        // Current (`b`) should get the pre-selection + "· current" tag.
        // Match the row body ("b  b" = id + name detail) so chrome lines
        // that merely contain the letter b (e.g. the filter hint) don't win.
        let bLine = lines.first(where: { $0.contains("b  b") && !$0.contains("Pick one") })
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
                let lines = modal.render(maxRows: maxRows, width: 80).map(strip)
                #expect(lines.count <= maxRows, "overflow at maxRows \(maxRows), selection \(step)")
                #expect(lines.contains(where: { $0.contains("❯ m\(step)  ") }),
                        "selected row m\(step) must be within the window at maxRows \(maxRows)")
                modal.down()
            }
        }
        // Position indicator shows while windowed.
        #expect(modal.render(maxRows: 12, width: 80).contains(where: { $0.contains("/50") }))
    }

    // MARK: - Provider tab bar

    /// Two providers sharing one model id, plus a provider-unique model each.
    @MainActor
    private func multiProviderFixture() -> (models: [Model], groups: [String]) {
        let models = [
            model("opus-4", provider: "anthropic"),
            model("sonnet-4", provider: "anthropic"),
            model("gpt-5", provider: "openai"),
            model("sonnet-4", provider: "openai"),
        ]
        let groups = ["Anthropic", "Anthropic", "OpenAI", "OpenAI"]
        return (models, groups)
    }

    private func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    @MainActor
    @Test("multi-provider list renders the tab bar; tab cycles filters and wraps")
    func tabCyclingFiltersAndWraps() {
        let (models, groups) = multiProviderFixture()
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "opus-4",
            groupLabels: groups,
            currentIndex: 0,
            onSelect: { _ in },
            onCancel: {}
        )
        func body() -> [String] { modal.render(maxRows: 40, width: 80).map(strip) }

        // "All" tab: every row + the tab bar with the filter hint.
        var lines = body()
        #expect(lines.contains(where: { $0.contains("All") && $0.contains("tab / ←→: filter provider") }))
        #expect(lines.contains(where: { $0.contains("opus-4") }))
        #expect(lines.contains(where: { $0.contains("gpt-5") }))

        // Tab → Anthropic: OpenAI rows filtered out.
        modal.tab()
        lines = body()
        #expect(lines.contains(where: { $0.contains("opus-4") }))
        #expect(!lines.contains(where: { $0.contains("gpt-5") }))

        // Tab → OpenAI: Anthropic-only rows filtered out.
        modal.tab()
        lines = body()
        #expect(lines.contains(where: { $0.contains("gpt-5") }))
        #expect(!lines.contains(where: { $0.contains("opus-4") }))

        // Tab wraps back to "All".
        modal.tab()
        lines = body()
        #expect(lines.contains(where: { $0.contains("opus-4") }))
        #expect(lines.contains(where: { $0.contains("gpt-5") }))

        // Left from "All" wraps to the last tab (OpenAI); right moves forward.
        modal.left()
        lines = body()
        #expect(lines.contains(where: { $0.contains("gpt-5") }))
        #expect(!lines.contains(where: { $0.contains("opus-4") }))
        modal.right() // back to All (wrap)
        lines = body()
        #expect(lines.contains(where: { $0.contains("opus-4") }))
    }

    @MainActor
    @Test("filtered tab confirm picks from the filtered rows")
    func filteredConfirm() {
        let (models, groups) = multiProviderFixture()
        let picked = Ref<Model?>(nil)
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "opus-4",
            groupLabels: groups,
            currentIndex: 0,
            onSelect: { picked.value = $0 },
            onCancel: {}
        )
        modal.tab(); modal.tab() // → OpenAI tab; current row not visible → first row
        modal.confirm()
        #expect(picked.value?.id == "gpt-5")
        #expect(picked.value?.provider == "openai")
    }

    @MainActor
    @Test("single provider renders exactly the ungrouped selector — no tab bar")
    func singleProviderHidesTabBar() {
        let models = [model("a"), model("b")]
        let plain = ModelSelectorModal(
            title: "t", models: models, currentModelId: "a",
            onSelect: { _ in }, onCancel: {}
        )
        let grouped = ModelSelectorModal(
            title: "t", models: models, currentModelId: "a",
            groupLabels: ["Anthropic", "Anthropic"],
            onSelect: { _ in }, onCancel: {}
        )
        #expect(!plain.render(maxRows: 40, width: 80).contains(where: { $0.contains("filter provider") }))
        #expect(!grouped.render(maxRows: 40, width: 80).contains(where: { $0.contains("filter provider") }))
        // A single-label grouping still renders its group header, as today —
        // but tab/left/right are no-ops.
        grouped.tab(); grouped.left(); grouped.right()
        #expect(grouped.render(maxRows: 40, width: 80).map(strip)
            .contains(where: { $0.contains("── Anthropic ──") }))
    }

    @MainActor
    @Test("current-model selection is preserved across tab switches when visible")
    func currentSelectionSurvivesTabSwitch() {
        let (models, groups) = multiProviderFixture()
        // Current model is the OpenAI copy of sonnet-4 (index 3).
        let picked = Ref<Model?>(nil)
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "sonnet-4",
            groupLabels: groups,
            currentIndex: 3,
            onSelect: { picked.value = $0 },
            onCancel: {}
        )
        // All → OpenAI: the current row is visible under this tab → stays selected.
        modal.tab(); modal.tab()
        modal.confirm()
        #expect(picked.value?.id == "sonnet-4")
        #expect(picked.value?.provider == "openai")

        // OpenAI → All: still pinned to the exact current row.
        modal.tab()
        modal.confirm()
        #expect(picked.value?.provider == "openai")

        // All → Anthropic: current row not visible → first row selected.
        modal.tab()
        modal.confirm()
        #expect(picked.value?.id == "opus-4")
        #expect(picked.value?.provider == "anthropic")
    }

    @MainActor
    @Test("tab bar line is charged against the maxRows budget")
    func tabBarWithinBudget() {
        let models = (0..<30).map { model("a\($0)", provider: "anthropic") }
            + (0..<30).map { model("o\($0)", provider: "openai") }
        let groups = Array(repeating: "Anthropic", count: 30) + Array(repeating: "OpenAI", count: 30)
        let modal = ModelSelectorModal(
            title: "t", models: models, currentModelId: nil, groupLabels: groups,
            onSelect: { _ in }, onCancel: {}
        )
        for maxRows in [4, 6, 9, 12, 40] {
            for _ in 0..<60 {
                let lines = modal.render(maxRows: maxRows, width: 80)
                #expect(lines.count <= maxRows, "overflow at maxRows \(maxRows)")
                modal.down()
            }
        }
    }

    // MARK: - Typed filter

    @MainActor
    @Test("typing filters the list by model id, case-insensitively")
    func typedFilter() {
        let models = [model("opus-4"), model("sonnet-4"), model("haiku-4")]
        let picked = Ref<String?>(nil)
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "opus-4",
            onSelect: { picked.value = $0.id },
            onCancel: {}
        )
        #expect(modal.handleText("SON") == true)
        let lines = modal.render(maxRows: 40, width: 80).map(strip)
        #expect(lines.contains(where: { $0.contains("sonnet-4") }))
        #expect(!lines.contains(where: { $0.contains("opus-4") }))
        #expect(lines.contains(where: { $0.contains("filter: SON") }))
        modal.confirm()
        #expect(picked.value == "sonnet-4")
    }

    @MainActor
    @Test("backspace edits the query; no-match shows a message; confirm is a no-op")
    func filterBackspaceAndNoMatch() {
        let models = [model("opus-4"), model("sonnet-4")]
        let picked = Ref<String?>(nil)
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: nil,
            onSelect: { picked.value = $0.id },
            onCancel: {}
        )
        _ = modal.handleText("zzz")
        var lines = modal.render(maxRows: 40, width: 80).map(strip)
        #expect(lines.contains(where: { $0.contains("no models match \"zzz\"") }))
        modal.confirm()
        #expect(picked.value == nil)

        // Backspace down to "z" — still no match; then to empty — full list.
        _ = modal.handleText("\u{7F}")
        _ = modal.handleText("\u{7F}")
        _ = modal.handleText("\u{7F}")
        lines = modal.render(maxRows: 40, width: 80).map(strip)
        #expect(lines.contains(where: { $0.contains("opus-4") }))
        #expect(lines.contains(where: { $0.contains("sonnet-4") }))
    }

    @MainActor
    @Test("Esc clears a non-empty query first, then closes")
    func escClearsQueryThenCloses() {
        let cancelled = Ref<Bool>(false)
        let modal = ModelSelectorModal(
            title: "t",
            models: [model("opus-4"), model("sonnet-4")],
            currentModelId: nil,
            onSelect: { _ in },
            onCancel: { cancelled.value = true }
        )
        _ = modal.handleText("opus")
        modal.cancel()
        #expect(cancelled.value == false)
        let lines = modal.render(maxRows: 40, width: 80).map(strip)
        #expect(lines.contains(where: { $0.contains("sonnet-4") })) // filter cleared
        modal.cancel()
        #expect(cancelled.value == true)
    }

    @MainActor
    @Test("query composes with the provider tab filter")
    func filterComposesWithTabs() {
        let (models, groups) = multiProviderFixture()
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "opus-4",
            groupLabels: groups,
            currentIndex: 0,
            onSelect: { _ in },
            onCancel: {}
        )
        _ = modal.handleText("sonnet")
        modal.tab() // → Anthropic
        var lines = modal.render(maxRows: 40, width: 80).map(strip)
        #expect(lines.contains(where: { $0.contains("sonnet-4") }))
        #expect(!lines.contains(where: { $0.contains("opus-4") }))
        #expect(lines.filter { $0.contains("sonnet-4") }.count == 1)
        modal.tab() // → OpenAI: its own sonnet-4 copy
        lines = modal.render(maxRows: 40, width: 80).map(strip)
        #expect(lines.contains(where: { $0.contains("sonnet-4") }))
        #expect(!lines.contains(where: { $0.contains("gpt-5") }))
    }

    @MainActor
    @Test("pasted text is unwrapped and escape sequences are swallowed")
    func pasteAndEscapes() {
        let models = [model("opus-4"), model("sonnet-4")]
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: nil,
            onSelect: { _ in },
            onCancel: {}
        )
        #expect(modal.handleText("\u{1B}[200~son\u{1B}[201~") == true)
        #expect(modal.handleText("\u{1B}[1;5C") == true) // swallowed, not typed
        let lines = modal.render(maxRows: 40, width: 80).map(strip)
        #expect(lines.contains(where: { $0.contains("filter: son") }))
        #expect(lines.contains(where: { $0.contains("sonnet-4") }))
        #expect(!lines.contains(where: { $0.contains("opus-4") }))
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
        let lines = modal.render(maxRows: 40, width: 80)
        #expect(lines.contains(where: { $0.contains("no models") }))
    }
}

@MainActor
private final class Ref<T> {
    var value: T
    init(_ v: T) { self.value = v }
}
