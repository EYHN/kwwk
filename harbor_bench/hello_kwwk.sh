#!/usr/bin/env bash
# Minimal smoke: kwwk answers a one-line "say hello" prompt.
# Requires: harbor_bench/secrets/kwwk, kwwk_KWWKAI.resources (same dir), kwwk-runtime-libs, ~/.kwwk/oauth.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KWWK="${KWWK_BIN:-$ROOT/harbor_bench/secrets/kwwk}"
RUNTIME="$ROOT/harbor_bench/secrets/kwwk-runtime-libs"
RES_DIR="$ROOT/harbor_bench/secrets/kwwk_KWWKAI.resources"

if [[ ! -x "$KWWK" || ! -d "$RES_DIR" ]]; then
  echo "Run: ./harbor_bench/build_kwwk_linux.sh" >&2
  exit 1
fi
if [[ ! -d "$RUNTIME" ]] || [[ -z "$(ls -A "$RUNTIME" 2>/dev/null)" ]]; then
  echo "Run: ./harbor_bench/bundle_kwwk_runtime_libs.sh" >&2
  exit 1
fi
if [[ ! -f "$HOME/.kwwk/oauth.json" ]]; then
  echo "Missing ~/.kwwk/oauth.json (kwwk login)" >&2
  exit 1
fi

export LD_LIBRARY_PATH="$RUNTIME${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
PROMPT="${1:-Reply with the single word hello and nothing else.}"

out=$(mktemp)
err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT
set +e
"$KWWK" -p "$PROMPT" >"$out" 2>"$err"
code=$?
set -e
if [[ -s "$err" ]]; then
  cat "$err" >&2
fi
echo "exit: $code" >&2
if grep -qi 'hello' "$out"; then
  echo "PASS: reply contains 'hello': $(head -c 200 <"$out" | tr '\n' ' ')" >&2
  exit 0
fi
echo "FAIL: no 'hello' in stdout" >&2
exit 1
