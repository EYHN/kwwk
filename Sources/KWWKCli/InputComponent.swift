import Foundation

/// Emacs-style kill ring: text removed by a kill command (Ctrl+W, Ctrl+U,
/// Ctrl+K, Alt+D, Alt+Backspace) is pushed here so Ctrl+Y can yank it back.
/// Consecutive kills accumulate into a single entry — prepended for backward
/// deletes, appended for forward — so a run of Ctrl+W yanks as one unit.
/// Port of pi-tui's `kill-ring.ts`.
struct KillRing {
    private var ring: [String] = []
    private let maxEntries = 60

    mutating func push(_ text: String, prepend: Bool, accumulate: Bool) {
        guard !text.isEmpty else { return }
        if accumulate, let last = ring.popLast() {
            ring.append(prepend ? text + last : last + text)
        } else {
            ring.append(text)
            if ring.count > maxEntries { ring.removeFirst() }
        }
    }

    /// Most recent entry without mutating the ring.
    func peek() -> String? { ring.last }

    /// Move the last entry to the front — drives Alt+Y yank-pop cycling.
    mutating func rotate() {
        guard ring.count > 1 else { return }
        let last = ring.removeLast()
        ring.insert(last, at: 0)
    }

    var count: Int { ring.count }
}

/// Category of the most recent edit. Drives three behaviors: kill-ring
/// accumulation (consecutive kills merge), yank-pop eligibility (Alt+Y only
/// after a yank), and single-undo coalescing (a run of typed characters or
/// deletes collapses into one undo step).
private enum EditorAction {
    case type, delete, kill, yank
}

/// Snapshot of editor buffer state for the single-level undo stack.
private struct EditorSnapshot {
    var chars: [Character]
    var cursor: Int
}

/// Coarse Unicode classification for word navigation. Mirrors pi-tui's
/// `getWordNavKind` in utils.ts — predictable across scripts without
/// language-specific segmentation. CJK ideographs/kana/hangul are treated as
/// per-character boundaries.
private enum WordNavKind {
    case whitespace, delimiter, cjk, word, other
}

/// Multi-line text editor. Content is stored as a flat `[Character]`
/// buffer; newlines (`\n`) inside the buffer force hard breaks in the
/// rendered output, and anything that would overflow `width` at render
/// time soft-wraps onto the next visual row. The cursor is tracked as a
/// linear index into the buffer but placed on the correct visual
/// (row, col) at render time. When the host sets `maxVisibleRows`, render
/// shows a viewport of at most that many visual rows, scrolled so the
/// cursor row is always visible (omp editor.ts `#updateScrollOffset`).
///
/// Keyboard map mirrors readline/emacs basics (left/right, home/end,
/// Ctrl-A/E/B/F/U/K, backspace, delete) plus word-wise editing and a
/// kill-ring: Ctrl+W / Alt+Backspace delete the word before the cursor,
/// Alt+D the word after, Alt+B/Alt+F move by word, Ctrl+Y yanks the last
/// kill and Alt+Y cycles older kills. Ctrl+_ / Ctrl+Z undo the last
/// destructive edit (single-level, with typed-run coalescing). Up/Down
/// follow omp's dispatch exactly (`cursorUp`/`cursorDown`): they move the
/// cursor by *visual* row with a sticky goal column, and only touch
/// prompt history from an empty buffer (or while already browsing on the
/// first/last visual row). Newline-insert triggers:
///
///   - Shift+Enter (Kitty/Ghostty keyboard protocol)
///   - Ctrl+Enter  (terminals that send a modifier-tagged Enter)
///   - Ctrl+J      (raw LF — 0x0A; always works)
///
/// Plain Enter is left alone so the owning view (CodingTUI) can bind
/// it to "submit".
final class InputComponent: Component, Focusable, @unchecked Sendable {
    private var chars: [Character]
    private(set) var cursor: Int  // cursor position in chars (0...count)
    var focused: Bool = false
    var wantsKeyRelease: Bool { false }

