#!/usr/bin/env bash
# Build a Linux x86_64 `kwwk` binary using the official Swift 6.1 image.
# Requires: Docker, network (use --network host if the default bridge has no DNS).
# Output:  repo/.build/release/kwwk
#          copies to harbor_bench/secrets/kwwk (for Terminal-Bench / Harbor).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Default to 22.04 (glibc 2.35) so the binary runs inside TB2 / Harbor task images
# (older glibc) — noble uses glibc 2.39+ and may require symbols missing on jammy.
IMAGE="${KWWK_SWIFT_IMAGE:-swift:6.1-focal}"

docker pull "$IMAGE" >/dev/null
docker run --rm --network host \
  -v "$ROOT":/src -w /src \
  "$IMAGE" \
  bash -lc 'swift build -c release -Xswiftc -static-stdlib'

OUT="$ROOT/.build/release/kwwk"
BUNDLE_DIR="$ROOT/.build/x86_64-unknown-linux-gnu/release/kwwk_KWWKAI.resources"
if [[ ! -x "$OUT" ]]; then
  echo "Build failed: missing $OUT" >&2
  exit 1
fi
if [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "Build failed: missing KWWKAI resource bundle at $BUNDLE_DIR" >&2
  exit 1
fi

mkdir -p "$ROOT/harbor_bench/secrets"
cp -f "$OUT" "$ROOT/harbor_bench/secrets/kwwk"
chmod +x "$ROOT/harbor_bench/secrets/kwwk"
rm -rf "$ROOT/harbor_bench/secrets/kwwk_KWWKAI.resources"
cp -a "$BUNDLE_DIR" "$ROOT/harbor_bench/secrets/"

echo "OK: $OUT"
echo "     -> $ROOT/harbor_bench/secrets/kwwk + kwwk_KWWKAI.resources"
ldd "$OUT" | head -8

KWWK_BIN="$OUT" "$ROOT/harbor_bench/bundle_kwwk_runtime_libs.sh"
