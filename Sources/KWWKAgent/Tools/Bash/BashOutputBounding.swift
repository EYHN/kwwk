import Foundation
import KWWKAI

/// Bound bash output before it enters the transcript: keep the first
/// `Truncate.bashHeadBytes` (where the first error of a build usually lands)
/// and the last `Truncate.bashTailBytes` (summaries, final status), and mark
/// the elided middle. The model reaches the middle through the full output
/// file the marker names; the full text is not duplicated into `details`.
func boundBashOutput(_ text: String, fullOutputPath: String? = nil) -> String {
    boundBashOutputDetailed(text, fullOutputPath: fullOutputPath).text
}

/// `boundBashOutput` plus the truncation verdict, so callers holding the raw
/// artifact on disk can decide whether to keep it.
func boundBashOutputDetailed(
    _ text: String,
    fullOutputPath: String? = nil
) -> (text: String, truncated: Bool) {
    renderBashHeadTail(Truncate.truncateHeadTail(text), fullOutputPath: fullOutputPath)
}

func renderBashHeadTail(
    _ result: Truncate.HeadTailResult,
    fullOutputPath: String?
) -> (text: String, truncated: Bool) {
    guard result.truncated else { return (result.head, false) }
    let lines = result.omittedLines.flatMap { $0 > 0 ? "\($0) line(s), " : nil } ?? ""
    var marker = "[… output truncated: \(lines)\(Truncate.formatSize(result.omittedBytes)) omitted "
        + "from the middle; showing the first \(Truncate.formatSize(result.head.utf8.count)) "
        + "and the last \(Truncate.formatSize(result.tail.utf8.count)) of "
        + "\(Truncate.formatSize(result.totalBytes))"
    if let fullOutputPath {
        marker += "; full output: \(fullOutputPath) — grep or read it for the omitted part, "
            + "e.g. grep -n \"error:\" \(bashShellQuote(fullOutputPath))"
    }
    marker += " …]"
    // The final newline of the output only ends its last line.
    let tail = result.tail.utf8.last == 0x0A
        ? String(decoding: result.tail.utf8.dropLast(), as: UTF8.self)
        : result.tail
    return (result.head + "\n" + marker + "\n" + tail, true)
}
