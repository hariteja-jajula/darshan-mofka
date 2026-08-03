#!/bin/bash
# study_alloc.sh -- runs INSIDE one PBS allocation. Runs the overhead study serially,
# reusing the allocated nodes. Calls workloads/job.sh directly (no qsub). Each (workload,arm)
# is routed into results/ALLOC_<TAG>/<arm>/ via RESULTS_TAG.
#
# Scale sweep: for each workload, run at 1/2/4/9 workload nodes (=2/3/5/10 total incl broker).
# cxi workloads (io_bench, io_bench_py) = 1 rank/node. tcp workloads (mpi, dlio) = 32 ranks/node.
# We build a per-run nodefile of exactly (1 broker + N workload) nodes from the full allocation.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
LOG="$ROOT/results/study_alloc.log"; mkdir -p "$ROOT/results"
STAMP() { date '+%H:%M:%S'; }
say() { echo "[$(STAMP)] $*" | tee -a "$LOG"; }

FULL_NODEFILE="${PBS_NODEFILE:?must run inside a PBS job}"
mapfile -t ALLNODES < <(sort -u "$FULL_NODEFILE")
NNODES=${#ALLNODES[@]}
say "allocation: $NNODES nodes"

WALL_S=$(( ${STUDY_WALL_S:-10800} ))          # 3h default
START=$(date +%s)
GUARD_S=$(( ${STUDY_GUARD_S:-1200} ))           # stop starting new arms if < this many s left

# calibration knob values (from deliverables/calibration.md)
CMP_IOBENCH=${CMP_IOBENCH:-72}                  # COMPUTE @ MATRIX=512 (~10 min)
CMP_IOBENCH_PY=${CMP_IOBENCH_PY:-15}            # COMPUTE @ MATRIX=256 (~10 min)
STEPS_MPI=${STEPS_MPI:-900}                     # ~10 min @ 32 ranks
EVENTS_DLIO=${EVENTS_DLIO:-320}                 # ~10 min @ 32 ranks

# run one (workload, arm) at a given workload-node count. builds a 2..10-node nodefile subset.
run_one() {
    local wl="$1" arm="$2" wlnodes="$3" proto="$4" tasks="$5" compute="$6" matrix="$7" events="$8" part="$9" cons="${10}"
    local left=$(( WALL_S - ($(date +%s) - START) ))
    if [ "$left" -lt "$GUARD_S" ]; then say "SKIP $wl/$arm nodes=$wlnodes (only ${left}s left < guard)"; return 0; fi
    local total=$(( wlnodes + 1 ))
    if [ "$total" -gt "$NNODES" ]; then say "SKIP $wl/$arm nodes=$wlnodes (needs $total > $NNODES alloc)"; return 0; fi

    # per-run nodefile: node0=broker, next wlnodes=workload. mpiprocs from full file preserved.
    local nf="$ROOT/results/_nf_${wl}_${arm}_${wlnodes}"
    : > "$nf"
    for h in "${ALLNODES[@]:0:$total}"; do grep -x "$h" "$FULL_NODEFILE" >> "$nf" 2>/dev/null || echo "$h" >> "$nf"; done

    local enable=1 nod=0
    case "$arm" in baseline) nod=1;; runtimeonly) enable=0;; streaming) enable=1;; esac

    say "RUN $wl/$arm wlnodes=$wlnodes total=$total proto=$proto tasks=$tasks compute=$compute events=$events part=$part cons=$cons"
    PBS_NODEFILE="$nf" \
      MOFKA_PROTOCOL="$proto" WORKLOAD="$wl" TASKS="$tasks" REPS="${REPS:-1}" PLACEMENT=separate \
      EVENTS="$events" PARTITIONS="$part" CONSUMERS="$cons" \
      IO_SIZE_MB=16 IO_ITERS=16 IO_SLEEP_MS=50 IO_BLOCK_KB=1024 COMPUTE="$compute" MATRIX_SIZE="$matrix" \
      DARSHAN_MOFKA_ENABLE="$enable" NO_DARSHAN="$nod" DARSHAN_MOFKA_DROP_POLICY=block \
      DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 RESULTS_TAG="ALLOC_${wl}_N${wlnodes}/${arm}" \
      bash workloads/job.sh "$wl" >> "$LOG" 2>&1 \
      && say "  done $wl/$arm nodes=$wlnodes" || say "  FAILED $wl/$arm nodes=$wlnodes (continuing)"
    pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 3
    rm -f "$nf"
}

say "===== STUDY START ====="

# cxi workloads: 1 rank/node, 3 arms, scale 1/2/4/9 workload nodes
for wlnodes in 1 2 4 9; do
  for arm in baseline runtimeonly streaming; do
    run_one io_bench     "$arm" "$wlnodes" ofi+cxi 1 "$CMP_IOBENCH"    512 100 16 16
    run_one io_bench_py  "$arm" "$wlnodes" ofi+cxi 1 "$CMP_IOBENCH_PY" 256 100 16 16
  done
done

# tcp workloads: 32 ranks/node, 3 arms, scale 1/2/4/9 workload nodes
for wlnodes in 1 2 4 9; do
  for arm in baseline runtimeonly streaming; do
    run_one mpi  "$arm" "$wlnodes" ofi+tcp 32 0 0 "$STEPS_MPI"   16 16
    run_one dlio "$arm" "$wlnodes" ofi+tcp 32 0 0 "$EVENTS_DLIO" 16 16
  done
done

say "===== STUDY DONE (elapsed $(( ($(date +%s)-START)/60 )) min) ====="
