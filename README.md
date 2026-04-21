# kwwk

A Swift-native coding agent with two faces:

- **`kwwk`** — an interactive coding CLI (TUI) that drives your existing
  Anthropic, ChatGPT (Codex), Gemini, or GitHub Copilot subscription.
- **`KWWKAgent` / `KWWKAI`** — the agent runtime underneath, exposed as
  SwiftPM libraries so you can embed it in your own app, build custom
  tools, or swap the LLM provider.

## Requirements

- macOS 14+
- Swift 6.0 toolchain (Xcode 16 or the matching `swift` toolchain)

---

## 1. The coding CLI

### Install

From Homebrew (recommended):

```sh
brew install EYHN/tap/kwwk
```

Or build from source:

```sh
swift build -c release
cp .build/release/kwwk /usr/local/bin/
```

### Run

```
kwwk              launch the interactive coding TUI
kwwk login        log in to an OAuth provider
kwwk --help       show this message
```

Credentials come from the OAuth store at `~/.kwwk/oauth.json` — run
`kwwk login` once to register a provider (OAuth subscription like
ChatGPT Codex, Gemini, Copilot, or Claude Code; or an API key for
Anthropic, OpenAI, Google, or any OpenAI-compatible endpoint).

Inside the TUI, `/help` lists slash commands (`/model`, `/thinking`,
`/clear`, …). The agent ships with Bash, Read, Write, Edit, Grep, Find,
LS, tmux, and background-task tools out of the box.

---

## 2. The agent SDK

Add `kwwk` as a SwiftPM dependency:

```swift
.package(url: "https://github.com/EYHN/kwwk", branch: "main"),
```

Then depend on the libraries you need:

```swift
.product(name: "KWWKAgent", package: "kwwk"),
.product(name: "KWWKAI",    package: "kwwk"),
```

- **`KWWKAI`** — model clients, provider registry, streaming, OAuth,
  message / tool types.
- **`KWWKAgent`** — the turn/tool loop, built-in coding tools, hooks.

### Quick start — one-shot run

`Agent.runOnce` mirrors `query()` in the Python Agent SDK: a fresh agent
runs a single prompt and yields every event as an async stream.

```swift
import KWWKAI
import KWWKAgent

// 1. Register a provider using an API key.
await registerBuiltins(anthropic: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])

// 2. Build a coding agent scoped to a working directory.
let agent = await makeCodingAgent(CodingAgentConfig(
    model: Models.claudeSonnet45,
    cwd: FileManager.default.currentDirectoryPath,
    tools: .all
))

// 3. Drive it.
try await agent.prompt("Summarize the Swift files under Sources/KWWKAgent.")

// 4. Read the transcript.
for message in agent.state.messages {
    print(message)
}
```

### Streaming events

Subscribe before prompting to observe tokens, tool calls, and the final
summary as they happen:

```swift
let unsubscribe = agent.subscribe { event, _ in
    switch event {
    case .messageUpdate(let assistant, _):
        // Live-render streaming assistant tokens.
        print(assistant.textPreview, terminator: "")
    case .toolExecutionStart(_, let name, let args):
        print("→ \(name) \(args)")
    case .agentEnd(_, let summary):
        print("\n[\(summary.turns) turns · $\(summary.cost.total)]")
    default: break
    }
}
defer { unsubscribe() }

try await agent.prompt("Find all TODOs in this repo.")
```

Or consume `runOnce` as an `AsyncThrowingStream`:

```swift
for try await event in Agent.runOnce(
    prompt: "what's in README.md?",
    options: AgentOptions(initialState: AgentInitialState(
        model: Models.claudeHaiku45,
        tools: [createReadTool(cwd: ".")]
    ))
) {
    if case .messageEnd(let message) = event { print(message) }
}
```

### Custom tools

A tool is a name, a JSON-Schema parameter spec, and an async `execute`
closure. The agent handles validation, cancellation, and wiring the
result back into the transcript.

