#!/usr/bin/env bash
# Example: Terminal-Bench 2 (terminal-bench-2) + kwwk inside Harbor.
# Prerequisites: Docker daemon running; Linux kwwk binary; oauth.json from `kwwk login`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
export PYTHONPATH="${ROOT}${PYTHONPATH:+:${PYTHONPATH}}"

KWWK_BIN="${KWWK_BIN:-${ROOT}/harbor_bench/secrets/kwwk}"
OAUTH_JSON="${OAUTH_JSON:-${ROOT}/harbor_bench/secrets/oauth.json}"

if [[ ! -f "${KWWK_BIN}" ]]; then
  echo "Set KWWK_BIN to your Linux kwwk binary path (currently missing: ${KWWK_BIN})" >&2
  exit 1
fi
if [[ ! -f "${OAUTH_JSON}" ]]; then
  echo "Set OAUTH_JSON or place oauth.json at ${OAUTH_JSON}" >&2
  exit 1
fi

MOUNTS="$(python3 -c "
import json, os
print(json.dumps([
    {'type': 'bind', 'source': os.path.abspath('${KWWK_BIN}'), 'target': '/mnt/kwwk/kwwk'},
    {'type': 'bind', 'source': os.path.abspath('${OAUTH_JSON}'), 'target': '/mnt/kwwk/oauth.json'},
]))
")"

exec harbor run \
  -d terminal-bench/terminal-bench-2 \
  --agent-import-path harbor_bench.kwwk_agent:KwwkHarborAgent \
  --ak kwwk_binary_container=/mnt/kwwk/kwwk \
  --ak oauth_container_path=/mnt/kwwk/oauth.json \
  --mounts-json "${MOUNTS}" \
  -n "${N_CONCURRENT:-4}" \
  -y \
  "$@"
