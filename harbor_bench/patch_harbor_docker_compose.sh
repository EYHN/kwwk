#!/usr/bin/env bash
# Apply harbor_bench/docker-compose-base.patched-for-threaded-cgroup.yaml to the
# installed Harbor package (adds network_mode: host; resource limits already dropped).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/harbor_bench/docker-compose-base.patched-for-threaded-cgroup.yaml"
DEST="$(python3 -c "import harbor.environments.docker as d, pathlib; print(pathlib.Path(d.__file__).parent / 'docker-compose-base.yaml')")"
if [[ ! -f "$SRC" ]]; then
  echo "Missing $SRC" >&2
  exit 1
fi
cp -f "$SRC" "$DEST"
echo "OK: updated $DEST"
