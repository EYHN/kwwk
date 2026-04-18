import Foundation
import KWAI

/// `kw-login <provider>` — drive the OAuth login flow for one of the
/// supported providers, persist the credentials in `~/.kw/oauth.json`, and
/// print a one-line summary.
///
/// Providers: `anthropic`, `openai-codex`, `google-gemini-cli`, `github-copilot`.
@main
struct LoginCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let provider = args.first else {
            usage()
            exit(1)
        }

        do {
            let credentials: OAuthCredentials
            switch provider {
            case "anthropic":
                credentials = try await OAuthLogin.loginAnthropic()
            case "openai-codex":
                credentials = try await OAuthLogin.loginOpenAICodex()
            case "google-gemini-cli":
                credentials = try await OAuthLogin.loginGeminiCLI()
            case "github-copilot":
                credentials = try await OAuthLogin.loginGitHubCopilot()
            default:
                usage()
                exit(1)
            }
            let store = OAuthStore()
            try await store.set(credentials, for: provider)
            let storedAt = await store.url.path
            print("✓ saved \(provider) credentials → \(storedAt)")
        } catch {
            FileHandle.standardError.write(Data(
                "login failed: \(error)\n".utf8
            ))
            exit(2)
        }
    }

    static func usage() {
        let message = """
        usage: kw-login <provider>

        providers:
          anthropic          Claude Pro / Max OAuth
          openai-codex       ChatGPT Plus / Pro Codex subscription
          google-gemini-cli  Gemini CLI (Google Cloud Code Assist)
          github-copilot     GitHub Copilot (device-flow)
        """
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
