#!/bin/bash
# run_overnight.sh -- WATCHDOG driver that runs Claude Code unattended until the
# job is actually DONE, not just until the process happens to exit.
#
# What makes this "strict" (see EVALUATION.md section 10 for the contract):
#   * It NEVER stops because a turn ended. It stops only when the mechanical
#     Definition of Done (all phases [x], clean+pushed, a fresh PASS oracle) is true,
#     or a hard cap (wall-clock / node-hours) is hit, or you `touch STOP`.
#   * Every resume injects a FRESH STATE SNAPSHOT (commits since base, unchecked
#     phases, unmet gates, budget, last error) -- the "more information" the agent
#     wakes up to and acts on, instead of guessing.
#   * It watches for STALLS (a turn that made no commit and did not touch
#     progress.md) and ESCALATES: re-prompt to force one concrete commit; after two
#     stalls in a row it orders a phase switch so it never loops on one wall.
#   * Each turn runs under a hard timeout, so a hung/idle turn is killed and woken
#     with fresh state rather than blocking the night.
#
# Usage (from a LOGIN node -- internet for installs; tmux/screen so it survives logout):
#     cd /home/hjajula/darshan-mofka-flowcept/darshan-mofka
#     tmux new -s overnight
#     bash run_overnight.sh            # Ctrl-b d to detach
#
# Logs:      ./overnight_logs/run_<N>.log  and  ./overnight_logs/driver.log
# Stop early: touch ./overnight_logs/STOP
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$REPO"
BRANCH="${OVERNIGHT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
LOGDIR="$REPO/overnight_logs"; mkdir -p "$LOGDIR"
DRIVER_LOG="$LOGDIR/driver.log"
MAX_HOURS="${MAX_HOURS:-9}"                  # wall-clock cap for the whole driver
ITER_TIMEOUT_MIN="${ITER_TIMEOUT_MIN:-45}"   # hard cap per turn; hung turn -> killed + woken
STALL_MAX="${STALL_MAX:-2}"                   # consecutive stalls before forcing a phase switch
MODEL="${CLAUDE_MODEL:-}"                     # e.g. CLAUDE_MODEL=opus (optional)
DEADLINE=$(( $(date +%s) + MAX_HOURS*3600 ))
BASE_REF="$(git merge-base origin/main HEAD 2>/dev/null || echo 'HEAD~30')"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$DRIVER_LOG"; }

# A fingerprint of "did anything change this turn": HEAD + a hash of progress.md.
state_fingerprint() {
    local head prog
    head="$(git rev-parse HEAD 2>/dev/null || echo none)"
    prog="$( (sha1sum progress.md 2>/dev/null || echo none) | awk '{print $1}')"
    echo "$head:$prog"
}

# The fresh state snapshot injected into every resume prompt AND logged. This is the
# "wake up for more information" payload -- the agent reads it and acts on it.
snapshot_state() {
    echo "===== STATE SNAPSHOT $(date '+%F %T') ====="
    echo "branch=$BRANCH  HEAD=$(git rev-parse --short HEAD 2>/dev/null)  base=$(git rev-parse --short "$BASE_REF" 2>/dev/null)"
    echo "-- commits this run (base..HEAD) --"
    git log --oneline "$BASE_REF..HEAD" 2>/dev/null | head -25 || true
    echo "-- uncommitted changes --"
    git status --porcelain 2>/dev/null | head -25 || echo "(clean)"
    local lh rh
    lh="$(git rev-parse --short HEAD 2>/dev/null)"
    rh="$(git rev-parse --short "origin/$BRANCH" 2>/dev/null || echo none)"
    echo "-- pushed? local=$lh remote=$rh  ($( [[ "$lh" == "$rh" ]] && echo IN-SYNC || echo NEEDS-PUSH ))"
    echo "-- UNCHECKED PHASES (progress.md) --"
    grep -nE '^\- \[ \] P[0-9]' progress.md 2>/dev/null || echo "(none unchecked)"
    echo "-- UNMET GATES (EVALUATION.md section 8) --"
    grep -nE '^\- \[ \].*\*\*G[0-9]' EVALUATION.md 2>/dev/null || echo "(none unmet)"
    echo "-- budget table tail --"
    grep -E '^\|' progress.md 2>/dev/null | tail -6 || true
    if [[ -f "$RUN_LOG" ]]; then
        echo "-- last turn log tail --"; tail -15 "$RUN_LOG" 2>/dev/null
        echo "-- last errors seen --"
        grep -iE 'error|fail|traceback|segfault|not found|denied|refused' "$RUN_LOG" 2>/dev/null | tail -8 || echo "(none)"
    fi
    echo "===== END SNAPSHOT ====="
}

