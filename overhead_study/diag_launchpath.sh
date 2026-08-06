#!/bin/bash
# diag_launchpath.sh -- decisive two-arm test for the python-ml streaming overhead.
#
# The +351s gap (881s streaming vs ~525s native-DIRECT) confounds TWO changes at once:
#   (a) execution context: streaming runs under the full MPMD mpiexec (broker+consumer+
#       workload in one launch); the 525s native run was launched DIRECTLY (no mpiexec).
#   (b) the Mofka connector itself (per-op emit + Adaptive send-on-notify + on CXI the
#       custom margo config parking RPC completions).
# BATCH=512 already REFUTED the "RPC count" sub-hypothesis (-1.3%). This job splits (a) from (b):
#
#   Arm 1  mpmd_native   DARSHAN_MOFKA_ENABLE=0  -- python-ml under the SAME MPMD launch
#          (broker+consumer stand up) but the connector never streams. Isolates PURE
#          launch-path cost. This is the INVERSE of the user's "python without mpiexec":
#          the 525s runs are python WITHOUT mpiexec; this is python WITH it, connector off.
#   Arm 2  streaming_fixB DARSHAN_MOFKA_ENABLE=1, BATCH=0 (Adaptive), and -- crucially --
#          NO custom DARSHAN_MOFKA_MARGO_JSON exported, so the connector uses its DEFAULT
#          use_progress_thread=1 (darshan-mofka.c:324), Mofka's own recommended shape.
#          This is "Fix B": a real progress ES completes RPCs instead of the basic_wait
#          __progress__ xstream parking them on CXI (na_cxi has no fi_trywait).
#
# Read across:  nostream-DIRECT 525s | Arm1 mpmd_native ??? | streaming-Adaptive 881s |
#               streaming-BATCH512 869s | Arm2 streaming_fixB ???
#   If Arm1 ~= 881s  -> the MPMD launch path IS the cost (connector is innocent).
#   If Arm1 ~= 525s and Arm2 ~= 525s -> Fix B (default progress thread) is the fix.
#   If Arm1 ~= 525s but Arm2 ~= 881s -> neither batch nor progress-thread; look elsewhere.
#
# Same python-ml config as run_artifacts/submit_cxi.sh (the 881s baseline):
#   EVENTS=1000 CHECKPOINTS=2 ML_FILES=64 ML_ROWS=4096 ML_COLS=64, ofi+cxi, 1 task, separate.
#
# Usage (submit):  qsub -A radix-io -q debug -l select=2:ncpus=32:mpiprocs=32 \
#                       -l walltime=01:00:00 -l filesystems=home:eagle -j oe \
#                       -o overhead_study/diag_launchpath.OU overhead_study/diag_launchpath.sh
set -uo pipefail
# PBS copies this script into a spool dir, so BASH_SOURCE-relative resolution breaks.
ROOT="${PBS_O_WORKDIR:-/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight}"
while [ "$ROOT" != / ] && [ ! -d "$ROOT/workloads" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/workloads" ] || { echo "FATAL: cannot locate project root (no workloads/ dir)"; exit 1; }
cd "$ROOT"
LOG="$ROOT/results/diag_launchpath.log"; mkdir -p "$ROOT/results"
say(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

FULL_NODEFILE="${PBS_NODEFILE:?must run inside a PBS job}"
mapfile -t ALLNODES < <(sort -u "$FULL_NODEFILE")
say "allocation: ${#ALLNODES[@]} nodes: ${ALLNODES[*]}"
[ "${#ALLNODES[@]}" -ge 2 ] || { say "need >=2 nodes"; exit 1; }
say "broker node = ${ALLNODES[0]} | workload node = ${ALLNODES[1]}"

# python-ml dataset = EXACT submit_cxi.sh 881s-baseline config.
EVENTS=${EVENTS:-1000}
CHECKPOINTS=${CHECKPOINTS:-2}
ML_FILES=${ML_FILES:-64}
ML_ROWS=${ML_ROWS:-4096}
ML_COLS=${ML_COLS:-64}
PARTITIONS=${PARTITIONS:-16}
CONSUMERS=${CONSUMERS:-1}

# run_arm <arm> <enable> <no_darshan> <tag> [extra KEY=VAL ...]
#   arm/enable/no_darshan set explicitly (no name-guessing) so intent is unambiguous.
run_arm() {
  local arm="$1" enable="$2" nod="$3" tag="$4"; shift 4
  local extra=( "$@" )
  say "RUN python-ml/$tag (enable=$enable no_darshan=$nod extra=[${extra[*]:-}])"
  # NOTE: MARGO_JSON is deliberately NOT exported anywhere in this script -> streaming
  # arm runs with the connector's DEFAULT use_progress_thread=1 (this IS Fix B).
  PBS_NODEFILE="$FULL_NODEFILE" \
  env "${extra[@]}" \
    MOFKA_PROTOCOL=ofi+cxi WORKLOAD=python-ml TASKS=1 REPS=1 PLACEMENT=separate \
    EVENTS="$EVENTS" CHECKPOINTS="$CHECKPOINTS" \
    ML_FILES="$ML_FILES" ML_ROWS="$ML_ROWS" ML_COLS="$ML_COLS" \
    PARTITIONS="$PARTITIONS" CONSUMERS="$CONSUMERS" \
    DM_MPSTAT=1 DM_MPSTAT_INT=5 \
    DARSHAN_MOFKA_ENABLE="$enable" NO_DARSHAN="$nod" \
    DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 DIASPORA_C_SENDER_THREADS=1 \
    RESULTS_TAG="DIAGLAUNCH_python-ml/${tag}" \
    bash workloads/job.sh python-ml >> "$LOG" 2>&1 \
    && say "  done python-ml/$tag" || say "  FAILED python-ml/$tag (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 4
}

say "===== python-ml launch-path split: mpmd_native (ENABLE=0) then streaming_fixB (default progress thread) ====="
# Arm 1: MPMD launch, connector OFF -> pure launch-path cost (broker stands up, no stream).
run_arm mpmd_native 0 0 mpmd_native
# Arm 2: streaming, Adaptive batch, DEFAULT progress thread (Fix B: no custom MARGO_JSON).
run_arm streaming   1 0 streaming_fixB DARSHAN_MOFKA_BATCH=0

say "===== DIAGLAUNCH DONE ====="
