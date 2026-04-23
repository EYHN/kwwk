#!/usr/bin/env bash
# Copy non-glibc .so files needed for kwwk (e.g. libcurl, ssl, zstd) from ldd(1)
# so TB2 task images without libcurl can run kwwk. We intentionally skip
# libc/libm/ld/libstdc++/libgcc to avoid fighting the base image C runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KWWK="${KWWK_BIN:-$ROOT/harbor_bench/secrets/kwwk}"
OUT="$ROOT/harbor_bench/secrets/kwwk-runtime-libs"

if [[ ! -x "$KWWK" ]]; then
  echo "Missing executable: $KWWK" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

skip_base() {
  case "$(basename "$1")" in
  libc.so.6|ld-linux-*.so.*|libm.so.6|libmvec.so.1|libstdc++.so.6|libgcc_s.so.1|libpthread.so.0|librt.so.1|libdl.so.2|libresolv.so.2|libnss_*.so.*)
    return 0
    ;;
  esac
  return 1
}

while IFS= read -r line; do
  f=$(echo "$line" | sed -n 's/.* => \(.*\) (0x.*/\1/p')
  [[ -z "$f" || ! -f "$f" ]] && continue
  if skip_base "$f"; then
    continue
  fi
  base="$(basename "$f")"
  cp -L "$f" "$OUT/$base"
done < <(ldd "$KWWK" 2>/dev/null)

echo "Bundled $(find "$OUT" -type f | wc -l) dynamic libs (excluding C runtime) into $OUT"
ls -la "$OUT" | head -25
