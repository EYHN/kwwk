import Foundation
import Testing
@testable import KWWKCli

// Regression: pressing ↑/↓ in the login API-key form was breaking the
// layout. Root cause was a focus-dependent cursor marker / caret that
// changed a row's visible width, so wrapping behavior on narrow terminals
// flipped between frames and left stale wrapped rows on screen.
//
// These tests pin the invariant on `FormModal` (the `/login` credential
// form): re-rendering at the same height budget with focus on any field
// produces the same line count and the same per-row visible widths (the
// input rows only swap their 4-col prefix, which is width-parallel between
// focused and unfocused).

@Suite("FormModal credential-form layout")
struct APIKeyFormLayoutTests {

    @MainActor
    private func form() -> FormModal {
        FormModal(
            title: "test",
            fields: [
                APIKeyFormField(key: "apiKey", label: "API key",
                                hint: "sk-…", placeholder: "sk-proj-…", required: true),
                APIKeyFormField(key: "baseUrl", label: "Base URL",
                                hint: "(optional)",
                                placeholder: "https://api.openai.com",
                                default: "https://api.openai.com",
                                required: false),
            ],
            onSubmit: { _ in },
            onCancel: {}
        )
    }

    @MainActor
    @Test("line count is stable across focus changes")
    func stableLineCount() {
        let f = form()
        let before = f.render(maxRows: 24).count
        f.down()
        let after = f.render(maxRows: 24).count
        #expect(before == after, "moving focus must not grow/shrink the frame")
    }

    @MainActor
    @Test("focus prefix swaps between rows without changing row count")
    func prefixSwap() {
        // The "exactly one focused row" invariant is owned by
        // FormModalTests.focusMovement; this test pins layout stability only.
        let f = form()
        let first = f.render(maxRows: 24)
        f.down()
        let second = f.render(maxRows: 24)
        #expect(first.count == second.count, "focus swap must not change the row count")
        let focusedA = first.filter { $0.contains("❯") }
        let focusedB = second.filter { $0.contains("❯") }
        #expect(focusedA.first != focusedB.first, "focus arrow moved to a different row")
    }

    @MainActor
    @Test("input rows are width-parallel on focus toggle")
    func widthParallelInputs() {
        let f = form()
        let a = f.render(maxRows: 24)
        f.down()
        let b = f.render(maxRows: 24)
        // Same count — check per-index visible width matches where layout
        // matters most (label + blank rows are text-stable; input rows
        // swap prefixes of equal visible length).
        #expect(a.count == b.count)
        for (la, lb) in zip(a, b) {
            #expect(ANSI.visibleWidth(la) == ANSI.visibleWidth(lb),
                    "row widths must match across focus so soft-wrap behavior is identical")
        }
    }
}
