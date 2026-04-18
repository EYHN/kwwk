import Foundation

/// UI-side compacting of the `<task-notification>` XML block that the
/// background-task bridge steers into the agent as a synthetic user
/// message. The LLM consumes the full XML; the TUI uses
/// `BgNotificationSummary` to render it as a `●`/`⎿` tool-result-style
/// entry instead of dumping the raw tags.
///
/// Detection is by lead-in prefix (see `BackgroundTaskNotification.messageText()`);
/// `parse` returns nil for anything that doesn't look like one of our
/// notifications, in which case the renderer falls through to treating it
/// as a regular user prompt.
struct BgNotificationSummary {
    let label: String
    let status: String          // e.g. "completed", "failed", "stalled"
    let summary: String?        // e.g. "exit 0", "exit 1 (signal)"
    let durationMs: Int?
    let outputTail: [String]    // lines from <output-tail>, trimmed
    let isError: Bool
    let isStalled: Bool

    /// Return nil if `text` isn't a background-task notification. We only
    /// recognise the two lead-ins the bridge emits so genuine user
    /// messages that happen to contain XML-looking strings pass through
    /// untouched.
    static func parse(_ text: String) -> BgNotificationSummary? {
        let completedLead = "A background task completed:"
        let stalledLead   = "A background task appears stuck"
        let isStalled: Bool
        if text.hasPrefix(completedLead) {
            isStalled = false
        } else if text.hasPrefix(stalledLead) {
            isStalled = true
        } else {
            return nil
        }

        let label     = tag(text, "label")     ?? tag(text, "task-id") ?? "background task"
        let status    = tag(text, "status")    ?? (isStalled ? "stalled" : "completed")
        let summary   = tag(text, "summary")
        let durationS = tag(text, "duration-ms")
        let duration  = durationS.flatMap(Int.init)
        let tail      = multilineTag(text, "output-tail")
        let isError   = status == "failed" || summary?.contains("exit") == true && summary?.contains("exit 0") == false && status != "completed"

        return BgNotificationSummary(
            label: label,
            status: status,
            summary: summary,
            durationMs: duration,
            outputTail: tail,
            isError: isError || isStalled,
            isStalled: isStalled
        )
    }

    /// Render into transcript lines. Mirrors the `●` header + `⎿` result
    /// arm style the normal tool-result path uses.
    func render() -> [String] {
        let header = renderHeader()
        let body = renderBody()
        return [header] + body
    }

    private func renderHeader() -> String {
        var parts: [String] = []
        let icon = isStalled ? "⚠" : (isError ? "●" : "●")
        parts.append(icon + " bg(\(label))")
        parts.append("· \(status)")
        if let summary, !summary.isEmpty, summary != status {
            parts.append("· \(summary)")
        }
        if let durationMs {
            parts.append("· \(formatDuration(durationMs))")
        }
        let joined = parts.joined(separator: " ")
        return isError || isStalled ? Style.error(joined) : Style.tool(joined)
    }

    private func renderBody() -> [String] {
        let arm = "  ⎿ "
        let errorStyle = isError || isStalled
        func styler(_ s: String) -> String { errorStyle ? Style.error(s) : Style.dimmed(s) }
        let preview = Array(outputTail.prefix(4))
        var out: [String] = preview.map { styler(arm + truncated($0, max: 200)) }
        let hidden = max(0, outputTail.count - preview.count)
        if hidden > 0 {
            out.append(styler("  ⎿ … \(hidden) more output lines"))
        }
        return out
    }

    // MARK: - Tiny XML-lite extraction
    //
    // The notification text is machine-emitted (see `BackgroundTaskNotification.formatXML`),
    // so we don't need a full XML parser — plain substring search on
    // `<tag>…</tag>` is safe and cheap.

    private static func tag(_ text: String, _ name: String) -> String? {
        let open = "<\(name)>"
        let close = "</\(name)>"
        guard let openRange = text.range(of: open) else { return nil }
        guard let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex)
        else { return nil }
        return String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func multilineTag(_ text: String, _ name: String) -> [String] {
        guard let raw = tag(text, name), !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = seconds / 60
        return String(format: "%.1fm", minutes)
    }

    private func truncated(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}
