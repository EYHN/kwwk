import Foundation
import KWWKAgent

/// Format a capacity suffix for the header's model line. Returns "" when
/// we can't usefully report anything (no window, no usage yet), a muted
/// `42% ctx` when comfortably below threshold, or a yellow
/// `● 78% ctx · auto-compact at 75%` when a compact will or just did fire.
func formatCapacityHint(usage: AgentContextUsage, threshold: Double?) -> String {
    guard usage.window > 0, usage.tokens > 0 else { return "" }
    let pct = Int((usage.ratio * 100).rounded(.down))
    let body = "\(pct)% ctx"
    if let threshold, usage.ratio >= threshold {
        let thresholdPct = Int((threshold * 100).rounded(.down))
        return Style.running("● \(body)") + " " + Style.dimmed("· auto-compact at \(thresholdPct)%")
    }
    return Style.dimmed(body)
}

/// A `width`-wide filled/empty bar with a trailing percent, used by
/// `/context` to visualize how full the window is. Ported from omp's
/// `renderAsciiBar` (format.ts). `fraction` is clamped to [0, 1].
func renderContextBar(fraction: Double, width: Int = 24) -> String {
    let clamped = min(max(fraction, 0), 1)
    let filled = Int((clamped * Double(width)).rounded())
    let pct = Int((clamped * 100).rounded())
    let bar = String(repeating: "█", count: filled)
        + String(repeating: "░", count: max(0, width - filled))
    return "[\(bar)] \(pct)%"
}
