# kwwk

A Swift-native coding agent with two faces:

- **`kwwk`** — an interactive coding CLI (TUI) that drives your existing
  Anthropic, ChatGPT (Codex), GitHub Copilot, Cursor, Kimi For Coding,
  xAI Grok, Z.AI GLM Coding Plan, or OpenRouter account — or an API key
  for Anthropic, OpenAI, Google (Gemini), OpenRouter, or any
  OpenAI-compatible endpoint.
- **`KWWKAgent` / `KWWKAI`** — the agent runtime underneath, exposed as
  SwiftPM libraries so you can embed it in your own app, build custom
  tools, or swap the LLM provider.

## Requirements

- macOS 14+ runtime; Homebrew release bottles target macOS 15+ on Apple
  Silicon and Intel.
- A bottled Homebrew install has no Swift or Xcode runtime dependency.
- Building from source requires the Swift 6.1 toolchain (Xcode 16.3+ or the
  matching `swift` toolchain).

---

## 1. The coding CLI

### Install

From Homebrew (recommended):

```sh
brew install EYHN/tap/kwwk
```

Or build from source:

```sh
swift build -c release --product kwwk
bin_dir="$(swift build -c release --show-bin-path)"
sudo install -d /usr/local/libexec/kwwk /usr/local/bin
sudo install -m 0755 "$bin_dir/kwwk" /usr/local/libexec/kwwk/kwwk
sudo cp -R "$bin_dir/kwwk_KWWKAI.bundle" /usr/local/libexec/kwwk/
printf '%s\n' '#!/bin/sh' 'exec /usr/local/libexec/kwwk/kwwk "$@"' \
  | sudo tee /usr/local/bin/kwwk >/dev/null
sudo chmod 0755 /usr/local/bin/kwwk
```

The resource bundle must stay beside the real executable. The launcher above
executes that path directly; replacing it with a symlink can make SwiftPM look
for `kwwk_KWWKAI.bundle` beside the symlink instead.

### Run

```
kwwk              launch the interactive coding TUI
kwwk --help       show this message
```

Credentials come from the OAuth store at `~/.kwwk/oauth.json`; if no login
exists, the CLI checks supported API-key environment variables. With
neither configured, kwwk starts logged out — launch it and run `/login`
to sign in to a provider (browser sign-in for ChatGPT Codex, Copilot,
Claude Code, Cursor, Kimi For Coding, xAI Grok, the Z.AI GLM Coding Plan,
or OpenRouter; or an API key for Anthropic, OpenAI, Google (Gemini),
OpenRouter, or any OpenAI-compatible endpoint).

Inside the TUI, `/help` lists slash commands (`/model`, `/thinking`,
`/clear`, …). The agent ships with Bash, Read, Write, Edit, Grep, Find,
LS, and background-task tools out of the box.

Official Anthropic Fable 5/5.1, Mythos 5/5.1, and Opus 5 requests automatically allow server-side fallback
to Opus 4.8. Replies show the requested → served model when they differ, also
when resuming history. Handoff blocks are preserved for Anthropic's continued
Opus routing on follow-up turns; this does not switch the configured model.
See [fallback behavior and tests](Documents/AnthropicFallback.md) for replay,
billing estimates, and the SDK opt-out.

Image inputs are resized and recompressed before entering the conversation.

### MCP servers

