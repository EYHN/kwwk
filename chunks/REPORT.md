# kwwk on Terminal-Bench 2.0 — Full Run Report

**Date:** 2026-04-26 / 04-27

## Configuration

| Setting | Value |
|---|---|
| Model | `claude-opus-4-7` (via Anthropic OAuth subscription) |
| Context window | 1,000,000 tokens (`anthropic-beta: context-1m-2025-08-07`) |
| Thinking level | `xhigh` (24,576 token budget per turn) |
| Trials per task (`k`) | 1 |
| Concurrency (`n`) | 1 (serial) |
| Agent | `harbor_bench.kwwk_agent:KwwkHarborAgent` (from PR #2) |
| Harbor version | 0.4.0 (Python 3.12 venv) |
| kwwk binary | Built with `swift:6.1-focal` (glibc 2.31, GLIBC ≤ 2.29 deps) |
| Trials total | 71 |

## Dataset

- Official source `terminal-bench/terminal-bench-2` (89 tasks) was unreachable: Harbor's Supabase backend (`ofhuhcpkvzjlejydnvyd.supabase.co`) returned 522 throughout the run.
- **Workaround:** built a local Harbor JSON registry pointing at HuggingFace `laude-institute/sandboxes-tasks` (main HEAD `d95904b`, 2025-09-25 — TB1.5-era snapshot) and intersected with the 86 TB2 task names listed at `tbench.ai/benchmarks/terminal-bench-2`.
- Resulting subset: **71 tasks** (15 TB2-only tasks added after that commit are unreachable until Supabase recovers).

## Headline numbers

- **Raw pass rate**: 50/71 = **70.4%**
- **Excluding infra failures** (env build / agent timeout): 50/67 = **74.6%**
- Infra failures: **4**

## Per-chunk summary

| Chunk | Pass / Total | % |
|---|---|---|
| 1 | 6/10 | 60% |
| 2 | 7/10 | 70% |
| 3 | 7/10 | 70% |
| 4 | 8/10 | 80% |
| 5 | 5/10 | 50% |
| 6 | 8/10 | 80% |
| 7 | 8/10 | 80% |
| 8 | 1/1 | 100% |

## Per-task results

| Chunk | Task | Reward | kwwk exit | Duration (s) | Exception |
|---|---|---|---|---|---|
| 1 | `adaptive-rejection-sampler` | ✗ 0 | 0 | 372 |  |
| 1 | `bn-fit-modify` | ✓ 1 | 0 | 79 |  |
| 1 | `break-filter-js-from-html` | ✓ 1 | 0 | 145 |  |
| 1 | `build-cython-ext` | ✗ 0 | 0 | 204 |  |
| 1 | `build-pmars` | ✓ 1 | 0 | 120 |  |
| 1 | `build-pov-ray` | ✗ 0 | 0 | 74 |  |
| 1 | `caffe-cifar-10` | ✓ 1 | 0 | 476 |  |
| 1 | `cancel-async-tasks` | ✓ 1 | 0 | 253 |  |
| 1 | `chess-best-move` | ✗ 0 | 0 | 373 |  |
| 1 | `circuit-fibsqrt` | ✓ 1 | 0 | 877 |  |
| 2 | `cobol-modernization` | ✓ 1 | 0 | 117 |  |
| 2 | `code-from-image` | ✓ 1 | 0 | 9 |  |
| 2 | `configure-git-webserver` | ✗ 0 | 0 | 190 |  |
| 2 | `constraints-scheduling` | ✓ 1 | 0 | 52 |  |
| 2 | `count-dataset-tokens` | ✓ 1 | 0 | 50 |  |
| 2 | `crack-7z-hash` | ✓ 1 | 0 | 83 |  |
| 2 | `db-wal-recovery` | ✓ 1 | 0 | 73 |  |
| 2 | `distribution-search` | ✓ 1 | 0 | 162 |  |
| 2 | `dna-assembly` | ✗ 0 | — | 720 | AgentTimeoutError |
| 2 | `dna-insert` | ✗ 0 | 0 | 154 |  |
| 3 | `extract-elf` | ✗ 0 | 0 | 62 |  |
| 3 | `feal-differential-cryptanalysis` | ✓ 1 | 0 | 235 |  |
| 3 | `feal-linear-cryptanalysis` | ✓ 1 | 0 | 222 |  |
| 3 | `filter-js-from-html` | ✗ 0 | 0 | 55 |  |
| 3 | `financial-document-processor` | ✓ 1 | 0 | 152 |  |
| 3 | `fix-code-vulnerability` | ✓ 1 | 0 | 42 |  |
| 3 | `fix-git` | ✓ 1 | 0 | 42 |  |
| 3 | `fix-ocaml-gc` | ✓ 1 | 0 | 294 |  |
| 3 | `git-leak-recovery` | ✓ 1 | 0 | 18 |  |
| 3 | `gpt2-codegolf` | ✗ 0 | 0 | 429 |  |
| 4 | `hf-model-inference` | ✓ 1 | 0 | 169 |  |
| 4 | `install-windows-3.11` | — | — | — | RuntimeError |
| 4 | `kv-store-grpc` | ✓ 1 | 0 | 171 |  |
| 4 | `large-scale-text-editing` | ✓ 1 | 0 | 60 |  |
| 4 | `largest-eigenval` | ✓ 1 | 0 | 45 |  |
| 4 | `log-summary-date-ranges` | ✓ 1 | 0 | 16 |  |
| 4 | `mailman` | ✓ 1 | 0 | 292 |  |
| 4 | `make-doom-for-mips` | ✗ 0 | — | 900 | AgentTimeoutError |
| 4 | `make-mips-interpreter` | ✓ 1 | 0 | 794 |  |
| 4 | `mcmc-sampling-stan` | ✓ 1 | 0 | 399 |  |
| 5 | `merge-diff-arc-agi-task` | ✓ 1 | 0 | 86 |  |
| 5 | `model-extraction-relu-logits` | ✗ 0 | 0 | 121 |  |
| 5 | `mteb-leaderboard` | ✗ 0 | 0 | 428 |  |
| 5 | `mteb-retrieve` | ✗ 0 | 0 | 47 |  |
| 5 | `nginx-request-logging` | ✓ 1 | 0 | 172 |  |
| 5 | `openssl-selfsigned-cert` | ✗ 0 | 0 | 28 |  |
| 5 | `password-recovery` | ✓ 1 | 0 | 182 |  |
| 5 | `path-tracing` | ✓ 1 | 0 | 1618 |  |
| 5 | `path-tracing-reverse` | ✓ 1 | 0 | 1422 |  |
| 5 | `polyglot-c-py` | ✗ 0 | 0 | 85 |  |
| 6 | `polyglot-rust-c` | ✗ 0 | 0 | 390 |  |
| 6 | `prove-plus-comm` | ✓ 1 | 0 | 18 |  |
| 6 | `pypi-server` | ✓ 1 | 0 | 165 |  |
| 6 | `pytorch-model-cli` | ✓ 1 | 0 | 109 |  |
| 6 | `pytorch-model-recovery` | ✓ 1 | 0 | 41 |  |
| 6 | `qemu-alpine-ssh` | ✗ 0 | — | 900 | AgentTimeoutError |
| 6 | `qemu-startup` | ✓ 1 | 0 | 192 |  |
| 6 | `query-optimize` | ✓ 1 | 0 | 188 |  |
| 6 | `regex-log` | ✓ 1 | 0 | 88 |  |
| 6 | `reshard-c4-data` | ✓ 1 | 0 | 184 |  |
| 7 | `rstan-to-pystan` | ✓ 1 | 0 | 326 |  |
| 7 | `sanitize-git-repo` | ✓ 1 | 0 | 76 |  |
| 7 | `schemelike-metacircular-eval` | ✓ 1 | 0 | 472 |  |
| 7 | `sparql-university` | ✓ 1 | 0 | 77 |  |
| 7 | `sqlite-db-truncate` | ✓ 1 | 0 | 55 |  |
| 7 | `sqlite-with-gcov` | ✓ 1 | 0 | 61 |  |
| 7 | `torch-pipeline-parallelism` | ✓ 1 | 0 | 155 |  |
| 7 | `torch-tensor-parallelism` | ✗ 0 | 0 | 60 |  |
| 7 | `train-fasttext` | ✗ 0 | 0 | 1329 |  |
| 7 | `tune-mjcf` | ✓ 1 | 0 | 575 |  |
| 8 | `video-processing` | ✓ 1 | 0 | 461 |  |

## Failures classified

### Infra failures (not kwwk's fault)

| Task | Why |
|---|---|
| `install-windows-3.11` | Task's docker compose `up --wait` failed — container exited with code 2 before kwwk ever ran. Task itself is broken (or this build of the task image is). |
| `dna-assembly` | Harbor `AgentTimeoutError` after 720s. xhigh thinking + complex primer3 / Golden Gate workflow needs more than the task's per-agent timeout budget. |
| `make-doom-for-mips` | Harbor `AgentTimeoutError` after 900s. Cross-compiling DOOM for MIPS in xhigh-thinking mode exceeded the budget. |
| `qemu-alpine-ssh` | Harbor `AgentTimeoutError` after 900s. Booting Alpine in QEMU + SSH-ing in needs more wall-clock than the budget. |

### Real kwwk failures (verifier ran, kwwk did not produce a passing solution)

Total: **17**

- `adaptive-rejection-sampler` (dur=372s)
- `build-cython-ext` (dur=204s)
- `build-pov-ray` (dur=74s)
- `chess-best-move` (dur=373s)
- `configure-git-webserver` (dur=190s)
- `dna-insert` (dur=154s)
- `extract-elf` (dur=62s)
- `filter-js-from-html` (dur=55s)
- `gpt2-codegolf` (dur=429s)
- `model-extraction-relu-logits` (dur=121s)
- `mteb-leaderboard` (dur=428s)
- `mteb-retrieve` (dur=47s)
- `openssl-selfsigned-cert` (dur=28s)
- `polyglot-c-py` (dur=85s)
- `polyglot-rust-c` (dur=390s)
- `torch-tensor-parallelism` (dur=60s)
- `train-fasttext` (dur=1329s)

## Notable wins

- `caffe-cifar-10` ✓ — bigger ML setup task, surprised given prior runs failed it.
- `path-tracing` + `path-tracing-reverse` ✓ — graphics ray-tracing tasks both passed (24-27 min each, near task timeout).
- `feal-differential-cryptanalysis` + `feal-linear-cryptanalysis` ✓ — pure cryptanalysis algorithms.
- `prove-plus-comm` ✓ in **18s** — a Coq/proof task one-shot.
- `make-mips-interpreter` ✓ after **12 ×600s 429 backoffs** — driver's rate-limit retry loop worked.

## Operational issues encountered

### Harbor Supabase backend (522)
Harbor's PostgREST + Storage endpoints returned 522 throughout. Patched `harbor.db.client._rpc_retry` to also retry PostgREST `APIError` 5xx (didn't help, origin was hard-down) and bypassed via local JSON registry pointing at HuggingFace.

