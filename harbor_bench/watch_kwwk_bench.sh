#!/usr/bin/env bash
# After each kwwk run, trial agent dir contains kwwk-{stdout,stderr,exit}.log
# This script reports new kwwk-exit.code files and stderr snippets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${ROOT}/jobs"
INTERVAL="${1:-45}"
STATE="${ROOT}/.kwwk_watch_state.txt"
touch "$STATE"

echo "Watching $JOBS (interval ${INTERVAL}s). State: $STATE"

while true; do
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! grep -Fxq "$f" "$STATE" 2>/dev/null; then
      echo "$f" >>"$STATE"
      trial_dir="$(dirname "$(dirname "$f")")"
      trial="$(basename "$trial_dir")"
      code=$(cat "$f" 2>/dev/null || echo "?")
      echo "=== $trial  kwwk exit=$code ==="
      d="$(dirname "$f")"
      if [[ -f "$d/kwwk-stderr.log" && -s "$d/kwwk-stderr.log" ]]; then
        head -c 6000 "$d/kwwk-stderr.log" | sed 's/^/[stderr] /' || true
        echo ""
      else
        echo "[stderr] (empty or missing)"
      fi
    fi
  done < <(find "$JOBS" -name kwwk-exit.code -type f 2>/dev/null | sort)
  sleep "$INTERVAL"
done
