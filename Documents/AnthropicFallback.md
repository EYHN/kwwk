# Anthropic Fable fallback

Official Anthropic Messages requests for `claude-fable-5` and
`claude-fable-5-1` automatically include `fallbacks: [{"model":"claude-opus-4-8"}]`
and `server-side-fallback-2026-06-01` (omp's protocol). Both API-key and Claude subscription
routes use this provider. Set `StreamOptions.anthropicServerSideFallback = false`
to disable it. Other models and third-party endpoints do not opt in.

This is server-side refusal fallback, not a client retry on quota, 429, or
network errors. The request's model selector remains Fable, while preserved
fallback blocks in history allow Anthropic's sticky routing to keep serving
Opus on subsequent turns. This does not promise permanent routing after that
history is removed (for example by compaction), or after disabling fallback.
`AssistantMessage.model` retains the requested model;
`responseModel` records the model actually reported by the server, including
fallback blocks and `fallback_message` usage iterations. The CLI displays the
requested and served models with each completed response, including history
replay. This separates configured model identity from actual service.

Both pre-output and mid-output fallback are supported. Positional `.fallback`
content blocks survive Codable/session storage and replay. Signed thinking on
both sides stays intact on opted-in official Anthropic requests. Opt-out and
cross-provider replay drop the protocol marker; incompatible thinking is
demoted. Tool-use blocks are stably moved to the end of the outgoing assistant
message, preserving thinking/handoff order and matching tool-result IDs.
Fallback blocks occupy content indices but are not rendered as assistant text.

Costs use each iteration's bundled model rates, waive attempts with no output
or cache creation, and price fallback input at the cache-read rate, following
omp. Top-level usage counts remain unchanged. Unknown model IDs use the request
model rates; absent iterations use the served model's ordinary rates. Raw
iterations and calculated costs survive storage; run summaries retain these
provider costs. These are local estimates, not billing records.

## Upstream research (2026-09-17)

- [omp settings adapter](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/session/settings-stream-fn.ts):
  opt-in Fable/Mythos family fallback to Opus 4.8, including Fable 5.1 through
  family classification.
- [omp provider](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/providers/anthropic.ts):
  June fallback beta, persisted handoff boundaries, mid-output fallback,
  iteration-aware pricing and fallback input credits.
- [pi provider](https://github.com/earendil-works/pi/blob/main/packages/ai/src/api/anthropic-messages.ts):
  July fallback beta, catalog-driven fallback requests, separate response model,
  served-model pricing, explicit rejection of mid-output fallback.
- [pi catalog generator](https://github.com/earendil-works/pi/blob/main/packages/ai/scripts/generate-models.ts):
  currently lists Fable 5 → Opus 4.8 / Opus 5 and Opus 5 → Opus 4.8;
  it does not explicitly list Fable 5.1. Our 5.1 policy follows omp's family rule.

Validation uses recorded SSE fixtures; no paid live inference is required.

Upstream coverage: `packages/ai/test/anthropic-server-side-fallback.test.ts`
tests opt-in, boundary persistence, per-iteration cost, replay gating and tool
ordering. Local equivalents are in `AnthropicFallbackTests`, with disk restore
coverage in `SessionStoreTests`, cost aggregation in `FallbackRunCostTests`, and
live/history visibility in `TranscriptSnapshotTests`. Mock tests verify the
outgoing sticky-routing contract; they cannot prove Anthropic's live routing.
