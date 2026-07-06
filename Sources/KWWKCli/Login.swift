import Foundation
import KWWKAI

/// Flow a picked `/login` entry runs. OAuth entries dispatch to the
/// browser-based PKCE flow (TUI suspended for the handoff); `apiKey` entries
/// open an in-session `FormModal` asking for the key (and optionally base
/// URL / default model), persisted to the same `OAuthStore` under a sentinel
/// credentials shape (`refresh=""`, `expires=Int64.max`).
enum LoginFlow {
    case oauth
    case apiKey(fields: [APIKeyFormField], extrasKeys: [String])
}

struct LoginEntry {
    let id: String
    let display: String
    let flow: LoginFlow
}

/// Providers shown in the `/login` picker. Order is display order.
let loginProviders: [LoginEntry] = [
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
        id: "openrouter",
        display: "OpenRouter API key (openrouter.ai)",
        flow: .apiKey(
            fields: [
                APIKeyFormField(
                    key: "apiKey",
                    label: "API key",
                    hint: "from openrouter.ai/keys",
                    placeholder: "sk-or-v1-…",
                    required: true
                ),
                APIKeyFormField(
                    key: "defaultModel",
                    label: "Default model id",
                    hint: "(optional)",
                    placeholder: "anthropic/claude-sonnet-5",
                    required: false
                ),
            ],
            extrasKeys: ["defaultModel"]
        )
    ),
    LoginEntry(
        id: "openai-compatible",
        display: "OpenAI-compatible endpoint (vLLM, custom proxies, etc.)",
        flow: .apiKey(
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

/// Human title for an API-key entry's `FormModal`, from the entry's
/// `ProviderDescriptor.formTitle`. Falls back to the raw entry id for any
/// future entry without a nicer name.
func loginFormTitle(for entry: LoginEntry) -> String {
    "Log in — " + (providerDescriptor(forStoreId: entry.id)?.formTitle ?? entry.id)
}

// MARK: - Terminal login callbacks

/// The CLI's interactive implementation of `OAuthLogin.Callbacks`: progress
/// to stderr, auth URL printed and handed to the system browser. The SDK no
/// longer bakes these in (it must not print or spawn a browser on its own),
/// so the terminal behavior lives here.
func terminalLoginCallbacks() -> OAuthLogin.Callbacks {
    OAuthLogin.Callbacks(
        onAuthURL: { url in
            FileHandle.standardError.write(Data("open in your browser:\n  \(url.absoluteString)\n".utf8))
            Browser.open(url)
        },
        onProgress: { msg in
            FileHandle.standardError.write(Data("\(msg)\n".utf8))
        }
    )
}

/// Best-effort URL opener. macOS uses `/usr/bin/open`; Linux tries
/// `xdg-open`, else falls back to stderr so the user can click manually.
enum Browser {
    static func open(_ url: URL) {
        #if os(macOS)
        let opener = "/usr/bin/open"
        #else
        let opener = "/usr/bin/xdg-open"
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: opener)
        process.arguments = [url.absoluteString]
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data(
                "please open manually:\n  \(url.absoluteString)\n".utf8
            ))
        }
    }
}

// MARK: - OAuth flow (TUI suspended)

