import Foundation
import KWWKAI

/// Flow the login selector should run after the user picks an entry. OAuth
/// entries dispatch to the browser-based PKCE flow; `apiKey` entries drop
/// into a small TUI form asking for the key (and optionally base URL /
/// default model), persisted to the same `OAuthStore` under a sentinel
/// credentials shape (`refresh=""`, `expires=Int64.max`).
private enum LoginFlow {
    case oauth
    case apiKey(storeId: String, fields: [APIKeyFormField], extrasKeys: [String])
}

private struct LoginEntry {
    let id: String
    let display: String
    let flow: LoginFlow
}

/// Providers shown in the `kwwk login` selector. Order is display order.
private let loginProviders: [LoginEntry] = [
    LoginEntry(
        id: "openai-codex",
        display: "ChatGPT Codex (OpenAI Plus/Pro subscription)",
        flow: .oauth
    ),
    LoginEntry(
        id: "anthropic",
        display: "Anthropic OAuth (Claude Pro/Max)",
        flow: .oauth
    ),
    LoginEntry(
        id: "github-copilot",
        display: "GitHub Copilot",
        flow: .oauth
    ),
    LoginEntry(
        id: "anthropic-api-key",
        display: "Anthropic API key (api.anthropic.com)",
        flow: .apiKey(
            storeId: "anthropic-api-key",
            fields: [
                APIKeyFormField(
                    key: "apiKey",
                    label: "API key",
                    hint: "sk-ant-…",
                    placeholder: "sk-ant-api03-…",
                    required: true
                ),
                APIKeyFormField(
                    key: "baseUrl",
                    label: "Base URL",
                    hint: "(optional)",
                    placeholder: "https://api.anthropic.com",
                    default: "https://api.anthropic.com",
                    required: false
                ),
            ],
            extrasKeys: ["baseUrl"]
        )
    ),
    LoginEntry(
        id: "openai-api-key",
        display: "OpenAI API key (api.openai.com)",
        flow: .apiKey(
            storeId: "openai-api-key",
            fields: [
                APIKeyFormField(
                    key: "apiKey",
                    label: "API key",
                    hint: "sk-…",
                    placeholder: "sk-proj-…",
                    required: true
                ),
                APIKeyFormField(
                    key: "baseUrl",
                    label: "Base URL",
                    hint: "(optional)",
                    placeholder: "https://api.openai.com",
                    default: "https://api.openai.com",
                    required: false
                ),
            ],
            extrasKeys: ["baseUrl"]
        )
    ),
    LoginEntry(
        id: "google-api-key",
        display: "Google AI Studio API key (Gemini direct)",
        flow: .apiKey(
            storeId: "google-api-key",
            fields: [
                APIKeyFormField(
                    key: "apiKey",
                    label: "API key",
                    hint: "from aistudio.google.com/apikey",
                    placeholder: "AIza…",
                    required: true
                ),
                APIKeyFormField(
                    key: "baseUrl",
                    label: "Base URL",
                    hint: "(optional)",
                    placeholder: "https://generativelanguage.googleapis.com",
                    default: "https://generativelanguage.googleapis.com",
                    required: false
                ),
            ],
            extrasKeys: ["baseUrl"]
        )
    ),
    LoginEntry(
        id: "openai-compatible",
        display: "OpenAI-compatible endpoint (OpenRouter, vLLM, etc.)",
        flow: .apiKey(
            storeId: "openai-compatible",
            fields: [
                APIKeyFormField(
                    key: "apiKey",
                    label: "API key",
                    hint: "bearer token",
                    required: true
                ),
                APIKeyFormField(
                    key: "baseUrl",
                    label: "Base URL",
                    hint: "e.g. https://openrouter.ai/api",
                    placeholder: "https://…",
                    required: true
                ),
                APIKeyFormField(
                    key: "defaultModel",
                    label: "Default model id",
                    hint: "model to use on startup",
                    placeholder: "e.g. anthropic/claude-sonnet-4.5",
                    required: true
                ),
            ],
            extrasKeys: ["baseUrl", "defaultModel"]
        )
    ),
]

enum LoginError: Error, LocalizedError {
    case cancelled
    case unknownProvider(String)
    case oauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "login cancelled"
        case .unknownProvider(let id): return "unknown provider '\(id)'"
        case .oauthFailed(let msg): return "OAuth flow failed: \(msg)"
        }
    }
}

