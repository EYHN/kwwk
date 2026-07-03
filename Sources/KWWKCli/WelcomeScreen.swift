import Foundation

/// Static data the welcome card renders. Resolved once at TUI startup
/// (model, provider, cwd, git branch, recent sessions) and handed to the
/// `CodingFrame`, which paints it in the transcript area until the first
/// turn produces output.
struct WelcomeContext: Sendable {
    var version: String
    var modelId: String
    var providerName: String
    var cwd: String
    var branch: String?
    var recentSessions: [RecentSession]
    /// True when the session started with no credentials (sentinel model,
    /// no provider slots) — the card adds a dim "/login" hint line.
    var loggedOut: Bool = false

    struct RecentSession: Sendable {
        var name: String
        var relativeTime: String
        var messageCount: Int
    }
}

/// Renders the omp-style welcome card: a rounded box with a gradient mark +
/// account on the left and tips + recent sessions on the right. Pure (no
/// state) so the frame can re-render it at any width on resize.
enum WelcomeScreen {
    /// "kwwk" block wordmark (gradient-painted at render time). 5 rows; the
    /// letters are k(4) w(5) w(5) k(4) joined by single-column gaps → 21 cols.
    private static let logo: [String] = [
        "█  █ █   █ █   █ █  █",
        "█ █  █   █ █   █ █ █ ",
        "██   █ █ █ █ █ █ ██  ",
        "█ █  ██ ██ ██ ██ █ █ ",
        "█  █ █   █ █   █ █  █",
    ]

    private static let tips: [(key: String, desc: String)] = [
        ("/",          "slash commands"),
        ("@path",      "attach a file or image"),
        ("⇧⏎",         "insert a newline"),
        ("Esc",        "interrupt · Ctrl-C to quit"),
    ]

    static func render(_ ctx: WelcomeContext, width: Int) -> [String] {
        let boxWidth = min(max(0, width - 2), 84)
        guard boxWidth >= 52 else { return compact(ctx, width: width) }

        let inner = boxWidth - 4
        let leftW = 22
        let gap = 3                     // " │ "
        let rightW = max(10, inner - leftW - gap)

        let left = leftColumn(ctx)
        let right = rightColumn(ctx, width: rightW)
        let rows = max(left.count, right.count)

        var lines: [String] = []
        let margin = "  "
        lines.append(margin + Box.top(width: boxWidth, label: Theme.gradient("kwwk", bold: true) + Theme.faintText(" v\(ctx.version)")))
        lines.append(margin + Box.row("", width: boxWidth))
        for i in 0..<rows {
            let l = i < left.count ? left[i] : ""
            let r = i < right.count ? right[i] : ""
            let content = Box.pad(l, to: leftW) + " " + Theme.borderText(Box.v) + " " + Box.pad(r, to: rightW)
            lines.append(margin + Box.row(content, width: boxWidth))
        }
        lines.append(margin + Box.row("", width: boxWidth))
        lines.append(margin + Box.bottom(width: boxWidth))
        lines.append("")
        if ctx.loggedOut {
            lines.append("  " + Theme.faintText("not signed in — run /login to pick a provider"))
        }
        lines.append("  " + Theme.faintText(shorten(ctx.cwd, to: max(20, width - 4))))
        return lines
    }

    // MARK: - Columns

    private static func leftColumn(_ ctx: WelcomeContext) -> [String] {
        var col: [String] = []
        // "Welcome back!" would ring false on a logged-out first run.
        col.append(Theme.bodyText(ctx.loggedOut ? "Welcome!" : "Welcome back!"))
        col.append("")
        for row in logo { col.append(Theme.gradient(row)) }
        col.append("")
        col.append(Theme.accentText(ctx.modelId, bold: true))
        col.append(Theme.faintText(ctx.providerName))
        return col
    }

    private static func rightColumn(_ ctx: WelcomeContext, width: Int) -> [String] {
        var col: [String] = []
        col.append(Theme.accentText("Tips"))
        let keyW = tips.map { ANSI.visibleWidth($0.key) }.max() ?? 0
        for tip in tips {
            let key = Box.pad(Theme.bodyText(tip.key), to: keyW)
            col.append("\(key)  \(Theme.mutedText(tip.desc))")
        }
        col.append("")
        col.append(Theme.accentText("Recent sessions"))
        if ctx.recentSessions.isEmpty {
            col.append(Theme.faintText("no recent sessions yet"))
        } else {
            for s in ctx.recentSessions.prefix(3) {
                let count = "\(s.messageCount) msg\(s.messageCount == 1 ? "" : "s")"
                let meta = Theme.faintText("· \(s.relativeTime) · \(count)")
                let head = Theme.mutedText(s.name)
                col.append(ANSI.truncate("\(head)  \(meta)", to: width))
            }
        }
        return col
    }

    // MARK: - Narrow fallback

    private static func compact(_ ctx: WelcomeContext, width: Int) -> [String] {
        var lines: [String] = []
        lines.append("  " + Theme.gradient("kwwk") + Theme.faintText(" v\(ctx.version)"))
        lines.append("  " + Theme.accentText(ctx.modelId, bold: true)
            + Theme.faintText("  \(ctx.providerName)"))
        lines.append("")
        lines.append("  " + Theme.accentText("Tips"))
        for tip in tips {
            lines.append("  " + Theme.bodyText(tip.key) + "  " + Theme.mutedText(tip.desc))
        }
        if !ctx.recentSessions.isEmpty {
            lines.append("")
            lines.append("  " + Theme.accentText("Recent sessions"))
            for s in ctx.recentSessions.prefix(3) {
                lines.append("  " + Theme.mutedText(s.name)
                    + Theme.faintText(" · \(s.relativeTime)"))
            }
        }
        lines.append("")
        if ctx.loggedOut {
            lines.append("  " + Theme.faintText("not signed in — run /login to pick a provider"))
        }
        lines.append("  " + Theme.faintText(shorten(ctx.cwd, to: max(20, width - 4))))
        return lines
    }

    // MARK: - Helpers

    static func relativeTime(fromMillis ms: Int64, now: Date = Date()) -> String {
        let then = Double(ms) / 1000.0
        let delta = max(0, now.timeIntervalSince1970 - then)
        switch delta {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(delta / 60))m ago"
        case ..<86400: return "\(Int(delta / 3600))h ago"
        case ..<604800: return "\(Int(delta / 86400))d ago"
        default: return "\(Int(delta / 604800))w ago"
        }
    }

    private static func shorten(_ path: String, to maxLen: Int) -> String {
        guard path.count > maxLen, maxLen > 8 else { return path }
        let head = max(1, maxLen / 2 - 1)
        let tail = max(1, maxLen - head - 1)
        return "\(path.prefix(head))…\(path.suffix(tail))"
    }
}

/// Best-effort current git branch for the welcome card + prompt breadcrumb.
/// Returns nil outside a repo or if `git` is unavailable.
enum GitInfo {
    static func currentBranch(cwd: String) -> String? {
        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let branch, !branch.isEmpty, branch != "HEAD" else { return nil }
            return branch
        } catch {
            return nil
        }
    }
}
