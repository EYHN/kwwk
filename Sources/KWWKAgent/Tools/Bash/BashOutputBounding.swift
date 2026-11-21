import Foundation
import KWWKAI

/// Bound bash output before it enters the transcript: keep the first
/// `Truncate.bashHeadBytes` (first errors) and the last `bashTailBytes`
/// (summaries, final status) and mark the omitted middle. Callers that keep a full copy on
/// disk (the flip/background paths) still expose it via the output file; this
/// only bounds what the model sees inline, and is not duplicated into `details`.
func boundBashOutput(_ text: String) -> String {
    boundBashOutputDetailed(text).text
}

/// `boundBashOutput` plus the truncation verdict, so callers holding the raw
/// artifact on disk can decide whether to keep it. When `fullOutputPath` is
/// given, the truncation notice points the model at that file — a first
/// compile error buried mid-log is one `grep` away instead of unreachable.
func boundBashOutputDetailed(
    _ text: String,
    fullOutputPath: String? = nil
) -> (text: String, truncated: Bool) {
    let totalBytes = text.utf8.count
    guard totalBytes > Truncate.bashHeadBytes + Truncate.bashTailBytes else { return (text, false) }
    let head = Truncate.truncateHead(text, maxLines: .max, maxBytes: Truncate.bashHeadBytes)
    let tail = Truncate.truncateTail(text, maxLines: .max, maxBytes: Truncate.bashTailBytes)
    var notice = "[… output truncated: \(Truncate.formatSize(totalBytes - head.outputBytes - tail.outputBytes)) "
        + "omitted from the middle of \(Truncate.formatSize(totalBytes))"
    if let fullOutputPath {
        notice += "; full output: \(fullOutputPath) — grep it for the omitted part, "
            + "e.g. grep -n \"error:\" \(bashShellQuote(fullOutputPath))"
    }
    return (head.content + "\n" + notice + " …]\n" + tail.content, true)
}