    /// Visual rows shown at once (nil = unlimited — the editor grows with
    /// content). Set by the host from the terminal height; content beyond
    /// the viewport is silently clipped, no indicators (omp behavior).
    var maxVisibleRows: Int? {
        didSet { if maxVisibleRows != oldValue { invalidate() } }
    }
    /// Topmost visible visual row. Follows the cursor with minimal moves:
    /// cursor above the viewport pins it to the top row, below pins it to
    /// the bottom row, otherwise unchanged (omp `#updateScrollOffset`).
    private var scrollOffset = 0
    /// Goal column for a run of vertical moves. Set only when a move lands
    /// on a row too short for the current visual column; consumed by the
    /// first row that fits it; cleared by any horizontal move or edit
    /// (omp `#preferredVisualCol`).
    private var preferredVisualCol: Int?
    /// Width of the last painted frame. Vertical navigation and the
    /// first/last-visual-row checks wrap against it, matching omp's
    /// `#lastLayoutWidth` (navigation uses the width of the last frame).
    /// Before the first render only hard newlines break rows.
    private var lastLayoutWidth = Int.max

    /// Invoked with the body of a bracketed-paste sequence (wrapper
    /// stripped, body as-is — may contain newlines). When nil the
    /// component inserts the body inline as plain text. Callers use
    /// this to peel off paths / images / multi-line blocks before they
    /// reach the editor.
    var onPaste: ((String) -> Void)?

    private var cachedOutput: [String]?
    private var cachedWidth: Int?
    private var cachedState: [Character]?
    private var cachedFocused: Bool?

    // Prompt recall (Up/Down). `history` is newest-first; `historyIndex`
    // is -1 when not browsing, 0 = most recent, growing into older entries.
    // There is no draft stash: history is only enterable from an empty
    // buffer (omp semantics), so a typed draft can never be replaced.
    private var history: [String] = []
    private var historyIndex: Int = -1

    // Emacs kill-ring + the last edit category that drives accumulation,
    // yank-pop eligibility, and undo coalescing.
    private var killRing = KillRing()
    private var lastAction: EditorAction?

    // Single-level (coalesced) undo. Bounded snapshot stack pushed before
    // each destructive op; consecutive typed chars / deletes share one entry.
    private var undoStack: [EditorSnapshot] = []
    private let maxUndoStack = 50

    init(initial: String = "") {
        self.chars = Array(initial)
        self.cursor = chars.count
    }

    // MARK: - Programmatic access

    var value: String {
        get { String(chars) }
        set {
            chars = Array(newValue)
            cursor = min(cursor, chars.count)
            // A programmatic replace is a fresh editing context: leave history
            // browse mode, drop the undo stack, and reset the edit category.
            historyIndex = -1
            preferredVisualCol = nil
            undoStack.removeAll()
            lastAction = nil
            invalidate()
        }
    }

    func moveCursor(_ delta: Int) {
        if delta > 0, cursor == chars.count {
            // omp quirk (editor.ts:2734-2740): Right at the very end of the
            // buffer can't move but records the visual column, so a following
            // Up/Down keeps the end-of-line-ish column.
            let rows = visualRows(width: lastLayoutWidth)
            let row = rows[cursorVisualRow(rows)]
            preferredVisualCol = visualColumn(from: row.start, to: cursor)
            lastAction = nil
            return
        }
        cursor = max(0, min(chars.count, cursor + delta))
        preferredVisualCol = nil
        lastAction = nil
        invalidate()
    }

    /// Buffer-wide jumps for programmatic callers (Tab completion, dequeue).
    /// The Home/End *keys* are line-relative — `moveToLineStart`/`moveToLineEnd`.
    func moveHome() { cursor = 0; preferredVisualCol = nil; lastAction = nil; invalidate() }
    func moveEnd() { cursor = chars.count; preferredVisualCol = nil; lastAction = nil; invalidate() }

    /// Start of the logical (hard-newline-bounded) line under the cursor
    /// (Home / Ctrl+A — omp `#moveToLineStart`).
    func moveToLineStart() {
        var i = cursor
        while i > 0 && chars[i - 1] != "\n" { i -= 1 }
        cursor = i
        preferredVisualCol = nil
        lastAction = nil
        invalidate()
    }

    /// End of the logical line under the cursor (End / Ctrl+E).
    func moveToLineEnd() {
        var i = cursor
        while i < chars.count && chars[i] != "\n" { i += 1 }
        cursor = i
        preferredVisualCol = nil
        lastAction = nil
        invalidate()
    }

    func insert(_ text: String) {
        exitHistoryForEditing()
        // Coalesce a run of single typed characters into one undo step; a
        // multi-char insert (paste, token) is its own step.
        let single = text.count == 1 && text.first != "\n"
        if !(single && lastAction == .type) {
            recordUndo()
        }
        insertCore(text)
        lastAction = single ? .type : nil
    }

