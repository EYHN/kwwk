# Adapted provider error regression tests

The Swift tests in `ProviderFailureParityTests.swift` adapt scenarios and
assertions from these MIT-licensed upstream tests, rather than embedding a
JavaScript test runner:

- pi (`badlogic/pi-mono`), commit `1283afd0d0685d1ffe88aa56a725c0e4ad3cfc7b`:
  `packages/ai/test/retry.test.ts` and `packages/ai/test/provider-retry.test.ts`.
- oh-my-pi (`can1357/oh-my-pi`), commit
  `1c0303b1f2ec515cbf4b44a9a49d68a029531aac`:
  `packages/ai/test/error-transient-status-boundary.test.ts` and the structural
  HTTP status cases from `packages/ai/test/error-aierr.test.ts`.

Coverage: real vs embedded status codes; terminal status precedence; explicit
provider guidance; DNS/socket/early EOF wording; quota/billing exclusions;
Retry-After and retry vetoes; delay caps; bounded one-shot retries; cancellation.
Additional native tests cover NSError transport codes, Codable compatibility,
provider SSE error events, and replay safety. These are a relevant subset, not
the entirety of either upstream's test suite.

Deliberate differences: one retry owner above the provider (no nested retries);
five total attempts by default; 30-second exponential backoff cap with jitter; no credential
rotation or client-side model fallback; permanent account limits do not retry the same
credential; no automatic replay after committed text or tools. JavaScript SDK
class names and timers are adapted to Swift errors and cancellation.

Audit follow-up at the same pinned revisions: pi's
`packages/ai/test/provider-error-body-regression.test.ts` and
`packages/ai/src/api/openai-completions.ts` inform the OpenRouter nested-error
cases; omp's `packages/ai/test/rate-limit-utils.test.ts` informs concurrent-quota
versus account-quota cases. Both Responses implementations reject premature EOF.
The Codex WebSocket implementations distinguish transport fallback from provider
rejection; our URLSession handshake-response cases are native regressions, not
literal upstream test ports. Numeric gRPC normalization, string SSE outer-status
retention, and mutable attempt-count clamping are local fixes. Neither upstream
is claimed to cover all these combinations. In particular, pi allows positive
retry hints to override some permanent statuses; our HTTP 402 veto intentionally
does not. `ProviderAuditRegressionTests` documents these combinations.

## Native compaction references

Native compaction follow-up references pi at
`1283afd0d0685d1ffe88aa56a725c0e4ad3cfc7b`, specifically regressions
`6647-compaction-retries-transient-stream-drop.test.ts` and
`7048-compaction-truncated-summary.test.ts` under
`packages/coding-agent/test/suite/regressions/`. Native routing/replay and
test scenarios reference omp at `116190d317ca319ae17ab624cb479c76a1ca4704`:
`packages/agent/src/compaction/{anthropic,openai,compaction-v2-streaming}.ts`,
`packages/agent/test/{anthropic-native-compaction,remote-compaction,compaction-oneshot-retry}.test.ts`.
The Swift adaptations cover retry opt-out/exhaustion without nested loops,
unchanged history on failure, below-trigger local summarization, opaque-payload
persistence and replay, assistant-final padding, and complete V2 output.
Pi's inspected compaction paths implement local summaries; native protocol
parity is with omp, not a claim that both projects implement these endpoints.
Unlike omp, this PR does not add WebSocket compaction, V2-to-V1 fallback on the
subscription route, custom remote-summary endpoints, or speculative compaction.
Retained Codex user messages are preserved rather than silently truncated; the
existing post-compaction budget check rejects insufficient reduction.

## MIT License (pi and oh-my-pi)

Anthropic fallback handling and `AnthropicFallbackTests` additionally adapt
protocol behavior and scenarios from oh-my-pi's
`packages/ai/src/providers/anthropic.ts` and
`packages/ai/test/anthropic-server-side-fallback.test.ts` (main, inspected
2026-09-17): positional replay, tool-use ordering, and iteration billing.

Copyright (c) 2025 Mario Zechner
Copyright (c) 2025-2026 Can Bölük
Copyright (c) 2026 Stencil Labs, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
