#!/usr/bin/env bash
# Prepare host tooling for Terminal-Bench 2.0 via Harbor (Python 3.12+).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 1
fi

python3 -m pip install --user -r "${ROOT}/harbor_bench/requirements.txt"

# Use host network for Harbor task containers (fixes broken Docker bridge NAT in some cloud setups).
"${ROOT}/harbor_bench/patch_harbor_docker_compose.sh" || {
  echo "Warning: could not patch Harbor docker-compose-base.yaml. Re-run: ./harbor_bench/patch_harbor_docker_compose.sh" >&2
}

mkdir -p "${ROOT}/harbor_bench/secrets"
echo "Default OAUTH for run_kwwk_tb2.example.sh: \${HOME}/.kwwk/oauth.json (from kwwk login)."
echo "Override with: OAUTH_JSON=/path ./harbor_bench/run_kwwk_tb2.example.sh"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "Docker daemon is reachable."
else
  echo "Warning: Docker is not usable from this shell. Harbor needs a running Docker daemon." >&2
fi

echo "Harbor CLI: $(command -v harbor || echo 'missing — add ~/.local/bin to PATH')"
