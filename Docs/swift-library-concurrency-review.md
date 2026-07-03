# Swift Library Concurrency Review (kwwk API)

Date: 2026-07-03

Scope reviewed:

- `Sources/KWWKAI` (model/provider API, streaming HTTP, OAuth callback)
- `Sources/KWWKAgent` (agent public API, tools, background/subagent execution)
- `Sources/KWWKCli` at boundary level (MainActor/UI confinement vs library targets)
- Test suites under `Tests/KWWKAITests`, `Tests/KWWKAgentTests`, `Tests/KWWKCliTests`

Verification commands run:

- `swift test --filter KWWKAITests` — passed, 280 tests / 37 suites
- `swift test` — passed, 825 tests / 137 suites

## Executive summary

`KWWKAI` is largely aligned with Swift library best practices: public provider APIs are async/stream-oriented, not `@MainActor`, providers run work off the caller via `Task.detached`, and shared provider registry state is actor-isolated. During review, two `KWWKAI` hardening fixes were applied:

1. `OAuthCallbackServer.waitForCallback()` now starts the NIO listener through an async future bridge instead of the blocking `.wait()` path.
2. `URLSessionHTTPClient`'s streaming delegate no longer resumes continuations or finishes `AsyncThrowingStream` continuations while holding `NSLock`.

`KWWKAgent` is mostly usable from non-main contexts and contains good concurrency primitives (`AgentState` locks, `BackgroundTaskManager` actor, `FileMutationQueue` actor, detached background/subagent runners). However, several library-quality risks remain, mostly around `@unchecked Sendable` reference state and synchronous process/file I/O inside async APIs. These are not necessarily current test failures, but they are the highest-priority areas before claiming the full API is free of deadlock/blocking risk.

`KWWKCli` intentionally contains `@MainActor` UI code. I did not find `@MainActor` annotations leaking into `KWWKAI` or `KWWKAgent` public APIs; grep found none in those library targets except comments. A CLI-boundary subreview found that the public `KWWKCli.KWWK` entry points are not themselves `@MainActor`, but several internal headless/setup/helper paths do unnecessary main-actor or main-queue synchronous work (details below).

## Findings and fixes

### Fixed: OAuth callback async API used a blocking NIO wait

Evidence before fix: `OAuthCallbackServer.waitForCallback()` called synchronous `start()`, and `start()` used NIO `.wait()`.

Current evidence:

- `Sources/KWWKAI/OAuthCallbackServer.swift:51-63` documents `start()` as synchronous compatibility API and still uses `.wait()` only there.
- `Sources/KWWKAI/OAuthCallbackServer.swift:66-70` adds `startAsync()` using `try await ...bind(...).get()`.
- `Sources/KWWKAI/OAuthCallbackServer.swift:91-93` has `waitForCallback()` call `try await startAsync()`.

Assessment: async OAuth login flow no longer blocks the caller executor/main actor during socket bind. The synchronous `start()` remains a documented compatibility API and should not be used from UI/main-actor code.

### Fixed: HTTP streaming delegate resumed continuations under lock

Evidence/current state:

- `Sources/KWWKAI/HTTPClient.swift:96-114` now extracts pending header state under `NSLock`, then resumes the continuation after the lock is released.
- `Sources/KWWKAI/HTTPClient.swift:117-135` now finishes pending body stream completion after the lock is released.
- `Sources/KWWKAI/HTTPClient.swift:161-203` now records completion actions under lock, then resumes/finishes outside the lock.
- `Sources/KWWKAI/HTTPClient.swift:206-223` now resumes header continuations outside the lock.

Assessment: reduces reentrancy/deadlock risk from continuation resumption callbacks executing synchronously while internal state lock is held.

## Remaining risks / recommended follow-up

### 1. `Agent` is `@unchecked Sendable` but exposes unsynchronized mutable public config

Evidence:

- `Sources/KWWKAgent/Agent.swift:133` declares `public final class Agent: @unchecked Sendable`.
- `Sources/KWWKAgent/Agent.swift:137-140` lock-protects listeners/cancellation/idle waiters only.
- `Sources/KWWKAgent/Agent.swift:142-156` exposes mutable public vars such as `sessionId`, `thinkingBudgets`, `maxTurns`, `toolExecution`, hooks, `autoCompact`, and `authResolver`.
- `Sources/KWWKAgent/Agent.swift:425-448` reads these vars into `AgentLoopConfig` without synchronization.

Risk: data races if callers mutate agent configuration from one task while prompt/continue/subagent execution reads it from another. `@unchecked Sendable` suppresses compiler help.

Recommendation: make runtime configuration immutable after init, or move public mutable options behind a lock/actor and expose thread-safe setters/snapshots. If mutation is only supported while idle, enforce it and document it.

### 2. Awaited subscribers can deadlock if they call back into same-agent idle/wait APIs inline

Evidence:

- `Sources/KWWKAgent/Agent.swift:559-562` awaits every listener during synthetic event emission.
- `Sources/KWWKAgent/Agent.swift:595-599` awaits every listener during failure event emission.
- `Sources/KWWKAgent/Agent.swift:466-472` marks the agent active until run lifecycle exits; `waitForIdle()` waits for this active handle to clear.

Risk: a listener that does `await agent.waitForIdle()` inline can wait for a run that is itself waiting for the listener to return.

Recommendation: document listener reentrancy rules and/or detect listener-context calls to `waitForIdle()`. Consider non-blocking listener fan-out if ordered backpressure is not required.

### 3. `FileMutationQueue` can deadlock on nested same-path mutations

Evidence:

