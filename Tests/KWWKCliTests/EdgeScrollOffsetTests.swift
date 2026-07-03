import Testing
@testable import KWWKCli

@Suite("edgeScrollOffset")
struct EdgeScrollOffsetTests {

    @Test("selection inside the window keeps the previous offset")
    func stableInsideWindow() {
        for selection in 3...7 {
            #expect(edgeScrollOffset(selection: selection, count: 20, windowSize: 5, previous: 3) == 3)
        }
    }

    @Test("crossing the bottom edge scrolls by the minimum")
    func bottomEdge() {
        // Window [0, 5) — selecting row 5 shifts the window down one.
        #expect(edgeScrollOffset(selection: 5, count: 20, windowSize: 5, previous: 0) == 1)
        // Walking down one row at a time keeps the selection on the last row.
        var scroll = 0
        for selection in 0..<20 {
            scroll = edgeScrollOffset(selection: selection, count: 20, windowSize: 5, previous: scroll)
            #expect(selection >= scroll && selection < scroll + 5,
                    "selection \(selection) must stay within [\(scroll), \(scroll + 5))")
        }
        #expect(scroll == 15)
    }

    @Test("crossing the top edge scrolls the window back up")
    func topEdge() {
        // Window [10, 15) — moving the selection up within it doesn't scroll…
        #expect(edgeScrollOffset(selection: 10, count: 20, windowSize: 5, previous: 10) == 10)
        // …but crossing the top edge snaps the window to the selection.
        #expect(edgeScrollOffset(selection: 9, count: 20, windowSize: 5, previous: 10) == 9)
    }

    @Test("selection jump far past an edge re-anchors the window")
    func selectionJump() {
        // Jump down (e.g. wraparound bottom): selection lands on the last row.
        #expect(edgeScrollOffset(selection: 19, count: 20, windowSize: 5, previous: 0) == 15)
        // Jump up (wraparound top): selection lands on the first row.
        #expect(edgeScrollOffset(selection: 0, count: 20, windowSize: 5, previous: 15) == 0)
    }

    @Test("shrinking window clamps a stale offset and keeps the selection visible")
    func shrinkingWindow() {
        // Offset computed for a taller window stays valid when the window
        // shrinks (terminal resize): the selection is pulled back into view.
        let shrunk = edgeScrollOffset(selection: 7, count: 20, windowSize: 3, previous: 5)
        #expect(shrunk == 5)
        // A previous offset now past the end of the list is clamped.
        #expect(edgeScrollOffset(selection: 19, count: 20, windowSize: 3, previous: 30) == 17)
        // Window taller than the list pins the offset to zero.
        #expect(edgeScrollOffset(selection: 2, count: 3, windowSize: 10, previous: 2) == 0)
    }

    @Test("degenerate sizes never go negative")
    func degenerate() {
        #expect(edgeScrollOffset(selection: 0, count: 0, windowSize: 5, previous: 3) == 0)
        #expect(edgeScrollOffset(selection: 0, count: 1, windowSize: 1, previous: 0) == 0)
        #expect(edgeScrollOffset(selection: 4, count: 5, windowSize: 1, previous: 0) == 4)
    }
}
