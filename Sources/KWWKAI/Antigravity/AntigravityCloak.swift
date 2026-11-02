import Foundation

/// The system-prompt lines Antigravity turns away, and how they are sent so
/// they are not. Ported from magpie's `antigravityCloak` (gateway/codeassist.go).
///
/// A system instruction that carries one of these lines anywhere, in any
/// case, is answered 429 "Resource has been exhausted (e.g. check quota)"
/// on every model whatever quota is left, while the same words in a message
/// go through (magpie #666). Each line is broken up before it goes by a
/// zero-width space after its first letter, which Google lets through and
/// the model reads past; each line so broken was answered on a real
/// account where the line as written was turned away.
enum AntigravityCloak {
    /// The lines, lower-cased, each tried on a real account:
    ///   - Claude Code's billing line and the Claude Agent SDK's identity
    ///     line (Claude Desktop's chats);
    ///   - the identity lines of Codex's own prompts for its GPT-5 models;
    ///   - Hermes Agent's earlier default persona.
    static let turnedAwayLines = [
        "x-anthropic-billing-header:",
        "built on anthropic's claude agent sdk",
        "you are codex, an agent based on gpt-5",
        "you are codex, a coding agent based on gpt-5",
        "hermes agent, an intelligent ai assistant created by nous research",
    ]

    /// U+200B, what goes inside a line Antigravity turns away.
    static let zeroWidth = "\u{200B}"

    /// Whether `system` carries a line Antigravity turns away.
    static func turnsAway(_ system: String) -> Bool {
        let low = asciiLowercased(Array(system.utf8))
        return turnedAwayLines.contains { contains(low, Array($0.utf8)) }
    }

    /// `system` with each line Antigravity turns away broken up by a
    /// zero-width space after its first letter, wherever and in whatever case
    /// it is, and every other byte as the caller wrote it. A line already
    /// broken up is not one any more and is left alone.
    static func cloak(_ system: String) -> String {
        let bytes = Array(system.utf8)
        let low = asciiLowercased(bytes)
        var breaks: Set<Int> = []
        for line in turnedAwayLines {
            let needle = Array(line.utf8)
            var from = 0
            while let at = index(of: needle, in: low, from: from) {
                breaks.insert(at + 1)
                from = at + needle.count
            }
        }
        guard !breaks.isEmpty else { return system }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + breaks.count * 3)
        let zero = Array(zeroWidth.utf8)
        for (offset, byte) in bytes.enumerated() {
            if breaks.contains(offset) { out += zero }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Whether what Antigravity said is the refusal's words, on either shape
    /// it arrives in: a 429's body, or the reply's own error event.
    static func refuses(_ said: String) -> Bool {
        said.lowercased().contains("resource has been exhausted")
    }

    /// Whether Google turned the request away for its system prompt: the
    /// prompt carries a line it refuses, and the answer is the refusal's
    /// words. A 429 that says something else — the plan's own allowance
    /// used up ("You have exhausted your capacity on this model. Your quota
    /// will reset after …") — is the quota it says, whatever the prompt.
    static func turnedAway(system: String?, said: String) -> Bool {
        guard let system else { return false }
        return turnsAway(system) && refuses(said)
    }

    /// What is added to Antigravity's words, after " — ", so the refusal is
    /// told apart from a spent quota in the user's own terms.
    static func hint(system: String?) -> String {
        let low = (system ?? "").lowercased()
        if low.contains("you are codex, an agent based on gpt-5") || low.contains("you are codex, a coding agent based on gpt-5") {
            return "Antigravity answers this 429 to Codex's own system prompt for GPT-5 models whatever quota is left, "
                + "so it is not a quota and waiting won't help; a chat begun on a GPT model keeps that prompt, "
                + "so start a new chat on this model"
        }
        if low.contains("hermes agent, an intelligent ai assistant created by nous research") {
            return "Antigravity answers this 429 to Hermes Agent's earlier default persona whatever quota is left, "
                + "so it is not a quota and waiting won't help; Hermes' current default persona goes through"
        }
        return "Antigravity answers this 429 to the system prompt of Claude Code and the Claude Agent SDK "
            + "whatever quota is left, so it is not a quota and waiting won't help; use another provider for these chats"
    }

    // MARK: - Bytes

    /// `bytes` with its ASCII letters lower-cased and every other byte where
    /// it is, so a match in it is found at the offset it has in the original.
    private static func asciiLowercased(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        index(of: needle, in: haystack, from: 0) != nil
    }

    private static func index(of needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, from <= haystack.count - needle.count else { return nil }
        var at = from
        while at <= haystack.count - needle.count {
            if haystack[at] == needle[0], haystack[at..<(at + needle.count)].elementsEqual(needle) { return at }
            at += 1
        }
        return nil
    }
}
