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
rotation or model fallback; permanent account limits do not retry the same
credential; no automatic replay after committed text or tools. JavaScript SDK
class names and timers are adapted to Swift errors and cancellation.

## MIT License (pi and oh-my-pi)

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
