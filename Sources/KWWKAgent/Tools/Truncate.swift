import Foundation

public enum Truncate {
    public static let defaultMaxLines = 2000
    public static let defaultMaxBytes = 50 * 1024
    public static let grepMaxLineLength = 300
    public static let grepMaxTotalBytes = 30 * 1024
    public static let grepDefaultLimit = 50
    /// How long a grep may run before it returns what it has (seconds).
    public static let grepDefaultTimeBudgetSeconds: Double = 30
    public static let grepMaxTimeBudgetSeconds: Double = 600
    /// Inline bash output keeps this much of the start (the command's first
    /// errors) and of the end (its summary); the middle goes to a file.
    public static let bashHeadBytes = 4 * 1024
    public static let bashTailBytes = 12 * 1024
    /// `read` without a `limit` returns at most this many lines.
    public static let readDefaultLimit = 500
    /// `find` / `ls` without a `limit` list at most this many entries.
    public static let findDefaultLimit = 1000
    public static let lsDefaultLimit = 500
    /// Total listing text `find` / `ls` return, whatever the limit.
    public static let listingMaxBytes = 50 * 1024

    public struct Result: Sendable {
        public var content: String
        public var truncated: Bool
        public var truncatedBy: String?   // "lines" | "bytes" | nil
        public var totalLines: Int
        public var totalBytes: Int
        public var outputLines: Int
        public var outputBytes: Int
        public var lastLinePartial: Bool
        public var firstLineExceedsLimit: Bool
        public var maxLines: Int
        public var maxBytes: Int
    }

    /// Splits on the "\n" byte, keeping a "\r" with its line. A Character
    /// split would not: Swift reads "\r\n" as one grapheme, so a CRLF text
    /// came back as a single line (a CRLF file over the byte budget read as
    /// "line 1 exceeds limit"). 0x0A never occurs inside a multi-byte
    /// sequence, so every piece decodes as it does in the whole text.
    static func splitLines(_ content: String) -> [String] {
        content.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    public static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 {
            return String(format: "%.1fKB", Double(bytes) / 1024.0)
        }
        return String(format: "%.1fMB", Double(bytes) / 1_048_576.0)
    }

