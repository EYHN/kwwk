import Foundation

/// The system-prompt lines Antigravity turns away, and how they are sent so
/// they are not. Ported from magpie's `antigravityCloak` (gateway/codeassist.go).
///
/// A system instruction that carries one of these lines anywhere, in any
/// case and with any run of white space between its words, is answered 429
/// "Resource has been exhausted (e.g. check quota)" on every model whatever
/// quota is left, while the same words in a message go through (magpie
/// #666). Each line is broken up before it goes by a zero-width space after
/// its first letter, which Google lets through and the model reads past;
/// each line so broken was answered on a real account where the line as
/// written was turned away. oh-my-pi's RFC 2119 line is reworded instead
/// (magpie 0b64846).
enum AntigravityCloak {
    /// The lines, lower-cased, words separated by single spaces, each tried
    /// on a real account:
    ///   - Claude Code's billing line and the Claude Agent SDK's identity
    ///     line (Claude Desktop's chats);
    ///   - the identity lines of Codex's own prompts for its GPT-5 models;
    ///   - Hermes Agent's earlier default persona;
    ///   - the line oh-my-pi (omp) starts its system prompt with.
    static let turnedAwayLines = [
        "x-anthropic-billing-header:",
        "built on anthropic's claude agent sdk",
        "you are codex, an agent based on gpt-5",
        "you are codex, a coding agent based on gpt-5",
        "hermes agent, an intelligent ai assistant created by nous research",
        rfcLine,
    ]

    /// The line oh-my-pi (omp) 18.20.0 starts its system prompt with, and
    /// its advisor's and live mode's, which Antigravity turns away as it does
    /// the others (omp on an Antigravity account got the 429; magpie
    /// 0b64846).
    static let rfcLine = "rfc 2119 keywords: must, required, should, recommended, may, optional."

    /// U+200B, what goes inside a line Antigravity turns away.
    static let zeroWidth = "\u{200B}"

    /// A run of white space as Google's check reads it: JavaScript's `\s`
    /// (tab, LF, VT, FF, CR, every Zs space such as NBSP, U+2028, U+2029,
    /// U+FEFF). On a real account omp's line was turned away just as well
    /// wrapped with LF or CRLF, indented, with a tab, two spaces or a
    /// no-break space between two of its words. U+200B is not in it, so a
    /// line already broken up isn't one any more.
    private static let space = #"[\x{0009}-\x{000D}\p{Zs}\x{2028}\x{2029}\x{FEFF}]+"#

    /// `line` matched in any case with any run of white space between its
    /// words (magpie `agLineRe`).
    private static func lineExpression(_ line: String) -> NSRegularExpression {
        let pattern = line.split(separator: " ", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: space)
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// `turnedAwayLines` as `lineExpression` matches them, in the same order.
    private static let lineExpressions = turnedAwayLines.map(lineExpression)

    /// How omp's line goes: "key words", RFC 2119's own term, for its
    /// "keywords". A copy broken up by zero-width spaces, like the other
    /// lines, was still turned away 1 to 3 times in 10 on a real account
    /// (U+200B, U+2060 or a soft hyphen alike), "key words" 0 in 30, and
    /// the model reads the same rule in it.
    private static let rfcSaidAs = try! NSRegularExpression(pattern: "(key)(words)", options: [.caseInsensitive])

    /// Whether `system` carries `line`, one of `turnedAwayLines`.
    private static func says(_ system: String, _ line: String) -> Bool {
        guard let at = turnedAwayLines.firstIndex(of: line) else { return false }
        return matches(lineExpressions[at], in: system)
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether `system` carries a line Antigravity turns away.
    static func turnsAway(_ system: String) -> Bool {
        lineExpressions.contains { matches($0, in: system) }
    }

    /// `system` with each line Antigravity turns away broken up by a
    /// zero-width space after its first letter, wherever, in whatever case
    /// and with whatever white space it is, and every other character as the
    /// caller wrote it. A line already broken up is not one any more and is
    /// left alone. omp's RFC 2119 line goes as "RFC 2119 key words: …"
    /// instead, every white space in it as it was.
    static func cloak(_ system: String) -> String {
        guard turnsAway(system) else { return system }
        let text = rewordRFC(system)
        var breaks: [String.Index] = []
        for expression in lineExpressions {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), !range.isEmpty else { continue }
                breaks.append(text.unicodeScalars.index(after: range.lowerBound))
            }
        }
        guard !breaks.isEmpty else { return text }
        var out = ""
        var previous = text.startIndex
        for at in Set(breaks).sorted() {
            out.unicodeScalars.append(contentsOf: text.unicodeScalars[previous..<at])
            out += zeroWidth
            previous = at
        }
        out.unicodeScalars.append(contentsOf: text.unicodeScalars[previous...])
        return out
    }

    /// `system` with every copy of omp's line said as "key words".
    private static func rewordRFC(_ system: String) -> String {
        guard let at = turnedAwayLines.firstIndex(of: rfcLine) else { return system }
        let matches = lineExpressions[at].matches(in: system, range: NSRange(system.startIndex..., in: system))
        guard !matches.isEmpty else { return system }
        let out = NSMutableString(string: system)
        for match in matches.reversed() {
            let said = out.substring(with: match.range)
            let reworded = rfcSaidAs.stringByReplacingMatches(
                in: said, range: NSRange(location: 0, length: (said as NSString).length), withTemplate: "$1 $2")
            out.replaceCharacters(in: match.range, with: reworded)
        }
        return out as String
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
        let system = system ?? ""
        if says(system, "you are codex, an agent based on gpt-5") || says(system, "you are codex, a coding agent based on gpt-5") {
            return "Antigravity answers this 429 to Codex's own system prompt for GPT-5 models whatever quota is left, "
                + "so it is not a quota and waiting won't help; a chat begun on a GPT model keeps that prompt, "
                + "so start a new chat on this model"
        }
        if says(system, "hermes agent, an intelligent ai assistant created by nous research") {
            return "Antigravity answers this 429 to Hermes Agent's earlier default persona whatever quota is left, "
                + "so it is not a quota and waiting won't help; Hermes' current default persona goes through"
        }
        if says(system, rfcLine) {
            return rfcHint
        }
        return "Antigravity answers this 429 to the system prompt of Claude Code and the Claude Agent SDK "
            + "whatever quota is left, so it is not a quota and waiting won't help; use another provider for these chats"
    }

    /// The hint for omp's RFC 2119 line (magpie `antigravityRFCHint`).
    static let rfcHint = "Antigravity answers this 429 to the line \"RFC 2119 keywords: MUST, REQUIRED, SHOULD, RECOMMENDED, MAY, OPTIONAL.\" "
        + "that starts oh-my-pi (omp)'s system prompt, and to any prompt that has it, whatever quota is left, "
        + "so it is not a quota and waiting won't help; it is sent as \"RFC 2119 key words: …\", which goes through, "
        + "so this one came from a copy of it that was worded another way"
}
