#!/usr/bin/env bash
# Run ldd inside the same glibc world as the Linux kwwk build (default: jammy) so
# we do not copy Ubuntu 24.04 OpenSSL (GLIBC_2.38+) by mistake.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KWWK="${KWWK_BIN:-$ROOT/harbor_bench/secrets/kwwk}"
OUT="$ROOT/harbor_bench/secrets/kwwk-runtime-libs"
# Must match the image used in build_kwwk_linux.sh
IMAGE="${KWWK_BUNDLE_IMAGE:-${KWWK_SWIFT_IMAGE:-swift:6.1-jammy}}"

if [[ ! -f "$KWWK" || ! -x "$KWWK" ]]; then
  echo "Missing kwwk at $KWWK (build with ./harbor_bench/build_kwwk_linux.sh first)" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

docker pull "$IMAGE" >/dev/null

# Copy non–C-runtime .so that ldd(1) would load for this binary, inside the build image.
docker run --rm --network host \
  -v "$ROOT":/work -w /work \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    K="/work/harbor_bench/secrets/kwwk"
    D="/work/harbor_bench/secrets/kwwk-runtime-libs"
    skip_base() {
      case "$(basename "$1")" in
      libc.so.6|ld-linux-*.so.*|libm.so.6|libmvec.so.1|libstdc++.so.6|libgcc_s.so.1|libpthread.so.0|librt.so.1|libdl.so.2|libresolv.so.2|libnss_*.so.*)
        return 0 ;;
      esac
      return 1
    }
    while IFS= read -r line; do
      f=$(echo "$line" | sed -n "s/.* => \(.*\) (0x.*/\1/p")
      [[ -z "$f" || ! -f "$f" ]] && continue
      if skip_base "$f"; then continue; fi
      cp -L -f "$f" "$D/$(basename "$f")"
    done < <(ldd "$K" 2>/dev/null)
    echo "Bundled $(find "$D" -type f | wc -l) files"
  '

ls -la "$OUT" | head -15
