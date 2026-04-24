#!/usr/bin/env bash
# Smoke test: run kwwk -p (hello) inside a throwaway container with --network host,
# using the same bind layout as Harbor (mounts + LD_LIBRARY_PATH) as kwwk_agent.py.
# Use after ./harbor_bench/patch_harbor_docker_compose.sh so TB tasks also use host network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KWWK="${KWWK_BIN:-$ROOT/harbor_bench/secrets/kwwk}"
RES="${KWWK_RESOURCES:-$ROOT/harbor_bench/secrets/kwwk_KWWKAI.resources}"
LIBS="${KWWK_RUNTIME_LIBS:-$ROOT/harbor_bench/secrets/kwwk-runtime-libs}"
OAUTH="${OAUTH_JSON:-$HOME/.kwwk/oauth.json}"
IMAGE="${KWWK_HELLO_CONTAINER_IMAGE:-ubuntu:22.04}"
PROMPT="${1:-Reply with the single word hello and nothing else.}"

if [[ ! -x "$KWWK" || ! -d "$RES" ]]; then
  echo "Build kwwk and resources: ./harbor_bench/build_kwwk_linux.sh" >&2
  exit 1
fi
if [[ ! -d "$LIBS" ]] || [[ -z "$(ls -A "$LIBS" 2>/dev/null)" ]]; then
  echo "Run: ./harbor_bench/bundle_kwwk_runtime_libs.sh" >&2
  exit 1
fi
if [[ ! -f "$OAUTH" ]]; then
  echo "Missing oauth: $OAUTH" >&2
  exit 1
fi

docker info >/dev/null 2>&1 || {
  echo "Docker daemon not available" >&2
  exit 1
}

echo "Pulling $IMAGE (if needed)…"
docker pull "$IMAGE" >/dev/null

# Minimal images may lack /etc/ssl/certs; kwwk/libcurl needs a CA bundle for HTTPS.
SSLCERTS="${SSL_CERTS_DIR:-/etc/ssl/certs}"

docker run --rm --network host \
  -e "KWWK_PROMPT=$PROMPT" \
  -v "$(realpath "$KWWK"):/mnt/kwwk/kwwk:ro" \
  -v "$(realpath "$RES"):/mnt/kwwk/kwwk_KWWKAI.resources:ro" \
  -v "$(realpath "$LIBS"):/mnt/kwwk/runtime-libs:ro" \
  -v "$(realpath "$OAUTH"):/mnt/kwwk/oauth.json:ro" \
  -v "$SSLCERTS:/etc/ssl/certs:ro" \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    mkdir -p "$HOME/.kwwk"
    cp /mnt/kwwk/oauth.json "$HOME/.kwwk/oauth.json"
    export LD_LIBRARY_PATH="/mnt/kwwk/runtime-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    set +e
    /mnt/kwwk/kwwk -p "$KWWK_PROMPT" >/tmp/kout 2>/tmp/kerr
    code=$?
    set -e
    if [[ -s /tmp/kerr ]]; then
      echo "--- kwwk stderr ---" >&2
      cat /tmp/kerr >&2
    fi
    echo "exit: $code" >&2
    if grep -qi hello /tmp/kout; then
      echo "PASS: stdout contains hello" >&2
      exit 0
    fi
    echo "FAIL: no hello in stdout" >&2
    exit 1
  '