The kwwk TUI connects to [Model Context Protocol](https://modelcontextprotocol.io)
servers listed in `~/.kwwk/mcp.json`, using the usual `mcpServers` shape.
`kwwk -p` and the SDK never read this file; SDK callers build an
`MCPManager` from configs they pass in.
Both stdio and Streamable HTTP servers are supported; SSE-only servers are
not. HTTP servers sign in with OAuth (MCP authorization, 2025-11-25) unless
their entry sends its own `Authorization` header or sets `"oauth": false`.

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_TOKEN": "${GITHUB_TOKEN}" },
      "description": "GitHub issues, pull requests and files"
    },
    "docs": {
      "type": "http",
      "url": "https://example.com/mcp",
      "headers": { "Authorization": "Bearer ${DOCS_TOKEN}" },
      "toolExposure": { "delete_*": "hidden" }
    }
  }
}
```

`kwwk mcp` edits these files for you, like `claude mcp`:

```sh
kwwk mcp add linear https://mcp.linear.app/mcp          # Streamable HTTP
kwwk mcp add -e GITHUB_TOKEN='${GITHUB_TOKEN}' github -- npx -y @modelcontextprotocol/server-github
kwwk mcp add --scope project docs https://example.com/mcp -H "Authorization: Bearer ${DOCS_TOKEN}"
kwwk mcp add-json weather '{"type":"http","url":"https://weather.example/mcp"}'
kwwk mcp list                     # check every server
kwwk mcp get linear               # show one (secrets hidden)
kwwk mcp login linear             # OAuth sign-in in the browser (--no-browser prints the URL)
kwwk mcp logout linear
kwwk mcp remove linear            # also forgets its sign-in
```

`--scope user` (default) writes `~/.kwwk/mcp.json`; `--scope project` writes
`.kwwk/mcp.json` in the current directory. `kwwk mcp add --help` lists the
options (`--transport`, `--env`, `--header`, `--description`,
`--client-id`, `--client-secret`, `--client-name`, `--oauth-scope`,
`--callback-port`, `--no-oauth`). Everything after `--` is the stdio
command, passed through untouched.

Tools are named `mcp__<server>__<tool>`. Servers connect in the background,
and `/mcp` shows their status. MCP tools are never declared up front, so no
request waits for a server. The model loads them with the built-in
`tool_search` tool, a BM25 search over tool names, descriptions and
parameters, and can call them from its next request. `tool_search` waits for
servers that are still connecting. Set `exposure` on a server, or map tools
with `*` globs in `toolExposure`, to `hidden` to keep tools out entirely.
Subagents that can write, edit or run commands get `tool_search` over the
same MCP tools (loading for themselves); read-only subagents get none.

A server that needs a sign-in shows as such in `/mcp` and `kwwk mcp list`;
run `kwwk mcp login <server>` (or `/mcp login <server>` inside the TUI) to
authorize it in the browser, and `logout` to forget it. kwwk registers itself with the server's
authorization server (dynamic client registration, or a client ID metadata
document when you set `oauth.clientMetadataUrl`), listens on
`http://127.0.0.1:<port>/callback` for the redirect, and keeps the tokens in
`~/.kwwk/mcp-oauth.json` (mode 0600), refreshing them as needed. An `oauth`
object may set `clientName`, `scope`, a pre-registered `clientId` /
`clientSecret`, `clientMetadataUrl` and a fixed `callbackPort`.