/// Interactive `kwwk login`:
///   1. Arrow-key selector over the known providers (OAuth + API-key).
///   2. Enter → tear down the TUI and run the chosen entry's flow:
///      OAuth = browser PKCE / device flow; API-key = small TUI form.
///   3. Persist the resulting credentials exclusively — any previously
///      logged-in provider is dropped so `AuthResolver` can't hit ambiguity.
///
/// The TUI is intentionally torn down before the OAuth flow begins so that
/// the browser handoff + stderr progress logs don't fight the raw-mode
/// terminal.
func runLoginInternal() async throws {
    let choice = try await selectProviderTUI()
    try await runLoginFlow(entry: choice)
}

// MARK: - Selector TUI

/// Small arrow-key selector built on top of TUIRunner. Returns the chosen
/// entry, or throws `.cancelled` if the user hits Esc / Ctrl-C.
@MainActor
private func selectProviderTUI() async throws -> LoginEntry {
    let runner = TUIRunner(hideCursor: true)

    let header = TextComponent([
        Style.header("✻ kwwk login"),
        Style.dimmed("  choose a provider to log in"),
        "",
    ])
    let menu = TextComponent([])
    let footer = TextComponent([
        "",
        Style.dimmed("  ↑/↓: move   Enter: select   Esc/Ctrl-C: cancel"),
    ])

    let state = SelectorState(count: loginProviders.count)

    renderSelectorMenu(into: menu, state: state)

    runner.tui.addChild(header)
    runner.tui.addChild(menu)
    runner.tui.addChild(footer)

    runner.bind(.init("up")) { _ in
        Task { @MainActor in
            state.selectedIndex = (state.selectedIndex - 1 + loginProviders.count) % loginProviders.count
            renderSelectorMenu(into: menu, state: state)
            runner.tui.requestRender()
        }
    }
    runner.bind(.init("down")) { _ in
        Task { @MainActor in
            state.selectedIndex = (state.selectedIndex + 1) % loginProviders.count
            renderSelectorMenu(into: menu, state: state)
            runner.tui.requestRender()
        }
    }
    runner.bind(.init("enter")) { _ in
        Task { @MainActor in
            state.submit(state.selectedIndex)
            runner.exit()
        }
    }
    runner.bind(.init("escape")) { _ in
        Task { @MainActor in
            state.cancel()
            runner.exit()
        }
    }
    runner.bind(.ctrl("c")) { _ in
        Task { @MainActor in
            state.cancel()
            runner.exit()
        }
    }

    try await runner.run()

    guard let idx = state.chosen else { throw LoginError.cancelled }
    return loginProviders[idx]
}

/// Mutable state shared between the key handlers and the caller.
@MainActor
private final class SelectorState {
    var selectedIndex: Int = 0
    var chosen: Int?
    let count: Int
    init(count: Int) { self.count = count }
    func submit(_ index: Int) { chosen = index }
    func cancel() { chosen = nil }
}

/// Regenerate the `menu` component's line strings based on the current
/// `state.selectedIndex`. Pulled out as a module-level function (rather than a
/// nested `func` inside `selectProviderTUI`) so the `@Sendable` key-binding
/// closures can invoke it without capturing a non-Sendable function
/// reference.
@MainActor
private func renderSelectorMenu(into menu: TextComponent, state: SelectorState) {
    menu.lines = loginProviders.enumerated().map { i, provider in
        let marker = i == state.selectedIndex ? Style.prompt("  ❯ ") : "    "
        let label  = i == state.selectedIndex ? Style.prompt(provider.display) : provider.display
        return marker + label
    }
    menu.invalidate()
}

// MARK: - Flow dispatch

private func runLoginFlow(entry: LoginEntry) async throws {
    switch entry.flow {
    case .oauth:
        try await runOAuthFlow(providerId: entry.id)
    case .apiKey(let storeId, let fields, let extrasKeys):
        try await runAPIKeyFlow(
            providerId: entry.id,
            storeId: storeId,
            fields: fields,
            extrasKeys: extrasKeys
        )
    }
}