# Mechanical Definition of Done (EVALUATION.md section 10.5). All must hold.
is_done() {
    grep -qE '^\- \[ \] P[0-9]' progress.md 2>/dev/null && return 1   # unchecked phase remains
    [[ -z "$(git status --porcelain 2>/dev/null)" ]] || return 1      # working tree dirty
    git fetch -q origin "$BRANCH" 2>/dev/null || true
    [[ "$(git rev-parse HEAD 2>/dev/null)" == "$(git rev-parse "origin/$BRANCH" 2>/dev/null)" ]] || return 1
    grep -rqs 'VERDICT: PASS' results/ 2>/dev/null || return 1        # fresh PASS oracle present
    grep -rqs 'INGEST: PASS'  results/ 2>/dev/null || return 1
    return 0
}

# ---- The invariant rules handed to every turn (first run + every resume) ----
read -r -d '' RULES <<'EOF'
You are running UNATTENDED OVERNIGHT on the darshan-mofka repo. progress.md is the
single source of truth; EVALUATION.md section 10 is the OPERATING CONTRACT and
section 10.5 is the only definition of "done". Read both before acting.

HARD RULES:
- DO NOT STOP until EVERY phase in progress.md is [x] and EVALUATION.md section 10.5
  is fully satisfied. Ending a turn without a commit+push OR a logged blocker+phase
  switch is a contract violation. Do not end on a question -- no human is awake;
  make the reversible decision (pre-authorized in progress.md locked decisions), log
  the assumption, continue.
- Every turn: end by appending a HEARTBEAT block to progress.md's running log
  (timestamp, phase, what changed, exact next action, blocker+workaround), then
  git add -A && commit && push. A turn with no commit is a stall and will be escalated.
- Reduce lines of code and files; prefer deleting/merging to adding. Every darshan/
  line needs a vetted reason (log it). This is the top PR priority.
- NEVER reference .so/libs/compiler runtimes by absolute path -- always via
  `module load` or a var derived from a module. Spack externals in spack.yaml are
  the only allowed place for system prefixes.
- Node-hour budget: 30 (hard cap 40; +10 only for final tests). Charge PBS account
  radix-io. Log every job in progress.md's budget table. Prefer the debug queue.
- Installs are pre-approved (pip/spack/git into account/venv/scratch); log each one.
- If stuck: ROOT-CAUSE from evidence (qstat, the .oNNNN log, results/<ts>/). Mine the
  reference branches for working recipes -- especially origin/polaris-verify (2-node
  MPI broker, partition-count curve, overhead microbench, spack mercury~hwloc fix),
  origin/feature/reproducible-split-nodes, origin/add-mpi-workload. Do not skip a
  workload silently; document a real blocker, switch to the next phase, return later.
- Overhead study: baseline (connector OFF) vs mofka (ON), 3 reps, C + python-ml, 2
  nodes; time init / avg-push / finalize; write results/<workload>_<ts>/ (jsonl,
  native.darshan, partial.darshan, compare.txt, pydarshan HTML, overhead csv).
- e2e pass = module record set + open/read/write/close counts match native; known
  diffs allowed (mount label unknown vs rootfs, timestamps, pid, synthetic metadata).
- pydarshan HTML: run its CLI from the results dir, never repo root (darshan/ source
  shadows the installed package).
