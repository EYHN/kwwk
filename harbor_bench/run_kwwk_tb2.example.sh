#!/usr/bin/env bash
# Example: Terminal-Bench 2 (terminal-bench-2) + kwwk inside Harbor.
# Prerequisites: Docker daemon running; Linux kwwk binary; oauth.json from `kwwk login`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
export PYTHONPATH="${ROOT}${PYTHONPATH:+:${PYTHONPATH}}"

KWWK_BIN="${KWWK_BIN:-${ROOT}/harbor_bench/secrets/kwwk}"
KWWK_RESOURCES="${KWWK_RESOURCES:-${ROOT}/harbor_bench/secrets/kwwk_KWWKAI.resources}"
KWWK_RUNTIME_LIBS="${KWWK_RUNTIME_LIBS:-${ROOT}/harbor_bench/secrets/kwwk-runtime-libs}"
# Same default as `kwwk login` (e.g. /Users/eyhn/.kwwk/oauth.json on macOS, ~/.kwwk/oauth.json on Linux).
OAUTH_JSON="${OAUTH_JSON:-${HOME}/.kwwk/oauth.json}"
# kwwk/libcurl needs a CA bundle; base images (host net) may lack a full /etc/ssl/certs.
SSL_CERTS_DIR="${SSL_CERTS_DIR:-/etc/ssl/certs}"

if [[ ! -f "${KWWK_BIN}" ]]; then
  echo "Set KWWK_BIN to your Linux kwwk binary path (currently missing: ${KWWK_BIN})" >&2
  exit 1
fi
if [[ ! -d "${KWWK_RESOURCES}" ]]; then
  echo "Set KWWK_RESOURCES to the kwwk_KWWKAI.resources dir (from swift build, missing: ${KWWK_RESOURCES})" >&2
  echo "  Run: ./harbor_bench/build_kwwk_linux.sh" >&2
  exit 1
fi
if [[ ! -d "${KWWK_RUNTIME_LIBS}" || -z "$(ls -A "${KWWK_RUNTIME_LIBS}" 2>/dev/null)" ]]; then
  echo "Run: ./harbor_bench/bundle_kwwk_runtime_libs.sh" >&2
  exit 1
fi
if [[ ! -f "${OAUTH_JSON}" ]]; then
  echo "Set OAUTH_JSON or place oauth.json at ${OAUTH_JSON}" >&2
  exit 1
fi
if [[ ! -d "${SSL_CERTS_DIR}" ]]; then
  echo "SSL_CERTS_DIR must be a directory (missing: ${SSL_CERTS_DIR})" >&2
  exit 1
fi

MOUNTS="$(SSL_CERTS_DIR="${SSL_CERTS_DIR}" KWWK_BIN="${KWWK_BIN}" KWWK_RESOURCES="${KWWK_RESOURCES}" KWWK_RUNTIME_LIBS="${KWWK_RUNTIME_LIBS}" OAUTH_JSON="${OAUTH_JSON}" python3 -c "
import json, os
certs = os.environ['SSL_CERTS_DIR']
print(json.dumps([
    {'type': 'bind', 'source': os.path.abspath(os.environ['KWWK_BIN']), 'target': '/mnt/kwwk/kwwk'},
    {'type': 'bind', 'source': os.path.abspath(os.environ['KWWK_RESOURCES']), 'target': '/mnt/kwwk/kwwk_KWWKAI.resources'},
    {'type': 'bind', 'source': os.path.abspath(os.environ['KWWK_RUNTIME_LIBS']), 'target': '/mnt/kwwk/runtime-libs'},
    {'type': 'bind', 'source': os.path.abspath(os.environ['OAUTH_JSON']), 'target': '/mnt/kwwk/oauth.json'},
    {'type': 'bind', 'source': os.path.abspath(certs), 'target': '/etc/ssl/certs'},
]))
")"

# Default concurrency only if caller did not pass -n / --n-concurrent (avoid duplicate -n).
has_n=0
for a in "$@"; do
  if [[ "$a" == "-n" || "$a" == "--n-concurrent" ]]; then
    has_n=1
    break
  fi
done
default_n=()
if [[ "$has_n" -eq 0 ]]; then
  default_n=( -n "${N_CONCURRENT:-4}" )
fi

exec harbor run \
  -d terminal-bench/terminal-bench-2 \
  --agent-import-path harbor_bench.kwwk_agent:KwwkHarborAgent \
  --ak kwwk_binary_container=/mnt/kwwk/kwwk \
  --ak oauth_container_path=/mnt/kwwk/oauth.json \
  --mounts-json "${MOUNTS}" \
  -y \
  "${default_n[@]}" \
  "$@"
