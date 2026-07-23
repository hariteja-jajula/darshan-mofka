#!/bin/bash
# run_overnight.sh -- drive Claude Code unattended overnight on the darshan-mofka
# restructure. Re-invokes claude in a loop so that if one run ends (turn/output
# limit, transient error) it RESUMES and keeps going until every phase in
# progress.md is DONE or the wall-clock budget is hit.
#
# Usage (from a LOGIN node so it has internet for installs; screen/tmux/nohup so
# it survives your logout):
#     cd /home/hjajula/darshan-mofka-flowcept/darshan-mofka
#     tmux new -s overnight        # or: screen -S overnight
#     bash run_overnight.sh        # Ctrl-b d to detach (tmux)
#
# Logs: ./overnight_logs/run_<N>.log  and  ./overnight_logs/driver.log
# Stop early: touch ./overnight_logs/STOP
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$REPO"
BRANCH="feature/restructure-overnight"
LOGDIR="$REPO/overnight_logs"; mkdir -p "$LOGDIR"
DRIVER_LOG="$LOGDIR/driver.log"
MAX_HOURS="${MAX_HOURS:-9}"                 # wall-clock cap for the whole driver
MODEL="${CLAUDE_MODEL:-}"                    # e.g. CLAUDE_MODEL=opus (optional)
DEADLINE=$(( $(date +%s) + MAX_HOURS*3600 ))

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$DRIVER_LOG"; }

# The instruction handed to Claude Code every iteration. progress.md is the
# single source of truth; the agent must NOT stop until phases are done.
read -r -d '' PROMPT <<'EOF'
You are running UNATTENDED OVERNIGHT on the darshan-mofka repo. Work autonomously
and DO NOT STOP until all phases in progress.md are DONE (or you hit the node-hour
budget documented there).

FIRST, orient yourself:
1. git fetch origin && git rebase origin/feature/restructure-overnight (a second
   agent on Polaris may be pushing; integrate its work; smaller diff wins).
2. Read progress.md TOP TO BOTTOM. It is the durable plan + state + all locked
   user decisions + the budget table + the running log + the phase checkboxes.
   Also read EVALUATION.md for the quality bar.
3. Find the first phase NOT marked done and continue from there.

HARD RULES (from the user):
- Review EVERY line and EVERY file you add or keep: is it actually needed? Can it
  be simpler / reuse existing code? Prefer DELETING/MERGING over adding. Minimize
  lines of code and file count. This is the top priority for reviewability/PR.
- NEVER reference .so files / libraries / compiler runtimes by absolute path.
  Always via `module load` (or a var derived from a module). Spack externals in
  spack.yaml are the only allowed place for system prefixes.
- Every line added under darshan/ must have a vetted reason; record non-obvious
  reasons in the "darshan line-vetting log" section of progress.md.
- Non-destructive: keep the known-good pipeline working; only delete old files
  after the new path is verified end-to-end. New directories are fine if genuinely
  needed; too many LINES is what's bad, not directories.
- Node-hour budget: 30 (hard cap 40; +10 only for final tests). Charge PBS account
  radix-io. Log every job in progress.md's budget table (cluster, nodes, walltime,
  node-hrs, cumulative). Prefer the debug queue for short e2e checks.
- Unattended installs are pre-approved: pip/spack/git into the account/venv/scratch
  as needed; log each install in progress.md.
- If something fails, ROOT-CAUSE it (check the previous main-branch merge and the
  reference branches origin/feature/reproducible-split-nodes and
  origin/add-mpi-workload for how it worked). Do not skip a workload silently. If
  truly blocked after real attempts, document it, move to the next independent
  phase, and return later. Never idle.
- COMMIT + PUSH after every phase (and after any meaningful chunk). progress.md and
  EVALUATION.md ARE tracked now (cross-agent sync) - keep them updated and pushed.
- Overhead study specifics: baseline (connector OFF) vs mofka (ON), 3 reps each,
  for the C and python-ml workloads, on 2 nodes (1 workload + 1 server). Time the
  INITIALIZATION phase, AVERAGE PUSH cost, and FINALIZE phase; report mean/stddev
  walltime. Write results into results/<workload>_<timestamp>/ (jsonl,
  native.darshan, partial.darshan, compare.txt, pydarshan HTML, overhead csv).
- e2e compare pass criterion: module record set + open/read/write/close counts
  match native; known diffs allowed (mount label unknown vs rootfs, timestamps,
  pid, synthetic job/exe metadata).
- pydarshan HTML: do NOT run its CLI from the repo root (the repo's darshan/ source
  dir shadows the installed package). Run it from the results dir.
- Compute nodes only for broker fabric + runs; the heavy from-scratch spack build
  for the final reproducibility test goes on a LOGIN node (free). Final repro test:
  clone into /lcrc/globalscratch/hjajula, build everything in place, run e2e.

Environment: `source env/server.sh --lcrc` (broker/consumer/mongod) and
`source env/workload.sh --lcrc` (compiler + darshan LD_PRELOAD). Profile
auto-detects lcrc vs polaris.

Now: continue the plan. Do real work this turn (edit files, run builds, submit or
poll PBS jobs), update progress.md, commit + push. Keep going.
EOF

CLAUDE_FLAGS=( --print --dangerously-skip-permissions --verbose )
[[ -n "$MODEL" ]] && CLAUDE_FLAGS+=( --model "$MODEL" )

# Make the env available to any shell the agent spawns.
# shellcheck disable=SC1091
source "$REPO/env/workload.sh" --lcrc >/dev/null 2>&1 || true

log "=== overnight driver start (branch=$BRANCH, cap=${MAX_HOURS}h) ==="
i=0
while :; do
    [[ -f "$LOGDIR/STOP" ]] && { log "STOP file found -> exiting"; break; }
    now=$(date +%s); (( now >= DEADLINE )) && { log "wall-clock cap reached -> exiting"; break; }
    i=$((i+1)); RUN_LOG="$LOGDIR/run_$i.log"
    log "--- iteration $i -> $RUN_LOG ---"

    if [[ $i -eq 1 ]]; then
        claude "${CLAUDE_FLAGS[@]}" "$PROMPT" >"$RUN_LOG" 2>&1
    else
        # resume the same session so it keeps its context/plan
        claude "${CLAUDE_FLAGS[@]}" --continue \
            "Continue the overnight plan. Re-read progress.md, git fetch+rebase, \
find the first unfinished phase, do real work, update progress.md, commit + push. \
Do not stop until phases are DONE or budget is hit." >"$RUN_LOG" 2>&1
    fi
    rc=$?
    log "iteration $i exited rc=$rc ($(wc -l <"$RUN_LOG") log lines)"

    # If all phases are done, stop.
    if grep -qiE '^\- \[x\] P12|ALL PHASES DONE|BUDGET EXHAUSTED' progress.md 2>/dev/null; then
        log "completion/stop marker detected in progress.md -> exiting"; break
    fi
    sleep 5
done
log "=== overnight driver end (ran $i iterations) ==="