- `Sources/KWWKAgent/FileMutationQueue.swift:19-24` chains a new mutation task after previous same-key task.
- `Sources/KWWKAgent/FileMutationQueue.swift:25-33` awaits the body and then awaits the task.

Risk: `queue.run(path) { try await queue.run(path) { ... } }` creates an inner task waiting on the outer task, while the outer body waits on the inner task.

Recommendation: track task-local current mutation key and throw a clear reentrant mutation error (or explicitly support reentrancy).

### 4. Legacy bash execution can deadlock on large stdout/stderr pipe output

Evidence:

- `Sources/KWWKAgent/BashTool.swift:88-91` attaches stdout/stderr pipes.
- `Sources/KWWKAgent/BashTool.swift:116-120` waits for process exit.
- `Sources/KWWKAgent/BashTool.swift:124-145` reads stdout/stderr only after process exit.

Risk: child process can block when pipe buffers fill; parent waits for exit; neither progresses.

Recommendation: drain stdout/stderr concurrently while the process runs, or route legacy foreground execution through the file-backed runner used by background-capable paths.

### 5. Some async APIs still do synchronous process/file work on the caller executor or actor

Evidence:

- `Sources/KWWKAgent/BashTool.swift:103` calls `Process.run()` before first suspension.
- `Sources/KWWKAgent/BashTool.swift:124-145` performs synchronous reads after await.
- `Sources/KWWKAgent/BashTool.swift:535-540` reads an entire output file with `Data(contentsOf:)` before capping to 1 MB.
- `Sources/KWWKAgent/BackgroundTaskManager.swift:224-227` reads output tail inside actor isolation.
- `Sources/KWWKAgent/BackgroundTaskManager.swift:383-385` reads tail while enqueueing notifications.
- `Sources/KWWKAgent/BackgroundTaskManager.swift:552-562` snapshots include synchronous tail reads.

Risk: not a direct global main-thread block unless called from `@MainActor`, but these APIs can block the caller executor or serialize unrelated actor work behind filesystem I/O.

Recommendation: offload process startup/file reads to non-main execution and cap tail reads without loading whole files. Move expensive tail reading outside hot actor paths where possible.

### 6. `KWWKCli` headless path and setup helpers do avoidable main-actor blocking

Evidence from CLI subreview:

- `Sources/KWWKCli/Headless.swift:21-24` marks `runHeadlessInternal` as `@MainActor`, and `Sources/KWWKCli/KWWK.swift:95-118` awaits it from the public headless entry point.
- `Sources/KWWKCli/SessionPicker.swift:44-56` performs blocking stdin read for interactive resume selection from the main-actor setup path.
- `Sources/KWWKCli/WelcomeScreen.swift:168-184` runs `git`, waits synchronously, then drains stdout during TUI setup.
- `Sources/KWWKCli/Attachments.swift:215-281` and `Sources/KWWKCli/Attachments.swift:314-418` resolve attachments with synchronous `FileManager` / `Data(contentsOf:)` work from main-actor call sites in `CodingTUI`.
- `Sources/KWWKCli/CustomSlashCommands.swift:241-260` and `Sources/KWWKCli/CustomSlashCommands.swift:276-291` synchronously discover/read custom command files during main-actor TUI setup.
- `Sources/KWWKCli/TUIRunner.swift` mixes main dispatch queue confinement with `@MainActor` UI state, which weakens Swift 6 isolation guarantees.

Risk: this is mostly CLI/UI responsiveness rather than core `KWWKAI` model API risk, but as `KWWKCli` is exported as a library product it can surprise embedders: headless usage hops to the main actor, TUI startup can freeze on slow stdin/process/filesystem work, and mixing `.main` queue callbacks with `MainActor` tasks creates subtle ordering/isolation issues.

Recommendation: remove `@MainActor` from headless internals, move blocking stdin/process/filesystem work to detached/nonisolated helpers, keep only actual UI state mutation on `@MainActor`, and choose one UI confinement model (`MainActor` preferred) instead of mixing direct main-queue mutation with actor-isolated UI code.

## Positive patterns confirmed

- `KWWKAI` and `KWWKAgent` public APIs are not `@MainActor`-isolated (`grep @MainActor` returned none in `Sources/KWWKAI`; only a comment in `Sources/KWWKAgent`).
- Provider registry is an actor: `Sources/KWWKAI/APIRegistry.swift`.
- Providers return streams immediately and run network drivers in detached tasks, e.g. `AnthropicProvider.stream`.
- `URLSessionHTTPClient` uses isolated ephemeral URL sessions by default.
- `AgentState` uses locked snapshots for mutable UI/agent state.
- `BackgroundTaskManager` and `FileMutationQueue` are actors.
- Background bash/subagent work uses detached tasks plus explicit cancellation handles.

## Suggested test additions

1. KWWKAgent TSan/stress tests for concurrent mutation of `Agent` public config while prompting/subagent snapshotting.
2. Regression test for listener reentrancy (`listener -> waitForIdle`) with timeout and expected documented behavior.
3. Regression test for nested same-path `FileMutationQueue.run` with timeout or explicit thrown error.
4. Large-output legacy bash test (`yes | head -c 10485760`) to catch pipe-buffer deadlock.
5. MainActor responsiveness test invoking bash/tool APIs from `@MainActor` while a ticking main-actor task continues.
6. `KWWKCli` boundary tests: `runHeadless` should not require/hop to `MainActor`; attachment/custom-command discovery should not block a ticking main-actor task.
7. Background manager responsiveness test while large output tails are read and `killAll`/`closeSession` are issued.
