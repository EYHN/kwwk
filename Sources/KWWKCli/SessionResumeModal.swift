import Foundation
import KWWKAgent

/// Arrow-key list for `/resume` — pick a prior session to restore into the
/// running TUI. Rows show the session title (or working-directory basename),
/// relative age, and message count; the live session (if present in the list)
/// is tagged `· current`. Selection, windowing, and rendering live in
/// `ModalListCore`.
@MainActor
final class SessionResumeModal: Modal {
    private let sessions: [SessionStore.SessionInfo]
    private let currentSessionId: String
    private let core: ModalListCore
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
        self.core = ModalListCore(
            rows: sessions.map { info in
                let base = (info.cwd as NSString).lastPathComponent
                let dir = base.isEmpty ? info.cwd : base
                // Prefer a user-set title (from /rename); fall back to the dir.
                let label = info.title?.isEmpty == false ? info.title! : dir
                let age = WelcomeScreen.relativeTime(fromMillis: info.updatedAt)
                let count = "\(info.messageCount) msg\(info.messageCount == 1 ? "" : "s")"
                return ModalListCore.Row(
                    label: label,
                    detail: "· \(age) · \(count)",
                    isCurrent: info.id == currentSessionId
                )
            },
            emptyMessage: "no saved sessions for this project yet"
        )
    }

    func up() { core.up() }
    func down() { core.down() }

    func confirm() {
        guard !core.isEmpty, sessions.indices.contains(core.selectedIndex) else { return }
        let selected = sessions[core.selectedIndex]
        // Reloading the live session is destructive rather than useful: the
        // replacement path retires its Agent and closes every active task in the
        // session namespace. Treat the explicitly-labelled current row as a
        // close/no-op so an accidental Enter cannot kill ongoing work.
        guard selected.id != currentSessionId else {
            onCancel()
            return
        }
        onSelect(selected)
    }

    func cancel() { onCancel() }

    func render(maxRows: Int) -> [String] {
        core.render(title: "Resume a session", maxRows: maxRows)
    }
}