    /// Raw insertion at the cursor — no undo/history/kill bookkeeping. Shared
    /// by `insert` and the kill-ring yank path.
    private func insertCore(_ text: String) {
        for ch in text {
            chars.insert(ch, at: cursor)
            cursor += 1
        }
        preferredVisualCol = nil
        invalidate()
    }

    func backspace() {
        guard cursor > 0 else { return }
        if lastAction != .delete { recordUndo() }
        chars.remove(at: cursor - 1)
        cursor -= 1
        historyIndex = -1
        preferredVisualCol = nil
        lastAction = .delete
        invalidate()
    }

    func deleteForward() {
        guard cursor < chars.count else { return }
        if lastAction != .delete { recordUndo() }
        chars.remove(at: cursor)
        historyIndex = -1
        preferredVisualCol = nil
        lastAction = .delete
        invalidate()
    }

    // MARK: - Word-wise editing + kill ring

    /// Delete from the cursor back to the previous word boundary, pushing the
    /// removed text onto the kill ring (Ctrl+W, Alt+Backspace).
    func deleteWordBackward() {
        guard cursor > 0 else { return }
        recordUndo()
        let start = wordBoundaryLeft(from: cursor)
        let deleted = String(chars[start..<cursor])
        chars.removeSubrange(start..<cursor)
        cursor = start
        recordKill(deleted, backward: true)
        historyIndex = -1
        preferredVisualCol = nil
        invalidate()
    }

    /// Delete from the cursor forward to the next word boundary, pushing the
    /// removed text onto the kill ring (Alt+D).
    func deleteWordForward() {
        guard cursor < chars.count else { return }
        recordUndo()
        let end = wordBoundaryRight(from: cursor)
        let deleted = String(chars[cursor..<end])
        chars.removeSubrange(cursor..<end)
        recordKill(deleted, backward: false)
        historyIndex = -1
        preferredVisualCol = nil
        invalidate()
    }

    /// Delete from buffer start up to the cursor through the kill ring (Ctrl+U).
    func deleteToStart() {
        guard cursor > 0 else { return }
        recordUndo()
        let deleted = String(chars[0..<cursor])
        chars.removeFirst(cursor)
        cursor = 0
        recordKill(deleted, backward: true)
        historyIndex = -1
        preferredVisualCol = nil
        invalidate()
    }

    /// Delete from the cursor to buffer end through the kill ring (Ctrl+K).
    func deleteToEnd() {
        guard cursor < chars.count else { return }
        recordUndo()
        let deleted = String(chars[cursor..<chars.count])
        chars.removeLast(chars.count - cursor)
        recordKill(deleted, backward: false)
        historyIndex = -1
        preferredVisualCol = nil
        invalidate()
    }

    func moveWordLeft() {
        cursor = wordBoundaryLeft(from: cursor)
        preferredVisualCol = nil
        lastAction = nil
        invalidate()
    }

    func moveWordRight() {
        cursor = wordBoundaryRight(from: cursor)
        preferredVisualCol = nil
        lastAction = nil
        invalidate()
    }

    /// Insert the most recent kill at the cursor (Ctrl+Y).
    func yank() {
        guard let text = killRing.peek() else { return }
        recordUndo()
        historyIndex = -1
        insertCore(text)
        lastAction = .yank
    }

    /// Replace the just-yanked text with the next older kill (Alt+Y). Only
    /// valid immediately after a yank/yank-pop.
    func yankPop() {
        guard lastAction == .yank, killRing.count > 1 else { return }
        guard let prev = killRing.peek() else { return }
        let plen = prev.count
        guard cursor >= plen, String(chars[(cursor - plen)..<cursor]) == prev else { return }
        recordUndo()
        historyIndex = -1
        chars.removeSubrange((cursor - plen)..<cursor)
        cursor -= plen
        killRing.rotate()
        if let text = killRing.peek() { insertCore(text) }
        lastAction = .yank
        invalidate()
    }

    private func recordKill(_ text: String, backward: Bool) {
        killRing.push(text, prepend: backward, accumulate: lastAction == .kill)
        lastAction = .kill
    }

    // MARK: - Undo

    private func recordUndo() {
        undoStack.append(EditorSnapshot(chars: chars, cursor: cursor))
        if undoStack.count > maxUndoStack { undoStack.removeFirst() }
    }

