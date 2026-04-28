#!/usr/bin/env python3
"""Generate a markdown report for a single chunk job."""
from __future__ import annotations
import json
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

job_name = sys.argv[1]
out_path = Path(sys.argv[2])
job_dir = Path("/root/kwwk/jobs") / job_name

trial_results = []
for trial_dir in sorted(job_dir.iterdir()):
    if not trial_dir.is_dir():
        continue
    rj = trial_dir / "result.json"
    if rj.exists():
        trial_results.append((trial_dir, json.load(open(rj))))

by_task: dict[str, list] = defaultdict(list)
for td, tr in trial_results:
    by_task[tr["task_name"]].append((td, tr))

def dur(tr):
    a = tr.get("agent_execution") or {}
    s = a.get("started_at"); e = a.get("finished_at")
    if not s or not e:
        return 0
    return (datetime.fromisoformat(e.rstrip("Z")) - datetime.fromisoformat(s.rstrip("Z"))).total_seconds()

lines: list[str] = []
lines.append(f"# Chunk report: {job_name}")
lines.append("")

def _reward(tr):
    vr = tr.get("verifier_result")
    if not vr: return None
    return (vr.get("rewards") or {}).get("reward")
all_rewards = [_reward(tr) for _, tr in trial_results if _reward(tr) is not None]
lines.append(f"- Trials: **{len(trial_results)}**, Tasks: **{len(by_task)}**")
if all_rewards:
    lines.append(f"- Mean reward (all trials): **{statistics.mean(all_rewards):.3f}**")
    n_pass = sum(1 for r in all_rewards if r > 0)
    lines.append(f"- Trials passed: **{n_pass}/{len(all_rewards)}** ({100*n_pass/len(all_rewards):.1f}%)")
lines.append("")
lines.append("| Task | k=5 mean | pass@1 | exit codes | dur median (s) |")
lines.append("|------|----------|--------|-----------|----------------|")
for task in sorted(by_task):
    items = by_task[task]
    rewards = [r for r in (_reward(tr) for _, tr in items) if r is not None]
    mean = statistics.mean(rewards) if rewards else float("nan")
    pass_any = 1 if rewards and max(rewards) > 0 else 0
    if not rewards:
        # All trials failed before verifier (e.g. environment build error / agent timeout).
        # Surface via exit_codes column so we can see what happened.
        pass
    exit_codes = []
    for td, _ in items:
        ed = td / "agent" / "kwwk-exit.code"
        exit_codes.append(open(ed).read().strip() if ed.exists() else "?")
    durs = [dur(tr) for _, tr in items]
    lines.append(f"| {task} | {mean:.2f} | {pass_any} | {','.join(exit_codes)} | {statistics.median(durs):.0f} |")

# Exception summary
exc_counts: dict[str, int] = defaultdict(int)
for _, tr in trial_results:
    ex = tr.get("exception_info")
    if ex:
        key = ex.get("type") or "?"
        exc_counts[key] += 1
if exc_counts:
    lines.append("")
    lines.append("### Exceptions")
    for k, v in exc_counts.items():
        lines.append(f"- `{k}`: {v}")

out_path.write_text("\n".join(lines) + "\n")
print(f"Wrote {out_path}")