### Harbor `--filter=blob:none` + HuggingFace LFS promisor
Harbor's `_download_tasks_from_git_url` clones with `--filter=blob:none --no-checkout`. HuggingFace's git server doesn't implement the promisor protocol, so subsequent `git checkout` failed with `expected 'packfile'`. Patched harbor to drop the filter and added `git-lfs` install.

### kwwk OAuth refresh persistence
`kwwk_agent.py` originally `cp`'d host's `oauth.json` into each container. kwwk's `OAuthStore.persist()` uses atomic write (`Data.write(..., options: .atomic)` = write tmpfile + `rename(2)`) which **replaces a per-file symlink** on disk. Net effect: container-side refresh succeeded, rotated the refresh_token server-side (Anthropic invalidates the old one after a grace period), but the new token was written to the in-container copy and lost on container teardown. After enough containers, host's stored refresh_token was stale and every trial 401-ed.

**Fix:** bind-mount `/root/.kwwk` directory (not the file) into the container at `/mnt/kwwk_dot`, and have `kwwk_agent.py` symlink the entire `$HOME/.kwwk` directory to it. Atomic rename now happens inside the bind-mounted directory and persists.

### Anthropic OAuth rate limit (429)
Hit during long sessions. Driver wraps each task in an infinite retry loop — sleep 600s on 429 (with the trial discarded), then re-invoke harbor for that task. `make-mips-interpreter` recovered after 12 backoffs.

