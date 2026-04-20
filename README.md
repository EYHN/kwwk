# kwwk

A coding-agent CLI written in Swift. Runs an interactive TUI that drives a
coding agent backed by your existing Anthropic, ChatGPT (Codex), Gemini, or
GitHub Copilot subscription.

## Requirements

- macOS 14+
- Swift 6.0 toolchain (Xcode 16 or the matching `swift` toolchain)

## Build

```sh
swift build -c release
```

The binary lands at `.build/release/kwwk`. Copy it onto your `PATH`, e.g.:

```sh
cp .build/release/kwwk /usr/local/bin/
```

## Usage

```
kwwk              launch the interactive coding TUI
kwwk login        log in to an OAuth provider
kwwk --help       show this message
```

Credentials are resolved on launch in this order:

1. OAuth store (`~/.kw/oauth.json`) containing a `openai-codex` entry → ChatGPT Codex
2. `ANTHROPIC_API_KEY` env var → Anthropic

Run `kwwk login` once to register a subscription.

## Layout

- `Sources/KWWKAI` — model clients, OAuth, provider adapters
- `Sources/KWWKAgent` — tool-using agent loop and built-in tools (Bash, Edit, Grep, etc.)
- `Sources/KWWKCli` — interactive TUI, slash commands, rendering
- `Sources/kwwk` — the executable entry point
- `Tests/` — XCTest suites for each module

Run the test suite with:

```sh
swift test
```

## A note on OAuth client IDs

`Sources/KWWKAI/OAuthProviders.swift` reuses the OAuth client IDs (and, for
Google, the client secret) shipped by the upstream first-party CLIs —
Anthropic's Claude Code, OpenAI's Codex CLI, Google's Gemini CLI, and
GitHub Copilot's VS Code extension. Those credentials are not secrets in any
meaningful sense — they are embedded in those open-source CLIs and are
required for the "log in with your existing subscription" flow to work. They
remain the property of their respective vendors, who may rotate or revoke
them at any time. `kwwk` is not affiliated with or endorsed by any of these
vendors.

## License

MIT — see [LICENSE](LICENSE).
