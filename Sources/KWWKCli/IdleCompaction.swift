import Foundation
import KWWKAgent

/// CLI-side knobs for the agent's idle compaction (`Agent.idleCompact`). Off
/// by default; enabled with `--idle-compact` or `/idle-compact on`.
struct IdleCompactionSettings: Equatable, Sendable {
    static let delayRange = 60...3600
    static let defaultThreshold = AgentIdleCompactThreshold.ratio(0.5)
    static let defaultDelaySeconds = 300

    var enabled: Bool
    var threshold: AgentIdleCompactThreshold
    private(set) var delaySeconds: Int

    init(
        enabled: Bool = false,
        threshold: AgentIdleCompactThreshold = IdleCompactionSettings.defaultThreshold,
        delaySeconds: Int = IdleCompactionSettings.defaultDelaySeconds
    ) {
        self.enabled = enabled
        self.threshold = threshold
        self.delaySeconds = Self.clampDelay(delaySeconds)
    }

    mutating func setDelay(seconds: Int) {
        delaySeconds = Self.clampDelay(seconds)
    }

    static func clampDelay(_ seconds: Int) -> Int {
        min(max(seconds, delayRange.lowerBound), delayRange.upperBound)
    }

    init(_ options: AgentIdleCompactOptions?) {
        self.init(
            enabled: options != nil,
            threshold: options?.threshold ?? Self.defaultThreshold,
            delaySeconds: Int(options?.delay ?? TimeInterval(Self.defaultDelaySeconds))
        )
    }

    /// `canCompact` is the host's veto; it survives retuning unchanged.
    func agentOptions(canCompact: (@Sendable () async -> Bool)?) -> AgentIdleCompactOptions? {
        guard enabled else { return nil }
        return AgentIdleCompactOptions(
            threshold: threshold,
            delay: TimeInterval(delaySeconds),
            canCompact: canCompact
        )
    }

    var summary: String {
        guard enabled else { return "off" }
        let level: String
        switch threshold {
        case .ratio(let ratio): level = "\(Int((ratio * 100).rounded()))% ctx"
        case .tokens(let tokens): level = "\(formatIdleTokens(tokens)) tokens"
        }
        return "on · at \(level) · after \(formatIdleDelay(delaySeconds)) idle"
    }
}

func formatIdleDelay(_ seconds: Int) -> String {
    if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
    if seconds % 60 == 0 { return "\(seconds / 60)m" }
    return "\(seconds)s"
}

/// Parse a delay such as `300`, `90s`, `5m`, or `1h` into seconds.
func parseIdleDelay(_ raw: String) -> Int? {
    let text = raw.lowercased()
    guard let last = text.last else { return nil }
    let multiplier: Int
    let digits: Substring
    switch last {
    case "s": multiplier = 1; digits = text.dropLast()
    case "m": multiplier = 60; digits = text.dropLast()
    case "h": multiplier = 3600; digits = text.dropLast()
    default: multiplier = 1; digits = Substring(text)
    }
    guard let value = Int(digits), value > 0 else { return nil }
    let (seconds, overflow) = value.multipliedReportingOverflow(by: multiplier)
    return overflow ? nil : seconds
}

func formatIdleTokens(_ tokens: Int) -> String {
    tokens % 1000 == 0 ? "\(tokens / 1000)k" : "\(tokens)"
}

/// Parse a threshold: `50%`, `50`, or `0.5` is a window ratio; a `k` suffix
/// (`150k`, `1.5k`) is an absolute token count. Bare numbers of 100 or more
/// are left for the delay parser.
func parseIdleThreshold(_ raw: String) -> AgentIdleCompactThreshold? {
    let text = raw.lowercased()
    if text.hasSuffix("k") {
        guard let value = Double(text.dropLast()), value.isFinite, value > 0,
              value < 1_000_000 else { return nil }
        return .tokens(Int((value * 1000).rounded()))
    }
    let isPercent = text.hasSuffix("%")
    guard let value = Double(isPercent ? String(text.dropLast()) : text), value.isFinite else {
        return nil
    }
    let ratio = (isPercent || value > 1) ? value / 100 : value
    return (ratio > 0 && ratio < 1) ? .ratio(ratio) : nil
}
