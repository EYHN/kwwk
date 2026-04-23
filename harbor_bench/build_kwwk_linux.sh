#!/usr/bin/env bash
# Build a Linux x86_64 `kwwk` binary using the official Swift 6.1 image.
# Requires: Docker, network (use --network host if the default bridge has no DNS).
# Output:  repo/.build/release/kwwk
#          copies to harbor_bench/secrets/kwwk (for Terminal-Bench / Harbor).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${KWWK_SWIFT_IMAGE:-swift:6.1-noble}"

docker pull "$IMAGE" >/dev/null
docker run --rm --network host \
  -v "$ROOT":/src -w /src \
  "$IMAGE" \
  bash -lc 'swift build -c release -Xswiftc -static-stdlib'

OUT="$ROOT/.build/release/kwwk"
if [[ ! -x "$OUT" ]]; then
  echo "Build failed: missing $OUT" >&2
  exit 1
fi

mkdir -p "$ROOT/harbor_bench/secrets"
cp -f "$OUT" "$ROOT/harbor_bench/secrets/kwwk"
chmod +x "$ROOT/harbor_bench/secrets/kwwk"

echo "OK: $OUT"
echo "     -> $ROOT/harbor_bench/secrets/kwwk (for run_kwwk_tb2.example.sh / KWWK_BIN)"
ldd "$OUT" | head -8
