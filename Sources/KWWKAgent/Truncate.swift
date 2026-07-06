import Foundation

public enum Truncate {
    public static let defaultMaxLines = 2000
    public static let defaultMaxBytes = 50 * 1024
    public static let grepMaxLineLength = 300
    public static let grepMaxTotalBytes = 30 * 1024
    public static let grepDefaultLimit = 50

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
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
        // ends in "" instead of "3".
        let body = content.hasSuffix("\n") ? String(content.dropLast()) : content
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
        for line in lines.reversed() {
            if kept.count >= maxLines {
                truncatedBy = "lines"
                break
            }
            let lineBytes = line.utf8.count + (kept.isEmpty ? 0 : 1)
            if outBytes + lineBytes > maxBytes {
                truncatedBy = "bytes"
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
            lastLinePartial: false,
            firstLineExceedsLimit: false,
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    /// Truncate a single line to `maxChars` characters, adding a suffix if needed.
    public static func truncateLine(
        _ line: String, maxChars: Int = grepMaxLineLength
    ) -> (text: String, wasTruncated: Bool) {
        if line.count <= maxChars { return (line, false) }
        let idx = line.index(line.startIndex, offsetBy: maxChars)
        return (String(line[..<idx]) + "... [truncated]", true)
    }
}
