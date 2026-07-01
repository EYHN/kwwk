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
/// (row, col) at render time.
///
/// Keyboard map mirrors readline/emacs basics (left/right, home/end,
/// Ctrl-A/E/B/F/U/K, backspace, delete) plus word-wise editing and a
/// kill-ring: Ctrl+W / Alt+Backspace delete the word before the cursor,
/// Alt+D the word after, Alt+B/Alt+F move by word, Ctrl+Y yanks the last
/// kill and Alt+Y cycles older kills. Ctrl+_ / Ctrl+Z undo the last
/// destructive edit (single-level, with typed-run coalescing), and
/// Up/Down recall prior submissions (`navigateHistory`). Newline-insert
/// triggers:
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
    private var history: [String] = []
    private var historyIndex: Int = -1

    // The live draft stashed the moment Up recall first steps off the buffer
    // (historyIndex -1 → a real entry). Stepping back Down to the newest entry
    // restores it verbatim instead of blanking an unsent draft. Nil whenever
    // not browsing; refreshed on each fresh move off the draft, so a stale
    // draft can never resurrect.
    private var pendingDraft: [Character]?

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
            pendingDraft = nil
            undoStack.removeAll()
            lastAction = nil
            invalidate()
        }
    }

    func moveCursor(_ delta: Int) {
        cursor = max(0, min(chars.count, cursor + delta))
        lastAction = nil
        invalidate()
    }

    func moveHome() { cursor = 0; lastAction = nil; invalidate() }
    func moveEnd() { cursor = chars.count; lastAction = nil; invalidate() }

    func insert(_ text: String) {
        // Coalesce a run of single typed characters into one undo step; a
        // multi-char insert (paste, token) is its own step.
        let single = text.count == 1 && text.first != "\n"
        if !(single && lastAction == .type) {
            recordUndo()
        }
        insertCore(text)
        historyIndex = -1
        lastAction = single ? .type : nil
    }

    /// Raw insertion at the cursor — no undo/history/kill bookkeeping. Shared
    /// by `insert` and the kill-ring yank path.
    private func insertCore(_ text: String) {
        for ch in text {
            chars.insert(ch, at: cursor)
            cursor += 1
        }
        invalidate()
    }

    func backspace() {
        guard cursor > 0 else { return }
        if lastAction != .delete { recordUndo() }
        chars.remove(at: cursor - 1)
        cursor -= 1
        historyIndex = -1
        lastAction = .delete
        invalidate()
    }

    func deleteForward() {
        guard cursor < chars.count else { return }
        if lastAction != .delete { recordUndo() }
        chars.remove(at: cursor)
        historyIndex = -1
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
        invalidate()
    }

    func moveWordLeft() {
        cursor = wordBoundaryLeft(from: cursor)
        lastAction = nil
        invalidate()
    }

    func moveWordRight() {
        cursor = wordBoundaryRight(from: cursor)
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
    /// (Down); stepping past the newest entry returns to the empty draft.
    /// Returns false when there is nothing to recall. Mirrors editor.ts's
    /// `navigateHistory`.
    @discardableResult
    func navigateHistory(_ direction: Int) -> Bool {
        lastAction = nil
        guard !history.isEmpty else { return false }
        let newIndex = historyIndex - direction
        guard newIndex >= -1, newIndex < history.count else { return false }
        // Leaving the live draft (index -1) for a real entry: stash the draft
        // (refreshing any prior stash) so a later Down restores it verbatim.
        if historyIndex == -1, newIndex >= 0 {
            pendingDraft = chars
        }
        historyIndex = newIndex
        if historyIndex == -1 {
            setBufferInternal(String(pendingDraft ?? []))
            pendingDraft = nil
        } else {
            setBufferInternal(history[historyIndex])
        }
        return true
    }

    /// Up-arrow recall, gated to the first hard row so multi-line drafts keep
    /// their in-text cursor movement once vertical navigation lands.
    @discardableResult
    func navigateHistoryUp() -> Bool {
        guard cursorOnFirstRow else { return false }
        return navigateHistory(-1)
    }

    /// Down-arrow recall, gated to the last hard row (see `navigateHistoryUp`).
    @discardableResult
    func navigateHistoryDown() -> Bool {
        guard cursorOnLastRow else { return false }
        return navigateHistory(1)
    }

    /// Replace the buffer without leaving history-browse mode (unlike `value`).
    private func setBufferInternal(_ text: String) {
        undoStack.removeAll()
        chars = Array(text)
        cursor = chars.count
        invalidate()
    }

    private var cursorOnFirstRow: Bool {
        !chars[0..<cursor].contains("\n")
    }

    private var cursorOnLastRow: Bool {
        !chars[cursor..<chars.count].contains("\n")
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

    // MARK: - Component

    func render(width: Int) -> [String] {
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

    /// Core wrap pass: walk the buffer once, laying each character out
    /// on (row, col) with `\n` forcing a new row and width overflow
    /// soft-wrapping. Returns the visual rows plus — when focused — a
    /// zero-width cursor marker inserted at the cursor's visual column.
    private func layoutRows(width: Int) -> [String] {
        var rows: [[Character]] = [[]]
        var cols: [Int] = [0]     // visible column width of each row so far
        var cursorRow = 0
        var cursorCol = 0

        for i in 0..<chars.count {
            if i == cursor {
                cursorRow = rows.count - 1
                cursorCol = cols.last!
            }
            let ch = chars[i]
            if ch == "\n" {
                rows.append([])
                cols.append(0)
                continue
            }
            let w = charColumnWidth(ch)
            // Soft-wrap: this char wouldn't fit on the current row.
            if cols.last! + w > width {
                rows.append([])
                cols.append(0)
            }
            rows[rows.count - 1].append(ch)
            cols[cols.count - 1] += w
        }
        if cursor == chars.count {
            cursorRow = rows.count - 1
            cursorCol = cols.last!
        }

        var out: [String] = rows.map { String($0) }
        if focused {
            out[cursorRow] = insertCursorMarker(in: out[cursorRow], atCol: cursorCol)
        }
        return out
    }

    /// Visible column width of a single `Character` — sums the per-scalar
    /// widths (a precomposed `Character` like "é" normally has width 1;
    /// CJK ideographs width 2).
    private func charColumnWidth(_ ch: Character) -> Int {
        var w = 0
        for scalar in ch.unicodeScalars {
            w += ANSI.columnWidth(of: scalar.value)
        }
        // A grapheme whose scalars are *all* zero-width (a lone combining mark
        // or ZWSP — reachable when a bracketed paste is inserted verbatim)
        // genuinely occupies no columns. `insertCursorMarker` accounts it as 0
        // too, so we must NOT floor it to 1 here: flooring would advance the
        // layout column past where the marker pass lands, dropping the cursor
        // one column too far right. Normal text (width ≥ 1) is unaffected.
        return w
    }

    /// Insert a zero-width cursor marker into `line` at the given
    /// visible column (counting scalar widths ANSI-style). If the
    /// column is at or past the visible end, the marker goes at the
    /// end — the TUI's cursor positioner handles "just past last col"
    /// naturally.
    private func insertCursorMarker(in line: String, atCol col: Int) -> String {
        var out = ""
        var visible = 0
        var inserted = false
        for scalar in line.unicodeScalars {
            if !inserted && visible >= col {
                out += CURSOR_MARKER
                inserted = true
            }
            out.unicodeScalars.append(scalar)
            visible += ANSI.columnWidth(of: scalar.value)
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
            case ("a", true, false): moveHome()
            case ("e", true, false): moveEnd()
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
            // many terminals); Ctrl+Z works where the terminal forwards it in
            // raw mode. Both pop the last pre-edit snapshot.
            case ("_", true, false): undo()
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
        case "home": moveHome()
        case "end": moveEnd()
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