When `tool_search` finds fewer tools than asked for, it names the servers
that cannot provide any right now (for example "Not connected: docs
(requires authorization)"). A tool result larger than about 25k tokens is
cut; the whole result is written under `~/.kwwk/mcp-results` and the
model is told where. `toolMaxTotalTimeout` bounds a tool call even while it
reports progress. Compaction unloads MCP tools that were not called since
the previous compaction; `tool_search` finds them again.

A project can also define servers in `.kwwk/mcp.json`; its entries replace
user entries of the same name. The file is only read when
`KWWK_ALLOW_PROJECT_MCP=1` is set, because opening a repository must not run
its commands. `"enabled": false` turns an entry off.

Tool changes are recorded in the session transcript. Models that support
mid-conversation tool changes (Anthropic Opus 4.8 and the 5.x family, OpenAI
GPT-5.4 and later on the Responses API) receive loaded tools in place, so the
prompt cache survives. Other models receive the full tool list, and loading
a tool costs one cache miss. Resumed sessions keep the tools they had
loaded, even while their servers are still connecting.

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
empty, `makeCodingAgent` does not register the subagent tools (`agent`,
`agent_send`, `agent_history`). Add subagent definitions explicitly when you
want model-driven delegation:

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

let shellEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
let coding = await makeCodingAgent(CodingAgentConfig(
    model: Models.claudeSonnet5,
    cwd: FileManager.default.currentDirectoryPath,
    tools: .standard,
    subagents: [reviewer],
    bashEnvironment: shellEnvironment
))

try await coding.agent.prompt("Use the reviewer subagent to review Sources/KWWKAgent.")

// A BackgroundTaskManager is created by default. Completed background tasks
// auto-continue the agent (new LLM runs start on their own). Call
// `coding.detachBackground?()` to unsubscribe when embedding, or pass
// `backgroundManager: nil` to disable background execution entirely.
```

The `agent` tool follows the same timing contract as `bash`: its `timeout`
is how long the call waits in the foreground (default
`SubagentLimits.foregroundTimeoutSeconds` = 120, at most
`maxForegroundTimeoutSeconds` = 600), not how long the child may run. A
foreground child still running when `timeout` elapses is moved to the
background — the work continues, the tool returns `auto_backgrounded` with a
task id, and completion arrives as the usual notification — or, without a
background manager, is cancelled as a timeout. A child's own runtime is
unbounded by default (`SubagentLimits.timeoutSeconds` is nil, and the
background manager then sets no deadline either), so foreground and
background children behave identically once launched.

`CodingAgentConfig.maxTaskTimeoutSeconds` (also on `createAgentTool`,
`createSubagentToolset`, and `SubagentRunner`) is a runtime-wide ceiling on
how long any single `bash` or `agent` call may keep the model waiting: it
folds into bash's `bashDefaultTimeoutSeconds`/`bashMaxTimeoutSeconds` and the
agent tool's foreground-wait bounds, overriding whatever `timeout` the model
asks for (a larger value is lowered, not rejected) and its
`run_in_background: false`. Both tool descriptions state the effective bound
so the model plans around it.

SDK users can enable the same built-ins that the CLI uses without copying
prompts:

```swift
let agent = await makeCodingAgent(CodingAgentConfig(
    model: Models.claudeSonnet5,
    cwd: FileManager.default.currentDirectoryPath,
    tools: .standard,
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

`SubagentLimits` sets no ceiling by default: active children, active children
with write/edit/bash capability, launches for the parent lifetime, child turns,
and child runtime are all unbounded, and the parent decides how to schedule its
children. A host that wants a ceiling sets it explicitly; `nil` always means
unbounded. Model-issued overrides
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
the subagent itself with `run_in_background`, that top-level subagent task
remains parent-visible to `task_poll` and automatic runtime completion
notifications. Normal completion is delivered automatically; `task_poll` is
only for a parent that is otherwise blocked, and one call can watch multiple
task ids with wait-any semantics.

Every child has a stable `agent_id` across all of its runs: `<type>-<n>` by
default, or the `name` the parent passes to `agent`. Tool results, task
notifications, and `task_list` all carry it.

`agent_send {agent_id, message}` talks to a child the parent already launched.
A running child (or one still waiting for capacity) reads the message at its
next step; if it already submitted its result when the message lands, the run
continues until it has answered the message and submitted again. A stopped
child — completed, incomplete, failed, or aborted — is resumed from its own
transcript with the message as a new prompt, in a new run with a new
background task id; `timeout` and `run_in_background` then work as they do for
`agent`. A resume does not count as another launch.

`agent_history` reads a child's transcript as compact markdown, by `agent_id`
or by the task id of any of its runs, and lists every child when given
neither. It shows the runs, user and assistant text in full, one line per
tool call (`→ [23.2] bash(xcodebuild -scheme App build) ⇒ error · 212 lines —
<first error line>`), and each submitted result in full; thinking, usage, and
image bytes are left out. The default view is the newest 20 messages;
`offset`/`limit` or `tail` page it. `tool_call: "23.2"` returns that call's
full arguments and its result paged by lines (120 by default). Internal child
session ids are not exposed to the model. The registry is process-local,
keeps at most 32 terminal children (least recently active evicted first)
subject to a 16 MiB estimated transcript budget, and does not survive
application restart; an evicted child cannot be resumed. Each response is
capped at 64 KiB.

`agent`, `agent_send`, `agent_history`, and the `task_*` tools treat an
optional argument sent as `null`, `""`, or whitespace exactly like an omitted
one, since some models fill every optional field. The agent loop drops such
arguments before schema validation for any `AgentTool` with
`omitsBlankOptionalArguments` set; required arguments are never touched.

SDK users who construct `createAgentTool` directly can share
a `SubagentHistoryStore` with `createSubagentHistoryTool`;
`SubagentRunner.historyStore` exposes the same process-local registry for
direct-run integrations.

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
id, independently of whether a runtime aside or `task_poll` consumes the
model-facing notification. Background-task snapshots retain the structured
outcome, including usage and cost. `agent.backgroundSubagentRuns()` exposes the
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
`agent_history({"task_id":"..."})` exposes a child's live transcript while
parent work remains. `task_list({})` exposes live status plus a bounded
progress/output tail, and completion is delivered as an internal runtime aside
rather than an editable user queue item. Use `--no-subagents` to disable them or
`--subagents read-only` or `--subagents general,test-runner` to enable only a
subset. The SDK does not enable those automatically. `readOnly` is a
tool whitelist, not an operating-system filesystem sandbox. The built-in
`explore` and `plan` definitions additionally use canonical workspace path
containment for read/grep/find/ls (including `..` and symlink checks). That
path policy still does not constrain Bash/custom tools and is not an OS-level
sandbox or a defense against hostile concurrent symlink replacement.

One-shot `kwwk -p` exposes the same background-task and background Bash
capabilities while its top-level Agent loop is running. It does not wait for
background-only work or start a fresh model run after the loop becomes idle:
when that loop returns, headless teardown retires the Agent, kills unfinished
tasks, and exits.

When an SDK application is done with an agent session, call
`await agent.closeSession()`. This permanently stops the agent, kills its
active background tasks, waits for the current run to finish cancelling, and
releases provider-owned resources keyed by that session id. For OpenAI
Responses WebSocket transport, this also closes the stored WebSocket
connection. Use `await agent.stop()` for the same deterministic agent/task
shutdown without closing provider session resources.

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

### MCP servers

`KWWKMCP` is an MCP client for any host. Build an `MCPManager` from server
configs, turn it into a `ToolCatalog`, and bind the catalog to an agent: the
agent gets `tool_search`, the server list in its system prompt, and every
tool it loads.

```swift
import KWWKMCP

let manager = MCPManager(configs: [
    MCPServerConfig(
        name: "docs",
        transport: .http(url: URL(string: "https://example.com/mcp")!),
        description: "Product docs and issue tracker"
    ),
], auth: ["docs": .provider(MyTokenProvider())])
let catalog = await manager.makeToolCatalog()
catalog.bind(to: agent)
```

Authentication follows the MCP TypeScript SDK's two layers:

- `MCPAuthProvider` (`token()`, `onUnauthorized(_:)`) for hosts that own
  their credentials. The transport sends the token on every request; a 401
  calls `onUnauthorized` once and retries.
- `MCPOAuthClientProvider` for a full OAuth client: discovery (RFC 9728,
  RFC 8414), client ID metadata documents or dynamic registration, PKCE,
  resource indicators, `iss` checks, refresh and 403 `insufficient_scope`
  step-up, all driven by `MCPOAuth.auth`. The provider stores what the flow
  produces and sends the user to the authorization page; finish with
  `MCPOAuth.finishAuthorization` and the callback's query parameters. Adopt
  `MCPOAuthClientRegistrationStore`, `MCPOAuthDiscoveryStore` and
  `MCPOAuthCredentialInvalidation` for the optional parts.

A server that needs authorization keeps the tools it offered and is not
reconnected in the background; every `tool_search` and every call on it
connects again and asks the auth provider for credentials, so new ones are
picked up without telling the manager (cache in the provider if asking is
expensive; `manager.reconnect("docs")` reconnects at once). A dropped
connection keeps its tools and reconnects in the background. `addServer`,
`updateServer` and `removeServer` change the set while running; call
`catalog.setInstructions(await manager.promptSection())` when the system
prompt may change. `resultLimits` caps what a tool result shows the model
and can spill the rest (`MCPDirectoryResultSpill`).

### Hooks — audit, redact, short-circuit

`beforeRunEnd` is an optional host completion policy on `AgentOptions` / `Agent`.
After a natural stop and drained queues, it can return runtime messages to keep
the same run going, or `[]` to finish. It receives the current `AgentContext`
and cancellation handle. Cancellation, provider failures and hard turn limits
remain terminal. No hook is installed by default; background task behavior is
unchanged. Hosts that wait in the hook must bound that wait and honor cancellation.

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

### Context compaction

`AgentOptions.autoCompact` defaults to a 75% threshold, matching
`CodingAgentConfig.autoCompactThreshold`, standalone subagent SDK entry points,
and the CLI. Pass `nil` explicitly to disable both proactive compaction and
provider-overflow recovery. Compaction turns older history into a structured,
incrementally updated recap while keeping recent turns verbatim. The budget
includes the system prompt and tool schemas, preserves tool-call / result
boundaries, and retries one provider-reported input overflow after rebuilding
the request. Manual `/compact` uses the same projection pipeline.

Set `AgentOptions.compactionModel` (or `CodingAgentConfig.compactionModel`) to
send summary-generation requests to a different model. Context thresholds,
recovery targets, and post-compaction validation still use the live conversation
model. Assign `nil` to follow the live model dynamically. In the TUI, use
`/compact-model` to pick an authenticated model, `/compact-model status` to
inspect it, or `/compact-model clear` to follow `/model` again. A custom
`streamFn` must route each request using the `Model` argument it receives.
`AgentContextCompactionConfig.summaryMaxTokens` defaults to `0`, which leaves
the summary stream cap automatic; set a positive value only when an explicit
hard output limit is required.

Idle compaction is off by default. Set `AgentOptions.idleCompact` (or
`CodingAgentConfig.idleCompact`, or assign `agent.idleCompact` at runtime) to
compact a session that has sat untouched for `delay` seconds (default 300) once
its context reaches `threshold` — `.ratio(0.5)` of the window by default, or an
absolute `.tokens(150_000)` that stays put across model switches. The countdown
starts whenever a run or maintenance window ends and is cancelled by the next
run; hosts report activity the agent cannot see with `agent.noteIdleActivity()`
and veto a due compaction (unsent draft, open dialog) with `canCompact`. Queued
messages, or active tasks on `autoCompact.backgroundManager` for the session,
mean the agent is waiting rather than idle, and skip it. It reuses
`autoCompact.config`, emits the same `compactStart` / `compactEnd` events (so
`SessionRecorder` persists it), and attempts at most once per transcript
revision. `agent.compactIfIdle()` runs the same checks immediately. The CLI
exposes it as `--idle-compact` and `/idle-compact [on|off] [50% | 150k] [delay]`.

Compaction requests retry transient network, rate-limit, and provider-overload
failures through `AgentContextCompactionConfig.summaryRetryPolicy` (five total
attempts by default, exponential backoff with jitter and Retry-After support).
Native requests and local summaries each have one retry owner, separate from
`maxSummaryAttempts` (context-reduction attempts). Cancellation, HTTP 402,
invalid requests, output-limit truncation, and context overflow do not retry
the same request. Premature transport EOF remains a transient failure.

Native compaction is enabled when available: ChatGPT Codex uses an authenticated
Responses V2 stream with `compaction_trigger` (its subscription endpoint does
not expose `/responses/compact`); explicitly opted-in Responses routes retain
the V1 `/responses/compact` protocol. Supported Anthropic models on the official route
use the compaction beta once context reaches 55k tokens. Compatible routes can
opt in with `ModelCompat.supportsServerCompaction = true`; `false` disables the
capability. Unsupported routes, smaller Anthropic contexts, or a separate
compaction model use the local summary pipeline. Native request failures remain
visible after bounded retries and leave the existing context intact.
Anthropic native summaries use the recap budget as their output cap (also
bounded by `summaryMaxTokens` when set); Codex's compact endpoint manages its
own output size.

Native payloads are persisted and replayed on subsequent requests. Codex's
encrypted context keeps its source prefix for switching providers, where normal
context management can summarize it again. Anthropic also supplies readable
summary text. Set `AgentContextCompactionConfig.useNativeCompaction = false`
to use only local summaries. Custom `streamFn` hosts stay on their own local
summary transport unless they also provide `config.nativeCompaction`.
No background or speculative compaction runs are started.

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
# In the pi-mono checkout, materialize the generated provider JSON first.
node packages/ai/scripts/generate-models.ts

# In the kwwk checkout, use that exact pi-mono checkout as the input.
swift run kwwk-generate-models /path/to/pi-mono/packages/ai/src/models.generated.ts
swift run kwwk-generate-cursor-models
swift test
```

Current pi-mono provider catalogs import their values from generated
`packages/ai/src/providers/data/*.json` files. Those files are intentionally
Git-ignored upstream, so the pi-mono generator must run in that checkout before
`kwwk-generate-models`. Older inline provider catalogs remain supported.

`kwwk-generate-cursor-models` authenticates via `CURSOR_ACCESS_TOKEN`,
an existing `cursor` login in `~/.kwwk/oauth.json`, or — with neither
present — an interactive browser login it persists for next time.

The catalog tests assert unsupported Google Gemini CLI and Google
Antigravity provider groups stay absent.

---

## Layout

- `Sources/KWWKAI` — model clients, OAuth, provider adapters
- `Sources/KWWKAgent` — tool-using agent loop and built-in tools
- `Sources/KWWKMCP` — MCP client SDK: stdio / Streamable HTTP transports, MCP authorization (OAuth), server manager, tool catalog binding, tool adapter (reads no config files)
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
