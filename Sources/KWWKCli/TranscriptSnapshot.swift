import Foundation
import KWWKAI

/// Render a stored `[Message]` transcript into display lines for the retained
/// frame. Used by `/resume` to show a readable history of the session being
/// restored (the model itself receives the full messages; this is only the
/// visual recap). Deliberately compact: user turns, assistant prose, and a
/// one-line marker per tool call. Thinking blocks and tool results are
/// omitted to keep the recap skimmable.
enum TranscriptSnapshot {
    static func render(_ messages: [Message], width: Int) -> [String] {
        var out: [String] = []
        for message in messages {
            switch message {
            case .user(let u):
                let text = userText(u)
                guard !text.isEmpty else { continue }
                if !out.isEmpty { out.append("") }
                out.append(Theme.paint("❯ \(text)", Theme.text, bold: true))
            case .assistant(let a):
                var blockLines: [String] = []
                for block in a.content {
                    switch block {
                    case .text(let t):
                        let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { blockLines.append(Theme.bodyText(trimmed)) }
                    case .toolCall(let call):
                        blockLines.append(Theme.accentText("● \(call.name)\(argHint(call.arguments))", bold: false))
                    case .thinking:
                        continue
                    }
                }
                guard !blockLines.isEmpty else { continue }
                if !out.isEmpty { out.append("") }
                out.append(contentsOf: blockLines)
            case .toolResult:
                continue
            }
        }
        return out
    }

    private static func userText(_ u: UserMessage) -> String {
        let text = u.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined(separator: " ")
        // Drop synthetic system blocks (task notifications, attachment
        // manifests) so the recap shows only real user prose.
        if text.hasPrefix("<") { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short single-arg hint for a tool call, e.g. `(path: Foo.swift)`.
    private static func argHint(_ args: JSONValue) -> String {
        guard case .object(let fields) = args, !fields.isEmpty else { return "" }
        let preferred = ["path", "file_path", "command", "pattern", "query", "cmd"]
        let key = preferred.first { fields[$0] != nil } ?? fields.keys.sorted().first
        guard let key, let value = fields[key] else { return "" }
        let str = scalar(value)
        guard !str.isEmpty else { return "" }
        let clipped = str.count > 40 ? String(str.prefix(40)) + "…" : str
        return "(\(key): \(clipped))"
    }

    private static func scalar(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s.replacingOccurrences(of: "\n", with: " ")
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return ""
        }
    }
}
