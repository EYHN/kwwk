import Foundation

/// The system-prompt lines Antigravity turns away, and how they are sent so
/// they are not. Ported from magpie's `antigravityCloak` (gateway/codeassist.go).
///
/// A system instruction that carries one of these lines anywhere, in any
/// case and with any run of white space between its words, is answered 429
/// "Resource has been exhausted (e.g. check quota)" on every model whatever
/// quota is left, while the same words in a message go through (magpie
/// #666). Each line goes reworded with the same meaning (`said`). Until
/// 11-14 they went broken up by zero-width spaces, which Google let through;
/// since then its check reads past invisible characters: every line here,
/// broken up by U+200B or U+2060, was turned away 5 of 5 on a real account,
/// and Claude Desktop's Code tab got nothing but the refusal, while each
/// rewording went through (magpie b325718). A mention of the Claude Agent
/// SDK elsewhere ("running within the Claude Agent SDK") goes as written.
enum AntigravityCloak {
    /// The lines, lower-cased, words separated by single spaces, each tried
    /// on a real account:
    ///   - Claude Code's billing line and the Claude Agent SDK's identity
    ///     line (Claude Desktop's chats);
    ///   - the identity lines of Codex's own prompts for its GPT-5 models;
    ///   - Hermes Agent's earlier default persona;
    ///   - the line oh-my-pi (omp) starts its system prompt with.
    static let turnedAwayLines = [
        billingLine,
        "built on anthropic's claude agent sdk",
        "you are codex, an agent based on gpt-5",
        "you are codex, a coding agent based on gpt-5",
        "hermes agent, an intelligent ai assistant created by nous research",
        rfcLine,
    ]

    /// Claude Code's billing line, as `turnedAwayLines` has it.
    static let billingLine = "x-anthropic-billing-header:"

    /// The line oh-my-pi (omp) 18.20.0 starts its system prompt with, and
    /// its advisor's and live mode's, which Antigravity turns away as it does
    /// the others (omp on an Antigravity account got the 429; magpie
    /// 0b64846).
    static let rfcLine = "rfc 2119 keywords: must, required, should, recommended, may, optional."

    /// A run of white space as Google's check reads it: JavaScript's `\s`
    /// (tab, LF, VT, FF, CR, every Zs space such as NBSP, U+2028, U+2029,
    /// U+FEFF). On a real account omp's line was turned away just as well
    /// wrapped with LF or CRLF, indented, with a tab, two spaces or a
    /// no-break space between two of its words.
    private static let space = #"[\x{0009}-\x{000D}\p{Zs}\x{2028}\x{2029}\x{FEFF}]+"#

    /// The characters Google's check reads past since 11-14 (soft hyphen,
    /// Mongolian vowel separator, U+200B–U+200F, U+2060–U+2064, U+FEFF): a
    /// line broken up by them is turned away as the line itself (magpie
    /// `agInvisible`).
    private static let invisible = #"[\x{00AD}\x{180E}\x{200B}-\x{200F}\x{2060}-\x{2064}\x{FEFF}]"#

    private static let invisibleExpression = try! NSRegularExpression(pattern: invisible)

    /// `line` matched in any case, with any run of white space between its
    /// words and any invisible characters inside them, so a copy someone
    /// broke up (an older cloak, magpie's or kwwk's) is found as the line.
    /// Claude Code's billing line is matched to the end of its line, since it
    /// goes whole (magpie `agLineRe`).
    private static func lineExpression(_ line: String) -> NSRegularExpression {
        let words = line.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word.unicodeScalars
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: invisible + "*")
        }
        var pattern = words.joined(separator: invisible + "*" + space + invisible + "*")
        if line == billingLine {
            pattern += #"[^\n]*\n?"#
        }
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// `turnedAwayLines` as `lineExpression` matches them, in the same order.
    static let lineExpressions = turnedAwayLines.map(lineExpression)

    private static let sdkSaidAs = try! NSRegularExpression(
        pattern: "^(built" + space + "on" + space + ")anthropic's(" + space + ")(claude" + space + "agent" + space + "sdk)$",
        options: [.caseInsensitive])
    private static let basedOn = try! NSRegularExpression(pattern: "based(" + space + ")on", options: [.caseInsensitive])
    private static let createdBy = try! NSRegularExpression(pattern: "created(" + space + ")by", options: [.caseInsensitive])
    private static let rfcSaidAs = try! NSRegularExpression(pattern: "(key)(words)", options: [.caseInsensitive])

    /// How each line of `turnedAwayLines` goes, in the same order, given the
    /// line as it was matched with its invisible characters taken out and
    /// its white space as it was (magpie `agSaidAs`):
    ///   - Claude Code's billing line not at all, to the end of its line: it
    ///     is Anthropic's, and no Antigravity model reads anything in it;
    ///   - the Agent SDK's "built on Anthropic's Claude Agent SDK" as "built
    ///     on the Claude Agent SDK by Anthropic";
    ///   - Codex's "based on GPT-5" as "built on GPT-5";
    ///   - Hermes' "created by Nous Research" as "built by Nous Research", as
    ///     Hermes' current persona says it;
    ///   - omp's "keywords" as "key words", RFC 2119's own term.
    private static func said(_ line: Int, _ matched: String) -> String {
        switch line {
        case 0: return ""
        case 1: return replace(sdkSaidAs, in: matched, with: "$1the$2$3 by Anthropic")
        case 2, 3: return replace(basedOn, in: matched, with: "built$1on")
        case 4: return replace(createdBy, in: matched, with: "built$1by")
        default: return replace(rfcSaidAs, in: matched, with: "$1 $2")
        }
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// Whether `system` carries `line`, one of `turnedAwayLines`.
    private static func says(_ system: String, _ line: String) -> Bool {
        guard let at = turnedAwayLines.firstIndex(of: line) else { return false }
        return matches(lineExpressions[at], in: system)
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Whether `system` carries a line Antigravity turns away, broken up by
    /// invisible characters or not.
    static func turnsAway(_ system: String) -> Bool {
        lineExpressions.contains { matches($0, in: system) }
    }

    /// `system` with each line Antigravity turns away said as `said` says,
    /// wherever, in whatever case and with whatever white space it is,
    /// broken up by invisible characters or not, and every other character as
    /// the caller wrote it. A prompt holding only Claude Code's billing line
    /// comes back empty, and goes with no system instruction.
    static func cloak(_ system: String) -> String {
        guard turnsAway(system) else { return system }
        let text = system as NSString
        var found: [(range: NSRange, line: Int)] = []
        for (line, expression) in lineExpressions.enumerated() {
            for match in expression.matches(in: system, range: NSRange(location: 0, length: text.length)) {
                found.append((match.range, line))
            }
        }
        found.sort { $0.range.location < $1.range.location }
        var out = ""
        var previous = 0
        for (range, line) in found where range.location >= previous {
            out += text.substring(with: NSRange(location: previous, length: range.location - previous))
            out += said(line, replace(invisibleExpression, in: text.substring(with: range), with: ""))
            previous = range.location + range.length
        }
        out += text.substring(from: previous)
        return out
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
