import Foundation

public enum EditDiff {

    public struct Edit: Sendable, Equatable {
        public var oldText: String
        public var newText: String
        public var replaceAll: Bool
        public init(oldText: String, newText: String, replaceAll: Bool = false) {
            self.oldText = oldText
            self.newText = newText
            self.replaceAll = replaceAll
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

    /// The ending of the first line, read on bytes. `range(of: "\n")`
    /// searches by Character and never finds the "\n" inside a "\r\n"
    /// grapheme, so every CRLF file read as LF and an edit rewrote all of
    /// its line endings to LF.
    public static func detectLineEnding(_ content: String) -> LineEnding {
        let utf8 = content.utf8
        guard let newline = utf8.firstIndex(of: 0x0A), newline > utf8.startIndex else { return .lf }
        return utf8[utf8.index(before: newline)] == 0x0D ? .crlf : .lf
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
            Edit(
                oldText: normalizeToLF($0.oldText),
                newText: normalizeToLF($0.newText),
                replaceAll: $0.replaceAll
            )
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
                let label = normEdits.count == 1 ? "the exact text" : "edits[\(i)]"
                var message = "Could not find \(label) in \(path). The oldText must match exactly including all whitespace and newlines."
                if let nearMiss = nearMissSnippet(for: edit.oldText, in: normalizedContent) {
                    message += " Closest candidate in the file (line \(nearMiss.line)):\n\(nearMiss.snippet)"
                }
                throw CodingToolError.textNotFound(message)
            }
            let occurrences = countOccurrences(of: edit.oldText, in: replacementBase)
            if occurrences > 1, !edit.replaceAll {
                throw CodingToolError.multipleMatches(count: occurrences)
            }
            if occurrences > 1 {
                let needle = matchResult.usedFuzzyMatch
                    ? normalizeForFuzzyMatch(edit.oldText)
                    : edit.oldText
                for occurrence in allOccurrences(of: needle, in: replacementBase) {
                    matches.append(Match(
                        editIndex: i,
                        matchIndex: occurrence.utf8Offset,
                        matchLength: occurrence.utf8Length,
                        newText: edit.newText
                    ))
                }
            } else {
                matches.append(Match(
                    editIndex: i,
                    matchIndex: matchResult.utf8Offset,
                    matchLength: matchResult.matchUTF8Length,
                    newText: edit.newText
                ))
            }
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
                original: normalizedContent,
                base: replacementBase,
                matches: matches,
                path: path
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
        original: String,
        base: String,
        matches: [Match],
        path: String
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
        _ spans: [(start: Int, end: Int)],
        _ rep: Match,
        path: String
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

    /// Non-overlapping occurrences of `needle` in `haystack`, as UTF-8 byte
    /// ranges valid for splicing against `haystack`.
    private static func allOccurrences(
        of needle: String,
        in haystack: String
    ) -> [(utf8Offset: Int, utf8Length: Int)] {
        guard !needle.isEmpty else { return [] }
        var results: [(Int, Int)] = []
        var searchStart = haystack.startIndex
        let needleLength = needle.utf8.count
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let offset = haystack.utf8.distance(
                from: haystack.utf8.startIndex,
                to: range.lowerBound.samePosition(in: haystack.utf8) ?? haystack.utf8.startIndex
            )
            results.append((offset, needleLength))
            searchStart = range.upperBound
        }
        return results
    }

    /// Locate the region a failed oldText most likely intended, so the error
    /// can show what the file actually contains there. Anchors on the first
    /// non-empty line of the needle in fuzzy space; the snippet is copied from
    /// the ORIGINAL content (fuzzy normalization preserves line counts), so
    /// the model sees the real bytes it must reproduce.
    private static func nearMissSnippet(
        for needle: String,
        in normalizedContent: String
    ) -> (line: Int, snippet: String)? {
        let anchor = normalizeForFuzzyMatch(needle)
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces)
        guard let anchor, !anchor.isEmpty else { return nil }

        let fuzzyContent = normalizeForFuzzyMatch(normalizedContent)
        guard let range = fuzzyContent.range(of: anchor) else { return nil }
        let lineIndex = fuzzyContent[..<range.lowerBound]
            .components(separatedBy: "\n").count - 1

        let needleLines = needle.components(separatedBy: "\n").count
        let originalLines = normalizedContent.components(separatedBy: "\n")
        guard lineIndex < originalLines.count else { return nil }
        let snippetLines = originalLines[lineIndex..<min(lineIndex + min(needleLines, 5), originalLines.count)]
            .map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }
        return (line: lineIndex + 1, snippet: snippetLines.joined(separator: "\n"))
    }
}