/// Browser-based OAuth login for `providerId`. Runs with the coding TUI
/// suspended (cooked terminal): the handoff prints progress to stderr and a
/// cbreak stdin watcher makes Esc / Ctrl-C cancel the flow. Persists the
/// credentials (with a stdout confirmation — the terminal is ours here) and,
/// for Copilot, runs the one-shot model policy enable.
func runOAuthFlow(providerId: String) async throws {
    // Clear a line so the OAuth progress logs start fresh below the TUI.
    FileHandle.standardError.write(Data("starting \(providerId) login…  (Esc/Ctrl-C to cancel)\n".utf8))

    let callbacks = terminalLoginCallbacks()
    let flow = Task {
        switch providerId {
        case "anthropic":
            return try await OAuthLogin.loginAnthropic(callbacks: callbacks)
        case "openai-codex":
            return try await OAuthLogin.loginOpenAICodex(callbacks: callbacks)
        case "github-copilot":
            return try await OAuthLogin.loginGitHubCopilot(callbacks: callbacks)
        default:
            throw LoginError.unknownProvider(providerId)
        }
    }
    // While the browser handoff / device-code poll runs there is no TUI and
    // SIGINT is still ignored (the suspended coding TUI's runner set SIG_IGN
    // and only paused its own dispatch source), so without this watcher the
    // flow is un-cancellable. cbreak stdin delivers Esc as 0x1B and Ctrl-C as
    // 0x03; either cancels the login task, which unblocks the callback
    // server / device poll with a `CancellationError`.
    let watcher = try? RawStdin(cbreak: true) { data in
        if data.contains(0x1B) || data.contains(0x03) {
            flow.cancel()
        }
    }
    // Keep the watcher (and its termios override) alive until the flow
    // resolves; deinit at scope exit restores cooked mode before the main
    // TUI resumes and installs its own raw stdin.
    defer { _ = watcher }

    let credentials: OAuthCredentials
    do {
        credentials = try await flow.value
    } catch is CancellationError {
        throw LoginError.cancelled
    } catch let error as LoginError {
        throw error
    } catch {
        throw LoginError.oauthFailed(error.localizedDescription)
    }

    try await persistCredentials(credentials, providerId: providerId)

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
    let store: OAuthStore
    do {
        store = try OAuthStore(url: OAuthStore.defaultURL())
    } catch {
        print(Style.dimmed("  (skipped model policy enable: \(error.localizedDescription))"))
        return
    }
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

// MARK: - Credential persistence

/// Pack API-key form values into the sentinel `OAuthCredentials` shape
/// (access = api key, refresh = "" , expires = Int64.max "never"), lifting
/// each non-empty `extrasKeys` value into `extras`. Returns nil when the
/// required `apiKey` value is missing/empty.
func apiKeyCredentials(values: [String: String], extrasKeys: [String]) -> OAuthCredentials? {
    guard let apiKey = values["apiKey"], !apiKey.isEmpty else { return nil }
    var extras: [String: JSONValue] = [:]
    for key in extrasKeys {
        if let v = values[key], !v.isEmpty {
            extras[key] = .string(v)
        }
    }
    return OAuthCredentials(access: apiKey, refresh: "", expires: .max, extras: extras)
}

/// What `saveCredentials` wrote, for the caller to present: the store path
/// and the other providers still logged in alongside the new one.
struct SavedLogin {
    let path: String
    let otherProviderIds: [String]
}

/// Save `credentials` under `providerId`, **keeping** any other providers
/// already in the store (additive multi-login). Logging into the same
/// provider again overwrites just that entry (re-auth / token refresh).
/// Pure persistence — no terminal output. The suspended OAuth path presents
/// the result on stdout (`persistCredentials`); the in-session API-key modal
/// path surfaces the same info via `ctx.notify` so nothing prints while the
/// TUI is live.
@discardableResult
func saveCredentials(
    _ credentials: OAuthCredentials,
    providerId: String,
    store: OAuthStore
) async throws -> SavedLogin {
    let others = await store.all().keys.filter { $0 != providerId }.sorted()
    try await store.set(credentials, for: providerId)
    return SavedLogin(path: await store.url.path, otherProviderIds: others)
}

/// OAuth-path persistence: save to the default store and print a
/// confirmation. Only called while the TUI is suspended (cooked terminal),
/// so stdout is safe here.
private func persistCredentials(
    _ credentials: OAuthCredentials,
    providerId: String
) async throws {
    let saved = try await saveCredentials(
        credentials,
        providerId: providerId,
        store: try OAuthStore(url: OAuthStore.defaultURL())
    )
    print("")
    print(Style.prompt("✓ saved \(providerId) credentials"))
    print(Style.dimmed("  → \(saved.path)"))
    if !saved.otherProviderIds.isEmpty {
        print(Style.dimmed("  (also logged in: \(saved.otherProviderIds.joined(separator: ", ")) — switch with /model or /login)"))
    }
}