    /// Pop the last pre-edit snapshot and restore it (Ctrl+_ / Ctrl+Z).
    func undo() {
        guard let snap = undoStack.popLast() else { return }
        chars = snap.chars
        cursor = min(snap.cursor, chars.count)
        historyIndex = -1
        preferredVisualCol = nil
        lastAction = nil
        invalidate()
    }

    // MARK: - Prompt history (Up/Down recall)

    /// Append a submitted prompt to the recall ring. Trims, drops empties and
    /// consecutive duplicates, caps at 100 entries (newest first).
    func addToHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if history.first == trimmed { return }
        history.insert(trimmed, at: 0)
        if history.count > 100 { history.removeLast() }
    }

    /// Step through history. `direction` is -1 for older (Up), +1 for newer
    /// (Down). The buffer is replaced wholesale; going older anchors the
    /// cursor at the *start* (so the very next Up is again "first visual
    /// row" and keeps scrubbing), newer at the *end*. Index -1 is "not
    /// browsing": stepping past the newest entry clears the editor. Returns
    /// false when there is nothing to recall. Port of editor.ts's
    /// `#navigateHistory`.
    @discardableResult
    func navigateHistory(_ direction: Int) -> Bool {
        lastAction = nil
        guard !history.isEmpty else { return false }
        let newIndex = historyIndex - direction
        guard newIndex >= -1, newIndex < history.count else { return false }
        historyIndex = newIndex
        if historyIndex == -1 {
            setBufferInternal("", cursorAtStart: false)
        } else {
            setBufferInternal(history[historyIndex], cursorAtStart: direction == -1)
        }
        return true
    }

    /// Replace the buffer without leaving history-browse mode (unlike `value`).
    private func setBufferInternal(_ text: String, cursorAtStart: Bool) {
        undoStack.removeAll()
        chars = Array(text)
        cursor = cursorAtStart ? 0 : chars.count
        preferredVisualCol = nil
        invalidate()
    }

    /// omp `#exitHistoryForEditing`: typing into a just-recalled entry whose
    /// cursor still sits at the Up-anchor (buffer start) first jumps the
    /// cursor to the end, then inserts — after Up the cursor is at the start
    /// purely for scrubbing; typing means "append to this prompt". Only
    /// insertion relocates; backspace and the kill ops merely leave browse
    /// mode.
    private func exitHistoryForEditing() {
        if historyIndex == -1 { return }
        if cursor == 0 {
            cursor = chars.count
        }
        historyIndex = -1
    }

    // MARK: - Up/Down dispatch (cursor movement vs history)

    /// Up — omp editor.ts:1391-1401. Empty buffer → begin browsing history
    /// (the *only* arrow entry point into history; a non-empty draft is never
    /// replaced). Browsing + first visual row → older entry. First visual row
    /// → start of line. Otherwise → one visual row up.
    func cursorUp() {
        if chars.isEmpty {
            navigateHistory(-1)
        } else if historyIndex > -1, isOnFirstVisualRow {
            navigateHistory(-1)
        } else if isOnFirstVisualRow {
            moveToLineStart()
        } else {
            moveCursorVertically(-1)
        }
    }

    /// Down — omp editor.ts:1403-1412. Browsing + last visual row → newer
    /// entry (or back past the newest, which clears the editor). Last visual
    /// row → end of line. Otherwise → one visual row down. Note the
    /// asymmetry: no empty-buffer branch — Down in an empty editor is a no-op
    /// line-end jump.
    func cursorDown() {
        if historyIndex > -1, isOnLastVisualRow {
            navigateHistory(1)
        } else if isOnLastVisualRow {
            moveToLineEnd()
        } else {
            moveCursorVertically(1)
        }
    }

    /// PageUp shares Up's history disambiguation with page-scroll as the
    /// fallback (omp editor.ts:1361-1368).
    func pageUp() {
        if chars.isEmpty {
            navigateHistory(-1)
        } else if historyIndex > -1, isOnFirstVisualRow {
            navigateHistory(-1)
        } else {
            pageScroll(-1)
        }
    }

    /// PageDown — omp editor.ts:1369-1375.
    func pageDown() {
        if historyIndex > -1, isOnLastVisualRow {
            navigateHistory(1)
        } else {
            pageScroll(1)
        }
    }

    private var isOnFirstVisualRow: Bool {
        cursorVisualRow(visualRows(width: lastLayoutWidth)) == 0
    }

    private var isOnLastVisualRow: Bool {
        let rows = visualRows(width: lastLayoutWidth)
        return cursorVisualRow(rows) == rows.count - 1
    }

    // MARK: - Word boundaries

    /// Index of the word boundary at or left of `from`. Port of pi-tui's
    /// `moveWordLeft`: skip trailing whitespace, then consume one run of the
    /// boundary character's kind (word runs keep `'`/`-` joiners inside).
    func wordBoundaryLeft(from: Int) -> Int {
        var i = min(max(from, 0), chars.count)
        if i == 0 { return 0 }
        while i > 0 && wordNavKind(chars[i - 1]) == .whitespace { i -= 1 }
        if i == 0 { return 0 }
        let kind = wordNavKind(chars[i - 1])
        if kind == .delimiter || kind == .cjk {
            while i > 0 && wordNavKind(chars[i - 1]) == kind { i -= 1 }
            return i
        }
        if kind == .word {
            var hasRightWord = false
            while i > 0 {
                let g = chars[i - 1]
                let k = wordNavKind(g)
                if k == .word { hasRightWord = true; i -= 1; continue }
                if hasRightWord, k == .delimiter, isWordNavJoiner(g),
                   i >= 2, wordNavKind(chars[i - 2]) == .word {
                    i -= 1; continue
                }
                break
            }
            return i
        }
        return i - 1
    }

    /// Index of the word boundary at or right of `from`. Port of `moveWordRight`.
    func wordBoundaryRight(from: Int) -> Int {
        let n = chars.count
        var i = min(max(from, 0), n)
        if i == n { return n }
        while i < n && wordNavKind(chars[i]) == .whitespace { i += 1 }
        if i == n { return i }
        let firstKind = wordNavKind(chars[i])
        if firstKind == .delimiter || firstKind == .cjk {
            while i < n && wordNavKind(chars[i]) == firstKind { i += 1 }
            return i
        }
        if firstKind == .word {
            var hasLeftWord = false
            while i < n {
                let g = chars[i]
                let k = wordNavKind(g)
                if k == .word { hasLeftWord = true; i += 1; continue }
                if hasLeftWord, k == .delimiter, isWordNavJoiner(g),
                   i + 1 < n, wordNavKind(chars[i + 1]) == .word {
                    i += 1; continue
                }
                break
            }
            return i
        }
        return i + 1
    }

    private func wordNavKind(_ ch: Character) -> WordNavKind {
        if ch.isWhitespace { return .whitespace }
        if isCJK(ch) { return .cjk }
        if ch == "_" || ch.isLetter || ch.isNumber { return .word }
        if ch.isPunctuation || ch.isSymbol { return .delimiter }
        return .other
    }

    private func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)      // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(v)      // Ext A
            || (0x20000...0x2FA1F).contains(v)    // Ext B+ / compat supplement
            || (0xF900...0xFAFF).contains(v)      // CJK Compatibility Ideographs
            || (0x3040...0x30FF).contains(v)      // Hiragana + Katakana
            || (0x31F0...0x31FF).contains(v)      // Katakana phonetic extensions
            || (0xAC00...0xD7AF).contains(v)      // Hangul syllables
            || (0x1100...0x11FF).contains(v)      // Hangul Jamo
            || (0x3130...0x318F).contains(v)      // Hangul Compatibility Jamo
            || (0xA960...0xA97F).contains(v)      // Hangul Jamo Extended-A
    }

    private static let wordNavJoiners: Set<Character> = ["'", "\u{2019}", "-", "\u{2010}", "\u{2011}"]

    private func isWordNavJoiner(_ ch: Character) -> Bool {
        Self.wordNavJoiners.contains(ch)
    }

    // MARK: - Visual rows (wrap layout shared by render + vertical navigation)

    /// One visual (wrapped) row: `chars[start..<end]`, hard newline excluded.
    /// `isLastOfLine` marks the final segment of a logical line, where the
    /// cursor may legally sit *at* `end` (the end-of-line position); on a
    /// soft-wrap boundary that index belongs to the next row.
    private struct VisualRow {
        let start: Int
        let end: Int
        let isLastOfLine: Bool
    }

    /// Wrap pass: `\n` forces a new row; a character whose column width
    /// would overflow `width` soft-wraps onto the next row. Never empty —
    /// an empty buffer is one empty row.
    private func visualRows(width: Int) -> [VisualRow] {
        let width = max(1, width)
        var rows: [VisualRow] = []
        var start = 0
        var col = 0
        for i in 0..<chars.count {
            let ch = chars[i]
            if ch == "\n" {
                rows.append(VisualRow(start: start, end: i, isLastOfLine: true))
                start = i + 1
                col = 0
                continue
            }
            let w = charColumnWidth(ch)
            if col + w > width {
                rows.append(VisualRow(start: start, end: i, isLastOfLine: false))
                start = i
                col = 0
            }
            col += w
        }
        rows.append(VisualRow(start: start, end: chars.count, isLastOfLine: true))
        return rows
    }

    /// Index of the visual row owning the cursor. A cursor sitting exactly on
    /// a soft-wrap boundary belongs to the *next* row (non-last segments
    /// exclude `cursor == end`), except at the true end of a logical line.
    private func cursorVisualRow(_ rows: [VisualRow]) -> Int {
        for (i, row) in rows.enumerated() {
            if cursor >= row.start, cursor < row.end || (row.isLastOfLine && cursor == row.end) {
                return i
            }
        }
        return rows.count - 1
    }

    /// Visible cell count of `chars[start..<end]`.
    private func visualColumn(from start: Int, to end: Int) -> Int {
        var col = 0
        for i in start..<end { col += charColumnWidth(chars[i]) }
        return col
    }

    /// Rightmost visual column the cursor may occupy on a row: the full row
    /// width on the last segment of a logical line, one grapheme short on a
    /// soft-wrapped segment whose end position belongs to the next row
    /// (omp `maxSegmentVisualCol`).
    private func maxVisualColumn(of row: VisualRow) -> Int {
        let width = visualColumn(from: row.start, to: row.end)
        if row.isLastOfLine || row.end == row.start { return width }
        return width - charColumnWidth(chars[row.end - 1])
    }

    /// Buffer index within `row` for a target visual column, snapped to a
    /// grapheme start — never splits a cluster (omp `offsetAtVisualCol`).
    private func index(in row: VisualRow, atVisualColumn target: Int) -> Int {
        var col = 0
        var i = row.start
        while i < row.end {
            let w = charColumnWidth(chars[i])
            if col + w > target { return i }
            col += w
            i += 1
        }
        return i
    }

    /// Move the cursor one visual row up/down with the sticky goal column.
    private func moveCursorVertically(_ direction: Int) {
        let rows = visualRows(width: lastLayoutWidth)
        let current = cursorVisualRow(rows)
        let target = current + direction
        guard target >= 0, target < rows.count else { return }
        moveToVisualRow(rows, from: current, to: target)
    }

    private func moveToVisualRow(_ rows: [VisualRow], from: Int, to: Int) {
        let src = rows[from]
        let dst = rows[to]
        let col = verticalMoveColumn(
            current: visualColumn(from: src.start, to: cursor),
            sourceMax: maxVisualColumn(of: src),
            targetMax: maxVisualColumn(of: dst)
        )
        cursor = index(in: dst, atVisualColumn: col)
        lastAction = nil
        invalidate()
    }

    /// omp's sticky-column decision table (`#computeVerticalMoveColumn`): the
    /// goal column is remembered only when a vertical move lands on a row too
    /// short for the current column, persists through further short rows, and
    /// is consumed by the first row that fits it. A cursor mid-row ignores
    /// and resets any pending goal.
    private func verticalMoveColumn(current: Int, sourceMax: Int, targetMax: Int) -> Int {
        let cursorInMiddle = current < sourceMax
        guard let preferred = preferredVisualCol, !cursorInMiddle else {
            if targetMax < current {
                preferredVisualCol = current
                return targetMax
            }
            preferredVisualCol = nil
            return current
        }
        if targetMax < current || targetMax < preferred {
            return targetMax
        }
        preferredVisualCol = nil
        return preferred
    }

    /// PageUp/PageDown move the cursor a viewportful of visual rows (step =
    /// visible rows − 1, min 1; 10 when uncapped) with the same sticky-column
    /// mapping as Up/Down (omp `#pageScroll`).
    private func pageScroll(_ direction: Int) {
        lastAction = nil
        let rows = visualRows(width: lastLayoutWidth)
        let current = cursorVisualRow(rows)
        let step = max(1, (maxVisibleRows ?? 10) - 1)
        let target = max(0, min(rows.count - 1, current + direction * step))
        guard target != current else { return }
        moveToVisualRow(rows, from: current, to: target)
    }

    // MARK: - Component

    func render(width: Int) -> [String] {
        lastLayoutWidth = max(1, width)
        if let cachedOutput,
           cachedWidth == width,
           cachedState == chars,
           cachedFocused == focused {
            return cachedOutput
        }
        let rows = layoutRows(width: max(1, width))
        cachedOutput = rows
        cachedWidth = width
        cachedState = chars
        cachedFocused = focused
        return rows
    }

    /// Render pass: wrap the buffer into visual rows, follow the cursor with
    /// the scroll offset, and return only the viewport slice (`maxVisibleRows`
    /// rows at most; everything when uncapped). The cursor row is always
    /// inside the slice, carrying — when focused — a zero-width cursor marker
    /// at the cursor's visual column.
    private func layoutRows(width: Int) -> [String] {
        let rows = visualRows(width: width)
        let visibleHeight = maxVisibleRows ?? rows.count
        updateScrollOffset(rows: rows, visibleHeight: visibleHeight)
        let cursorRow = cursorVisualRow(rows)
        var out: [String] = []
        for i in scrollOffset..<min(rows.count, scrollOffset + visibleHeight) {
            let row = rows[i]
            var text = String(chars[row.start..<row.end])
            if focused, i == cursorRow {
                text = insertCursorMarker(in: text, atCol: visualColumn(from: row.start, to: cursor))
            }
            out.append(text)
        }
        return out
    }

    /// omp `#updateScrollOffset`: content fits → pinned to 0; cursor above
    /// the viewport → cursor becomes the top row; below → the bottom row;
    /// otherwise unchanged. Always clamped so shrinking content pulls the
    /// viewport up. No scroll margin, no indicators.
    private func updateScrollOffset(rows: [VisualRow], visibleHeight: Int) {
        if rows.count <= visibleHeight {
            scrollOffset = 0
            return
        }
        let cursorRow = cursorVisualRow(rows)
        if cursorRow < scrollOffset {
            scrollOffset = cursorRow
        } else if cursorRow >= scrollOffset + visibleHeight {
            scrollOffset = cursorRow - visibleHeight + 1
        }
        scrollOffset = min(scrollOffset, rows.count - visibleHeight)
    }

    /// Visible column width of a single `Character` (grapheme cluster). Uses
    /// the shared grapheme-aware width so modern emoji stay 2 columns: a ZWJ
    /// family/profession sequence collapses to one glyph, skin-tone modifiers
    /// and variation selectors add nothing, and a regional-indicator pair is a
    /// single 2-column flag — matching how the terminal advances its cursor.
    ///
    /// A grapheme whose scalars are *all* zero-width (a lone combining mark or
    /// ZWSP — reachable when a bracketed paste is inserted verbatim) genuinely
    /// occupies no columns. `insertCursorMarker` accounts it as 0 too, so we
    /// must NOT floor it to 1: flooring would advance the layout column past
    /// where the marker pass lands, dropping the cursor one column too far
    /// right. Normal text (width ≥ 1) is unaffected.
    private func charColumnWidth(_ ch: Character) -> Int {
        ANSI.graphemeWidth(ch)
    }

    /// Insert a zero-width cursor marker into `line` at the given visible
    /// column. Walks grapheme clusters with the same width accounting as
    /// `layoutRows` (`charColumnWidth`), so a ZWJ emoji or flag is treated as
    /// one 2-column glyph and the marker lands on the same column the layout
    /// pass computed. If the column is at or past the visible end, the marker
    /// goes at the end — the TUI's cursor positioner handles "just past last
    /// col" naturally.
    private func insertCursorMarker(in line: String, atCol col: Int) -> String {
        var out = ""
        var visible = 0
        var inserted = false
        for ch in line {
            if !inserted && visible >= col {
                out += CURSOR_MARKER
                inserted = true
            }
            out.append(ch)
            visible += charColumnWidth(ch)
        }
        if !inserted {
            out += CURSOR_MARKER
        }
        return out
    }

    func invalidate() {
        cachedOutput = nil
        cachedWidth = nil
        cachedState = nil
        cachedFocused = nil
    }

    // MARK: - Bracketed paste wrapper

    private static let pasteStart = "\u{1B}[200~"
    private static let pasteEnd = "\u{1B}[201~"

    /// If `data` is a complete bracketed-paste sequence, return the
    /// body; otherwise nil. `StdinBuffer` only emits completed paste
    /// events, so this is just a wrapper-stripping helper that also
    /// normalizes terminal line separators — macOS + most *nix shells
    /// convert Return → `\r` when the body is typed/keystroke-sent,
    /// but the pasted body is logically multi-line. Converting to
    /// `\n` up front means downstream path/attachment detection can
    /// treat newline uniformly.
    private func extractBracketedPasteBody(_ data: String) -> String? {
        guard data.hasPrefix(Self.pasteStart),
              data.hasSuffix(Self.pasteEnd)
        else { return nil }
        let startIdx = data.index(data.startIndex, offsetBy: Self.pasteStart.count)
        let endIdx = data.index(data.endIndex, offsetBy: -Self.pasteEnd.count)
        let raw = String(data[startIdx..<endIdx])
        return raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func handleInput(_ data: String) {
        // Bracketed paste wrapper `ESC[200~ … ESC[201~` arrives as a
        // single synthetic sequence from StdinBuffer. Unwrap and route
        // to `onPaste` (or insert the body as a fallback so the text
        // isn't silently swallowed).
        if let pasteBody = extractBracketedPasteBody(data) {
            if let handler = onPaste {
                handler(pasteBody)
            } else {
                // No handler configured — insert verbatim. The editor is
                // multi-line, so newlines survive.
                insert(pasteBody)
            }
            return
        }
        guard let event = Keys.parse(data) else {
            // Not a key we recognize — treat printable text as insertion.
            if !data.isEmpty && !data.hasPrefix("\u{1B}") { insert(data) }
            return
        }
        if event.ctrl || event.alt {
            switch (event.name, event.ctrl, event.alt) {
            case ("a", true, false): moveToLineStart()
            case ("e", true, false): moveToLineEnd()
            case ("b", true, false): moveCursor(-1)
            case ("f", true, false): moveCursor(1)
            case ("u", true, false): deleteToStart()
            case ("k", true, false): deleteToEnd()
            // Word-wise editing (emacs/readline). Ctrl+W and Alt+Backspace
            // both delete the word before the cursor; Alt+D deletes the word
            // after it. Alt+B/Alt+F move by word.
            case ("w", true, false): deleteWordBackward()
            case ("backspace", false, true): deleteWordBackward()
            case ("d", false, true): deleteWordForward()
            case ("b", false, true): moveWordLeft()
            case ("f", false, true): moveWordRight()
            // Kill-ring yank / yank-pop.
            case ("y", true, false): yank()
            case ("y", false, true): yankPop()
            // Single-level undo. Ctrl+_ is byte 0x1F (also sent by Ctrl+/ on
            // legacy terminals); Ctrl+Z works where the terminal forwards it in
            // raw mode. Under the Kitty keyboard protocol Ctrl+/ arrives as a
            // distinct "/" codepoint rather than collapsing to 0x1F, so bind it
            // too. All pop the last pre-edit snapshot.
            case ("_", true, false): undo()
            case ("/", true, false): undo()
            case ("z", true, false): undo()
            // Newline-insert triggers. Ctrl+J is the raw LF byte
            // (0x0A); terminals emit it even without any keyboard
            // protocol support. Shift+Enter and Ctrl+Enter require
            // a terminal that tags Enter with modifiers (for example
            // Kitty/Ghostty keyboard protocol support).
            case ("j", true, false): insert("\n")
            case ("enter", true, false): insert("\n")
            default: break
            }
            return
        }
        switch event.name {
        case "left": moveCursor(-1)
        case "right": moveCursor(1)
        case "up": cursorUp()
        case "down": cursorDown()
        case "pageup": pageUp()
        case "pagedown": pageDown()
        case "home": moveToLineStart()
        case "end": moveToLineEnd()
        case "backspace": backspace()
        case "delete": deleteForward()
        case "enter":
            if event.shift {
                insert("\n")
            }
            break
        case "escape": break
        case "space": insert(" ")
        case "tab": insert("\t")
        default:
            // Single-char names fall through here.
            if event.name.count == 1 {
                insert(event.shift ? event.name.uppercased() : event.name)
            }
        }
    }
}
