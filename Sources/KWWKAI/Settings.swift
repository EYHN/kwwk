import Foundation

/// User/project settings model, ported from pi's `Settings` interface in
/// `coding-agent/src/core/settings-manager.ts`. kwwk loads a global
/// `~/.kwwk/settings.json` and an optional project `./.kwwk/settings.json`,
/// deep-merging the two (project wins) into a single `Settings`.
///
/// Unknown keys are preserved verbatim in `extra` so a forward-compatible
/// config doesn't lose data on round-trips, and so the deep-merge can recurse
/// into nested objects pi knows about but this Swift port hasn't typed yet.
public struct Settings: Sendable, Equatable {
    // MARK: model / provider defaults
    public var defaultProvider: String?
    public var defaultModel: String?
    /// "off" | "minimal" | "low" | "medium" | "high" | "xhigh"
    public var defaultThinkingLevel: ModelThinkingLevel?

    // MARK: presentation
    public var theme: String?
    public var hideThinkingBlock: Bool?
    public var quietStartup: Bool?

    // MARK: telemetry / analytics
    /// pi exposes `enableInstallTelemetry` (default true) and `enableAnalytics`
    /// (default false). We surface a single derived "opted out" view below.
    public var enableInstallTelemetry: Bool?
    public var enableAnalytics: Bool?

    // MARK: enabled-model cycling
    public var enabledModels: [String]?

    /// Any keys not modeled above, kept verbatim for forward-compatibility and
    /// nested deep-merge. Values are arbitrary JSON.
    public var extra: [String: JSONValue]

    public init(
        defaultProvider: String? = nil,
        defaultModel: String? = nil,
        defaultThinkingLevel: ModelThinkingLevel? = nil,
        theme: String? = nil,
        hideThinkingBlock: Bool? = nil,
        quietStartup: Bool? = nil,
        enableInstallTelemetry: Bool? = nil,
        enableAnalytics: Bool? = nil,
        enabledModels: [String]? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.defaultProvider = defaultProvider
        self.defaultModel = defaultModel
        self.defaultThinkingLevel = defaultThinkingLevel
        self.theme = theme
        self.hideThinkingBlock = hideThinkingBlock
        self.quietStartup = quietStartup
        self.enableInstallTelemetry = enableInstallTelemetry
        self.enableAnalytics = enableAnalytics
        self.enabledModels = enabledModels
        self.extra = extra
    }

    /// Empty defaults — every typed key nil, no extras. Used as the base when no
    /// settings file exists on disk.
    public static let empty = Settings()

    // MARK: - Typed getters for common keys

    /// The resolved default model, preferring an explicit `defaultModel`.
    public var resolvedDefaultModel: String? { defaultModel }

    /// The resolved thinking level (`.off` when unset).
    public var resolvedThinkingLevel: ModelThinkingLevel { defaultThinkingLevel ?? .off }

    /// The resolved theme name, or nil to let the app pick its default.
    public var resolvedTheme: String? { theme }

    /// Whether the user has opted out of telemetry. Mirrors pi's defaults:
    /// install telemetry is on unless disabled, analytics is off unless enabled.
    /// "Opted out" means install telemetry is explicitly disabled AND analytics
    /// is not enabled.
    public var telemetryOptOut: Bool {
        let installEnabled = enableInstallTelemetry ?? true
        let analyticsEnabled = enableAnalytics ?? false
        return !installEnabled && !analyticsEnabled
    }
}

// MARK: - Codable

extension Settings: Codable {
    /// We decode into the typed fields we know about and stash everything else
    /// into `extra`, so unknown/nested keys survive.
    private static let knownKeys: Set<String> = [
        "defaultProvider", "defaultModel", "defaultThinkingLevel",
        "theme", "hideThinkingBlock", "quietStartup",
        "enableInstallTelemetry", "enableAnalytics", "enabledModels",
    ]

    public init(from decoder: Decoder) throws {
        // Decode the full object as JSON first, then peel off typed keys. This
        // keeps a single, robust path for the "preserve unknown keys" behavior.
        let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)

        func string(_ key: String) -> String? {
            if case .string(let s) = raw[key] { return s } else { return nil }
        }
        func bool(_ key: String) -> Bool? {
            if case .bool(let b) = raw[key] { return b } else { return nil }
        }
        func stringArray(_ key: String) -> [String]? {
            guard case .array(let items) = raw[key] else { return nil }
            return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }

        self.defaultProvider = string("defaultProvider")
        self.defaultModel = string("defaultModel")
        self.defaultThinkingLevel = string("defaultThinkingLevel").flatMap(ModelThinkingLevel.init(rawValue:))
        self.theme = string("theme")
        self.hideThinkingBlock = bool("hideThinkingBlock")
        self.quietStartup = bool("quietStartup")
        self.enableInstallTelemetry = bool("enableInstallTelemetry")
        self.enableAnalytics = bool("enableAnalytics")
        self.enabledModels = stringArray("enabledModels")

        var extra: [String: JSONValue] = [:]
        for (key, value) in raw where !Settings.knownKeys.contains(key) {
            extra[key] = value
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        if let v = defaultProvider { object["defaultProvider"] = .string(v) }
        if let v = defaultModel { object["defaultModel"] = .string(v) }
        if let v = defaultThinkingLevel { object["defaultThinkingLevel"] = .string(v.rawValue) }
        if let v = theme { object["theme"] = .string(v) }
        if let v = hideThinkingBlock { object["hideThinkingBlock"] = .bool(v) }
        if let v = quietStartup { object["quietStartup"] = .bool(v) }
        if let v = enableInstallTelemetry { object["enableInstallTelemetry"] = .bool(v) }
        if let v = enableAnalytics { object["enableAnalytics"] = .bool(v) }
        if let v = enabledModels { object["enabledModels"] = .array(v.map(JSONValue.string)) }

        var container = encoder.singleValueContainer()
        try container.encode(object)
    }
}
