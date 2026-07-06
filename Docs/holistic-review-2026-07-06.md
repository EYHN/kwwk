# kwwk 全面 Review 报告

> 2026-07-06 · 7 维度并行审查 + 每条发现独立对抗验证 · 74 个 agent 通过、4 条发现被验证推翻、3 条验证 agent 崩溃后由人工复核确认


参照项目：`~/Draw/pi-mono`（pi 的 TypeScript 实现）。审查范围：`Sources/KWWKAI`、`Sources/KWWKAgent`、`Sources/KWWKCli`、`Sources/kwwk`。


## 各维度总体评价

### SDK DX — KWWKAI

KWWKAI's public API is broadly well-designed for a 34k-line port: types are Sendable/Codable value types mirroring pi-ai's shapes, providers take explicit keys and pluggable HTTPClients with zero hidden ProcessInfo/env reads (EnvAPIKeys and registerBuiltinsFromEnvironment take explicit snapshots), and the scoped APIRegistry with sourceId teardown is genuinely nicer than pi-mono's flat module-global map. The significant gaps cluster in two places: cancellation semantics (stream iteration ignores Swift task cancellation and CancellationHandle is polled rather than eagerly aborting in-flight requests, so cancelling a stalled stream hangs) and silent-failure paths (empty-dict env defaults, corrupt OAuth store overwrites, try?-swallowed OAuth refresh errors, empty ModelsCatalog on resource failure, and complete() returning errors as ordinary-looking messages).

### SDK DX — KWWKAgent

The KWWKAgent public API is unusually disciplined about avoiding init-time surprises — bashEnvironment is a required explicit parameter, skills/context files/user directories are opt-in, SessionStore() is inert without a directory, and the append-only session log plus ResolvedResume/SessionRecorder design is coherent — but several sharp edges undercut the "no surprising side effects" goal: SessionRecorder.ensureCreated silently truncates resumed session files, a subagent definition containing .tmux can preconditionFailure-crash the host process at model tool-call time, makeCodingAgent installs an auto-continue background bridge (spontaneous billable LLM runs) while discarding the only detach handle, and Agent's public mutable config vars are unsynchronized despite the @unchecked Sendable annotation. A second tier of issues is about the obvious call being wrong or half-working: the README's steer(UserMessage) example does not compile, mutating agent.sessionId does not actually re-scope tools or background attachments, and invalid resume ids silently degrade to random fresh sessions.

### 正确性 — KWWKAI

Sources/KWWKAI is a careful, well-commented port of pi's provider layer and most of the streaming/state machinery is sound, but the review found three high-impact correctness gaps: an OAuth token-refresh race through actor reentrancy that can invalidate rotated refresh tokens under concurrent requests, Bedrock's failure to capture Claude thinking signatures (breaking thinking replay that pi explicitly handles), and cancellation that is only polled per-SSE-event on every HTTP provider path so a cancel during a silent stream gap neither aborts the request nor stops server-side token burn. A second tier of issues makes failures look like successes (Anthropic 'refusal' and premature EOF mapped to .stop, OpenAI Responses 'response.incomplete' unhandled and misclassified as a WebSocket transport failure) plus smaller robustness gaps in the OAuth callback server, byte-stream buffering, and error-body reporting.

### 正确性 — KWWKAgent

Sources/KWWKAgent is a generally faithful, carefully-commented port of pi's agent core — the loop, compactor, session store/recorder/resume, pending queues, and subagent runner all check out on the paths I traced, including tricky spots like compaction/persistedCount interplay and steering-queue drain semantics. The real defects cluster in process plumbing and advertised-but-unimplemented surface: two read-after-waitUntilExit pipe deadlocks (default bash path and tmux), missing process-group handling on the foreground bash paths, atomic-rename writes that defeat FileMutationQueue's inode keying and clobber symlinks, untruncated bash output, dead grep glob/context and read autoResizeImages options, plus two smaller protocol bugs (duplicate turnStart, stall-suppressed completion notifications).

### TUI 用户体验

The kwwk TUI is unusually carefully built for its size — escape-sequence disambiguation with a timed flush, IME-aware hardware-cursor placement via a zero-width APC marker, height-budgeted modals that survive tiny terminals, a thoughtful suspend/resume dance for the OAuth handoff, and multiplexer-aware resize repaints all show real polish, and the login/model/logout flows have consistent, well-worded feedback. The gaps that remain are concentrated and concrete: manual /compact runs entirely outside the busy/streaming machinery (no feedback, un-cancellable, and a real transcript-clobbering race with a concurrently submitted prompt), large pastes stall the main queue quadratically, modern emoji/ZWJ widths misalign the prompt box and IME cursor, signal-driven exits leak background processes by bypassing shutdown, and single-tap Ctrl-C plus the bare --resume prompt diverge from the pi/omp interaction conventions the project explicitly targets.

### 性能