```swift
import KWWKAI
import KWWKAgent

let weather = AgentTool(
    name: "get_weather",
    label: "weather",
    description: "Look up the current temperature for a city.",
    parameters: [
        "type": "object",
        "properties": [
            "city": ["type": "string", "description": "City name"]
        ],
        "required": ["city"]
    ],
    execute: { _, args, _, _ in
        guard case .object(let obj) = args,
              case .string(let city) = obj["city"] ?? .null else {
            throw CodingToolError.invalidArgument("city required")
        }
        let temp = try await fetchTemp(city)
        return AgentToolResult(content: [.text(.init(text: "\(temp)°C in \(city)"))])
    }
)

let agent = Agent(initialState: AgentInitialState(
    model: Models.claudeSonnet45,
    tools: [weather]
))
try await agent.prompt("Is it warmer in Tokyo or Oslo right now?")
```

### Hooks — audit, redact, short-circuit

Every `AgentOptions` accepts hooks that fire at well-defined points. Use
them to enforce policy without forking the loop:

```swift
let options = AgentOptions(
    initialState: AgentInitialState(model: Models.claudeSonnet45, tools: [...]),
    // Block or rewrite a tool call before it runs.
    beforeToolCall: { ctx, _ in
        if ctx.toolCall.name == "bash",
           case .object(let o) = ctx.args,
           case .string(let cmd) = o["command"] ?? .null,
           cmd.contains("rm -rf") {
            return BeforeToolCallResult(block: true, reason: "destructive command blocked")
        }
        return nil
    },
    // Intercept a user prompt before it enters the transcript.
    userPromptSubmit: { ctx, _ in
        // e.g. redact secrets, inject policy preamble.
        return nil
    }
)
let agent = Agent(options: options)
```

Other hook points: `afterToolCall`, `convertToLlm`, `transformContext`
(for context pruning / summarization).

### Steering a running agent

Queue a message that will be injected at the next turn boundary —
without aborting the current turn:

```swift
Task {
    try await agent.prompt("refactor this module end-to-end")
}

// later, from any thread:
agent.steer(UserMessage(text: "also add tests as you go"))
```

### Providers

`registerBuiltins` covers Anthropic, OpenAI (Completions + Responses),
and Google Gemini. `Models` exposes a small curated catalog
(`claudeSonnet45`, `gpt5`, `gemini25Pro`, …) or you can construct
`Model` values by hand. For OpenAI-compatible endpoints (xAI, Groq,
OpenRouter) there are `Models.xaiGrok(id:)`, `Models.groq(id:)`,
`Models.openRouter(id:)` helpers.

To use a subscription (OAuth) token instead of a raw API key, drive the
flow via `KWWKAI.OAuth` / `OAuthLogin` — the same code path the CLI's
`kwwk login` command uses.

---

## Layout

- `Sources/KWWKAI` — model clients, OAuth, provider adapters
- `Sources/KWWKAgent` — tool-using agent loop and built-in tools
- `Sources/KWWKCli` — interactive TUI, slash commands, rendering
- `Sources/kwwk` — the executable entry point
- `Tests/` — XCTest suites for each module

```sh
swift test
```

## A note on OAuth client IDs

`Sources/KWWKAI/OAuthProviders.swift` reuses the OAuth client IDs (and,
for Google, the client secret) shipped by the upstream first-party CLIs
— Anthropic's Claude Code, OpenAI's Codex CLI, Google's Gemini CLI, and
GitHub Copilot's VS Code extension. Those credentials are not secrets
in any meaningful sense — they are embedded in those open-source CLIs
and are required for the "log in with your existing subscription" flow
to work. They remain the property of their respective vendors, who may
rotate or revoke them at any time. `kwwk` is not affiliated with or
endorsed by any of these vendors.

## License

MIT — see [LICENSE](LICENSE).
