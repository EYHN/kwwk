import Foundation
import KWWKAgent

/// Interactive picker for `--resume`: lists every persisted session (across all
/// projects, newest first) and lets the user choose one. Ports the intent of
/// pi's `selectSession` / `SessionSelectorComponent` as a minimal numbered
/// stdin prompt — kwwk has no reusable live-filtering selectable-list TUI, so
/// this stays a plain prompt that's trivially unit-testable.
enum SessionPicker {

    /// Pure selection step: given the listed sessions and a single input line,
    /// return the chosen `SessionInfo`. An empty line (or any non-`1...n`
    /// value) cancels and returns `nil`. Factored out so the parsing is unit
    /// testable without touching stdin.
    static func select(from infos: [SessionStore.SessionInfo], line: String) -> SessionStore.SessionInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(trimmed), n >= 1, n <= infos.count else { return nil }
        return infos[n - 1]
    }

    /// One rendered menu row for `info` at 1-based `index`.
    static func renderRow(_ info: SessionStore.SessionInfo, index: Int) -> String {
        let base = (info.cwd as NSString).lastPathComponent
        let dir = base.isEmpty ? info.cwd : base
        // Prefer a user-set title (from /rename); fall back to the dir.
        let label = info.title?.isEmpty == false ? info.title! : dir
        let when = relativeTime(fromMillis: info.updatedAt)
        let idPrefix = String(info.id.prefix(8))
        return "\(index)) \(label) · \(info.messageCount) msgs · \(when) · \(idPrefix)"
    }

    /// Render the full menu (header + rows) for a non-empty session list.
    static func renderMenu(_ infos: [SessionStore.SessionInfo]) -> String {
        var lines = ["Select a session to resume (enter a number, blank to cancel):"]
        for (i, info) in infos.enumerated() {
            lines.append("  " + renderRow(info, index: i + 1))
        }
        return lines.joined(separator: "\n")
    }

    /// Interactive entry point. Prints the menu to stderr, reads one line from
    /// stdin, and returns the chosen session id (or `nil` on cancel / empty
    /// list). Kept thin so the testable surface is `select(from:line:)`.
    static func choose(store: SessionStore) async -> String? {
        let infos = await store.list()
        guard !infos.isEmpty else {
            FileHandle.standardError.write(Data("No sessions to resume.\n".utf8))
            return nil
        }
        FileHandle.standardError.write(Data((renderMenu(infos) + "\n> ").utf8))
        guard let data = try? FileHandle.standardInput.read(upToCount: 1024),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return select(from: infos, line: line)?.id
    }

    private static func relativeTime(fromMillis millis: Int64) -> String {
        let secondsAgo = Int(Date().timeIntervalSince1970) - Int(millis / 1000)
        if secondsAgo < 0 { return "just now" }
        if secondsAgo < 60 { return "\(secondsAgo)s ago" }
        let minutes = secondsAgo / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
