import Foundation
import KWWKAI

/// Regenerates KWWK's bundled Cursor model catalog by calling Cursor's
/// `GetUsableModels` RPC with a real account token. This is a development-time
/// tool — the runtime never syncs models and only reads the bundled JSON.
///
/// Usage:
///
///   swift run kwwk-generate-cursor-models [output.json]
///
/// Authentication (first match wins):
///   1. CURSOR_ACCESS_TOKEN environment variable
///   2. a `cursor` login in ~/.kwwk/oauth.json (refreshed automatically)
///   3. interactive browser login (persisted to ~/.kwwk/oauth.json)
///
/// By default the output is written to:
///
///   Sources/KWWKAI/Resources/cursor-models.json
///
/// NOTE: when syncing the model catalogs, also regenerate the regular
/// catalog (`swift run kwwk-generate-models …`) — the two bundled files
/// are updated together.
///
@main
struct GenerateCursorModels {
    static let defaultOutputPath = "Sources/KWWKAI/Resources/cursor-models.json"

    static let usage = """
    usage: kwwk-generate-cursor-models [output.json]

    arguments:
      output.json    optional output path; defaults to \(defaultOutputPath)

    auth:
      CURSOR_ACCESS_TOKEN env var, or a `cursor` login in ~/.kwwk/oauth.json;
      with neither present a browser login is started and persisted

    options:
      -h, --help     show this help

    note: also run `swift run kwwk-generate-models …` when syncing — the
    regular catalog (models.json) is regenerated separately.
    """

    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("-h") || arguments.contains("--help") {
            print(usage)
            exit(0)
        }
        guard arguments.count <= 1, !(arguments.first?.hasPrefix("-") ?? false) else {
            FileHandle.standardError.write(Data("unexpected arguments\n\n\(usage)\n".utf8))
            exit(1)
        }
        let outputPath = arguments.first ?? defaultOutputPath

        do {
            let token = try await resolveToken()
            let fetched = try await CursorModelCatalog.fetchUsableModels(apiKey: token)
            let models = withAutoDefault(fetched)
            try write(models, to: outputPath)
            print("generated \(outputPath)")
            print("  models: \(models.count)")
            for model in models {
                let thinking = model.reasoning ? " (reasoning)" : ""
                print("    \(model.id)  \(model.name)\(thinking)")
            }
        } catch {
            FileHandle.standardError.write(Data("kwwk-generate-cursor-models: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func resolveToken() async throws -> String {
        if let token = ProcessInfo.processInfo.environment["CURSOR_ACCESS_TOKEN"], !token.isEmpty {
            return token
        }
        let store = try OAuthStore(url: OAuthStore.defaultURL())
        let manager = OAuthManager(store: store)
        do {
            return try await manager.apiKey(for: "cursor")
        } catch OAuthError.missing {
            return try await interactiveLogin(store: store)
        }
    }

    /// No stored Cursor login: run the browser PKCE flow (same one the kwwk
    /// CLI uses), persist the credentials so future runs skip this, and use
    /// the fresh access token.
    private static func interactiveLogin(store: OAuthStore) async throws -> String {
        stderr("no Cursor login found — starting browser login…")
        let callbacks = OAuthLogin.Callbacks(
            onAuthURL: { url in
                stderr("open in your browser:\n  \(url.absoluteString)")
                openBrowser(url)
            },
            onProgress: { message in stderr(message) }
        )
        let credentials = try await OAuthLogin.loginCursor(callbacks: callbacks)
        try await store.set(credentials, for: "cursor")
        stderr("logged in; credentials saved to \(OAuthStore.defaultURL().path)")
        return credentials.access
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    /// Best-effort URL opener. macOS uses `/usr/bin/open`; Linux tries
    /// `xdg-open`; failures fall back to the URL already printed on stderr.
    private static func openBrowser(_ url: URL) {
        #if os(macOS)
        let opener = "/usr/bin/open"
        #else
        let opener = "/usr/bin/xdg-open"
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opener)
        process.arguments = [url.absoluteString]
        try? process.run()
    }

    /// Cursor's `GetUsableModels` doesn't return the pseudo-model `default`
    /// (server-side Auto routing), but it's the launch default, so pin it at
    /// the top of the generated catalog. Capability flags come from the
    /// curated reference table (Auto is not a reasoning model; it accepts
    /// image input).
    private static func withAutoDefault(_ fetched: [Model]) -> [Model] {
        var models = fetched.filter { $0.id != "default" }
        let auto = CursorModelCatalog.curated["default"]!
        models.insert(Model(
            id: "default",
            name: auto.name,
            api: "cursor-agent",
            provider: "cursor",
            baseURL: "https://\(CursorAgentProvider.defaultBaseHost)",
            reasoning: auto.reasoning,
            input: auto.image ? [.text, .image] : [.text],
            cost: ModelCost(),
            contextWindow: auto.contextWindow,
            maxTokens: auto.maxTokens
        ), at: 0)
        return models
    }

    private static func write(_ models: [Model], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(models)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}
