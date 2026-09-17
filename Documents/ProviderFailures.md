# Provider failures and recovery

Providers report `AssistantMessage.failure` (`ProviderFailure`) alongside the
legacy `errorMessage`. The new optional field is Codable, so existing transcripts
decode unchanged. Error events and final results retain the same failure and any
partial output. HTTP status, provider code, NSError domain/code, request ID,
Retry-After, retry veto, and exceptional stop details stay separate from prose.
HTTP error bodies are bounded to 4096 bytes; a broken body never erases the HTTP
status. Provider messages remain diagnostics, not trusted end-user copy.

`ProviderFailure` is the shared classifier. Permanent account limits, auth,
validation, safety refusals, caller cancellation, and context overflow do not
retry the same request. Transport codes and governing HTTP status take precedence
over fallback prose. Legacy text statuses require an HTTP/status prefix or a
leading status, not an arbitrary number embedded in an identifier.
`ProviderContextLimit` supplies the existing overflow rules to both AI and Agent.

`ProviderRetryPolicy` is the single scheduling policy. The Agent owns live-turn
retries, and the summary generator owns its self-contained call retries. Provider
adapters never add another retry loop. Defaults: five total attempts, exponential
backoff capped at 30 seconds with 0.75–1 jitter. Server retry delays are not
jittered or shortened. `maxRetryDelayMs` defaults to 60 seconds for server hints;
zero explicitly removes that cap. A delay above the cap ends retrying, preserving
the original failure. All waits are cancellable. Summary callers can configure
`AgentContextCompactionConfig.summaryRetryPolicy` independently.

Live turns only retry before non-whitespace text, tool calls or inline tool
execution escapes. The inline invocation gate closes atomically before replay;
thinking-only output can be rewound. In-memory rollback cannot undo external
side effects. A terminal failed attempt retains its output and completed inline
results rather than re-executing them. Summaries expose no tools/output, so their
transient retries reuse the same prompt after closing the isolated provider
session. Context overflow remains a separate input-shrinking path; refusal and
rate limiting never trigger shrinking.

No retry UI, automatic model switching, credential rotation, or unlimited retry
was introduced. Existing stream retry events remain available to internal
subscribers. See `THIRD_PARTY_NOTICES.md` for the pi/omp test provenance and the
intentional differences from upstream.

Audit follow-up: Responses EOF without a terminal event is a failure, including
when partial text arrived. OpenRouter `metadata.raw` is retained separately as
bounded, credential-redacted upstream diagnostics, so nested context overflow
can enter input shrinking. String-valued SSE errors still retain outer status.
WebSocket transport fallback never bypasses a known provider HTTP rejection or
retry veto; URLSession upgrade responses contribute status and retry headers.
Cursor numeric gRPC trailers and named Connect errors share structured codes.
Concurrent-request quotas are backpressure; exhausted account credit is terminal.
HTTP 402 is always terminal, including with explicit positive retry hints.

Opt-in smoke check: `KWWK_LIVE_STORED_OAUTH=1 swift test --filter
LiveStoredOAuthSmokeTests`. This uses existing ChatGPT and Claude OAuth logins,
may refresh them normally, and sends one fixed tiny prompt per provider, without
tools or project context. It prints only model/status/event counts, never tokens
or raw provider errors. Normal test runs do not access the credential store.