### GLIBC mismatch (jammy build)
Originally built with `swift:6.1-jammy` (glibc 2.35). Failed with `version 'GLIBC_2.34' not found` on Debian-bullseye-based task images (qemu-*). **Fix:** rebuilt with `swift:6.1-focal` (glibc 2.31). Resulting binary needs only GLIBC ≤ 2.29 — universally compatible. Bundled runtime libs also re-extracted from focal.

### Harbor `docker compose` v1 vs v2
Default Ubuntu `docker.io` package ships docker only (no compose). Installed `docker-compose-v2`.

## Suggested upstream fixes (PR feedback)

1. **`build_kwwk_linux.sh` should default to `swift:6.1-focal`** (not `swift:6.1-jammy`). focal-built binary works on every TB2 task image we tried; jammy-built one breaks on bullseye-based ones.
2. **`kwwk_agent.py` install step should symlink the `.kwwk` directory, not `cp` the oauth file.** Otherwise OAuth refresh is silently lost across container boundary, ultimately bricking the host's refresh token on long benchmark runs.
3. **`KwwkHarborAgent.run` should pass through a `thinking_level` agent kwarg** (currently hardcoded to default `medium` because `kwwk -p` is invoked without `--thinking`).

## Driver / harness

- `scripts/run_all_chunks.sh` — chunked driver, 8 chunks × 10 task (last chunk 1), per-task k=1 with `-n 1`.
- 429-aware: failed trial detected via `kwwk-stderr.log` containing `rate_limit_error`, trial dir deleted, sleep 600s, retry — no upper bound.
- 401-aware: aborts (no point sleeping if OAuth is bad).
- Resume: skips tasks whose `<task>-trial-{1..k}` dirs already exist in the chunk's final dir.
- After each chunk: regenerates markdown report + `docker system prune -af --volumes`.
