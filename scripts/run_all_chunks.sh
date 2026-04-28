#!/usr/bin/env bash
# Run all 71 TB2 tasks in chunks of 10, k=5 trials each, serial (-n 1).
# 429-aware: any trial that died at turn=1 from rate_limit_error is discarded;
# we sleep 10 minutes and retry that task until 5 clean trials are collected.
# Retry loop has NO upper bound — it keeps trying every 10 min until success.
# After each chunk: write report + docker prune, then continue.
set -uo pipefail

ROOT=/root/kwwk
REGISTRY="$ROOT/chunks/tb2-local-registry.json"
CHUNKS_DIR="$ROOT/chunks"
mkdir -p "$CHUNKS_DIR"

export PATH="$ROOT/.venv/bin:${PATH}"
export PYTHONPATH="$ROOT"

mapfile -t TASKS < <(python3 -c "import json; print('\n'.join(t['name'] for t in json.load(open('$REGISTRY'))[0]['tasks']))")
NUM=${#TASKS[@]}
CHUNK_SIZE=10
K_PER_TASK=1
RETRY_SLEEP=600  # 10 minutes

MOUNTS_JSON='[{"type":"bind","source":"/root/kwwk/harbor_bench/secrets/kwwk","target":"/mnt/kwwk/kwwk"},{"type":"bind","source":"/root/kwwk/harbor_bench/secrets/kwwk_KWWKAI.resources","target":"/mnt/kwwk/kwwk_KWWKAI.resources"},{"type":"bind","source":"/root/kwwk/harbor_bench/secrets/kwwk-runtime-libs","target":"/mnt/kwwk/runtime-libs"},{"type":"bind","source":"/root/.kwwk/oauth.json","target":"/mnt/kwwk/oauth.json"},{"type":"bind","source":"/root/.kwwk","target":"/mnt/kwwk_dot"},{"type":"bind","source":"/etc/ssl/certs","target":"/etc/ssl/certs"}]'

is_429() {
  local trial_dir="$1"
  grep -q "rate_limit_error\|status 429" "$trial_dir/agent/kwwk-stderr.log" 2>/dev/null
}

is_401_auth() {
  local trial_dir="$1"
  grep -q "status 401\|authentication_error\|x-api-key header is required" "$trial_dir/agent/kwwk-stderr.log" 2>/dev/null
}

# run_one_task <chunk_n> <task_name> <final_dir>
# Collects exactly $K_PER_TASK clean (non-429) trials into $final_dir/<task>-trial-N.
# Discards 429 trials and sleeps RETRY_SLEEP between retries. Infinite retry on 429.
run_one_task() {
  local chunk_n=$1
  local task=$2
  local final_dir=$3

  local collected=0
  local retry=0
  local target_chunk_job="opus47-tb2-chunk$(printf '%02d' "$chunk_n")"

  while [ "$collected" -lt "$K_PER_TASK" ]; do
    retry=$((retry+1))
    local need=$((K_PER_TASK - collected))
    local job_name="${target_chunk_job}-${task}-r${retry}"

    echo "===TRIAL_BATCH_START chunk=$chunk_n task=$task retry=$retry collected=$collected need=$need==="

    harbor run \
      --registry-path "$REGISTRY" \
      -d tb2-local@2.0 \
      -i "$task" \
      --agent-import-path harbor_bench.kwwk_agent:KwwkHarborAgent \
      --ak kwwk_binary_container=/mnt/kwwk/kwwk \
      --ak oauth_container_path=/mnt/kwwk/oauth.json \
      --mounts-json "$MOUNTS_JSON" \
      -y -k "$need" -n 1 \
      --job-name "$job_name" \
      --jobs-dir "$ROOT/jobs" \
      >>"$CHUNKS_DIR/chunk$(printf '%02d' "$chunk_n").log" 2>&1
    local exit_code=$?

    local job_dir="$ROOT/jobs/$job_name"
    local batch_429=0
    local batch_ok=0

    local batch_401=0
    if [ -d "$job_dir" ]; then
      for trial_dir in "$job_dir"/*/; do
        [ -d "$trial_dir" ] || continue
        if is_401_auth "$trial_dir"; then
          batch_401=$((batch_401+1))
        elif is_429 "$trial_dir"; then
          batch_429=$((batch_429+1))
        else
          collected=$((collected+1))
          batch_ok=$((batch_ok+1))
          mkdir -p "$final_dir"
          cp -a "$trial_dir" "$final_dir/${task}-trial-${collected}"
        fi
      done
    fi

    # Discard the temp job dir entirely (we copied what we need)
    rm -rf "$job_dir"

    # 401 = OAuth expired/invalid. Sleeping won't help — abort the whole run.
    if [ "$batch_401" -gt 0 ]; then
      echo "===AUTH_ERROR_ABORT chunk=$chunk_n task=$task batch_401=$batch_401 — re-run kwwk login then restart driver==="
      exit 3
    fi

    echo "===TRIAL_BATCH_DONE chunk=$chunk_n task=$task retry=$retry exit=$exit_code ok=$batch_ok 429=$batch_429 collected=$collected/$K_PER_TASK==="

    if [ "$collected" -lt "$K_PER_TASK" ]; then
      echo "===RATE_LIMIT_BACKOFF chunk=$chunk_n task=$task sleep=${RETRY_SLEEP}s==="
      sleep "$RETRY_SLEEP"
    fi
  done
}

echo "===RUN_START total_tasks=$NUM chunks=$(((NUM+CHUNK_SIZE-1)/CHUNK_SIZE)) k=$K_PER_TASK retry_sleep=${RETRY_SLEEP}s==="

i=0
n=0
while [ $i -lt $NUM ]; do
  n=$((n+1))
  end=$((i+CHUNK_SIZE))
  [ $end -gt $NUM ] && end=$NUM
  size=$((end-i))
  chunk_tasks=("${TASKS[@]:$i:$size}")

  chunk_pad=$(printf '%02d' $n)
  final_dir="$ROOT/jobs/opus47-tb2-chunk${chunk_pad}"
  mkdir -p "$final_dir"
  log="$CHUNKS_DIR/chunk${chunk_pad}.log"
  report="$CHUNKS_DIR/chunk${chunk_pad}.report.md"

  echo "===CHUNK_START n=$n size=$size tasks=${chunk_tasks[*]}==="
  start_ts=$(date +%s)
  : >"$log"

  for task in "${chunk_tasks[@]}"; do
    # Resume: skip task if its expected k=K_PER_TASK trial dirs already exist.
    skip=1
    for k in $(seq 1 $K_PER_TASK); do
      [ -d "$final_dir/${task}-trial-${k}" ] || { skip=0; break; }
    done
    if [ "$skip" -eq 1 ]; then
      echo "===TASK_SKIP chunk=$n task=$task (already collected ${K_PER_TASK} trials)==="
      continue
    fi
    run_one_task "$n" "$task" "$final_dir"
  done

  end_ts=$(date +%s)
  dur=$((end_ts-start_ts))

  python3 "$ROOT/scripts/report_chunk.py" "$(basename "$final_dir")" "$report" 2>>"$log" || true

  prune_log="$CHUNKS_DIR/chunk${chunk_pad}.prune.log"
  docker system prune -af --volumes >"$prune_log" 2>&1 || true

  disk=$(df -h / | awk 'NR==2 {print $4 " avail (" $5 " used)"}')
  echo "===CHUNK_DONE n=$n dur_s=$dur disk=[$disk] report=$report==="

  i=$end
done

echo "===RUN_DONE chunks=$n==="
