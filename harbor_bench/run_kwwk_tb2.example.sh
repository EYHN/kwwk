#!/usr/bin/env bash
# Example: Terminal-Bench 2 (terminal-bench-2) + kwwk inside Harbor.
# Prerequisites: Docker daemon running; Linux kwwk binary; oauth.json from `kwwk login`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
export PYTHONPATH="${ROOT}${PYTHONPATH:+:${PYTHONPATH}}"

KWWK_BIN="${KWWK_BIN:-${ROOT}/harbor_bench/secrets/kwwk}"
KWWK_RESOURCES="${KWWK_RESOURCES:-${ROOT}/harbor_bench/secrets/kwwk_KWWKAI.resources}"
# Same default as `kwwk login` (e.g. /Users/eyhn/.kwwk/oauth.json on macOS, ~/.kwwk/oauth.json on Linux).
OAUTH_JSON="${OAUTH_JSON:-${HOME}/.kwwk/oauth.json}"

if [[ ! -f "${KWWK_BIN}" ]]; then
  echo "Set KWWK_BIN to your Linux kwwk binary path (currently missing: ${KWWK_BIN})" >&2
  exit 1
fi
if [[ ! -d "${KWWK_RESOURCES}" ]]; then
  echo "Set KWWK_RESOURCES to the kwwk_KWWKAI.resources dir (from swift build, missing: ${KWWK_RESOURCES})" >&2
  echo "  Run: ./harbor_bench/build_kwwk_linux.sh" >&2
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
    {'type': 'bind', 'source': os.path.abspath('${KWWK_RESOURCES}'), 'target': '/mnt/kwwk/kwwk_KWWKAI.resources'},
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