private func runOAuthFlow(providerId: String) async throws {
    // Clear a line so the OAuth progress logs start fresh below the TUI.
    FileHandle.standardError.write(Data("\nstarting \(providerId) login…\n".utf8))

    let credentials: OAuthCredentials
    do {
        switch providerId {
        case "anthropic":
            credentials = try await OAuthLogin.loginAnthropic()
        case "openai-codex":
            credentials = try await OAuthLogin.loginOpenAICodex()
        case "github-copilot":
            credentials = try await OAuthLogin.loginGitHubCopilot()
        default:
            throw LoginError.unknownProvider(providerId)
        }
    } catch {
        throw LoginError.oauthFailed(error.localizedDescription)
    }

    try await persistExclusive(credentials, providerId: providerId)

    // GitHub Copilot post-login: opt the account in on every Copilot model
    // we know about. Claude/Grok/Gemini require this one-shot enable before
    // the chat endpoints will route to them; GPT-family models don't need
    // it but the call is idempotent so we fire for everything. Best-effort:
    // one 403 for an un-entitled model shouldn't abort the whole login.
    if providerId == "github-copilot" {
        await runCopilotPolicyEnable()
    }
}

/// Resolve a fresh Copilot session token and hit `/models/<id>/policy` for
/// every Copilot model in the bundled catalog. Nothing here throws —
/// failures are printed and swallowed. Business/Enterprise accounts
/// store their proxy host under `extras["endpoint"]` (populated by
/// `GitHubCopilotOAuthProvider.refresh`); we prefer that over the
/// Individual default so policy POSTs hit the correct tier.
private func runCopilotPolicyEnable() async {
    let store = OAuthStore(url: OAuthStore.defaultURL())
    let manager = OAuthManager(store: store)
    let sessionToken: String
    do {
        sessionToken = try await manager.apiKey(for: "github-copilot")
    } catch {
        print(Style.dimmed("  (skipped model policy enable: \(error.localizedDescription))"))
        return
    }
    let refreshed = await store.get("github-copilot")
    let baseURL: URL = {
        if case .string(let s) = refreshed?.extras["endpoint"] ?? .null,
           let u = URL(string: s) {
            return u
        }
        return URL(string: "https://api.individual.githubcopilot.com")!
    }()
    let ids = ModelsCatalog.models(for: "github-copilot").map { $0.id }.sorted()
    if ids.isEmpty { return }
    print(Style.dimmed("  enabling Copilot models (\(ids.count))…"))
    let callbacks = OAuthLogin.Callbacks(
        onAuthURL: { _ in },
        onProgress: { line in
            FileHandle.standardError.write(Data((Style.dimmed(line) + "\n").utf8))
        }
    )
    await OAuthLogin.enableCopilotModels(
        sessionToken: sessionToken,
        baseURL: baseURL,
        modelIds: ids,
        callbacks: callbacks
    )
}

/// API-key flow: show a form TUI, pack the result into `OAuthCredentials`
/// (access = api key, refresh = "" sentinel, expires = Int64.max "never"),
/// and persist.
@MainActor
private func runAPIKeyFlow(
    providerId: String,
    storeId: String,
    fields: [APIKeyFormField],
    extrasKeys: [String]
) async throws {
    let title = "kwwk login — " + {
        switch providerId {
        case "anthropic-api-key": return "Anthropic API key"
        case "openai-api-key": return "OpenAI API key"
        case "google-api-key": return "Google AI Studio API key"
        case "openai-compatible": return "OpenAI-compatible endpoint"
        default: return providerId
        }
    }()

    let values = try await runAPIKeyForm(title: title, fields: fields)
    guard let apiKey = values["apiKey"], !apiKey.isEmpty else {
        throw LoginError.oauthFailed("API key required")
    }
    var extras: [String: JSONValue] = [:]
    for key in extrasKeys {
        if let v = values[key], !v.isEmpty {
            extras[key] = .string(v)
        }
    }
    let credentials = OAuthCredentials(
        access: apiKey,
        refresh: "",
        expires: .max,
        extras: extras
    )
    try await persistExclusive(credentials, providerId: storeId)
}

/// Save `credentials` under `providerId` as the only entry in the store,
/// print a confirmation line and list any replaced entries.
private func persistExclusive(
    _ credentials: OAuthCredentials,
    providerId: String
) async throws {
    let store = OAuthStore(url: OAuthStore.defaultURL())
    let previous = await store.all().keys.filter { $0 != providerId }.sorted()
    try await store.setExclusive(credentials, for: providerId)
    let path = await store.url.path
    print("")
    print(Style.prompt("✓ saved \(providerId) credentials"))
    print(Style.dimmed("  → \(path)"))
    if !previous.isEmpty {
        print(Style.dimmed("  (replaced previous credentials: \(previous.joined(separator: ", ")))"))
    }
}