    /// Head truncation — keep first N lines/bytes. Never returns a partial line
    /// (except when the first line alone exceeds the byte budget).
    public static func truncateHead(
        _ content: String,
        maxLines: Int = defaultMaxLines,
        maxBytes: Int = defaultMaxBytes
    ) -> Result {
        let totalBytes = content.utf8.count
        let lines = splitLines(content)
        let totalLines = lines.count

        if totalLines <= maxLines && totalBytes <= maxBytes {
            return Result(
                content: content,
                truncated: false,
                truncatedBy: nil,
                totalLines: totalLines,
                totalBytes: totalBytes,
                outputLines: totalLines,
                outputBytes: totalBytes,
                lastLinePartial: false,
                firstLineExceedsLimit: false,
                maxLines: maxLines,
                maxBytes: maxBytes
            )
        }

        let firstLineBytes = lines.first?.utf8.count ?? 0
        if firstLineBytes > maxBytes {
            return Result(
                content: "",
                truncated: true,
                truncatedBy: "bytes",
                totalLines: totalLines,
                totalBytes: totalBytes,
                outputLines: 0,
                outputBytes: 0,
                lastLinePartial: false,
                firstLineExceedsLimit: true,
                maxLines: maxLines,
                maxBytes: maxBytes
            )
        }

        var out: [String] = []
        var outBytes = 0
        var truncatedBy = "lines"
        for (i, line) in lines.enumerated() {
            if i >= maxLines { break }
            let lineBytes = line.utf8.count + (i > 0 ? 1 : 0)
            if outBytes + lineBytes > maxBytes {
                truncatedBy = "bytes"
                break
            }
            out.append(line)
            outBytes += lineBytes
        }
        if out.count >= maxLines && outBytes <= maxBytes {
            truncatedBy = "lines"
        }
        let output = out.joined(separator: "\n")
        return Result(
            content: output,
            truncated: true,
            truncatedBy: truncatedBy,
            totalLines: totalLines,
            totalBytes: totalBytes,
            outputLines: out.count,
            outputBytes: output.utf8.count,
            lastLinePartial: false,
            firstLineExceedsLimit: false,
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    /// Tail truncation — keep the last N lines/bytes. Command output (bash,
    /// test runs) is most useful at the end, where errors and summaries land,
    /// so this is the counterpart to `truncateHead` for tool output that we
    /// want to bound without losing the tail.
    public static func truncateTail(
        _ content: String,
        maxLines: Int = defaultMaxLines,
        maxBytes: Int = defaultMaxBytes
    ) -> Result {
        let totalBytes = content.utf8.count
        // A trailing newline terminates the last line — it does not start an
        // empty one. Without this, `seq 1 3` counts 4 lines and the kept tail
        // ends in "" instead of "3". Checked on the byte: a text ending in
        // "\r\n" ends in that one Character, which is not "\n".
        let body = content.utf8.last == 0x0A
            ? String(decoding: content.utf8.dropLast(), as: UTF8.self)
            : content
        let lines = splitLines(body)
        let totalLines = lines.count

        if totalLines <= maxLines && totalBytes <= maxBytes {
            return Result(
                content: content,
                truncated: false,
                truncatedBy: nil,
                totalLines: totalLines,
                totalBytes: totalBytes,
                outputLines: totalLines,
                outputBytes: totalBytes,
                lastLinePartial: false,
                firstLineExceedsLimit: false,
                maxLines: maxLines,
                maxBytes: maxBytes
            )
        }

        var kept: [String] = []
        var outBytes = 0
        var truncatedBy = "lines"
        var lastLinePartial = false
        for line in lines.reversed() {
            if kept.count >= maxLines {
                truncatedBy = "lines"
                break
            }
            let lineBytes = line.utf8.count + (kept.isEmpty ? 0 : 1)
            if outBytes + lineBytes > maxBytes {
                truncatedBy = "bytes"
                // The last line alone is over budget (minified JSON, a
                // \r-only progress bar): keep its tail rather than nothing,
                // since that is where the final status or error lands.
                if kept.isEmpty {
                    let partial = suffix(line, fittingUTF8Bytes: maxBytes)
                    if !partial.isEmpty {
                        kept.append(partial)
                        lastLinePartial = true
                    }
                }
                break
            }
            kept.append(line)
            outBytes += lineBytes
        }
        let output = kept.reversed().joined(separator: "\n")
        return Result(
            content: output,
            truncated: true,
            truncatedBy: truncatedBy,
            totalLines: totalLines,
            totalBytes: totalBytes,
            outputLines: kept.count,
            outputBytes: output.utf8.count,
            lastLinePartial: lastLinePartial,
            firstLineExceedsLimit: false,
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    public struct HeadTailResult: Sendable, Equatable {
        /// The whole content when not truncated.
        public var head: String
        public var tail: String
        public var truncated: Bool
        public var totalBytes: Int
        public var omittedBytes: Int
        /// Lines cut from the middle; nil when the middle was never read.
        public var omittedLines: Int?
    }

    /// Keep the first `headBytes` and the last `tailBytes` of `content`, cut
    /// on line boundaries where one falls in budget, otherwise on a UTF-8
    /// scalar boundary. A "\r" stays with its line, so CRLF text is never
    /// split inside a line ending.
    public static func truncateHeadTail(
        _ content: String,
        headBytes: Int = bashHeadBytes,
        tailBytes: Int = bashTailBytes
    ) -> HeadTailResult {
        let bytes = Array(content.utf8)
        return truncateHeadTail(
            prefix: bytes,
            suffix: bytes,
            totalBytes: bytes.count,
            headBytes: headBytes,
            tailBytes: tailBytes
        )
    }

    /// Head/tail cut over a content of `totalBytes` known only by its first
    /// bytes (`prefix`) and last bytes (`suffix`), as when a large file is
    /// read in two windows. The omitted line count is reported only when
    /// `suffix` is the whole content.
    static func truncateHeadTail(
        prefix: [UInt8],
        suffix: [UInt8],
        totalBytes: Int,
        headBytes: Int,
        tailBytes: Int
    ) -> HeadTailResult {
        let headBytes = max(0, headBytes)
        let tailBytes = max(0, tailBytes)
        if totalBytes <= headBytes + tailBytes, prefix.count == totalBytes {
            return HeadTailResult(
                head: String(decoding: prefix, as: UTF8.self),
                tail: "",
                truncated: false,
                totalBytes: totalBytes,
                omittedBytes: 0,
                omittedLines: 0
            )
        }

        // Head: through the last line that fits; a first line over budget
        // keeps its start.
        let headLimit = min(headBytes, prefix.count)
        var headEnd: Int
        var headEndsAtNewline = false
        if let newline = prefix[..<headLimit].lastIndex(of: 0x0A) {
            headEnd = newline
            headEndsAtNewline = true
        } else {
            headEnd = headLimit
            while headEnd > 0, headEnd < prefix.count, isUTF8Continuation(prefix[headEnd]) {
                headEnd -= 1
            }
        }

        // Tail: from the first line start in budget (a trailing newline ends
        // the last line, it does not start one); a last line over budget
        // keeps its end.
        let suffixStart = max(0, suffix.count - tailBytes)
        let searchEnd = suffix.last == 0x0A ? suffix.count - 1 : suffix.count
        var tailStart: Int
        if suffixStart < searchEnd,
           let newline = suffix[suffixStart..<searchEnd].firstIndex(of: 0x0A) {
            tailStart = newline + 1
        } else {
            tailStart = suffixStart
            while tailStart < suffix.count, isUTF8Continuation(suffix[tailStart]) {
                tailStart += 1
            }
        }

        let suffixOffset = totalBytes - suffix.count
        let middleStart = headEnd
        let middleEnd = max(middleStart, suffixOffset + tailStart)
        var omittedLines: Int?
        if suffix.count == totalBytes {
            let newlines = suffix[middleStart..<middleEnd].reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            omittedLines = max(0, newlines - (headEndsAtNewline ? 1 : 0))
        }
        return HeadTailResult(
            head: String(decoding: prefix[..<headEnd], as: UTF8.self),
            tail: String(decoding: suffix[tailStart...], as: UTF8.self),
            truncated: true,
            totalBytes: totalBytes,
            omittedBytes: middleEnd - middleStart,
            omittedLines: omittedLines
        )
    }

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    /// How many leading `entries` fit, newline-joined, in `maxBytes`.
    static func entriesFitting(_ entries: [String], maxBytes: Int) -> Int {
        var used = 0
        for (index, entry) in entries.enumerated() {
            used += entry.utf8.count + (index > 0 ? 1 : 0)
            if used > maxBytes { return index }
        }
        return entries.count
    }

    /// Write `text` to a new private file so a model can reach output that was
    /// cut from its inline result. Returns the path, or nil if writing failed.
    static func saveFullOutput(
        _ text: String,
        directory: URL? = nil,
        prefix: String,
        fileExtension: String = "log"
    ) -> String? {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-tool-output", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = dir.appendingPathComponent(
                "\(prefix)_\(UUID().uuidString.prefix(8)).\(fileExtension)"
            )
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(text.utf8),
                attributes: [.posixPermissions: 0o600]
            ) else { return nil }
            return url.path
        } catch {
            return nil
        }
    }

    /// The longest suffix of `text` that fits in `limit` UTF-8 bytes, cut on
    /// a Character boundary.
    private static func suffix(_ text: String, fittingUTF8Bytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        var used = 0
        var start = text.endIndex
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let bytes = text[previous..<index].utf8.count
            if used + bytes > limit { break }
            used += bytes
            start = previous
            index = previous
        }
        return String(text[start...])
    }

    /// Truncate a single line to `maxChars` characters, adding a suffix if needed.
    public static func truncateLine(
        _ line: String,
        maxChars: Int = grepMaxLineLength
    ) -> (text: String, wasTruncated: Bool) {
        if line.count <= maxChars { return (line, false) }
        let idx = line.index(line.startIndex, offsetBy: maxChars)
        return (String(line[..<idx]) + "... [truncated]", true)
    }
}
