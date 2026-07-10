import Foundation

/// UI-side compacting of the `<task-notification>` XML block that the
/// background-task bridge injects into the agent as a runtime aside. The LLM
/// consumes the full XML; the TUI uses
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
    let outputTruncated: Bool
    let isError: Bool
    let isStalled: Bool
    let isIncomplete: Bool

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
        let rawStatus = tag(text, "status")    ?? (isStalled ? "stalled" : "completed")
        let summary   = tag(text, "summary")
        let isIncomplete = summary == "incomplete"
        let status = isIncomplete ? "incomplete" : rawStatus
        let durationS = tag(text, "duration-ms")
        let duration  = durationS.flatMap(Int.init)
        // New notifications wrap escaped task output in an explicit trust
        // boundary. Keep the outer-tag fallback so transcripts written by
        // older kwwk versions still render correctly when resumed.
        let tail      = multilineTag(text, "untrusted-output", fallback: "output-tail")
        let truncated = tag(text, "output-truncated") == "true"
        let isError = !isIncomplete && (
            rawStatus == "failed"
                || summary?.contains("exit") == true
                    && summary?.contains("exit 0") == false
                    && rawStatus != "completed"
        )

        return BgNotificationSummary(
            label: label,
            status: status,
            summary: summary,
            durationMs: duration,
            outputTail: tail,
            outputTruncated: truncated,
            isError: isError || isStalled,
            isStalled: isStalled,
            isIncomplete: isIncomplete
        )
    }

    /// Render into transcript lines. Mirrors the `●` header + `⎿` result
    /// arm style the normal tool-result path uses.
    func render() -> [String] {
        let header = renderHeader()
        let body = renderBody()
        // Leading blank, no trailing — matches the "every scrollback
        // block opens with a separator, never closes with one" rule.
        return [""] + [header] + body
    }

    private func renderHeader() -> String {
        var parts: [String] = []
        let icon = isStalled || isIncomplete ? "⚠" : "●"
        parts.append(icon + " bg(\(label))")
        parts.append("· \(status)")
        if let summary, !summary.isEmpty, summary != status {
            parts.append("· \(summary)")
        }
        if let durationMs {
            parts.append("· \(formatDuration(durationMs))")
        }
        let joined = parts.joined(separator: " ")
        if isError || isStalled { return Style.error(joined) }
        if isIncomplete { return Style.running(joined) }
        return Style.tool(joined)
    }

    private func renderBody() -> [String] {
        let arm = "  ⎿ "
        func styler(_ s: String) -> String {
            if isError || isStalled { return Style.error(s) }
            if isIncomplete { return Style.running(s) }
            return Style.dimmed(s)
        }
        let preview = Array(outputTail.prefix(4))
        var out: [String] = preview.map { styler(arm + truncated($0, max: 200)) }
        let hidden = max(0, outputTail.count - preview.count)
        if hidden > 0 {
            out.append(styler("  ⎿ … \(hidden) more output lines"))
        }
        if outputTruncated {
            out.append(styler("  ⎿ … preview truncated; full output is available through job read"))
        }
        return out
    }

    // MARK: - Tiny XML-lite extraction
    //
    // The notification text is machine-emitted (see `BackgroundTaskNotification.formatXML`),
    // so we don't need a full XML parser — plain substring search on
    // `<tag>…</tag>` is safe and cheap.

    private static func tag(_ text: String, _ name: String) -> String? {
        rawTag(text, name).map(decodeXMLEntities)
    }

    private static func rawTag(_ text: String, _ name: String) -> String? {
        let open = "<\(name)>"
        let close = "</\(name)>"
        guard let openRange = text.range(of: open) else { return nil }
        guard let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex)
        else { return nil }
        return String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func multilineTag(
        _ text: String,
        _ name: String,
        fallback: String? = nil
    ) -> [String] {
        // The preferred tag belongs to the new escaped format. The fallback
        // belongs to legacy transcripts whose output tail was stored raw, so
        // decoding it would incorrectly turn an original literal `&lt;` into
        // `<` during resume rendering.
        let raw = rawTag(text, name).map(decodeXMLEntities)
            ?? fallback.flatMap { rawTag(text, $0) }
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Decode exactly one layer of the entities emitted by
    /// `BackgroundTaskNotification`. Decode `&amp;` last so an original literal
    /// such as `&lt;` round-trips as `&lt;` instead of being decoded twice.
    private static func decodeXMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
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
