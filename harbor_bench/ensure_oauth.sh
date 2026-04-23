#!/usr/bin/env bash
# Install ~/.kwwk/oauth.json from a local file or from $KWWK_OAUTH_B64 (base64 of file).
# Example:  KWWK_OAUTH_B64=$(base64 -i ~/Downloads/oauth.json) ./harbor_bench/ensure_oauth.sh
set -euo pipefail

DEST="${HOME}/.kwwk/oauth.json"
mkdir -m 700 -p "${HOME}/.kwwk"

if [[ -n "${KWWK_OAUTH_B64:-}" ]]; then
  echo "Writing ${DEST} from KWWK_OAUTH_B64"
  printf '%s' "$KWWK_OAUTH_B64" | base64 -d >"$DEST"
elif [[ -n "${KWWK_OAUTH_FILE:-}" && -f "$KWWK_OAUTH_FILE" ]]; then
  echo "Copying $KWWK_OAUTH_FILE -> ${DEST}"
  cp "$KWWK_OAUTH_FILE" "$DEST"
elif [[ -f "$DEST" ]]; then
  echo "${DEST} already exists; not overwriting"
  exit 0
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "${ROOT}/harbor_bench/oauth.json.example" ]]; then
    echo "No credentials supplied — copying placeholder from oauth.json.example"
    echo "Replace tokens before running the benchmark."
    cp "${ROOT}/harbor_bench/oauth.json.example" "$DEST"
  else
    echo "No oauth source. Set KWWK_OAUTH_B64, KWWK_OAUTH_FILE, or paste a real file to ${DEST}" >&2
    exit 1
  fi
fi

chmod 600 "$DEST"
echo "Created or updated: ${DEST}"
