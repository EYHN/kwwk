import Foundation

public enum EditDiff {

    public struct Edit: Sendable, Equatable {
        public var oldText: String
        public var newText: String
        public init(oldText: String, newText: String) {
            self.oldText = oldText
            self.newText = newText
        }
    }

    public enum LineEnding: String, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
    }

    public static func stripBOM(_ content: String) -> (bom: String, text: String) {
        if content.hasPrefix("\u{FEFF}") {
            return ("\u{FEFF}", String(content.dropFirst()))
        }
        return ("", content)
    }

    public static func detectLineEnding(_ content: String) -> LineEnding {
        guard let lfRange = content.range(of: "\n") else { return .lf }
        guard let crlfRange = content.range(of: "\r\n") else { return .lf }
        return crlfRange.lowerBound < lfRange.lowerBound ? .crlf : .lf
    }

    public static func normalizeToLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func restoreLineEndings(_ text: String, ending: LineEnding) -> String {
        ending == .crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
    }

    /// Fuzzy-normalize a string: NFKC compose, strip trailing whitespace per
    /// line, collapse smart quotes/dashes, normalize fancy spaces to plain
    /// space. Mirrors pi-coding-agent's `normalizeForFuzzyMatch`.
    public static func normalizeForFuzzyMatch(_ text: String) -> String {
        let composed = text.precomposedStringWithCompatibilityMapping
        let stripped = composed
            .components(separatedBy: "\n")
            .map { line -> String in
                var s = line
                while let last = s.last, last == " " || last == "\t" {
                    s.removeLast()
                }
                return s
            }
            .joined(separator: "\n")

        var out = ""
        out.reserveCapacity(stripped.count)
        for scalar in stripped.unicodeScalars {
            let value = scalar.value
            // Smart single quotes → '
            if value == 0x2018 || value == 0x2019 || value == 0x201A || value == 0x201B {
                out.append("'")
                continue
            }
            // Smart double quotes → "
            if value == 0x201C || value == 0x201D || value == 0x201E || value == 0x201F {
                out.append("\"")
                continue
            }
            // Dashes/hyphens → -
            if value == 0x2010 || value == 0x2011 || value == 0x2012 || value == 0x2013
                || value == 0x2014 || value == 0x2015 || value == 0x2212 {
                out.append("-")
                continue
            }
            // Fancy spaces → space
            if value == 0x00A0
                || (value >= 0x2002 && value <= 0x200A)
                || value == 0x202F || value == 0x205F || value == 0x3000 {
                out.append(" ")
                continue
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Apply edits to LF-normalized content. Throws on missing / duplicate /
    /// overlapping / no-op edits. Mirrors edit-diff.ts `applyEditsToNormalizedContent`.
    public static func applyEdits(
        to normalizedContent: String,
        edits: [Edit],
        path: String
    ) throws -> (baseContent: String, newContent: String) {
        let normEdits = edits.map {
            Edit(oldText: normalizeToLF($0.oldText), newText: normalizeToLF($0.newText))
        }

        for (i, edit) in normEdits.enumerated() {
            if edit.oldText.isEmpty {
                if normEdits.count == 1 {
                    throw CodingToolError.invalidArgument("oldText must not be empty in \(path).")
                }
                throw CodingToolError.invalidArgument("edits[\(i)].oldText must not be empty in \(path).")
            }
        }

        // Probe each edit against the normalized content; if any uses fuzzy
        // matching, match/replacement offsets are computed in fuzzy-normalized
        // space (`replacementBase`). But the written output is overlaid back
        // onto the ORIGINAL `normalizedContent`, so lines the edits never touch
        // keep their exact bytes — fuzzy matching must never flatten trailing
        // whitespace / smart quotes / etc. on unrelated lines (data loss).
        let initialMatches = normEdits.map { fuzzyFindText($0.oldText, in: normalizedContent) }
        let usedFuzzy = initialMatches.contains(where: { $0.usedFuzzyMatch })
        let replacementBase: String = usedFuzzy
            ? normalizeForFuzzyMatch(normalizedContent)
            : normalizedContent

        var matches: [Match] = []
        for (i, edit) in normEdits.enumerated() {
            let matchResult = fuzzyFindText(edit.oldText, in: replacementBase)
            if !matchResult.found {
                if normEdits.count == 1 {
                    throw CodingToolError.textNotFound(
                        "Could not find the exact text in \(path). The old text must match exactly including all whitespace and newlines."
                    )
                }
                throw CodingToolError.textNotFound(
                    "Could not find edits[\(i)] in \(path). The oldText must match exactly including all whitespace and newlines."
                )
            }
            let occurrences = countOccurrences(of: edit.oldText, in: replacementBase)
            if occurrences > 1 {
                throw CodingToolError.multipleMatches(count: occurrences)
            }
            matches.append(Match(
                editIndex: i,
                matchIndex: matchResult.utf8Offset,
                matchLength: matchResult.matchUTF8Length,
                newText: edit.newText
            ))
        }

        matches.sort { $0.matchIndex < $1.matchIndex }
        for i in 1..<matches.count {
            let prev = matches[i - 1]
            let cur = matches[i]
            if prev.matchIndex + prev.matchLength > cur.matchIndex {
                throw CodingToolError.invalidArgument(
                    "edits[\(prev.editIndex)] and edits[\(cur.editIndex)] overlap in \(path)."
                )
            }
        }

        let newContent: String
        if usedFuzzy {
            newContent = try applyReplacementsPreservingUnchangedLines(
                original: normalizedContent, base: replacementBase, matches: matches, path: path
            )
        } else {
            var utf8 = Array(replacementBase.utf8)
            for match in matches.reversed() {
                utf8.replaceSubrange(
                    match.matchIndex..<(match.matchIndex + match.matchLength),
                    with: Array(match.newText.utf8)
                )
            }
            newContent = String(decoding: utf8, as: UTF8.self)
        }

        // Diff + no-op detection are against the ORIGINAL content, never the
        // fuzzy-normalized view.
        let baseContent = normalizedContent
        if baseContent == newContent {
            throw CodingToolError.invalidArgument("No changes made to \(path).")
        }
        return (baseContent, newContent)
    }

    private struct Match: Sendable {
        var editIndex: Int
        var matchIndex: Int
        var matchLength: Int
        var newText: String
    }

    /// Overlay fuzzy-space replacements onto the original content, rewriting
    /// only the lines each match actually spans and copying every other line
    /// verbatim from the original. Ported from pi
    /// `applyReplacementsPreservingUnchangedLines`. All offsets are UTF-8 bytes.
    private static func applyReplacementsPreservingUnchangedLines(
        original: String, base: String, matches: [Match], path: String
    ) throws -> String {
        let originalBytes = Array(original.utf8)
        let baseBytes = Array(base.utf8)
        let originalSpans = lineSpans(originalBytes)
        let baseSpans = lineSpans(baseBytes)
        guard originalSpans.count == baseSpans.count else {
            // Fuzzy normalization preserves line count; a mismatch means we
            // cannot safely overlay. Fail loudly rather than corrupt the file.
            throw CodingToolError.invalidArgument(
                "Cannot apply fuzzy edit to \(path) without risking unrelated lines; please provide exact text."
            )
        }

        struct Group { var startLine: Int; var endLine: Int; var reps: [Match] }
        var groups: [Group] = []
        for rep in matches.sorted(by: { $0.matchIndex < $1.matchIndex }) {
            let range = try replacementLineRange(baseSpans, rep, path: path)
            if var current = groups.last, range.start < current.endLine {
                current.endLine = max(current.endLine, range.end)
                current.reps.append(rep)
                groups[groups.count - 1] = current
            } else {
                groups.append(Group(startLine: range.start, endLine: range.end, reps: [rep]))
            }
        }

        var result: [UInt8] = []
        var origLineIdx = 0
        for g in groups {
            if g.startLine > origLineIdx {
                let from = originalSpans[origLineIdx].start
                let to = originalSpans[g.startLine - 1].end
                result.append(contentsOf: originalBytes[from..<to])
            }
            let groupStart = baseSpans[g.startLine].start
            let groupEnd = baseSpans[g.endLine - 1].end
            var slice = Array(baseBytes[groupStart..<groupEnd])
            for rep in g.reps.sorted(by: { $0.matchIndex < $1.matchIndex }).reversed() {
                let localStart = rep.matchIndex - groupStart
                let localEnd = localStart + rep.matchLength
                slice.replaceSubrange(localStart..<localEnd, with: Array(rep.newText.utf8))
            }
            result.append(contentsOf: slice)
            origLineIdx = g.endLine
        }
        if origLineIdx < originalSpans.count {
            result.append(contentsOf: originalBytes[originalSpans[origLineIdx].start...])
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Byte ranges of each line (including its trailing `\n`), mirroring pi's
    /// `[^\n]*\n|[^\n]+` split.
    private static func lineSpans(_ bytes: [UInt8]) -> [(start: Int, end: Int)] {
        var spans: [(Int, Int)] = []
        var start = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                spans.append((start, i + 1))
                start = i + 1
            }
            i += 1
        }
        if start < bytes.count { spans.append((start, bytes.count)) }
        return spans
    }

    private static func replacementLineRange(
        _ spans: [(start: Int, end: Int)], _ rep: Match, path: String
    ) throws -> (start: Int, end: Int) {
        let repStart = rep.matchIndex
        let repEnd = rep.matchIndex + rep.matchLength
        var startLine = -1
        for (i, span) in spans.enumerated() where repStart >= span.start && repStart < span.end {
            startLine = i
            break
        }
        guard startLine != -1 else {
            throw CodingToolError.invalidArgument("Replacement range is outside \(path).")
        }
        var endLine = startLine
        while endLine < spans.count && spans[endLine].end < repEnd { endLine += 1 }
        guard endLine < spans.count else {
            throw CodingToolError.invalidArgument("Replacement range is outside \(path).")
        }
        return (startLine, endLine + 1)
    }

    public struct FuzzyFind: Sendable {
        public var found: Bool
        public var utf8Offset: Int
        public var matchUTF8Length: Int
        public var usedFuzzyMatch: Bool
    }

    /// Find `needle` in `haystack`, preferring exact match over fuzzy.
    /// Returned offsets/lengths are in the UTF-8 representation of the content
    /// the caller should splice against (either original or fuzzy-normalized).
    public static func fuzzyFindText(_ needle: String, in haystack: String) -> FuzzyFind {
        if let range = haystack.range(of: needle) {
            let offset = haystack.utf8.distance(
                from: haystack.utf8.startIndex,
                to: range.lowerBound.samePosition(in: haystack.utf8) ?? haystack.utf8.startIndex
            )
            return FuzzyFind(
                found: true,
                utf8Offset: offset,
                matchUTF8Length: needle.utf8.count,
                usedFuzzyMatch: false
            )
        }
        let fuzzyContent = normalizeForFuzzyMatch(haystack)
        let fuzzyNeedle = normalizeForFuzzyMatch(needle)
        if let r = fuzzyContent.range(of: fuzzyNeedle) {
            let offset = fuzzyContent.utf8.distance(
                from: fuzzyContent.utf8.startIndex,
                to: r.lowerBound.samePosition(in: fuzzyContent.utf8) ?? fuzzyContent.utf8.startIndex
            )
            return FuzzyFind(
                found: true,
                utf8Offset: offset,
                matchUTF8Length: fuzzyNeedle.utf8.count,
                usedFuzzyMatch: true
            )
        }
        return FuzzyFind(found: false, utf8Offset: -1, matchUTF8Length: 0, usedFuzzyMatch: false)
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        let fuzzyContent = normalizeForFuzzyMatch(haystack)
        let fuzzyNeedle = normalizeForFuzzyMatch(needle)
        return fuzzyContent.components(separatedBy: fuzzyNeedle).count - 1
    }

    // MARK: - Diff output

    public struct DiffStringResult: Sendable, Equatable {
        public var diff: String
        public var firstChangedLine: Int?

        public init(diff: String, firstChangedLine: Int? = nil) {
            self.diff = diff
            self.firstChangedLine = firstChangedLine
        }
    }

    /// Backwards-compatible display diff wrapper.
    public static func generateDiff(old: String, new: String, contextLines: Int = 3) -> String {
        generateDiffString(old: old, new: new, contextLines: contextLines).diff
    }

    /// Generate a display-oriented diff with line numbers and folded context,
    /// mirroring pi's `generateDiffString`.
    public static func generateDiffString(
        old: String,
        new: String,
        contextLines: Int = 4
    ) -> DiffStringResult {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let ops = lineDiff(oldLines, newLines)
        let ranges = changedRanges(in: ops, contextLines: contextLines)
        let firstChangedLine = ops.compactMap { op -> Int? in
            switch op {
            case .equal:
                return nil
            case .delete, .insert:
                return op.newLine
            }
        }.first

        guard !ranges.isEmpty else {
            return DiffStringResult(diff: "", firstChangedLine: firstChangedLine)
        }

        var out: [String] = []
        let width = max(String(max(oldLines.count, newLines.count)).count, 1)
        var previousUpper = 0

        for range in ranges {
            if range.lowerBound > previousUpper {
                out.append(skipLine(width: width))
            }
            for op in ops[range] {
                out.append(formatDisplayOp(op, width: width))
            }
            previousUpper = range.upperBound
        }
        if previousUpper < ops.count {
            out.append(skipLine(width: width))
        }

        return DiffStringResult(diff: out.joined(separator: "\n"), firstChangedLine: firstChangedLine)
    }

    /// Generate a standard unified patch (`---`, `+++`, `@@`) for tools that
    /// need machine-readable patch details in addition to the display diff.
    public static func generateUnifiedPatch(
        path: String,
        old: String,
        new: String,
        contextLines: Int = 4
    ) -> String {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let ops = lineDiff(oldLines, newLines)
        let ranges = changedRanges(in: ops, contextLines: contextLines)
        var out = ["--- \(path)", "+++ \(path)"]

        for range in ranges {
            let hunk = Array(ops[range])
            let oldLen = hunk.filter(\.consumesOld).count
            let newLen = hunk.filter(\.consumesNew).count
            guard let first = hunk.first else { continue }
            let oldStart = oldLen == 0 ? max(0, first.oldLine - 1) : first.oldLine
            let newStart = newLen == 0 ? max(0, first.newLine - 1) : first.newLine
            out.append("@@ -\(patchRange(start: oldStart, length: oldLen)) +\(patchRange(start: newStart, length: newLen)) @@")
            for op in hunk {
                out.append(formatPatchOp(op))
            }
        }

        return out.joined(separator: "\n")
    }

    private enum DiffOp {
        case equal(line: String, oldLine: Int, newLine: Int)
        case delete(line: String, oldLine: Int, newLine: Int)
        case insert(line: String, oldLine: Int, newLine: Int)

        var oldLine: Int {
            switch self {
            case .equal(_, let oldLine, _), .delete(_, let oldLine, _), .insert(_, let oldLine, _):
                return oldLine
            }
        }

        var newLine: Int {
            switch self {
            case .equal(_, _, let newLine), .delete(_, _, let newLine), .insert(_, _, let newLine):
                return newLine
            }
        }

        var consumesOld: Bool {
            switch self {
            case .equal, .delete:
                return true
            case .insert:
                return false
            }
        }

        var consumesNew: Bool {
            switch self {
            case .equal, .insert:
                return true
            case .delete:
                return false
            }
        }

        var line: String {
            switch self {
            case .equal(let line, _, _), .delete(let line, _, _), .insert(let line, _, _):
                return line
            }
        }
    }

    private static func lineDiff(_ oldLines: [String], _ newLines: [String]) -> [DiffOp] {
        let difference = newLines.difference(from: oldLines)
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _):
                removals[offset] = element
            case .insert(let offset, let element, _):
                insertions[offset] = element
            }
        }

        var oldIndex = 0
        var newIndex = 0
        var ops: [DiffOp] = []
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if let removed = removals[oldIndex] {
                ops.append(.delete(line: removed, oldLine: oldIndex + 1, newLine: newIndex + 1))
                oldIndex += 1
                continue
            }
            if let inserted = insertions[newIndex] {
                ops.append(.insert(line: inserted, oldLine: oldIndex + 1, newLine: newIndex + 1))
                newIndex += 1
                continue
            }
            if oldIndex < oldLines.count && newIndex < newLines.count {
                ops.append(.equal(line: oldLines[oldIndex], oldLine: oldIndex + 1, newLine: newIndex + 1))
                oldIndex += 1
                newIndex += 1
                continue
            }
            if oldIndex < oldLines.count {
                ops.append(.delete(line: oldLines[oldIndex], oldLine: oldIndex + 1, newLine: newIndex + 1))
                oldIndex += 1
                continue
            }
            if newIndex < newLines.count {
                ops.append(.insert(line: newLines[newIndex], oldLine: oldIndex + 1, newLine: newIndex + 1))
                newIndex += 1
            }
        }
        return ops
    }

    private static func changedRanges(in ops: [DiffOp], contextLines: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for index in ops.indices where !isEqual(ops[index]) {
            let lower = max(ops.startIndex, index - contextLines)
            let upper = min(ops.endIndex, index + contextLines + 1)
            if let last = ranges.last, lower <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                ranges.append(lower..<upper)
            }
        }
        return ranges
    }

    private static func isEqual(_ op: DiffOp) -> Bool {
        if case .equal = op { return true }
        return false
    }

    private static func formatDisplayOp(_ op: DiffOp, width: Int) -> String {
        switch op {
        case .equal(let line, let oldLine, _):
            return " \(pad(oldLine, width: width)) \(line)"
        case .delete(let line, let oldLine, _):
            return "-\(pad(oldLine, width: width)) \(line)"
        case .insert(let line, _, let newLine):
            return "+\(pad(newLine, width: width)) \(line)"
        }
    }

    private static func formatPatchOp(_ op: DiffOp) -> String {
        switch op {
        case .equal:
            return " \(op.line)"
        case .delete:
            return "-\(op.line)"
        case .insert:
            return "+\(op.line)"
        }
    }

    private static func patchRange(start: Int, length: Int) -> String {
        length == 1 ? "\(start)" : "\(start),\(length)"
    }

    private static func skipLine(width: Int) -> String {
        " \(String(repeating: " ", count: width)) ..."
    }

    private static func pad(_ n: Int, width: Int) -> String {
        String(format: "%\(width)d", n)
    }
}