- Heavy from-scratch spack build goes on a LOGIN node (free); compute nodes only for
  broker fabric + runs.
Environment: `source env/server.sh --lcrc` (broker/consumer/mongod) and
`source env/workload.sh --lcrc` (compiler + darshan LD_PRELOAD). Profile auto-detects.
EOF

CLAUDE_FLAGS=( --print --dangerously-skip-permissions --verbose )
[[ -n "$MODEL" ]] && CLAUDE_FLAGS+=( --model "$MODEL" )

# Make the workload env available to shells the agent spawns.
# shellcheck disable=SC1091
source "$REPO/env/workload.sh" --lcrc >/dev/null 2>&1 || true

log "=== watchdog driver start (branch=$BRANCH cap=${MAX_HOURS}h iter_timeout=${ITER_TIMEOUT_MIN}m base=$BASE_REF) ==="
i=0
stalls=0
RUN_LOG="$LOGDIR/run_0.log"   # placeholder so snapshot_state before iter 1 is safe
while :; do
    [[ -f "$LOGDIR/STOP" ]] && { log "STOP file found -> exiting"; break; }
    (( $(date +%s) >= DEADLINE )) && { log "wall-clock cap reached -> exiting (NOT done -- see MORNING_REPORT.md)"; break; }
    if is_done; then log "Definition of Done satisfied (section 10.5) -> exiting DONE"; break; fi

    i=$((i+1)); RUN_LOG="$LOGDIR/run_$i.log"
    before="$(state_fingerprint)"

    # Build this turn's prompt: rules + fresh snapshot (+ escalation if stalling).
    SNAP="$(snapshot_state)"
    log "--- iteration $i (stalls=$stalls) -> $RUN_LOG ---"
    printf '%s\n' "$SNAP" >>"$DRIVER_LOG"

    if (( stalls >= STALL_MAX )); then
        ESCALATION=$'\nESCALATION: you have stalled twice on the same item. STOP retrying it.\nMark it BLOCKED in progress.md with the exact error + what you tried, then move to\nthe NEXT independent unchecked phase and commit this turn.'
    elif (( stalls > 0 )); then
        ESCALATION=$'\nESCALATION: last turn produced no commit. Pick EXACTLY ONE unchecked phase or\nunmet gate from the snapshot below and produce a commit THIS turn, however small.'
    else
        ESCALATION=""
    fi

    PROMPT="$RULES

First: git fetch origin && git rebase origin/$BRANCH (integrate the other agent;
smaller diff wins). Then read progress.md + EVALUATION.md section 10, find the first
unfinished item, and do REAL work (edit files, run builds, submit/poll PBS), update
progress.md with a heartbeat, commit + push. Keep going until done.
$ESCALATION

CURRENT STATE SNAPSHOT (this is the 'more information' you woke up for -- act on it):
$SNAP"

    if [[ $i -eq 1 ]]; then
        timeout "${ITER_TIMEOUT_MIN}m" claude "${CLAUDE_FLAGS[@]}" "$PROMPT" >"$RUN_LOG" 2>&1
    else
        timeout "${ITER_TIMEOUT_MIN}m" claude "${CLAUDE_FLAGS[@]}" --continue "$PROMPT" >"$RUN_LOG" 2>&1
    fi
    rc=$?
    [[ $rc -eq 124 ]] && log "iteration $i TIMED OUT after ${ITER_TIMEOUT_MIN}m (killed + will wake with fresh state)"
    log "iteration $i exited rc=$rc ($(wc -l <"$RUN_LOG" 2>/dev/null || echo 0) log lines)"

    # Stall accounting: did the turn change HEAD or progress.md?
    after="$(state_fingerprint)"
    if [[ "$after" == "$before" ]]; then
        stalls=$((stalls+1)); log "no commit + no progress.md change -> STALL #$stalls"
    else
        stalls=0
    fi

    sleep 5
done
log "=== watchdog driver end (ran $i iterations, $( is_done && echo DONE || echo NOT-DONE )) ==="
