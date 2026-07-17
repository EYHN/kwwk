import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli

@MainActor
private func model(_ id: String, name: String? = nil, provider: String = "anthropic") -> Model {
    Model(
        id: id,
        name: name ?? id,
        api: "anthropic-messages",
        provider: provider,
        baseURL: "https://api.anthropic.com",
        reasoning: false,
        input: [.text],
        contextWindow: 0,
        maxTokens: 0
    )
}

/// Width-contract + hardware-cursor coverage for the modal system.
///
/// The frame keeps only the BOTTOM of a modal that overflows its height
/// budget, so any emitted line wider than the terminal (which the terminal
/// would soft-wrap into extra physical rows) silently pushes the title off
/// screen. Every modal must therefore emit lines that fit `width`.
///
/// Text-input surfaces (the /model filter, ask's "Other" input, form fields)
/// must carry the zero-width `CURSOR_MARKER` so the TUI parks the hardware
/// cursor at the modal's caret instead of the prompt box below it.
@MainActor
@Suite("Modal width contract + cursor markers")
struct ModalWidthCursorTests {

    /// The /model regression: long ids + long display names on a narrow
    /// terminal. One entry must stay one row (tail-truncated with `…`), and
    /// the whole render must respect both budgets so the title/tab bar/filter
    /// chrome is never pushed out.
    @Test("model selector rows never exceed the width, so maxRows holds")
    func modelSelectorWidthContract() {
        let models = (1...40).map { i in
            model(
                "claude-fable-5-thinking-extra-high-\(String(format: "%02d", i))",
                name: "Fable 5 1M Extra High Thinking (NO ZDR) variant \(i)",
                provider: i % 2 == 0 ? "cursor" : "anthropic (claude pro/max)"
            )
        }
        let modal = ModelSelectorModal(
            title: "Select a model",
            models: models,
            currentModelId: models[0].id,
            groupLabels: models.map(\.provider),
            onSelect: { _ in },
            onCancel: {}
        )
        let width = 60
        let maxRows = 18
        for step in 0..<45 {
            let lines = modal.render(maxRows: maxRows, width: width)
            #expect(lines.count <= maxRows, "overflowed maxRows at step \(step)")
            #expect(
                lines.allSatisfy { ANSI.visibleWidth($0) <= width },
                "line wider than terminal at step \(step)"
            )
            // The title must survive scrolling — it is exactly what the
            // suffix-clipping bug used to eat.
            #expect(lines.contains(where: { $0.contains("Select a model") }))
            modal.down()
        }
    }

    @Test("model selector filter line carries the cursor marker at the caret")
    func modelSelectorFilterCursor() {
        let modal = ModelSelectorModal(
            title: "t",
            models: [model("alpha"), model("beta")],
            currentModelId: "alpha",
            onSelect: { _ in },
            onCancel: {}
        )
        // Empty query: marker sits before the placeholder hint.
        let idle = modal.render(maxRows: 20, width: 80)
        #expect(idle.contains(where: { $0.contains(CURSOR_MARKER) }))

        _ = modal.handleText("alp")
        let typing = modal.render(maxRows: 20, width: 80)
        let filterRow = typing.first(where: { $0.contains(CURSOR_MARKER) })
        #expect(filterRow != nil)
        // Marker directly after the typed query.
        #expect(ANSI.stripEscapes(filterRow ?? "").contains("alp"))
    }

    @Test("overlong filter query shows its tail and keeps the marker visible")
    func modelSelectorLongQueryTail() {
        let modal = ModelSelectorModal(
            title: "t",
            models: [model("alpha")],
            currentModelId: "alpha",
            onSelect: { _ in },
            onCancel: {}
        )
        _ = modal.handleText(String(repeating: "x", count: 100) + "TAIL")
        let width = 50
        let lines = modal.render(maxRows: 20, width: width)
        #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= width })
        let filterRow = lines.first(where: { $0.contains(CURSOR_MARKER) })
        #expect(filterRow != nil)
        #expect(ANSI.stripEscapes(filterRow ?? "").contains("TAIL"))
    }

    @Test("provider tab bar is windowed to the width and keeps the active tab")
    func modelSelectorTabBarFits() {
        let providers = [
            "ChatGPT Codex", "Anthropic (Claude Pro/Max)", "Cursor",
            "Kimi For Coding", "Z.AI Coding Plan",
        ]
        let models = providers.enumerated().map { i, p in
            model("m\(i)", provider: p)
        }
        let modal = ModelSelectorModal(
            title: "t",
            models: models,
            currentModelId: "m0",
            groupLabels: providers,
            onSelect: { _ in },
            onCancel: {}
        )
        let width = 44
        for _ in 0..<providers.count + 1 {
            modal.tab()
            let lines = modal.render(maxRows: 20, width: width)
            #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= width })
        }
        // Whatever tab is active must always be visible in the fitted bar.
        var sawLastTab = false
        for _ in 0...providers.count {
            let lines = modal.render(maxRows: 20, width: width).map(ANSI.stripEscapes)
            if lines.contains(where: { $0.contains("Z.AI Coding Plan") }) { sawLastTab = true }
            modal.tab()
        }
        #expect(sawLastTab, "active tab scrolled out of the fitted tab bar")
    }

    @Test("list selector + session-style rows are tail-truncated, not wrapped")
    func listSelectorWidthContract() {
        let items = (1...20).map { i in
            ListSelectorModal.Item(
                label: "provider-with-a-very-long-name-number-\(i)",
                detail: "an extremely long detail string that would surely wrap on a narrow terminal"
            )
        }
        let modal = ListSelectorModal(title: "Pick", items: items, onSelect: { _ in }, onCancel: {})
        let width = 40
        let maxRows = 10
        let lines = modal.render(maxRows: maxRows, width: width)
        #expect(lines.count <= maxRows)
        #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= width })
        #expect(lines.contains(where: { $0.contains("Pick") }))
    }

    @Test("form modal focused field carries the cursor marker")
    func formModalCursorMarker() {
        let modal = FormModal(
            title: "Log in",
            fields: [
                APIKeyFormField(key: "apiKey", label: "API key", placeholder: "sk-…"),
                APIKeyFormField(key: "baseURL", label: "Base URL", required: false),
            ],
            onSubmit: { _ in },
            onCancel: {}
        )
        // Placeholder state: marker on the focused (first) input row.
        let idle = modal.render(maxRows: 24, width: 80)
        #expect(idle.filter { $0.contains(CURSOR_MARKER) }.count == 1)

        _ = modal.handleText("secret")
        let typed = modal.render(maxRows: 24, width: 80)
        let row = typed.first(where: { $0.contains(CURSOR_MARKER) })
        #expect(ANSI.stripEscapes(row ?? "").contains("secret"))

        // Focus moves → so does the marker.
        modal.tab()
        let second = modal.render(maxRows: 24, width: 80)
        let secondRow = second.first(where: { $0.contains(CURSOR_MARKER) })
        #expect(!(ANSI.stripEscapes(secondRow ?? "").contains("secret")))
    }

    @Test("form modal shows the tail of an overlong value with the cursor")
    func formModalLongValueTail() {
        let modal = FormModal(
            title: "Log in",
            fields: [APIKeyFormField(key: "apiKey", label: "API key")],
            onSubmit: { _ in },
            onCancel: {}
        )
        _ = modal.handleText(String(repeating: "k", count: 120) + "TAIL")
        let width = 50
        let lines = modal.render(maxRows: 24, width: width)
        #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= width })
        let row = lines.first(where: { $0.contains(CURSOR_MARKER) })
        let plain = ANSI.stripEscapes(row ?? "")
        #expect(plain.contains("TAIL"))
        #expect(plain.contains("…"))
    }

    @Test("degenerate widths never compose rows wider than the budget")
    func degenerateWidthsKeepMarker() {
        // Input rows are prefix (4 cols) + value; a floored value budget used
        // to overflow `width` below ~8 columns, and the host's fit backstop
        // then cut the trailing cursor marker. Rows must fit as long as the
        // prefix itself fits, keeping the marker alive.
        let form = FormModal(
            title: "t",
            fields: [APIKeyFormField(key: "k", label: "Key")],
            onSubmit: { _ in },
            onCancel: {}
        )
        _ = form.handleText("supercalifragilistic")
        let selector = ModelSelectorModal(
            title: "t",
            models: [model("alpha"), model("beta")],
            currentModelId: "alpha",
            onSelect: { _ in },
            onCancel: {}
        )
        _ = selector.handleText("alphabetically-long-query")
        // Each surface is checked from the width its fixed prefix needs
        // (4-col form prefix; 10-col "  filter: " label) — below that even
        // the chrome cannot fit and the host backstop takes over.
        func assertMarkerRowsFit(_ lines: [String], width: Int) {
            for line in lines where line.contains(CURSOR_MARKER) {
                #expect(
                    ANSI.visibleWidth(line) <= width,
                    "marker row wider than width \(width): \(ANSI.stripEscapes(line))"
                )
            }
        }
        for width in 4...14 {
            assertMarkerRowsFit(form.render(maxRows: 24, width: width), width: width)
        }
        for width in 10...14 {
            assertMarkerRowsFit(selector.render(maxRows: 24, width: width), width: width)
        }
    }

    @Test("fitTail keeps the tail within the width, wide-char aware")
    func fitTailBasics() {
        #expect(ANSI.fitTail("short", to: 10) == "short")
        #expect(ANSI.fitTail("abcdefghij", to: 5) == "…ghij")
        // CJK: each char is 2 columns; the "…" costs 1.
        let cjk = ANSI.fitTail("一二三四五六", to: 5)
        #expect(cjk == "…五六")
        #expect(ANSI.visibleWidth(cjk) <= 5)
        #expect(ANSI.fitTail("anything", to: 0) == "")
    }

    @Test("ask other-input carries the cursor marker at the buffer end")
    func askOtherInputCursorMarker() {
        let question = AskQuestion(
            id: "q", question: "Q?",
            options: [AskOption(label: "A", description: nil)],
            multi: false, recommended: nil
        )
        let prompt = AskPrompt(
            question: question, progressText: nil,
            allowBack: false, allowForward: false,
            previousSelection: [], previousCustomInput: nil
        )
        let modal = AskModal(prompt: prompt) { _ in }
        modal.up() // onto "Other"
        modal.confirm()

        // Placeholder state.
        let idle = modal.render(maxRows: 12, width: 60)
        #expect(idle.contains(where: { $0.contains(CURSOR_MARKER) }))

        _ = modal.handleText("my answer")
        let typed = modal.render(maxRows: 12, width: 60)
        let row = typed.first(where: { $0.contains(CURSOR_MARKER) })
        #expect(ANSI.stripEscapes(row ?? "").contains("my answer"))

        // List mode never claims the cursor — typing falls through to the
        // prompt box there, and the marker must follow the actual target.
        modal.cancel() // back to list
        let list = modal.render(maxRows: 12, width: 60)
        #expect(!list.contains(where: { $0.contains(CURSOR_MARKER) }))
    }
}