The architecture makes fundamentally sound performance choices — append-only JSONL session persistence, a retained live zone with settled lines committed to native scrollback, cached input rendering, and activity-gated spinner ticks — so there are no whole-transcript-per-token or rewrite-file-per-message disasters. The real hot-path costs are concentrated in the transport layer (byte-granular AsyncThrowingStream delivery and a fresh URLSession/TLS handshake per API call), unpruned filesystem tools (grep/find walk .git and node_modules with per-file regex compilation, versus pi's ripgrep/fd with .gitignore), and several quadratic per-delta accumulation patterns (tool-call JSON re-parsed per SSE delta in all providers, O(n) snapshot re-derivation per delta in the transcript renderer), plus an unconditional full live-zone rewrite on every agent event with the stored previous frame never consulted for diffing.

### 副作用/全局状态

This codebase is unusually disciplined about side effects for an agent SDK: persistence is opt-in (OAuthStore()/SessionStore() are in-memory by default), bashEnvironment has no default so the host env is never silently exposed, EnvAPIKeys takes env snapshots as parameters instead of reading ProcessInfo, URLSession is ephemeral with cookies/cache disabled, tmux runs on a per-PID socket, background task logs are 0700/0600, and goal-mode internals are redacted before hitting disk. The real hazards found are concentrated in four places: atomic writes in Edit/Write that silently destroy symlinks (contradicting FileMutationQueue's inode-based design and pi's in-place writes), APIRegistry's scope-to-flat fallback that can send one vendor's API key to another vendor's host, tmux panes inheriting the full host environment despite the bash tool's explicit isolation contract, and permission gaps around ~/.kwwk (oauth.json's chmod-after-write race, world-readable session transcripts).


## 发现清单（共 69 条：high 10 / medium 33 / low 26）


---

## HIGH（10 条）

### H1. Cancellation on all HTTP/SSE provider paths is only polled per-event; a cancel during a silent stream gap does nothing and never aborts the request

`Sources/KWWKAI/AnthropicProvider.swift:191` · 正确性 — KWWKAI


**证据：** `drive()` checks `if state.signal?.isCancelled == true` only at the top of `for try await sse in events` — i.e. only when the server delivers the next SSE event. No `onCancel` registration cancels the in-flight HTTP task. The same poll-only pattern exists in OpenAICompletionsProvider.swift:160, BedrockProvider.swift:187, GoogleGeminiProvider.swift:138, and the OpenAIResponses HTTP path (OpenAIResponsesProvider.swift:482). By contrast, the Responses WebSocket path does it correctly: `cancellationRegistration = options?.cancellation?.onCancel { _ in connection.close() }` (OpenAIResponsesProvider.swift:281), and pi passes an AbortSignal into every fetch/SDK call (amazon-bedrock.ts:204 `client.send(command, { abortSignal })`).


**影响：** A user pressing Esc/cancel while the model is in a long silent stretch (extended thinking with no summary deltas, slow first token, provider hiccup) sees nothing happen until the next event arrives; if the stream has genuinely stalled, cancel hangs indefinitely (until URLSession's request timeout). Meanwhile the server-side request keeps generating and billing tokens the user asked to stop.


**建议：** Register `options?.cancellation?.onCancel { ... }` in each provider's `run` right after obtaining the byte stream, and have it cancel the underlying transport (e.g. keep the `AsyncThrowingStream` termination handle, or expose a cancel token from `HTTPClient.stream`). Remove or keep the per-event poll as a fallback.

### H2. BedrockProvider never captures the reasoningContent.signature delta, so Claude thinking signatures are lost and replay degrades

`Sources/KWWKAI/BedrockProvider.swift:257` · 正确性 — KWWKAI


**证据：** The `contentBlockDelta` handler only reads `delta["reasoningContent"].text` (lines 257-269); there is no code path that reads `reasoningContent.signature`, and `BedrockStreamState` has no `appendSignature`. The reference implementation explicitly accumulates it (pi amazon-bedrock.ts:417-419: `thinkingBlock.thinkingSignature = (thinkingSignature || "") + delta.reasoningContent.signature`). On replay, `encodeMessages` (lines 484-499) requires a non-blank `th.thinkingSignature` to emit a `reasoningContent` block for Claude models; because the signature was never captured, every same-model thinking block falls into the `parts.append(["text": thinking])` degradation branch (line 499). pi's own comment (amazon-bedrock.ts:675) notes: "persisted message lacks a signature, Bedrock rejects the replayed [block]".


**影响：** Any multi-turn conversation on Bedrock Claude with extended thinking enabled loses all reasoning blocks on the very next request: the thinking is re-sent as plain assistant text. In tool-use loops with thinking enabled, Anthropic-on-Bedrock expects signed thinking blocks to precede tool_use on replay; converting them to text can trigger request rejections or silently strip the model's chain-of-thought, degrading agent behavior versus pi.


**建议：** In the `contentBlockDelta` case, also match `reasoningContent.signature` (a string delta) and accumulate it onto the thinking block's `thinkingSignature` (mirroring the existing `appendSignature` pattern in AnthropicStreamState); also handle `reasoningContent.redactedContent` if parity with pi's redaction handling is desired.

### H3. A brand-new URLSession is created and invalidated per streaming request, so no TCP/TLS connection is ever reused across API calls

`Sources/KWWKAI/HTTPClient.swift:67` · 性能


**证据：** streamViaDelegate does `let driver = URLSession(configuration: base.configuration, delegate: delegate, delegateQueue: nil)` for every call, and StreamingDelegate.didCompleteWithError calls `session.finishTasksAndInvalidate()` (line 203). URLSession connection pools are per-session, so each request performs a fresh DNS lookup + TCP connect + TLS handshake. The injected `session` in URLSessionHTTPClient is only used as a configuration donor, never for requests.


**影响：** An agent turn is a sequence of API calls (assistant turn -> tool results -> next turn, plus retries and compaction summaries), all to the same provider host. Each call pays a full handshake (~100-300ms to api.anthropic.com plus TLS CPU) that HTTP keep-alive would amortize to near zero. Over a long session this adds seconds of dead time and directly worsens perceived latency between tool call and next token.


**建议：** Keep one long-lived URLSession and use per-task delegates: `session.dataTask(with: request)` + `task.delegate = StreamingDelegate()` (supported on macOS 12+/iOS 15+), or on Linux keep a single session-level delegate that demultiplexes callbacks by `dataTask.taskIdentifier` into per-request continuations.

### H4. OAuthManager token refresh races via actor reentrancy, causing concurrent refreshes with the same refresh token

`Sources/KWWKAI/OAuth.swift:205` · (补录)


**证据：** In `OAuthManager.apiKey(for:)`: `if credentials.isExpired { credentials = try await provider.refresh(credentials, using: client); try await store.set(...) }`. `OAuthManager` is an actor, but Swift actors are reentrant: while the first call is suspended in `await provider.refresh(...)` (a network round-trip), a second `apiKey(for:)` call enters the actor, reads the still-stale credentials from the store, sees `isExpired == true`, and launches a second refresh with the same refresh token. There is no in-flight-refresh deduplication (no pending-task cache, no flag). The `resolver()` closure (line 214) is handed to every stream request, so concurrent requests (parallel subagents, retry overlap) hit this path simultaneously.


**影响：** Anthropic's OAuth token endpoint rotates refresh tokens: two concurrent refreshes with the same refresh token means one of them uses an already-consumed token, and whichever `store.set` lands last can persist credentials whose refresh token was just invalidated. The user gets intermittently logged out of Claude Pro/Max mid-session and must re-run login. GitHub Copilot is also hit with duplicate session-token exchanges (wasteful but benign).


**建议：** Deduplicate in-flight refreshes: keep a `[String: Task<OAuthCredentials, Error>]` inside the actor keyed by providerId; if a refresh task already exists for the provider, `await` its value instead of starting a new one, and re-read the store after resuming before deciding to refresh.

### H5. Default (no-manager) bash path deadlocks on output larger than the pipe buffer because pipes are read only after waitUntilExit

`Sources/KWWKAgent/BashTool.swift:117` · 正确性 — KWWKAgent


**证据：** LocalBashOperations.execute wires `process.standardOutput = stdoutPipe; process.standardError = stderrPipe`, then blocks: `await withCheckedContinuation { ... DispatchQueue.global().async { process.waitUntilExit(); cont.resume() } }` and only afterwards calls `readAll(stdoutPipe.fileHandleForReading)` (lines 117-125). Nothing drains the pipes while the child runs.


**影响：** A pipe holds ~64KB. Any command whose stdout+stderr exceeds that (e.g. `git log`, `npm install`, a failing test suite) blocks in write(2); the parent blocks in waitUntilExit — a permanent deadlock until the soft-timeout task SIGTERMs the child, after which the (truncated-at-64KB-buffered) run is reported as "Command timed out". This is the default path for every SDK consumer who does not attach a BackgroundTaskManager (BashToolOptions.manager defaults to nil), so ordinary commands mysteriously "time out" at exactly 64KB of output.


**建议：** Start readabilityHandler-based draining (or readToEnd on background threads) for both pipes before/while waiting, and only then waitUntilExit — mirroring how pi streams child output. Alternatively route the legacy path through the same fd-dup-to-file mechanism used by BashRunnerImpl.

### H6. CodingTools.tmux without a tmuxManager crashes the whole process via preconditionFailure — reachable at model tool-call time through subagent definitions

`Sources/KWWKAgent/CodingAgentBuilder.swift:267` · SDK DX — KWWKAgent


**证据：** buildCodingToolList: `guard let tmuxManager else { preconditionFailure("CodingTools.tmux requires an explicit TmuxSessionManager") }`. makeCodingAgent never validates `config.subagents[*].tools`; SubagentInvocationRunner.runChild (SubagentTool.swift:850-861) calls buildCodingToolList with `selectedTools = definition.tools ?? parent.tools` and the tmuxManager forwarded from config (possibly nil) — so the trap fires lazily when the model invokes the `agent` tool, not at build time. Failure policy is also inconsistent: `.taskStatus`/`.waitTask` without a manager are silently dropped (lines 259-264), and `.tmux` with a manager but no tmux binary is silently dropped (`createTmuxTool` returns nil, TmuxTool.swift:23), while a nil manager traps.


**影响：** A host app that registers a SubagentDefinition with `tools: [.read, .tmux]` but no tmuxManager builds and prompts fine, then hard-crashes mid-conversation the first time the model delegates to that subagent — taking down the embedding application. Same class of misconfiguration produces three different behaviors (silent drop, silent drop, process abort).


**建议：** Validate subagent tool sets in makeCodingAgent and either throw a typed error or degrade like the other tools do (omit tmux and surface a diagnostic). Reserve preconditionFailure for programmer invariants that cannot be data-driven by config.

### H7. Edit and Write tools' atomic writes silently destroy symlinks (and detach hard links) instead of writing through them

`Sources/KWWKAgent/EditTool.swift:24` · 副作用/全局状态


**证据：** LocalEditOperations.writeFile and LocalWriteOperations.writeFile (WriteTool.swift:17) both do `try content.write(to: URL(fileURLWithPath: absolutePath), options: .atomic)`. I verified empirically on this machine (Darwin, Swift 6): writing with `.atomic` to a path that is a symlink replaces the symlink itself with a new regular file — afterwards `FileManager.attributesOfItem` reports `NSFileTypeRegular` and the link target still contains the original content. EditTool reads through the link (`Data(contentsOf:)` follows symlinks), so an edit "succeeds" while the real target file is never modified and the link is severed. This also detaches hard-link siblings (rename swaps the inode). It directly contradicts FileMutationQueue.swift:7-9, which keys its queue by inode explicitly "so symlink siblings [stay] on the same queue" — the queue assumes symlink-transparent writes that these operations do not perform. The pi reference behaves correctly: packages/coding-agent/src/core/tools/write.ts:33 and edit.ts:81 use `fsWriteFile(path, content)`, which opens and truncates in place, following symlinks and preserving the inode.


**影响：** A user whose project or dotfiles use symlinks (e.g. `~/.zshrc` -> dotfiles repo, `node_modules` links, Bazel/Nix trees) asks the agent to edit such a file. The tool reports success, but the actual target file is untouched and the symlink is silently converted to a divergent regular file. The user's dotfiles repo and live config now disagree with no error anywhere — classic silent data corruption from a coding agent.


**建议：** In LocalEditOperations/LocalWriteOperations, resolve symlinks before writing (`URL.resolvingSymlinksInPath()`), or write in place via `FileHandle`/`open(path, O_WRONLY|O_TRUNC)` like pi's fs.writeFile. If atomic replacement is desired for crash safety, resolve the final target first and rename over that resolved path.

### H8. grep walks the entire tree including .git and node_modules, reads every file fully into memory, and the advertised glob filter is never applied

`Sources/KWWKAgent/GrepTool.swift:81` · 性能


**证据：** collectFiles uses `fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey])` with no `.skipsHiddenFiles`, no `skipDescendants()`, and no ignore rules, then materializes the full file list before any matching. The scan loop (line 47) does `Data(contentsOf: fileURL)` + full UTF-8 decode + `components(separatedBy: "\n")` for every file — including .git pack files and binaries, whose bytes are fully read from disk before the decode fails. The tool schema declares `glob` and `context` parameters (lines 100, 104) and GrepParams carries them (CodingTools.swift:99,102), but the execute closure never extracts them and LocalGrepOperations never uses them, so every grep is an unfiltered whole-tree scan. The pi reference implementation shells out to ripgrep and documents "Respects .gitignore" (pi-mono/packages/coding-agent/src/core/tools/grep.ts:130).


**影响：** In any real project (a node_modules tree of 100k+ files, a .git directory with multi-hundred-MB packfiles), a single model-issued grep reads gigabytes from disk and holds each file's full contents in memory, taking tens of seconds per call — and the model calls grep constantly. Because the file list is fully collected up front, even a `limit: 5` query still enumerates every path.


**建议：** Prune during enumeration: skip `.git`, `node_modules`, and other VCS/dependency directories via `enumerator.skipDescendants()` (or honor .gitignore like pi's ripgrep path). Apply the declared `glob` parameter to filter candidate files. Stream files line-by-line (or at least skip files whose first bytes look binary) instead of `Data(contentsOf:)` on everything, and interleave matching with enumeration so `limit` can stop the walk early.

### H9. SessionRecorder.ensureCreated() truncates an existing session file, destroying resumed history if called on the obvious path

`Sources/KWWKAgent/SessionRecorder.swift:53` · SDK DX — KWWKAgent


**证据：** ensureCreated() unconditionally calls store.create: `_ = try? await store.create(id: sessionId, cwd: cwd, ...)`. SessionStore.create (SessionStore.swift:311-325) is documented "Overwrites any existing file for the same id" and does `try data.write(to: try path(for: id), options: .atomic)` with only the header line — replacing the entire JSONL log. Every in-house caller must remember the guard the CLI uses (CodingTUI.swift:83 `if !resolvedResume.resumed { await initialRecorder.ensureCreated() }`); Headless.swift:85 repeats the same guard.


**影响：** An SDK user resuming a session (`resolveResume(.id(x))` → `SessionRecorder(persistedCount: loaded.persistedCount)`) who then calls `ensureCreated()` — the name says "ensure", implying idempotence, and the doc says "Call once before the first run" — silently wipes the entire persisted transcript, leaving a header-only file. The recorder's non-zero persistedCount then also suppresses re-persisting the seeded messages, so the history is unrecoverable.


**建议：** Make ensureCreated() create-if-missing (the fileExists check already used by SessionStore.append/setTitle), or have SessionStore.create throw/skip when the file exists and add a separate `recreate`. Alternatively fold the `resumed` guard into the recorder so callers cannot get it wrong.

### H10. Manual /compact runs with no busy gate: a prompt submitted during the compact round-trip gets its turn clobbered when the compactor overwrites agent.state.messages

`Sources/KWWKCli/BuiltinSlashCommands.swift:689` · TUI 用户体验


**证据：** handleCompactCommand awaits performCompact → AgentContextCompactor.compactAgent, which does its LLM summarize via agent.streamForCompaction (Agent.swift:216) — a path that never calls state.setStreaming(true) (only runLifecycle at Agent.swift:473 does) and never emits .compactStart (only the auto path at Agent.swift:529 does). The Enter handler's busy gate is `let busy = agent.state.isStreaming || isAutoCompacting` (CodingTUI.swift:696), and isAutoCompacting is set only by the .compactStart event (CodingTUI.swift:486). So during a manual /compact the TUI reports idle: the user can submit a prompt, agent.prompt() starts streaming, and when the compact finishes compactAgent executes `agent.state.messages = replacement.messages` (AgentContextCompactor.swift:104), replacing the transcript out from under the in-flight turn. There is also zero progress feedback: the state line stays at the idle hint and the "summarizing N messages…" notify prints only AFTER the compact completed (BuiltinSlashCommands.swift:705), and Esc cannot cancel it (the Esc binding checks agent.state.isStreaming, which is false).


**影响：** On a long transcript /compact takes tens of seconds with the UI looking completely idle. A user who types /compact and then continues prompting (the natural thing to do when nothing indicates work in progress) has their new turn's messages silently discarded or interleaved with the summary when the compactor's assignment lands — lost user input plus an inconsistent context sent to the model on the next request.


**建议：** Before awaiting performCompact, set the same busy state the auto path uses (flip isAutoCompacting / frameMode = .compacting and requestRender so the spinner shows), and have the Enter handler treat that as busy so prompts queue via steer instead of starting a turn. Alternatively emit .compactStart/.compactEnd from compactAgent itself so both paths share one signal. Print the "summarizing…" notice before the await, not after.


---

## MEDIUM（33 条）

### M1. APIRegistry's flat fallback can route a model to a provider holding a different vendor's API key and send that key to the model's foreign baseUrl

`Sources/KWWKAI/APIRegistry.swift:73` · 副作用/全局状态 ·（对抗验证后降级）


**证据：** `provider(scope:api:)` returns `scoped[scope]?[api] ?? providers[api]` — when a model's `provider` scope has no registration, dispatch silently falls back to whatever flat provider owns the wire `api`, with no check that the flat provider belongs to that vendor. Providers then build the request URL from the model, not from their own configuration: AnthropicProvider.swift:74-77 uses `model.baseUrl` and lines 103-105 attach `defaultAPIKey` via `x-api-key`. So a flat `AnthropicProvider(defaultAPIKey: <ANTHROPIC_API_KEY>)` (registered unscoped by registerBuiltins in RegisterBuiltins.swift:41-44 or by the CLI env path in AuthResolver.swift:490) will serve any model with `api: "anthropic-messages"` — including catalog models whose provider is "github-copilot" with `baseUrl: api.individual.githubcopilot.com` — POSTing the Anthropic key to that third-party host. The same pattern applies to OpenAICompletionsProvider + openrouter-catalog models (OpenAI key sent to openrouter.ai).


**影响：** An SDK embedder (e.g. the OpenBridge app) registers builtins with an Anthropic API key, then calls the top-level `stream(model:)` with a catalog model from another provider that shares the wire protocol. Instead of `ProviderNotFoundError`, the request silently transmits the user's Anthropic secret key to a different company's endpoint. Secret exfiltration to an unintended host, with no error and no log.


**建议：** Gate the flat fallback: only fall back when `model.provider` matches the vendor the flat provider was registered for (record a provider/vendor tag at registration), or when the model's baseUrl host matches the provider's defaultBaseURL. Otherwise throw ProviderNotFoundError so mis-scoped models fail loudly instead of leaking credentials.

### M2. CancellationHandle.cancel() is only polled between SSE events, so cancelling a stalled stream never aborts the HTTP request and the stream never ends

`Sources/KWWKAI/AnthropicProvider.swift:191` · SDK DX — KWWKAI ·（对抗验证后降级）


**证据：** The Anthropic drive loop checks `if state.signal?.isCancelled == true` only after `for try await sse in events` yields an event (line 190-196). Grep confirms the same polled pattern in BedrockProvider.swift:187, GoogleGeminiProvider.swift:138, OpenAICompletionsProvider.swift:160, and OpenAIResponsesProvider SSE path; only the Responses WebSocket path registers `options?.cancellation?.onCancel { connection.close() }` (OpenAIResponsesProvider.swift:281). CancellationHandle.onCancel exists precisely for eager abort but no SSE provider uses it to cancel the in-flight request.


**影响：** The user hits Esc / the app calls handle.cancel(reason:) while the connection is stalled or the model is between events. Nothing happens: the socket stays open, `stream.result()` never resolves, and combined with the non-cancellable `next()` (previous finding) there is no way to reclaim the task. The advertised 'AbortSignal analog' silently does not abort.


**建议：** In each provider's run(), register `options?.cancellation?.onCancel { ... }` that cancels the byte stream / URLSession task (the HTTPClient stream already cancels the task on termination via onTermination), then emit the .aborted error immediately rather than waiting for the next SSE event.

### M3. AnthropicProvider maps 'refusal' / 'sensitive' / unknown stop reasons to .stop, reporting a refused response as a successful completion

`Sources/KWWKAI/AnthropicProvider.swift:780` · 正确性 — KWWKAI


**证据：** `mapStopReason` handles only end_turn/max_tokens/tool_use/stop_sequence and has `default: return .stop`. pi's anthropic.ts:1190-1208 maps `"refusal" → "error"` and `"sensitive" → "error"`, and throws on unknown values so new API stop reasons are surfaced rather than silently absorbed.


**影响：** When Claude refuses or a safety filter fires, the stream ends with `.done(reason: .stop)` and an (often empty or partial) assistant message that looks like a normal turn. The agent loop proceeds as if the model completed successfully — no retry, no error surfaced to the user — and the bogus turn is persisted into the transcript for replay.


**建议：** Map `refusal` and `sensitive` to `.error` (setting `errorMessage`), and treat unknown stop reasons conservatively (log verbose + map to `.error` or at least surface the raw value) instead of defaulting to `.stop`.

### M4. Anthropic stream that closes without message_stop finalizes as a successful .done(.stop) instead of an error

`Sources/KWWKAI/AnthropicProvider.swift:313` · 正确性 — KWWKAI


**证据：** After the event loop, the comment says "Upstream closed without message_stop." and the code runs `let final = state.finalize(); out.push(.done(reason: final.stopReason, message: final))` — `state.stopReason` is initialized to `.stop` and is only changed by a `message_delta`, so a clean half-close mid-message yields `.done(.stop)`. The sibling OpenAICompletionsProvider explicitly guards this case (`validateAndFinish`: "Stream ended without finish_reason" → `.error`, lines 325-332), so the codebase already treats premature EOF as an error elsewhere.


**影响：** If a proxy or the server cleanly closes the SSE connection mid-generation (no transport error thrown), the truncated assistant message is reported as a normal successful stop; the agent loop will not retry and persists an incomplete turn as if the model finished.


**建议：** Track whether `message_stop` (or an `error` event) was seen; if the loop exits without one, finish with `.error` ("stream ended before message_stop") the same way OpenAICompletionsProvider validates a missing finish_reason.

### M5. Provider stream state re-parses the full accumulated tool-call JSON with a fresh JSONDecoder on every delta, giving O(n^2) work while a tool call streams

`Sources/KWWKAI/AnthropicProvider.swift:739` · 性能


**证据：** Every delta event pushes `partial: state.snapshot()` (e.g. toolCallDelta at line 260, textDelta at 238). AnthropicStreamState.snapshot() (lines 730-758) rebuilds the message and, for each `.toolUse` block, runs `json.data(using: .utf8)` + `try? JSONDecoder().decode(JSONValue.self, ...)` on the entire accumulated (usually still-incomplete) argument buffer — a full UTF-8 conversion and a parse attempt per delta, per block, with a new JSONDecoder allocation each time. OpenAICompletionsProvider has the identical pattern (snapshot -> parseArguments, lines 1123-1186), as does OpenAIResponsesProvider.


**影响：** Streaming a `write` tool call whose arguments embed a 50KB file arriving in ~500 deltas performs ~500 parse attempts over an average of 25KB each — roughly 12.5MB of cumulative JSON scanning for one tool call, on the token hot path. Multi-tool turns are worse: deltas for tool #2 re-parse tool #1's complete JSON too. This is pure waste since nearly all consumers ignore the partial's parsed arguments until toolCallEnd.


**建议：** In snapshot(), represent in-progress tool calls with the raw JSON string (or an empty-object placeholder) and parse exactly once in finishBlock/finalize; alternatively cache the parsed value per block keyed by buffer length so unchanged blocks are never re-parsed. Reuse a single static JSONDecoder.

### M6. AssistantMessageStream iteration is not cancellation-aware: a consumer task that gets cancelled while awaiting the next event hangs until the producer pushes or ends

`Sources/KWWKAI/AssistantMessageStream.swift:91` · SDK DX — KWWKAI ·（对抗验证后降级）


**证据：** StreamState.nextEvent() suspends with `await withCheckedContinuation { ... eventWaiters.append(cont) ... }` (lines 90-107) and awaitResult() does the same (lines 109-120). Neither uses withTaskCancellationHandler, and the continuation is Never-failing, so Swift Task cancellation of the consuming task is invisible: the continuation stays queued until the producer's next push()/end().


**影响：** A Swift developer naturally writes `let t = Task { for await ev in stream { ... } }; t.cancel()`. If the provider is stalled (network hang, no SSE events arriving), t.cancel() does nothing — the task never resumes, and any structured-concurrency group waiting on it deadlocks. This directly violates the ecosystem expectation that AsyncSequence iteration responds to task cancellation (URLSession.bytes, AsyncStream, AsyncChannel all do).


**建议：** Wrap the suspension in withTaskCancellationHandler and, on cancellation, remove the waiter and resume it with nil (iteration) — or back StreamState with AsyncStream/AsyncThrowingStream continuations, which are cancellation-aware for free. Document whether ending iteration early also aborts the underlying request.

### M7. EnvAPIKeys functions default env to [:] so calls like EnvAPIKeys.apiKey(for: "openai") silently always return nil

`Sources/KWWKAI/EnvAPIKeys.swift:81` · SDK DX — KWWKAI


**证据：** `public static func apiKey(for provider: String, env: [String: String] = [:]) -> String?` — same `env: [String: String] = [:]` default on foundEnvVars (line 74), hasBedrockAuth (line 91), configuredProviders (line 104), firstValue (line 112), azure (line 144), cloudflare (line 182). With the default, every function is a guaranteed no-op (empty dict has no keys).


**影响：** The type is named EnvAPIKeys and pi's env-api-keys.ts reads process.env, so a consumer writing `EnvAPIKeys.apiKey(for: "anthropic")` compiles, runs, and always gets nil — they then debug a mysterious 'no provider configured' state. An always-wrong default is worse than no default: it converts a forgotten argument into silent misbehavior instead of a compile error.


**建议：** Drop the default value (force callers to pass a snapshot, keeping the no-hidden-env-reads property), or default to ProcessInfo.processInfo.environment and document the read. Either is defensible; the empty-dict default is not.

### M8. HTTPClient protocol bakes byte-at-a-time AsyncThrowingStream<UInt8> into the public extension point, with a comment that mis-states its copying and backpressure behavior

`Sources/KWWKAI/HTTPClient.swift:153` · SDK DX — KWWKAI


**证据：** The public protocol requires `AsyncThrowingStream<UInt8, Error>` (line 16). The delegate feeds it with `for byte in data { cont.yield(byte) }` (line 158) under the comment '`yield(contentsOf:)` on a Data ... yields without copying and keeps the stream back-pressured' — but the code doesn't call yield(contentsOf:), it yields one element per byte, and AsyncThrowingStream's default buffering policy is .unbounded, so urlSession(_:didReceive:) enqueues the entire chunk regardless of consumer speed: there is no backpressure at all.


**影响：** Every custom HTTPClient a consumer writes (proxy, mock, retry wrapper) is forced into per-byte streaming — one continuation enqueue + one await-path element per byte, easily millions of operations for an image-bearing response, and HTTPClient.request() re-assembles Data one appended byte at a time (line 254). The misleading comment also tells implementers the contract provides backpressure when it does not.


**建议：** Change the protocol to stream Data chunks (AsyncThrowingStream<Data, Error>) and adapt SSEParser to consume chunks; fix or delete the incorrect comment. This is a small pre-1.0 break that removes a permanent per-byte tax from the public contract.

### M9. HTTP body streaming yields one AsyncThrowingStream element per byte, making SSE consumption cost ~1000x more than chunk-level delivery

`Sources/KWWKAI/HTTPClient.swift:158` · 性能 ·（对抗验证后降级）


**证据：** StreamingDelegate.urlSession(_:dataTask:didReceive:) does `for byte in data { cont.yield(byte) }` into an `AsyncThrowingStream<UInt8, Error>`. The comment claims "yields without copying and keeps the stream back-pressured", but each yield individually locks the stream's internal state and buffers one element (the default buffering policy is unbounded, so there is no back-pressure either). The consumer side (SSEParser.swift:96 `for try await byte in bytes { chunk.append(byte) ... }`) pays one async-iterator hop plus one Array append per byte, and the non-streaming helper `request()` (HTTPClient.swift:254) does `for try await byte in stream { buffer.append(byte) }`.


**影响：** Every streamed LLM response is shuttled through the pipeline byte-by-byte: a 200KB response body becomes ~200,000 lock-protected yield calls plus ~200,000 awaits, instead of a few hundred Data-chunk events. This burns CPU on the hot token-streaming path of every single turn, and the same per-byte loop makes one-shot requests (OAuth, model catalogs) needlessly slow for large bodies.


**建议：** Change the stream element type to Data (or [UInt8]) and yield the whole `didReceive data:` chunk once (`cont.yield(data)`). Update SSEParser/parseSSE to ingest chunks (it already has an `ingest(bytes: Data)` entry point) and split on newlines inside the chunk. Consider a bounded buffering policy if back-pressure is actually desired.

### M10. OAuthStore silently discards an unreadable/corrupt store at init, and the next set() overwrites the file — destroying all stored logins with no error surfaced

`Sources/KWWKAI/OAuth.swift:114` · SDK DX — KWWKAI


**证据：** init: `if isPersistent, let data = try? Data(contentsOf: self.url), let decoded = try? JSONDecoder().decode(...) { self.credentials = decoded } else { self.credentials = [:] }` (lines 114-120). Any decode failure (one malformed entry, partial write, permissions) yields an empty in-memory store; persist() (line 148) then writes that empty/partial state back over ~/.kwwk/oauth.json atomically on the next set()/remove(). The code's own comment on OAuthCredentials.init(from:) (lines 28-31) acknowledges this exact failure mode but only fixes the missing-`extras` case.


**影响：** A user with three OAuth logins hand-edits oauth.json and introduces a typo in one entry; the next kwwk run sees an empty store, prompts them to log in to one provider, and set() persists — wiping the refresh tokens for the other two providers with no warning. Refresh tokens are not recoverable.


**建议：** Make the load failure loud: either a throwing `OAuthStore.load(url:)` factory, or record a `loadError` and refuse to persist() over a file that existed but failed to decode (e.g. rename it to oauth.json.corrupt first). Decode per-entry so one bad record doesn't drop the rest.

### M11. OAuthManager.resolver() swallows every refresh error with try?, degrading expired-token failures into anonymous requests and confusing 401s

`Sources/KWWKAI/OAuth.swift:218` · SDK DX — KWWKAI


**证据：** `return { model, _ in ... return try? await manager.resolvedAuth(for: oauthId) }` (lines 214-220). A failed refresh (revoked token, network down, OAuthError.refreshFailed) becomes nil; in AnthropicProvider.run the nil resolvedAuth falls through to `options?.apiKey ?? defaultAPIKey` (AnthropicProvider.swift:104) which is typically nil in the OAuth setup, so the request goes out with no auth header at all.


**影响：** A user whose Claude OAuth refresh token was revoked sees 'Anthropic returned status 401 — authentication_error' with zero indication that the actual failure was the OAuth refresh call, whose error text (OAuthError.refreshFailed with the token endpoint's body) was thrown away. Debugging requires reading library source.


**建议：** Propagate the failure: make the resolver signature `async throws -> ResolvedProviderAuth?` (or log through StreamOptions.onVerbose / a callback) so the provider can emit the refresh error into the stream's .error event instead of sending an unauthenticated request.

### M12. ~/.kwwk/oauth.json is momentarily world-readable on first creation and the 0600 lockdown is silently best-effort

`Sources/KWWKAI/OAuth.swift:157` · 副作用/全局状态


**证据：** `persist()` writes via `try data.write(to: url, options: .atomic)` and only afterwards runs `try? FileManager.default.setAttributes([.posixPermissions: 0o600], ...)`. I verified empirically that a fresh file created by `Data.write(.atomic)` under the default umask gets mode 0644. So on the very first `/login` (and any re-creation after deletion) the file containing OAuth access + refresh tokens and stored API keys is world-readable until the chmod lands; if `setAttributes` fails or the process dies in between, it stays 0644 forever because the failure is swallowed by `try?`. The pi reference sets the mode at write time: coding-agent/src/migrations.ts:69 `writeFileSync(authPath, ..., { mode: 0o600 })` and auth-storage.ts chmods unconditionally on every save. (The 0700 directory mitigates the default `~/.kwwk` case, but callers can pass any `url` — e.g. a store in a shared or pre-existing 0755 directory gets no protection.)


**影响：** On a multi-user machine or when an embedder points OAuthStore at a directory that already exists with default permissions, refresh tokens (long-lived account credentials) are readable by other local users during the race window, or permanently if the silent chmod fails.


**建议：** Create the file with 0600 before writing (e.g. `open(path, O_CREAT|O_EXCL, 0o600)` or FileManager.createFile(attributes:)), or write to a 0600 temp file and rename over the destination; make the permission set a hard error rather than `try?`.

### M13. OpenAI Responses provider requests encrypted reasoning (`include: reasoning.encrypted_content`) but never captures or replays it

`Sources/KWWKAI/OpenAIResponsesProvider.swift:770` · 正确性 — KWWKAI


**证据：** `makeRequest` sets `root["include"] = .array([.string("reasoning.encrypted_content")])` with the comment "Required so encrypted reasoning round-trips across turns" (line 770), and defaults `store: false` (line 804). But the drive loop's `response.output_item.done` handler for reasoning items only emits `thinkingEnd` (lines 620-623) — it never reads `item["encrypted_content"]` — and `encodeInput` (lines 835-865) encodes assistant messages as only text parts and `function_call` items, dropping thinking blocks entirely. pi persists the full serialized reasoning item in `thinkingSignature` and replays it (`output.push(JSON.parse(block.thinkingSignature))`, openai-responses-shared.ts:173-174) and preserves fc_ item ids via the `callId|itemId` scheme.


**影响：** With `store:false`, reasoning state for GPT-5/Codex models is silently discarded between turns: every request pays for the `include` option yet the model loses its prior chain-of-thought at each tool round-trip, degrading multi-step task quality versus pi. (Hard 400s from OpenAI's reasoning/function_call pairing validation are only avoided because kwwk also omits the fc_ item ids.)


**建议：** Capture the full reasoning item (including `encrypted_content` and item `id`) from `response.output_item.done`, store it on the thinking block's `thinkingSignature` (serialized JSON, as pi does), and re-emit it in `encodeInput` for same-model assistant messages.

### M14. OpenAI Responses `response.incomplete` terminal event is unhandled: truncation reports stopReason .stop over HTTP and a spurious transport failure over WebSocket

`Sources/KWWKAI/OpenAIResponsesProvider.swift:648` · 正确性 — KWWKAI


**证据：** The drive switch handles `response.completed`, `response.failed`, `response.error`, and `error` but not `response.incomplete` (OpenAI's terminal event when `max_output_tokens` is hit). The stream then ends without a terminal case: on HTTP (`finishOnStreamEnd: true`, lines 677-687) the message is finished with the default `state.stopReason = .stop`; on WebSocket the run lands in the `endedWithoutTerminalEvent` branch (lines 353-390), which calls `session.recordWebSocketFailure(...)` and — because `progress.hasReceivedEvent` is true — pushes the error "WebSocket stream closed before response.completed".


**影响：** A merely length-truncated response is misreported: over HTTP the agent sees a clean `.stop` and treats truncated output as a complete answer; over WebSocket the user gets a hard stream error for a normal truncation, and three truncations trip `maxWebSocketFailures`, permanently disabling the WebSocket transport for that session.


**建议：** Add a `case "response.incomplete":` that reads `response.status` / `incomplete_details`, sets `state.stopReason = .length`, and finishes via the same path as `response.completed` (including usage capture and `recordCompletedResponse`).

### M15. README steering example does not compile: steer() takes Message, not UserMessage, and no ergonomic overloads exist

`Sources/KWWKAgent/Agent.swift:225` · SDK DX — KWWKAgent


**证据：** The only signature is `public func steer(_ message: Message)` (same for followUp, line 228). README.md:336 shows `agent.steer(UserMessage(text: "also add tests as you go"))`, which fails to type-check — callers must write `agent.steer(.user(UserMessage(text: ...)))`. pi-mono's Agent accepts `string | AgentMessage | AgentMessage[]` overloads for prompt and plain AgentMessage for steer (packages/agent/src/agent.ts:325-336).


**影响：** The first thing a developer copies from the "Steering a running agent" README section is a compile error; the fix (`.user(...)` wrapping) is non-obvious because UserMessage is the natural type to construct. Every steer/followUp call site pays the wrapping boilerplate.


**建议：** Add `steer(_ text: String)` and `steer(_ message: UserMessage)` conveniences (and the same for followUp), and fix the README snippet.

### M16. Agent's public mutable configuration properties are unsynchronized on an @unchecked Sendable class

`Sources/KWWKAgent/Agent.swift:142` · SDK DX — KWWKAgent


**证据：** `public var sessionId`, `thinkingBudgets`, `maxRetryDelayMs`, `maxTurns`, `toolExecution`, `toolChoice`, `parallelToolCalls`, and all eight hook closures (lines 142-156) are plain stored properties with no lock, on `final class Agent: @unchecked Sendable`. They are read during runs — loopConfig() (line 412) reads them at run start, and builtInBetweenTurnsHook captures `autoCompact`. Contrast AgentState, which routes every field through `lock.withLock`, and the same class's own `listeners`/`activeCancellation` which are lock-protected.


**影响：** The type signature advertises cross-thread use (Sendable, and steer() is documented "from any thread"), but setting e.g. `agent.maxTurns` or `agent.beforeToolCall` from a UI thread while a run executes on another thread is a Swift data race (undefined behavior; existential/closure fields can tear). Developers get no compiler diagnostic because of @unchecked.


**建议：** Protect these vars with the existing NSLock (computed get/set like AgentState), or make them immutable after init and provide an explicit `updateOptions` API with documented run-boundary semantics.

### M17. Foreground bash results bypass truncation: legacy path returns unbounded output, flip path returns up to 1MB verbatim

`Sources/KWWKAgent/BashTool.swift:470` · 正确性 — KWWKAgent


**证据：** runBashLegacy joins full stdout+stderr into the tool result with no cap (`let body = [result.stdout, result.stderr]...joined`), and ForegroundBashExecution.readOutput only caps at `data.prefix(1_000_000)` (line 539) before the whole string is returned as content AND duplicated into `details.stdout`. Nothing downstream applies Truncate to tool results (Truncate.truncateHead is used only by ReadTool).


**影响：** One `cat large.log` or verbose test run injects up to 1MB (legacy: arbitrarily more) into the transcript — twice, since details duplicates content — blowing the context window, triggering immediate auto-compaction, and inflating cost. pi truncates bash output to a bounded head/tail for exactly this reason.


**建议：** Run bash output through Truncate (e.g. tail-biased, ~50KB/2000 lines like the read tool) before building AgentToolResult, keep the full output in the on-disk file, and don't duplicate the full text into details.

### M18. makeCodingAgent silently wires an auto-continue bridge that starts new LLM runs at arbitrary times, and discards the only detach handle

`Sources/KWWKAgent/CodingAgentBuilder.swift:224` · SDK DX — KWWKAgent


**证据：** `_ = await agent.attachBackgroundManager(bgManager, sessionId: sessionId)` — the returned unsubscribe closure (the only way to detach the bridge, Agent+Background.swift:118-123) is thrown away. BackgroundAgentBridge.onNotification (Agent+Background.swift:48-63) steers a user message and, when the agent is idle, fires `Task { try? await ref?.continue() }` — a brand-new model run.


**影响：** For an SDK caller, `try await agent.prompt(...)` returning does not mean the agent is done: a background bash task (including one auto-flipped on the 120s foreground timeout) completing minutes later spontaneously triggers a new billable LLM turn on an agent the caller may no longer be observing. There is no public API to detach; the only recourse is `abortAndKillBackgroundTasks()`, which also kills the tasks. Conflicts with the stated goal of "no surprising side effects".


**建议：** Return the detach handle from makeCodingAgent (e.g. a small `CodingAgent` result type bundling agent + detach), or make auto-continue-when-idle an explicit opt-in flag, and document the spontaneous-run behavior prominently.

### M19. Session identity is duplicated across Agent.sessionId, tool closures, recorder, and background attachments with no coherent way to rotate it

`Sources/KWWKAgent/CodingAgentBuilder.swift:250` · SDK DX — KWWKAgent


**证据：** buildCodingToolList bakes `sessionId` into the bash/task_status/wait_task tool closures at construction time (lines 250-263); attachBackgroundManager captures it again (CodingAgentBuilder.swift:224); `Agent.sessionId` is a separate public mutable var consumed per-run by the loop (AgentLoop.swift:479,491) and by closeSession(). Setting `agent.sessionId` re-scopes only provider auth/streams — tools and the notification bridge keep the old id. The CLI's own `/new` and `/resume` (CodingTUI.swift performNewSession, SessionSlashCommands.swift:85-101) swap only the recorder's id and never touch agent.sessionId or the tools.


**影响：** The obvious call — mutate the public `agent.sessionId` to move an agent to a new session — silently half-works: background tasks are still tagged and killed under the old id, subagent child ids still prefix the old id, and `closeSession()` closes the new id while provider resources from earlier turns were opened under the old one. Developers cannot implement /new-style session rotation correctly with the public surface.


**建议：** Either make sessionId immutable and per-agent (document "one Agent = one session"), or thread it through a shared mutable box that tools and bridges read at call time, exposing a single `agent.rotateSession(to:)`.

### M20. FileMutationQueue's inode-based keying is defeated by the tools' own atomic writes, breaking per-file serialization

`Sources/KWWKAgent/FileMutationQueue.swift:47` · 正确性 — KWWKAgent


**证据：** `queueKey(for:)` returns "inode:st_dev:st_ino" when the file exists. But LocalEditOperations/LocalWriteOperations write with `Data.write(to:options:.atomic)` (EditTool.swift line 24, WriteTool.swift line 17), which writes a temp file and rename(2)s it over the path — allocating a NEW inode on every mutation. So after edit A completes, a chained edit B is still running under key inode:X while a newly arriving edit C stats the file, gets inode:Y, finds no inflight entry, and runs concurrently with B.


**影响：** With the loop's default `toolExecution: .parallel`, overlapping edit/write calls to the same file across turns can interleave read-modify-write: one edit's changes are silently lost or `applyEdits` corrupts/fails on stale content. Additionally, `.atomic` rename-over-path replaces a symlink with a regular file — editing a file through a symlink clobbers the link and never touches the real target, directly contradicting the queue's "keeps symlink siblings on the same queue" design comment.


**建议：** Key the queue by canonical resolved path (realpath) instead of inode, and write via truncate-and-write on the resolved target (or FileHandle) rather than `.atomic` rename, so both serialization and symlinks survive.

### M21. find/Glob recompiles the glob regex for every visited file and walks .git/node_modules unpruned

`Sources/KWWKAgent/Glob.swift:7` · 性能


**证据：** Glob.matches does `path.range(of: regex, options: .regularExpression)`, which compiles a fresh NSRegularExpression on each call, and it is invoked once per enumerated file inside Glob.expand's loop (line 55). patternToRegex is also re-run per file. Like GrepTool, `expand` uses `fm.enumerator` with no pruning of .git or node_modules (line 45). pi's find explicitly ignores `**/node_modules/**` and `**/.git/**` (pi-mono/.../find.ts:168).


**影响：** A `find **/*.swift` in a repo with 200k files under node_modules/.git performs 200k regex compilations plus 200k directory-tree stats — multiple seconds of pure overhead per tool call for work that pruning plus a single pre-compiled NSRegularExpression would reduce by orders of magnitude.


**建议：** Compile the pattern once (NSRegularExpression instance) before the enumeration loop and reuse it, and prune well-known ignore directories via `skipDescendants()` during enumeration (ideally honoring .gitignore).

### M22. Grep tool advertises `glob` and `context` parameters that are silently ignored

`Sources/KWWKAgent/GrepTool.swift:150` · 正确性 — KWWKAgent


**证据：** The tool schema declares `"glob": ["type": "string"]` and `"context": ["type": "number"]` (lines 101, 104), and GrepParams has `glob`/`context` fields (CodingTools.swift lines 99-111), but the execute closure builds `GrepParams(pattern:path:ignoreCase:literal:limit:)` without ever reading obj["glob"] or obj["context"], and LocalGrepOperations never consults `params.glob`/`params.context` either.


**影响：** When the model narrows a search with `glob: "*.swift"` it silently gets matches from every file type (node_modules, binaries-as-UTF8, build output), burning the 50-match limit on noise; requesting `context: 3` yields no context lines. The model receives no error, so it trusts wrong results — exactly the "surprising side effect" class the project wants to avoid.


**建议：** Either implement glob filtering (filter collectFiles via Glob.matches) and context-line output in LocalGrepOperations, or remove the two parameters from the published schema until implemented.

### M23. resolveResume(.id) with an invalid-format id silently substitutes a random fresh session id

`Sources/KWWKAgent/SessionResume.swift:91` · SDK DX — KWWKAgent


**证据：** `case .id(let id): guard SessionStore.isValidSessionId(id) else { return ResolvedResume(sessionId: freshId) }` — freshId is a random UUID. The very next branch honors caller intent for an unknown-but-valid id ("create a new session under that id so the caller's intent ... is honored", line 104-107), but a validation failure (e.g. `--session "my session"` with a space, or a leading dot) discards the requested id without any signal: `resumed` is false either way and no error is thrown.


**影响：** A user or SDK caller asking for a specific named session gets a silently different, randomly-named session; subsequent runs with the same flag mint yet another id each time, scattering transcripts across UUID files with no explanation. The API is documented "Never throws", so the caller cannot distinguish "typo in id" from "fresh session as requested".


**建议：** Surface invalid ids: either throw SessionStoreError.invalidId from a throwing variant, or add a `rejectedId`/reason field on ResolvedResume so callers can warn. Silent degradation should be reserved for unreadable files, not caller typos.

### M24. SessionStore.load silently drops any undecodable entry, so schema drift or corruption loses messages with no diagnostics

`Sources/KWWKAgent/SessionStore.swift:456` · SDK DX — KWWKAgent


**证据：** `guard let data = ..., let entry = try? Self.decoder.decode(Entry.self, from: data) else { // Skip malformed/partial trailing lines ... continue }`. The rationale covers a crash-truncated trailing line, but the catch-all applies to every line: an entry written by a newer build (new Message block type, renamed key) fails decode and vanishes. The file-level `version` is only checked on the header (line 496), and entries carry no version. Contrast Skills, which reports every skipped file via SkillDiagnostic.


**影响：** After an upgrade/downgrade or partial corruption mid-file, `--resume` reconstructs a context with messages silently missing from the middle of the conversation — potentially breaking user/assistant alternation that providers reject — and neither the developer nor the user gets any indication that data was skipped.


**建议：** Return skipped-line diagnostics (count + line numbers) on LoadedSession, and restrict the lenient path to the final line of the file; a mid-file decode failure should at least be observable.

### M25. Session listing fully JSON-decodes every message of every session file just to count messages, and --continue startup pays for all of it

`Sources/KWWKAgent/SessionStore.swift:547` · 性能


**证据：** info(at:) reads each session file entirely into a String and runs `Self.decoder.decode(Entry.self, ...)` on every line — decoding every message body (full transcripts, embedded base64 images) — only to increment `messageCount` and pick up the last meta values. list() does this for every .jsonl file in the directory, and latestForCwd (line 581) calls list(), so the `--resume`/`--continue` startup path and the session picker replay the user's entire on-disk history.


**影响：** With 100 accumulated sessions averaging 2MB each, opening the CLI with --continue parses ~200MB of JSON (including image attachments) before the first prompt renders; the /resume picker does the same on each open. Cost grows without bound as sessions accumulate.


**建议：** For listing, avoid full Entry decodes: count lines and decode only the header plus a lightweight probe of `"type":"meta"` lines (e.g. match the type field before decoding, or scan the file backwards for the last meta). Alternatively maintain a small sidecar index (id, cwd, updatedAt, count, title) updated on append.

### M26. TmuxSessionManager.runProcessSync has the same read-after-wait pipe deadlock, and it hangs the whole actor on large capture-pane output

`Sources/KWWKAgent/TmuxSessionManager.swift:273` · 正确性 — KWWKAgent


**证据：** `process.waitUntilExit()` (line 273) runs before `stdoutPipe.fileHandleForReading.readDataToEndOfFile()` (line 274). `capture(_:lines:)` passes a model-controlled `lines` straight to `capture-pane -S -<lines>` (TmuxTool.swift lines 195-200 accept any Int with no cap), and runTmuxSync executes synchronously on the actor.


**影响：** The model calling `tmux capture` with a large `lines` value (e.g. 10000 lines of a busy pane) makes tmux emit more than the ~64KB pipe buffer; tmux blocks writing, kwwk blocks in waitUntilExit, and because the call is synchronous actor-isolated work, every subsequent tmux tool call (and the cooperative-pool thread) is wedged forever — no timeout ever fires.


**建议：** Drain stdout/stderr concurrently with the wait (readabilityHandler or background readToEnd started before waitUntilExit), and clamp/truncate the `lines` argument in TmuxTool.

### M27. tmux tool panes inherit the full host process environment, bypassing the SDK's explicit bashEnvironment isolation guarantee

`Sources/KWWKAgent/TmuxSessionManager.swift:259` · (补录)


**证据：** `runProcessSync` builds a `Process()` and never sets `process.environment`, so the tmux server spawned by the first `new-session` inherits kwwk's complete environment, and every pane command inherits it from the server. This defeats the deliberate design elsewhere: CodingAgentConfig.bashEnvironment has no default and is documented "Exact environment passed to bash tool processes. Empty by default so SDK callers do not expose host process environment variables" (CodingAgentBuilder.swift:80-82), and BashTool.swift:83 sets `process.environment = environment` explicitly.


**影响：** A host app (or the kwwk CLI itself, which runs with ANTHROPIC_API_KEY / OPENROUTER_API_KEY etc. exported) carefully passes a minimal bashEnvironment, but as soon as the model uses the tmux tool, every command it runs in a pane can read the host's secrets via `env`, and those secrets can then land in captured pane output inside the session transcript.


**建议：** Accept an explicit environment in TmuxSessionManager (like BashToolOptions does), set it on the tmux server Process, and/or use `tmux new-session -e`/`set-environment` so pane processes see only the caller-approved variables.

### M28. Scalar-summed width table misses modern emoji (U+1FA70–1FAFF), ZWJ sequences, and skin-tone composition, misaligning the prompt box and cursor

`Sources/KWWKCli/ANSI.swift:107` · (补录)


**证据：** columnWidth's wide table ends its emoji coverage at (0x1F900, 0x1F9FF); the entire Symbols & Pictographs Extended-A block U+1FA70–1FAFF (🫠 🩷 🪄 🫡 — very common emoji) falls through to `return 1` while terminals render them at width 2. InputComponent.charColumnWidth (InputComponent.swift:523) sums per-scalar widths, so a ZWJ family emoji 👨‍👩‍👧 counts 2+0+2+0+2=6 and a skin-toned 👍🏽 counts 4 (modifier U+1F3FD is in the 1F300–1F64F wide range), where terminals render both at 2. pi-tui instead segments graphemes and applies an RGI-emoji regex → width 2 per cluster (utils.ts:155-176).


**影响：** Typing or pasting any of these emoji into the input box shifts the prompt box's right border (Box.pad/Box.row pad by the wrong visible width), soft-wraps at the wrong column, and parks the hardware cursor — the IME anchor — on the wrong cell, so CJK IME candidate windows and the visible caret drift from the actual insertion point. Same drift affects committed transcript lines that carry emoji.


**建议：** Add the missing wide ranges (0x1FA70–0x1FAFF, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F191–0x1F19A, 0x1F6D5–…) and, in InputComponent/visibleWidth, measure per grapheme cluster (Character) rather than per scalar: if the cluster contains ZWJ or an emoji base + modifier/VS16, treat it as width 2, mirroring pi-tui's graphemeWidth.

### M29. A stale clipboard image silently wins over genuinely pasted text — the paste body is discarded whenever NSPasteboard holds an unseen image

`Sources/KWWKCli/CodingTUI.swift:1419` · TUI 用户体验


**证据：** handlePastedBody checks the pasteboard first: `if let image = ClipboardImageReader.readIfPresent() { … input.insert(token); return }` — the bracketed-paste body is unconditionally thrown away when an image is found ("the terminal's paste body is typically empty or garbage in this case, so we discard it"). But bracketed paste also fires for text that never came from NSPasteboard: tmux paste-buffer (prefix-]), iTerm paste history, and Finder drag-and-drop of a file path all send a meaningful body. ClipboardImageReader only dedupes by changeCount (Clipboard.swift:34), so the first such paste after any image copy takes this branch.


**影响：** User screenshots something (image lands on the clipboard), then drags a file from Finder into the terminal or pastes a tmux buffer: kwwk discards the real pasted text and attaches the unrelated stale screenshot as `[image #N]`. The user's path/text is lost and a wrong image is silently queued for the model.


**建议：** Only prefer the pasteboard image when the paste body is empty or degenerate (e.g. blank/whitespace or a few control bytes). When the body carries real text, route it through the normal path/text logic and leave the pasteboard untouched.

### M30. Bracketed-paste accumulation is O(n²) with a per-byte Array allocation, freezing the whole TUI on large pastes

`Sources/KWWKCli/StdinBuffer.swift:130` · TUI 用户体验


**证据：** While a paste is in flight, every feed() re-runs takeOne → findBracketedPasteEnd, which rescans the entire buffer from index 0: `for i in 0...(buffer.count - end.count) { if Array(buffer[i..<(i + end.count)]) == end { … } }` — allocating a fresh 6-element Array per byte position on every chunk. A paste delivered in 4KB read chunks (RawStdin reads 4096 bytes, StdoutTerminal.swift:107) rescans ~n²/2 positions total. All of this runs on the main dispatch queue, the same queue that renders frames and handles keys. pi-tui's stdin-buffer instead keeps a pasteMode flag and does an incremental indexOf on the growing buffer (stdin-buffer.ts:315-325).


**影响：** Pasting a large block (a long log, a big diff, a few hundred KB file) visibly hangs the TUI for seconds to minutes — no keystrokes, no spinner, no render — because the quadratic scan monopolizes the main queue. Pasting big text into the prompt is a core coding-agent workflow (the app even has a pasted-text attachment path designed for exactly this).


**建议：** Track a resume offset (the buffer length already scanned minus 5) and continue the end-marker search from there on each feed; compare bytes in place (buffer[i] == end[0] && … or memcmp-style) instead of materializing an Array per position.

### M31. TUI has no frame diffing or no-op suppression: every agent event, including every token delta, rewrites the entire live zone

`Sources/KWWKCli/TUI.swift:108` · 性能


**证据：** `requestRender()` calls `render()` synchronously with no coalescing, and CodingTUI's subscriber calls `runner.tui.requestRender()` after every event (CodingTUI.swift:530), including `.messageUpdate` deltas that usually change nothing visible (assistant text is committed at newline boundaries, not held in the live zone). render() always re-renders all children, ANSI-truncates every row, and emits rewind + `ESC[2K` + reprint for the full frame. `lastRenderedLines` is stored (line 434) but never read for comparison anywhere in the file — the previous frame is retained and then ignored.


**影响：** At 50-100 stream events/sec with a ~15-row live zone (prompt box + tool slots), the terminal receives ~1-2KB of redundant escape output per token even when the frame is pixel-identical, costing CPU in both kwwk and the terminal emulator and risking visible flicker on slower terminals. During parallel tool execution with partial-result updates, the entire zone is repainted for each tool's update.


**建议：** Compare the newly rendered lines against `lastRenderedLines` and skip the terminal write when identical and no commits are pending (or emit only changed rows). Additionally coalesce bursts by scheduling at most one render per run-loop tick / small interval rather than one per event.

### M32. Every SIGWINCH triggers an unthrottled full-transcript replay of up to 20,000 lines, rebuilt as one giant string per resize step

`Sources/KWWKCli/TUI.swift:211` · 性能


**证据：** handleResize calls fullRepaint "synchronously on every SIGWINCH, no throttle" (comment, lines 208-211). fullRepaint copies `committedLines` (capped at 20,000 lines, line 32) and string-concatenates `"\u{1B}[2K" + line + "\r\n"` for every history line into a single output string before writing (lines 281-283). multiplexerRepaint is worse per step: it re-wraps the entire history through ANSI.wrap (line 346), which allocates `Array(s.unicodeScalars)` per line.


**影响：** With a long session (near the 20k-line cap, ~1.5-2MB of text), an interactive corner-drag emitting ~30 SIGWINCHs/sec forces ~50MB/s of string building and terminal writes plus scrollback-clear escape codes — visible stutter and a pegged core during resize, and inside tmux an additional full re-wrap of history per step.


**建议：** Debounce/coalesce resize repaints (e.g. repaint at most every ~50ms during a burst, with a trailing authoritative repaint), and cap the replayed history to what can plausibly matter (viewport + recent tail) during the drag, replaying full history only on the final settle.

### M33. SIGTERM/SIGINT exit path calls Foundation.exit inside TUIRunner.run, skipping CodingTUI's shutdown — background tasks, tmux socket, and provider session leak

`Sources/KWWKCli/TUIRunner.swift:99` · TUI 用户体验


**证据：** run() ends with `let code = lock.withLock { pendingExitCode } ?? 0; if code != 0 { Foundation.exit(code) }`. The SIGINT/SIGTERM dispatch sources set code 130/143 (TUIRunner.swift:165,168), so any signal-driven exit terminates the process right there. The caller's cleanup in runCodingTUIInternal — `await shutdown()` which runs agent.abortAndKillBackgroundTasks(), agent.closeSession(), and tmuxManager?.teardown() (CodingTUI.swift:994-1013) — only runs after `try await runner.run()` returns normally, which the Foundation.exit call prevents. (Terminal modes themselves are restored: tearDown() runs first.)


**影响：** Kill kwwk with `kill <pid>` (SIGTERM) or deliver SIGINT externally while background tasks are running: the process exits but its spawned background processes keep running and the isolated tmux server/socket is left behind — exactly the leak the shutdown closure documents itself as preventing. Users accumulate orphaned processes after every signal-driven exit.


**建议：** Return the exit code from run() (or store it) and let the caller perform its shutdown before terminating, e.g. `let code = try await runner.run(); await shutdown(); Foundation.exit(code)` — keeping Foundation.exit out of the runner so the API has no hidden process-terminating side effect.


---

## LOW（26 条）

### L1. Top-level stream()/complete() are hardwired to APIRegistry.shared with no registry parameter, unlike registerBuiltins which accepts one

`Sources/KWWKAI/APIRegistry.swift:122` · SDK DX — KWWKAI ·（对抗验证后降级）


**证据：** `public func stream(model:context:options:) async throws` looks up `APIRegistry.shared.provider(scope:api:)` (line 123) with no way to supply another registry, while registerBuiltins takes `registry: APIRegistry = .shared` and its doc comment explicitly advertises 'tests can pass a private APIRegistry() to avoid mutating global state' (RegisterBuiltins.swift:28-29).


**影响：** The advertised isolation escape hatch is half-built: a test or embedding app that registers into a private APIRegistry() cannot use the documented entry points stream()/complete() at all — it must reimplement the scoped-then-flat lookup and the ProviderNotFoundError throw by hand. Meanwhile any code in the process can mutate .shared and change what a library caller's stream() resolves to (hidden global mutable state). pi-mono has the same module-global registry, but it doesn't dangle an instance-registry API that the entry points then ignore.


**建议：** Add `registry: APIRegistry = .shared` parameters to stream() and complete() (and closeProviderSession), or move them onto APIRegistry as instance methods with global free-function wrappers.

### L2. complete() has a split error surface: missing provider throws, but every runtime failure is silently encoded in the returned message's stopReason

`Sources/KWWKAI/APIRegistry.swift:130` · SDK DX — KWWKAI ·（对抗验证后降级）


**证据：** complete() throws ProviderNotFoundError (line 124) yet drains the stream and returns `await s.result()` unconditionally (lines 131-134). Per the APIProvider contract (lines 3-5: providers surface errors 'never via thrown errors'), an auth failure, 400, or network error comes back as a normal-looking AssistantMessage with stopReason == .error and the detail in errorMessage. Nothing forces the caller to inspect it, and ProviderNotFoundError isn't LocalizedError so it also prints as `api("anthropic-messages")`.


**影响：** The obvious consumer code `let msg = try await complete(model: m, context: ctx); print(msg.content)` compiles, 'succeeds', and prints an empty content array on a 401 — the try suggests errors are handled when the dominant failure mode isn't thrown. Every consumer must know to check stopReason == .error/.aborted, which is only documented on a different type.


**建议：** Keep the event-encoded errors for streaming (pi parity), but give complete() an honest contract: either throw a typed StreamFailedError(message:) when stopReason is .error, or add a `try message.get()`-style helper / `completeOrThrow` variant, and document the check prominently on complete().

### L3. AnthropicProvider's doc comment lists OAuth bearer tokens, anthropic-beta headers, and retry as 'non-goals' even though the first two are implemented in this exact file

`Sources/KWWKAI/AnthropicProvider.swift:9` · SDK DX — KWWKAI


**证据：** Lines 9-15: 'Non-goals for this implementation: OAuth bearer tokens, anthropic-beta opt-in headers ... These are tracked in follow-up work'. The same type ships authHeaderBuilder for Bearer auth (line 30, used by ProviderVariants.anthropicOAuth), systemPromptPrefix for OAuth identity (line 35), and an appendBeta() helper stamping extended-cache-ttl / fine-grained-tool-streaming / interleaved-thinking betas (lines 113-139).


**影响：** This is the header documentation a consumer reads first when choosing how to authenticate; it tells them OAuth is unsupported and sends them looking for a nonexistent alternative, when ProviderVariants.anthropicOAuth is the supported path three files away.


**建议：** Rewrite the header to describe the actual capabilities and point to ProviderVariants.anthropicOAuth; keep only genuinely-missing items (e.g. retry-after handling if still absent) in the non-goals list.

### L4. AssistantMessageStream is silently single-consumer and exposes producer push()/end() to consumers with no guard or documentation

`Sources/KWWKAI/AssistantMessageStream.swift:34` · SDK DX — KWWKAI


**证据：** makeAsyncIterator() hands every iterator the same StreamState (line 35), whose nextEvent() destructively pops a shared buffer — two concurrent `for await` loops each receive an arbitrary interleaved subset of events. Meanwhile push() and end() are public (lines 17-25): a consumer calling end() on a provider-owned stream makes all subsequent provider push()/end() calls silently no-ops (StreamState lines 56-59, 75-78). Neither constraint is documented. Additionally, if a caller only awaits result() without iterating, every event (each carrying a full `partial` AssistantMessage snapshot) accumulates in the unbounded buffer.


**影响：** A developer who iterates in one task for UI deltas and iterates again elsewhere (or hands the stream to two observers) gets nondeterministically split events with no error. One accidental end() call on the returned stream truncates the run and freezes result() at a stale message, with the real provider outcome silently dropped.


**建议：** Document single-consumer semantics on the type; consider trapping or asserting on a second makeAsyncIterator(). Separate the producer surface (an internal or provider-facing continuation type) from the consumer-facing stream, mirroring AsyncStream's makeStream(of:) split.

### L5. Gemini and Bedrock discard the HTTP error body on 4xx/5xx, unlike the other providers

`Sources/KWWKAI/GoogleGeminiProvider.swift:113` · 正确性 — KWWKAI


**证据：** On `response.statusCode >= 400` GoogleGeminiProvider emits only "Gemini returned status \(response.statusCode)" without draining the body; BedrockProvider.swift:161-168 does the same ("Bedrock returned status N"). AnthropicProvider (lines 145-167) and both OpenAI providers deliberately read up to 4KB of the error body "so the user has signal whether it's the thinking field, max_tokens, or the proxy rejecting a shape."


**影响：** Gemini's and Bedrock's error bodies carry the actionable message (invalid tool schema field, unsupported thinkingConfig, AccessDeniedException detail). Users debugging a 400 on these two providers only see the bare status code and must resort to packet captures, exactly the DX failure the Anthropic code comments call out.


**建议：** Reuse the `errorBodyPreview(from:)` helper from OpenAICompletionsProvider (or the Anthropic drain pattern) in both providers' >=400 branches.

### L6. HTTPClient byte stream claims back-pressure but is unbounded, and yields one continuation call per byte

`Sources/KWWKAI/HTTPClient.swift:158` · 正确性 — KWWKAI


**证据：** `didReceive data:` does `for byte in data { cont.yield(byte) }` under the comment "yields without copying and keeps the stream back-pressured." Both claims are wrong: `AsyncThrowingStream` is created with the default `.unbounded` buffering policy, so `yield` never suspends and every byte the server sends is buffered if the consumer lags; and yielding per-UInt8 performs a synchronized continuation operation per byte (then `parseSSE` re-iterates the same bytes one at a time), which is a large constant factor on every streamed token.


**影响：** A slow or paused consumer (e.g. the 4096-byte error-preview loops that `break` early in AnthropicProvider.swift:152-155 while the server keeps sending) lets the buffer grow without bound — memory, not back-pressure, absorbs the stream. Per-byte yields also tax the hot streaming path in a project that lists performance as a goal.


**建议：** Change the transport element type to `Data`/`[UInt8]` chunks (yield each `didReceive data:` once) and have `parseSSE`/`parseAWSEventStream` consume chunks; or at minimum set a bounded buffering policy and fix the comment.

### L7. Inconsistent URL casing across the public surface: Model.baseUrl vs ResolvedProviderAuth.baseURL vs provider defaultBaseURL

`Sources/KWWKAI/Model.swift:29` · SDK DX — KWWKAI


**证据：** Model declares `public var baseUrl: String` (Model.swift:29) while ResolvedProviderAuth declares `public var baseURL: String?` (Context.swift:90) and every provider initializer takes `defaultBaseURL: URL` (e.g. AnthropicProvider.swift:21). The Model field is also a String while the provider fields are URL.


**影响：** Consumers constructing models and auth side by side must remember two spellings of the same concept ('baseUrl' compiles on Model, errors on ResolvedProviderAuth, and vice versa), and autocomplete/grep across the codebase splits. Swift API Design Guidelines uniformly uppercase acronyms (URL). Since Model is Codable and baseUrl matches pi's JSON wire key, renaming the property with a CodingKeys mapping preserves compatibility.


**建议：** Standardize on `baseURL` in Swift API (keep the `baseUrl` JSON coding key via CodingKeys), and consider typing it as URL? for parity with the provider constructors — a cheap pre-1.0 cleanup.

### L8. ModelsCatalog silently returns an empty catalog when the bundled models.json is missing or unparseable

`Sources/KWWKAI/ModelsCatalog.swift:37` · SDK DX — KWWKAI ·（对抗验证后降级）


**证据：** loadAll(): `guard let url = Bundle.module.url(forResource: "models", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [:] }` and `guard let root = try? JSONSerialization... else { return [:] }` (lines 36-43). Individual model entries that fail decode are also silently skipped (line 50 `compactMap`-style continue). There is no diagnostic of any kind, and the static `byProvider` caches the empty result for the process lifetime.


**影响：** A consumer embedding KWWKAI in a context where SwiftPM resource bundles are mishandled (static linking, custom packaging, renamed bundle) gets ModelsCatalog.all == [] and ModelsCatalog.model(provider:id:) == nil everywhere. The docs promise '900+ models'; the developer has no signal whether the id is wrong, the provider key is wrong, or the whole resource failed to load.


**建议：** At minimum distinguish 'resource missing/corrupt' from 'empty' — e.g. expose `ModelsCatalog.loadError: Error?` or a `loadCatalog() throws` entry point, and count/report skipped entries. First access is a fine time to fail loudly in debug builds.

### L9. OAuth callback server resolves success for any request hitting the path — even with no query parameters — killing the pending login

`Sources/KWWKAI/OAuthCallbackServer.swift:238` · 正确性 — KWWKAI ·（对抗验证后降级）


**证据：** `CallbackHandler.handle` resolves the flow for any GET whose path matches: it only special-cases an `error` query param; otherwise it runs `write(... status: .ok, html: server.successHTML); server.resolveSuccess(params)` even when `params` is empty (no `code`, no `state`). `resolveSuccess` sets `resolved = true` and calls `stop()`, closing the listener. The `code` check only happens later in `OAuthLogin.loginAnthropic` (line 79), which then throws "callback had no code" — and `waitForCallback()` can never be re-armed (`resolved` is sticky, line 97). Additionally, loginAnthropic's state check is `if let state, state != pkce.verifier` (OAuthLogin.swift:83), so a callback that simply omits `state` bypasses CSRF validation.


**影响：** Any stray localhost request — a browser prefetch, another local app probing ports 53692/1455, a security scanner — that hits `/callback` before the real OAuth redirect permanently aborts the login: the server shuts down, the real redirect gets connection-refused, and the user sees "callback had no code" and must restart the flow. The optional-state check also weakens the PKCE/CSRF story.


**建议：** In `CallbackHandler.handle`, only resolve when the expected parameter is present (`code` or `error`); reply 404/ignore otherwise and keep listening. Make the `state` parameter mandatory in both login flows (`guard params["state"] == expected`).

### L10. OAuthLogin's default Callbacks make the SDK write to stderr, spawn the user's browser, and block reading stdin

`Sources/KWWKAI/OAuthLogin.swift:31` · 副作用/全局状态


**证据：** `Callbacks()` defaults are `defaultAuthURL` (writes to `FileHandle.standardError` and calls `Browser.open(url)`, which spawns `/usr/bin/open` / `xdg-open`), `defaultProgress` (stderr writes), and `defaultPrompt` (stderr write + blocking `readLine()` on stdin). `loginAnthropic(callbacks: Callbacks = Callbacks(), ...)` and the other login entry points use these defaults, so a library call with no arguments performs process-global stdio and launches an external application. The hooks are injectable, which is good, but the terminal-oriented behavior is the silent default in the SDK target (KWWKAI), not the CLI.


**影响：** An embedder like a GUI app that calls `OAuthLogin.loginGitHubCopilot()` without customizing callbacks gets a surprise browser launch plus a `readLine()` that blocks a thread forever (GUI apps have no interactive stdin), and progress text interleaved into its stderr stream.


**建议：** Make `Callbacks` parameters non-defaulted in the SDK (force the caller to choose), or move the stderr/readLine/browser defaults into the CLI target and give the library a `.silent`/throwing default so headless embedders fail fast instead of blocking.

### L11. SSEParser.ingest(bytes:) silently drops a whole chunk when it splits a multi-byte UTF-8 character

`Sources/KWWKAI/SSEParser.swift:23` · 正确性 — KWWKAI


**证据：** `public func ingest(bytes: Data) { guard let s = String(data: bytes, encoding: .utf8) else { return } ... }` — if a network chunk boundary lands inside an emoji/CJK character, UTF-8 decoding of that chunk fails and the entire chunk (possibly kilobytes of events) is discarded with no error and no resynchronization. The only internal caller (`parseSSE`) happens to cut chunks at 0x0A so it is safe today, but this is a public API of the SSE parser and nothing documents the newline-alignment requirement.


**影响：** Any future or external caller feeding raw URLSession chunks (the natural usage) will intermittently lose events exactly when responses contain non-ASCII text — corrupted transcripts that are near-impossible to reproduce.


**建议：** Buffer raw bytes in the parser and only decode up to the last complete UTF-8 sequence boundary (retain the trailing partial bytes for the next ingest), or make the parser byte-oriented and decode per-line.

### L12. Every run emits a duplicate turnStart event because runLoop is entered with firstTurn: false

`Sources/KWWKAgent/AgentLoop.swift:138` · 正确性 — KWWKAgent


**证据：** AgentLoop.run emits `.turnStart` (line 130) and then calls `runLoop(currentContext:firstTurn: false, ...)`; inside runLoop the first iteration hits `if !firstTurn { await emit(.turnStart) }` (line 253) and emits a second `.turnStart` before any turnEnd. runContinue has the same shape. The pi reference passes `firstTurn = true` into its inner loop precisely to skip this (pi-mono agent-loop.ts line 165).


**影响：** SDK consumers that pair turnStart/turnEnd (turn counters, per-turn timers, transcript segmenters) see two turn_start events for one turn on every single run — an off-by-one that silently corrupts turn-based accounting. Nothing in-repo consumes turnStart today, which is why it went unnoticed.


**建议：** Pass `firstTurn: true` from run()/runContinue() so the pre-emitted turnStart is consumed by the first iteration, matching pi's semantics.

### L13. A stall notification permanently suppresses the task's completion notification, breaking the tool's promise that the model "will be notified on completion"

`Sources/KWWKAgent/BackgroundTaskManager.swift:526` · 正确性 — KWWKAgent


**证据：** stallTick enqueues a `stalled` notification and sets `tasks[taskId]?.notified = true` (line 526); complete() later runs `if !entry.notified { enqueueNotification(...) }` (line 366) and therefore skips the completion notification. The bash tool result explicitly tells the model: "You will receive a <task-notification> user message when it completes."


**影响：** A background `apt-get install`-style task that prints a prompt-like line ("Do you want to continue? [Y/n]") triggers a stall notification; if the process then proceeds and finishes (default answer, timeout, buffered input), no completion notification is ever delivered. The agent, told to "not poll", waits indefinitely for a message that cannot arrive, and the user sees a hung session unless the model spontaneously calls wait_task.


**建议：** Track stall and completion notification flags separately (suppress duplicate stalls, but always deliver the terminal completion/failure notification), or reset `notified` when output growth resumes after a stall.

### L14. CodingTools.all is identical to .standard and, contrary to its name, excludes tmux

`Sources/KWWKAgent/CodingTools.swift:38` · SDK DX — KWWKAgent


**证据：** `.standard` (lines 33-35) and `.all` (lines 38-40) contain the exact same ten... nine flags; `.all` is commented "Everything except tmux" and a third name `.allIncludingTmux` (line 43) holds the actual full set. Also, `.standard`/`.all` include `.taskStatus` and `.waitTask`, which buildCodingToolList silently drops when no backgroundManager is supplied (CodingAgentBuilder.swift:259-264).


**影响：** A developer choosing between `.standard` and `.all` reasonably assumes they differ; `.all` not meaning "all" and two of its members evaporating depending on an unrelated config field (backgroundManager) makes the option set's behavior non-obvious from the call site.


**建议：** Drop `.all` (or make it a deprecated alias of `.standard`), rename `.allIncludingTmux` to `.all`, and document the backgroundManager dependency on the individual flags rather than only on the type doc.

### L15. Glob patterns containing [ ] are passed unescaped into the regex, silently matching wrong files or nothing

`Sources/KWWKAgent/Glob.swift:31` · 正确性 — KWWKAgent


**证据：** patternToRegex escapes only `"().+|^$\\{}"`; `[` and `]` fall through to the literal-append branch. `matches` then does `path.range(of: regex, options: .regularExpression)` — an unbalanced `[` yields an invalid regex, for which range(of:) returns nil for every path.


**影响：** `find` with a pattern like `page[1].tsx` (bracket characters are common in Next.js route filenames: `[id].tsx`, `[...slug].ts`) matches `pageid.tsx`-style names via an unintended character class, or — with an unclosed bracket — silently returns "No files match" for files that exist, sending the model down a wrong path with no error signal.


**建议：** Escape `[` and `]` (and validate the final regex, falling back to literal comparison on failure) in patternToRegex.

### L16. ReadToolOptions.autoResizeImages is a dead option: images are never resized and unbounded image bytes are base64-inlined

`Sources/KWWKAgent/ReadTool.swift:89` · 正确性 — KWWKAgent


**证据：** `autoResizeImages` is stored on ReadToolOptions (lines 5-16) but never read anywhere in the module (grep shows only the declaration/init). The image branch does `let buffer = try await ops.readFile(absolutePath); let base64 = buffer.base64EncodedString()` with no size check, unlike the text branch which enforces maxBytes.


**影响：** An API caller who sets `autoResizeImages: true` (the default!) reasonably expects pi-style downscaling; instead a `read` of a 20MB screenshot injects ~27MB of base64 into the request, typically producing a provider 400/413 or an enormous bill. The option's existence actively misleads.


**建议：** Either implement resizing/size-capping for the image path (reject or downscale above a byte threshold) or delete the option until it does something.

### L17. read tool loads the entire file into memory and splits every line even when only an offset/limit window is requested

`Sources/KWWKAgent/ReadTool.swift:102` · 性能


**证据：** The text path does `try await ops.readFile(absolutePath)` (Data(contentsOf:) of the whole file, line 27), decodes all of it to a String, then `text.components(separatedBy: "\n")` materializes an array of every line — before offset/limit slicing and the maxLines/maxBytes truncation are applied.


**影响：** Asking the model to read a window of a large artifact (a 1-2GB build log or JSONL dump) allocates the entire file in memory twice (Data + String) plus a per-line array, potentially causing multi-second stalls or memory pressure, when only ~2000 lines were ever going to be returned.


**建议：** Stream the file: read incrementally (FileHandle chunks), count newlines to skip to `offset`, and stop after `limit`/maxBytes lines are collected. At minimum, stat the file and bail out with a helpful error above some size threshold.

### L18. Session transcripts are persisted world-readable while the same content in background task logs is deliberately locked to 0600

`Sources/KWWKAgent/SessionStore.swift:293` · 副作用/全局状态


**证据：** `ensureDirectory()` calls `createDirectory(at:withIntermediateDirectories:)` with no attributes (default 0755) and `create(id:)`/`appendEntry` write `<id>.jsonl` with default 0644 permissions. Contrast BashTool.swift:615-628, where the same project deliberately creates the background-output directory with `[.posixPermissions: 0o700]` and each log file with `0o600`. The JSONL transcript contains the full conversation plus every tool result — including bash output, which is exactly the data the 0600 task logs protect (and, via the tmux env-inheritance issue above, potentially `env` dumps with API keys). Note ~/.kwwk itself is only created 0700 if the OAuth store made it first; SessionStore.ensureDirectory can be the creator when a user runs kwwk before ever logging in via OAuth (env-key auth), leaving ~/.kwwk itself 0755.


**影响：** On shared machines, other local users can read complete agent transcripts — proprietary code, prompts, and any secrets echoed by tools — even though the project's own task-log handling shows the authors consider this class of data sensitive.


**建议：** Create the sessions directory with 0700 and session files with 0600, mirroring BackgroundTaskManager.allocateForegroundOutputFile.

### L19. Built-in subagent names have inconsistent casing and lookup is case-sensitive, unlike the selection parser

`Sources/KWWKAgent/SubagentDefinition.swift:127` · SDK DX — KWWKAgent


**证据：** Built-ins are named "general" (lowercase, line 98) but "Explore" (line 127) and "Plan" (line 152) capitalized. SubagentRegistry.definition and SubagentRunner.definition(named:) do exact dictionary/equality matches (SubagentTool.swift:385-387, 696-699), while BuiltinSubagentSelection.named() lowercases its input (SubagentDefinition.swift:59). The README itself directs `runner.run(type: "Plan", ...)`. Additionally SubagentRegistry keeps the last duplicate definition but the first name-order slot (SubagentTool.swift:374-380), silently overriding earlier definitions — the opposite of Skills.load, where the first duplicate wins (Skills.swift:298).


**影响：** `runner.run(type: "plan")` throws "unknown type 'plan'. Available subagents: general, Explore, Plan" — a needless failure for both SDK callers and models emitting `subagent_type`. Duplicate subagent names silently shadow each other with a policy inconsistent with the neighboring Skills subsystem.


**建议：** Normalize subagent names to lowercase (or make lookups case-insensitive), and make duplicate handling explicit and consistent (first-wins with a diagnostic, matching Skills).

### L20. CLI startup performs OAuth token refresh/exchange network calls for every stored login, not just the session's active provider

`Sources/KWWKCli/AuthResolver.swift:183` · 副作用/全局状态


**证据：** `registerAllStored` loops over every store id and each register function eagerly primes credentials before any prompt is sent: `_ = try? await manager.apiKey(for: "openai-codex")` (line 514), `_ = try? await manager.apiKey(for: "anthropic")` (line 561), `_ = try? await manager.apiKey(for: "github-copilot")` (line 614). OAuthManager.apiKey refreshes whenever `isExpired`, and GitHub Copilot's "refresh" is a PAT→session-token exchange whose token is short-lived, so it round-trips github.com on essentially every launch even when the user only intends to use, say, Anthropic this session. The Copilot resolver itself would refresh on demand at first request (AuthResolver.swift:887-897), so the launch-time priming is not required for correctness of the other providers.


**影响：** Every kwwk launch with multiple stored logins fires N sequential token-refresh requests before the TUI is usable — added startup latency, needless traffic to providers the session never touches, and refresh-token rotation churn on accounts the user did not intend to exercise (a failure/ratelimit on an unused provider's refresh happens invisibly at startup).


**建议：** Register providers lazily and let each `oauthResolver` perform the refresh on first actual request (the code path already exists); only prime the active provider, and fetch Copilot's `extras["endpoint"]` from the stored credentials without forcing a token exchange.

### L21. Single-tap Ctrl-C exits the whole app instantly — even mid-stream — where pi requires a double-press and uses the first press to clear the editor

`Sources/KWWKCli/CodingTUI.swift:885` · TUI 用户体验 ·（对抗验证后降级）


**证据：** `runner.bind(.ctrl("c")) { … await agent.abortAndKillBackgroundTasks(); runner.exit() }` — one keypress kills all background tasks and quits, regardless of streaming state or a draft in the input. pi-mono's interactive mode binds ctrl+c to "Clear editor" and only shuts down on a second press within 500ms (interactive-mode.ts:3227-3235, hint "ctrl+c twice to exit").


**影响：** Ctrl-C is deeply wired muscle memory for "stop the current thing" — a user reflexively hitting it to interrupt a generation (instead of the less conventional Esc) instantly loses their draft, kills every background task, and exits the app. There is no confirmation and no grace window; recovery requires relaunching with --continue.


**建议：** Adopt the pi/Claude Code convention: first Ctrl-C aborts the stream (if streaming) or clears the input, and only a second press within ~500ms exits; surface the "press again to exit" hint in the state line. Keep Ctrl-D-on-empty as the deliberate quit.

### L22. Background-task status poll repaints the idle UI and queries the task actor 4 times per second even when nothing is running

`Sources/KWWKCli/CodingTUI.swift:968` · 性能


**证据：** frameStatusTask loops forever: every 250ms it awaits `bgManager.list(sessionId:)`, calls updateFrameStatus() (which rebuilds breadcrumb/meta strings and queries agent state and the goal store), and calls `runner.tui.requestRender()` unconditionally — with no check that anything changed and no gating on activity. This contradicts the adjacent spinnerTask comment (lines 982-983): "so an idle prompt isn't redrawn ~11x/s for no reason" — it is still redrawn 4x/s by this task, and (per the TUI finding above) each redraw rewrites the whole live zone.


**影响：** A kwwk instance sitting idle at the prompt performs continuous actor hops, string formatting, and full live-zone terminal writes 4 times per second indefinitely — wasted CPU wakeups and battery drain on laptops, and constant redraw traffic for terminals that render on output.


**建议：** Skip updateFrameStatus/requestRender when the computed status is unchanged (compare the previous running-count/status tuple), and back the poll off (or park the task entirely) while the agent is idle and no background tasks exist, resuming on task spawn.

### L23. Kitty CSI-u decoding only maps letters and five named keys, so Ctrl+_ / Ctrl+/ undo (and other modified punctuation) dies on kitty-protocol terminals kwwk itself opts into

`Sources/KWWKCli/Keys.swift:161` · TUI 用户体验


**证据：** TUIRunner enables the kitty keyboard protocol (`ESC[>1u`, TUIRunner.swift:93), under which modified keys arrive as CSI-u. kittyKeyName maps only tab/enter/escape/space/backspace and a–z/A–Z; every other keycode returns nil, parse returns nil, and InputComponent.handleInput drops ESC-prefixed data (InputComponent.swift:609). Ctrl+_ (keycode 95) and Ctrl+/ (keycode 47) — the advertised undo chords (InputComponent.swift:631-634) — therefore parse to nothing on kitty/Ghostty/foot, while on legacy terminals they work via the raw 0x1F byte.


**影响：** On exactly the modern terminals that honor kwwk's own protocol opt-in, undo via Ctrl+_ / Ctrl+/ silently does nothing (and other modified punctuation/digit chords are swallowed), an inconsistency users can't diagnose — the /hotkeys help still advertises the binding.


**建议：** Extend kittyKeyName to cover the printable ASCII range (map the keycode to its character, deriving shift from the shifted-key field or uppercase range) so CSI-u punctuation and digits resolve; at minimum map 95 → "_" and 47 → "/" and route ctrl+"/" to undo.

### L24. `kwwk --resume` drops to a bare numbered stdin prompt while `/resume` inside the TUI gets the polished arrow-key picker

`Sources/KWWKCli/SessionPicker.swift:45` · TUI 用户体验


**证据：** SessionPicker.choose prints a plain text menu to stderr and reads one line from cooked stdin (`FileHandle.standardInput.read(upToCount: 1024)`), requiring the user to type an index number; any non-number cancels and exits 0 ("No session selected", CodingTUI.swift:35-41). The in-session `/resume` command opens SessionResumeModal with arrow keys, titles, relative ages, windowing and `· current` tags. pi's --resume shows its full SessionSelectorComponent.


**影响：** The very first interaction a returning user has with the app (resuming from the shell) is its least polished: no arrow keys, no highlighting, session ids truncated into a dense line, and a stray Enter cancels straight to exit. It also renders no titles styling consistent with the rest of the product, undercutting the stated goal of a polished first-run experience.


**建议：** Boot a minimal TUIRunner with the existing SessionResumeModal (or a standalone raw-mode list using ModalListCore) for --resume, falling back to the numbered prompt only when stdin/stdout isn't a TTY.

### L25. Normal render path erases and rewrites the entire live zone every frame with no diffing and no synchronized-output guard

`Sources/KWWKCli/TUI.swift:487` · TUI 用户体验


**证据：** renderInline unconditionally clears all oldHeight rows (`for i in 0..<oldHeight { out += "\u{1B}[2K" … }`) and repaints every live row on every requestRender — which fires per keystroke, per agent event, and at ~11Hz from the spinner tick while streaming. lastRenderedLines is stored (TUI.swift:434) but never compared, and unlike fullRepaint/multiplexerRepaint the inline path is not wrapped in DEC 2026 synchronized output. pi-tui diffs against previousLines and repaints only changed rows inside a ?2026h/?2026l bracket (tui.ts:1053-1145).


**影响：** With a tall live zone (running tool blocks + queue list + prompt box) the terminal receives a full clear+rewrite many times per second during streaming. On terminals without atomic-write coalescing, over SSH, or under load, this shows as flicker/shimmer of the input box and status line — precisely the polish gap versus pi the project aims to close.


**建议：** Wrap the inline frame in \u{1B}[?2026h … \u{1B}[?2026l (already done for the repaint paths), and short-circuit when rendered == lastRenderedLines (cursor-only moves can reposition without repainting). Full per-line diffing à la pi-tui is a further step but the two cheap changes remove most of the churn.

### L26. TranscriptRenderer re-derives the full assistant text snapshot and does O(n) character-index math on every stream delta, O(n^2) over a long message

`Sources/KWWKCli/TranscriptRenderer.swift:382` · 性能 ·（对抗验证后降级）


**证据：** ingestAssistantText runs on every `.messageUpdate` (line 174). It calls assistantTextSnapshot(assistant), which concatenates all text blocks into a fresh String; then `snapshot.count` (O(chars) grapheme walk), `snapshot.index(snapshot.startIndex, offsetBy: assistantIngestedCharacters)` (another O(chars) walk), and a substring copy — all proportional to the total message length so far, per delta.


**影响：** A 20KB assistant response arriving in ~1000 deltas performs on the order of 30M grapheme-cluster traversals plus 1000 full-string rebuilds on the MainActor render path. Long responses make token rendering measurably lag toward the end of the message, competing with input handling on the same actor.


**建议：** Consume the delta payload the event already carries (AssistantMessageEvent.textDelta includes the delta string) instead of re-deriving the full snapshot, or track ingestion with a stored String.Index per block so no offsetBy walk is needed.
