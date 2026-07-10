# kwwk

A Swift-native coding agent with two faces:

- **`kwwk`** — an interactive coding CLI (TUI) that drives your existing
  Anthropic, ChatGPT (Codex), or GitHub Copilot subscription — or an API
  key for Anthropic, OpenAI, Google (Gemini), OpenRouter, or any
  OpenAI-compatible endpoint.
- **`KWWKAgent` / `KWWKAI`** — the agent runtime underneath, exposed as
  SwiftPM libraries so you can embed it in your own app, build custom
  tools, or swap the LLM provider.

## Requirements

- macOS 14+
- Swift 6.1 toolchain (Xcode 16.3+ or the matching `swift` toolchain)

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
kwwk --help       show this message
```

Credentials come from the OAuth store at `~/.kwwk/oauth.json`; if no login
exists, the CLI checks supported API-key environment variables. With
neither configured, kwwk starts logged out — launch it and run `/login`
to sign in to a provider (OAuth subscription like ChatGPT Codex, Copilot,
or Claude Code; or an API key for Anthropic, OpenAI, Google (Gemini),
OpenRouter, or any OpenAI-compatible endpoint).

Inside the TUI, `/help` lists slash commands (`/model`, `/thinking`,
`/clear`, …). The agent ships with Bash, Read, Write, Edit, Grep, Find,
LS, and background-task tools out of the box.

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

The SDK does not read `~/.kwwk` or process environment variables by
default. Pass credentials, session stores, context files, and skill
directories explicitly. The `kwwk` binary is the layer that opts into
`~/.kwwk/*` and environment-key discovery.

### Quick start — one-shot run

`Agent.runOnce` mirrors `query()` in the Python Agent SDK: a fresh agent
runs a single prompt and yields every event as an async stream.

```swift
import KWWKAI
import KWWKAgent

// 1. Register a provider using an API key.
let anthropicAPIKey = "sk-ant-..."
await registerBuiltins(anthropic: anthropicAPIKey)

// 2. Build a coding agent scoped to a working directory.
let agent = await makeCodingAgent(CodingAgentConfig(
    model: Models.claudeSonnet5,
    cwd: FileManager.default.currentDirectoryPath,
    tools: .readOnly,
    bashEnvironment: [:]
)).agent

// 3. Drive it.
try await agent.prompt("Summarize the Swift files under Sources/KWWKAgent.")

// 4. Read the transcript.
for message in agent.state.messages {
    print(message)
}
```

### Subagents

`CodingAgentConfig.subagents` defaults to an empty array. When it is
empty, `makeCodingAgent` does not register the `agent` tool. Add
subagent definitions explicitly when you want model-driven delegation:

```swift
let reviewer = SubagentDefinition(
    name: "reviewer",
    description: "Use for code quality, security, maintainability, and test coverage review.",
    prompt: """
    You are a senior code reviewer. Review code carefully, do not edit files,
    and report findings with file paths, severity, and concrete evidence.
    """,
    tools: .readOnly,
    model: .inherit
)

let bg = BackgroundTaskManager()
let shellEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
let coding = await makeCodingAgent(CodingAgentConfig(
    model: Models.claudeSonnet5,
    cwd: FileManager.default.currentDirectoryPath,
    tools: .standard,
    backgroundManager: bg,
    subagents: [reviewer],
    bashEnvironment: shellEnvironment
))

try await coding.agent.prompt("Use the reviewer subagent to review Sources/KWWKAgent.")

// With a backgroundManager, completed background tasks auto-continue the
// agent (new LLM runs start on their own). Call `coding.detachBackground?()`
// to unsubscribe when embedding.
```

For the same built-ins that the CLI uses, SDK users can opt in without
copying prompts:

```swift
let agent = await makeCodingAgent(CodingAgentConfig(
    model: Models.claudeSonnet5,
    cwd: FileManager.default.currentDirectoryPath,
    tools: .standard,
    backgroundManager: BackgroundTaskManager(),
    bashEnvironment: shellEnvironment
).withBuiltinSubagents([.general, .explore, .plan, .codeReviewer, .testRunner])).agent
```

SDK users can also run a subagent directly:

```swift
let runner = SubagentRunner(
    cwd: FileManager.default.currentDirectoryPath,
    subagents: [.plan()],
    parentModel: Models.claudeSonnet5,
    parentTools: .readOnly,
    bashEnvironment: [:]
)
let result = try await runner.run(
    type: "Plan",
    prompt: "Plan how to simplify Sources/KWWKAgent/SubagentTool.swift."
)
```

Subagents are fresh-context agents: they do not inherit the parent
transcript. The parent model must put the relevant files, errors, goals,
and constraints into the `agent` tool's `prompt`. Trusted project context
files and visible skill metadata are rebuilt into the child system prompt.
Child coding tools are always capped by the parent's current coding-tool
set; an explicit definition can narrow that set, but cannot expand it.
The parent's `beforeToolCall` and `afterToolCall` policy/audit hooks are
propagated to child tools. Conversation-specific hooks such as
`betweenTurns`, `transformContext`, `convertToLlm`, and `userPromptSubmit`
remain local to the parent.

Each `agent` surface has bounded defaults: four active children, one active
child with write/edit/bash capability, four launches per assistant turn,
64 launches for the parent lifetime, 16 child turns, and a 600-second child
deadline. Configure these through `SubagentLimits`. Model-issued overrides
must name the parent model, a same-provider catalog model, or a host-approved
`allowedSubagentModels` entry; programmatic `SubagentModel.override` remains
the trusted host path for custom models. Child completion uses an internal,
structured `subagent_yield` contract: a plain provider stop is not treated as
success. A child that forgets to yield receives at most three internal
reminders; the final reminder exposes only the yield tool. Missing or explicit
incomplete yields are reported as incomplete and retain usage, cost, duration,
turns, and bounded untrusted salvage when available.

Each subagent run gets its own child session id. Tools inside that
subagent, including background-capable tools such as Bash, are scoped to
the child session. While the child agent is running, background task
notifications are attached to that child session. When the subagent
finishes or is cancelled, the generic background-task session is closed:
still-running tasks in that child session are killed and queued
notifications for that child session are discarded. If the parent starts
the subagent itself with `run_in_background`, that top-level subagent job
remains parent-visible so `job poll` and automatic runtime completion
notifications still work. Normal completion is delivered automatically;
`job poll` is only for a parent that is otherwise blocked, and one poll can
watch multiple task ids with wait-any semantics.

`makeCodingAgent` also registers a parent-only `agent_history` tool whenever
subagents are configured. It lists live/terminal children and pages their full
retained messages by stable child-session or background-task id, rather than
depending on the job output tail. The registry is process-local, keeps at most
the newest 32 terminal children (subject to a 16 MiB estimated transcript
budget), and reports eviction counts; it does not survive application restart.
Each tool response is capped at 64 KiB and explicitly marks an individual
message that is too large for one response. SDK users who construct
`createAgentTool` directly can share a `SubagentHistoryStore` with
`createSubagentHistoryTool`; `SubagentRunner.historyStore` exposes the same
process-local registry for direct-run integrations.

In the interactive TUI, foreground subagent tool calls update their
in-flight display with the child agent's token usage as it runs. When a
provider does not stream exact usage until the end of the turn, the live
counter falls back to an approximate output-token estimate and is
replaced by provider-reported usage once available.

Subagent tools also emit structured runtime events through
`AgentEvent.runtimeEvent(.subagent(...))`: started, tool update,
background started, completed, and failed. The terminal
`AgentRunSummary.subagents` array records each foreground child run's
usage, cost, turns, duration, status, model, and child session id.
Background subagents are recorded when the parent-visible background task
is started; their terminal completion/failure is emitted later as the same
`SubagentLifecycleEvent`, correlated by background task id and child session
id, independently of whether a runtime aside or `job poll` consumes the
model-facing notification. `job` snapshots retain the structured outcome,
including usage and cost. `agent.backgroundSubagentRuns()` exposes the
terminal cross-run aggregate to SDK hosts.

The interactive `kwwk` CLI enables five built-ins by default: `explore`,
`plan`, `code-reviewer`, `test-runner`, and `general`. `subagent_type` is
required, and the tool description orders narrower specialists before
`general`; there is no silent fallback to a full-power child. `general`
inherits the parent agent's tools and is reserved for implementation work.
`explore`, `plan`, and `code-reviewer` are read-only specialists.
`test-runner` has Bash but enforces a conservative runtime policy: exactly one
direct build/test process per tool call; shell composition, redirection,
command substitution, cleanup arguments, and unrelated executables are
rejected before spawn. This is an accidental-destruction boundary, not an OS
sandbox—the selected build system still executes trusted project code. Interactive
CLI built-ins default to background execution so independent team fan-out
does not turn the parent into a wait-all barrier; pass
`run_in_background: false` when the parent must block for one result.
`agent_history(task_id: ...)` exposes a child's live transcript while parent
work remains. `job(list: true)` exposes live status plus a bounded progress/output tail,
and completion is delivered as an internal runtime aside rather than an
editable user queue item. Use `--no-subagents` to disable them or
`--subagents read-only` or `--subagents general,test-runner` to enable only a
subset. The SDK does not enable those automatically. `readOnly` is a
tool whitelist, not an operating-system filesystem sandbox. The built-in
`explore` and `plan` definitions additionally use canonical workspace path
containment for read/grep/find/ls (including `..` and symlink checks). That
path policy still does not constrain Bash/custom tools and is not an OS-level
sandbox or a defense against hostile concurrent symlink replacement.

One-shot `kwwk -p` deliberately disables background execution: it does not
expose job/task-status or background bash options, and rejects background
subagent requests instead of exiting after reporting a task as started.

When an SDK application is done with an agent session, call
`await agent.closeSession()` to release provider-owned resources keyed by
that session id. For OpenAI Responses WebSocket transport, this closes the
stored WebSocket connection for the session.

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
    model: Models.claudeSonnet5,
    tools: [weather]
))
try await agent.prompt("Is it warmer in Tokyo or Oslo right now?")
```

### Hooks — audit, redact, short-circuit

Every `AgentOptions` accepts hooks that fire at well-defined points. Use
them to enforce policy without forking the loop:

```swift
let options = AgentOptions(
    initialState: AgentInitialState(model: Models.claudeSonnet5, tools: [...]),
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
agent.steer("also add tests as you go")
```

### Providers

`registerBuiltins` covers Anthropic, OpenAI (Completions + Responses),
and Google Gemini from explicit keys. For CLI-style environment discovery,
call `registerBuiltinsFromEnvironment(env:)` with an environment snapshot.
`Models` exposes a small curated catalog
(`claudeSonnet5`, `gpt55`, `gemini35Flash`, …) or you can construct
`Model` values by hand. For OpenAI-compatible endpoints (xAI, Groq,
OpenRouter) there are `Models.xaiGrok(id:)`, `Models.groq(id:)`,
`Models.openRouter(id:)` helpers.

To use a subscription (OAuth) token instead of a raw API key, drive the
flow via `KWWKAI.OAuth` / `OAuthLogin` — the same code path the CLI's
in-session `/login` command uses.

### Updating the model catalog

There are two bundled catalogs, and a sync should regenerate BOTH —
don't update one without the other:

1. `Sources/KWWKAI/Resources/models.json` — every regular provider,
   generated from pi-mono's `packages/ai/src/models.generated.ts`.
2. `Sources/KWWKAI/Resources/cursor-models.json` — the Cursor
   subscription models, pulled live from Cursor's `GetUsableModels` RPC
   (there is no runtime model sync; this file is the authoritative
   Cursor catalog).

```sh
swift run kwwk-generate-models /path/to/pi-mono/packages/ai/src/models.generated.ts
swift run kwwk-generate-cursor-models
swift test
```

`kwwk-generate-cursor-models` authenticates via `CURSOR_ACCESS_TOKEN`,
an existing `cursor` login in `~/.kwwk/oauth.json`, or — with neither
present — an interactive browser login it persists for next time.

The catalog tests assert unsupported Google Gemini CLI and Google
Antigravity provider groups stay absent.

---

## Layout

- `Sources/KWWKAI` — model clients, OAuth, provider adapters
- `Sources/KWWKAgent` — tool-using agent loop and built-in tools
- `Sources/KWWKCli` — interactive TUI, slash commands, rendering
- `Sources/kwwk` — the executable entry point
- `Tests/` — XCTest suites for each module

Run the full package test suite with SwiftPM:

```sh
swift test
```

## A note on OAuth client IDs

`Sources/KWWKAI/OAuthProviders.swift` reuses the OAuth client IDs (and,
where applicable, public app metadata) shipped by the upstream
first-party CLIs — Anthropic's Claude Code, OpenAI's Codex CLI, and
GitHub Copilot's VS Code extension. Those credentials are not secrets in
any meaningful sense — they are embedded in those open-source CLIs and
are required for the "log in with your existing subscription" flow to
work. They remain the property of their respective vendors, who may
rotate or revoke them at any time. `kwwk` is not affiliated with or
endorsed by any of these vendors.

## License

MIT — see [LICENSE](LICENSE).
