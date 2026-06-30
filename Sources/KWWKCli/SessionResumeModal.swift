import Foundation
import KWWKAgent

/// Arrow-key list for `/resume` — pick a prior session to restore into the
/// running TUI. Rows show the working directory, relative age, and message
/// count; the live session (if present in the list) is tagged `· current`.
@MainActor
final class SessionResumeModal: Modal {
    private let sessions: [SessionStore.SessionInfo]
    private let currentSessionId: String
    private var selectedIndex = 0
    private let onSelect: @MainActor (SessionStore.SessionInfo) -> Void
    private let onCancel: @MainActor () -> Void

    init(
        sessions: [SessionStore.SessionInfo],
        currentSessionId: String,
        onSelect: @MainActor @escaping (SessionStore.SessionInfo) -> Void,
        onCancel: @MainActor @escaping () -> Void
    ) {
        self.sessions = sessions
        self.currentSessionId = currentSessionId
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    func up() {
        guard !sessions.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + sessions.count) % sessions.count
    }

    func down() {
        guard !sessions.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % sessions.count
    }

    func confirm() {
        guard sessions.indices.contains(selectedIndex) else { return }
        onSelect(sessions[selectedIndex])
    }

    func cancel() { onCancel() }

    func render() -> [String] {
        var out: [String] = []
        out.append("")
        out.append(Theme.accentText("  Resume a session"))
        out.append("")
        if sessions.isEmpty {
            out.append(Theme.faintText("  no saved sessions for this project yet"))
        } else {
            // Window the list so a long history stays on screen.
            let maxRows = 10
            var start = 0
            if selectedIndex >= maxRows { start = selectedIndex - maxRows + 1 }
            start = min(start, max(0, sessions.count - maxRows))
            for i in start..<min(sessions.count, start + maxRows) {
                let info = sessions[i]
                let selected = i == selectedIndex
                let marker = selected ? Theme.accentText("  ❯ ", bold: false) : "    "
                let base = (info.cwd as NSString).lastPathComponent
                let dir = base.isEmpty ? info.cwd : base
                // Prefer a user-set title (from /rename); fall back to the dir.
                let label = info.title?.isEmpty == false ? info.title! : dir
                let age = WelcomeScreen.relativeTime(fromMillis: info.updatedAt)
                let count = "\(info.messageCount) msg\(info.messageCount == 1 ? "" : "s")"
                let name = selected ? Theme.accentText(label, bold: true) : Theme.bodyText(label)
                let meta = Theme.faintText("· \(age) · \(count)")
                let current = info.id == currentSessionId ? Theme.faintText("  · current") : ""
                out.append(marker + name + "  " + meta + current)
            }
        }
        out.append("")
        out.append(Theme.faintText("  ↑/↓ move · ↵ resume · Esc cancel"))
        return out
    }
}
