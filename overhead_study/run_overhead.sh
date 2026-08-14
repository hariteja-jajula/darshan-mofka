#!/bin/bash
# run_overhead.sh -- ONE clean overhead-study submit. ONE PBS job runs all 3 arms
# sequentially in a single allocation (no per-arm jobs, no dripfeed, no queue-limit
# dance): baseline rep1, darshan-only rep2, streaming rep1..3 -> results/<STUDY>/<arm>/.
#
# Edit the KNOBS block, then:  bash overhead_study/run_overhead.sh
#   DRYRUN=1 bash overhead_study/run_overhead.sh   # print qsub, don't submit
#
# ============================== KNOBS ==============================
WORKLOAD="${WORKLOAD:-io_bench}"     # io_bench | python-ml
WLNODES="${WLNODES:-1}"              # workload nodes (broker/consumer adds 1 more)
TASKS="${TASKS:-1}"                  # ranks per workload node (cxi = 1)
PROTO="${PROTO:-ofi+cxi}"
PARTITIONS="${PARTITIONS:-4}"        # broker partitions
CONSUMERS="${CONSUMERS:-1}"          # sharded consumers (scale with WLNODES)
BASE_REPS="${BASE_REPS:-1}"          # baseline reps
RUNTIME_REPS="${RUNTIME_REPS:-1}"    # darshan-only reps
STREAM_REPS="${STREAM_REPS:-3}"     # streaming reps
# workload scale knobs (io_bench = realistic C train-style; python-ml = numpy MLP):
IO_ITERS="${IO_ITERS:-8}" ML_FILES="${ML_FILES:-8}" IO_SIZE_MB="${IO_SIZE_MB:-16}"
COMPUTE="${COMPUTE:-72}" MATRIX_SIZE="${MATRIX_SIZE:-512}" CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-4}"
EVENTS="${EVENTS:-1000}"             # python-ml epochs (ML_EPOCHS)
ML_ROWS="${ML_ROWS:-4096}" ML_COLS="${ML_COLS:-64}" ML_CHECKPOINTS="${ML_CHECKPOINTS:-2}"
# The margo basic_wait + dedicated-sender-ES config is WORKLOAD-DEPENDENT:
#   io_bench (few events, compute-bound): default margo SPINS a core -> +100%; the fix -> +2.7%.
#   python-ml (100k+ events): the fix adds per-send handoff cost (0.77us -> 117us/event) that
#     dominates at high event counts -> +60%. Default margo is FASTER for it (+2.85%).
# So apply the fix ONLY for low-event workloads. Default: io_bench=1, python-ml=0. Override APPLY_MARGO_FIX.
if [ -z "${APPLY_MARGO_FIX:-}" ]; then
  case "$WORKLOAD" in python-ml) APPLY_MARGO_FIX=0 ;; *) APPLY_MARGO_FIX=1 ;; esac
fi
STUDY="${STUDY:-OVH_${WORKLOAD}_${WLNODES}wl}"
WALLTIME="${WALLTIME:-01:00:00}"
# ==================================================================

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
account="${PBS_ACCOUNT:-radix-io}"
NODES=$(( WLNODES + 1 ))
[ "$NODES" -le 2 ] && QUEUE="${QUEUE:-debug}" || QUEUE="${QUEUE:-debug-scaling}"
NCPUS=32
source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=()
[[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")

# shared knobs forwarded to every arm (env-wins over config files)
COMMON="MOFKA_PROTOCOL=$PROTO,WORKLOAD=$WORKLOAD,NODES=$NODES,TASKS=$TASKS,PLACEMENT=separate"
COMMON="$COMMON,EVENTS=$EVENTS,PARTITIONS=$PARTITIONS,CONSUMERS=$CONSUMERS"
COMMON="$COMMON,IO_ITERS=$IO_ITERS,ML_FILES=$ML_FILES,IO_SIZE_MB=$IO_SIZE_MB"
COMMON="$COMMON,COMPUTE=$COMPUTE,MATRIX_SIZE=$MATRIX_SIZE,CHECKPOINT_EVERY=$CHECKPOINT_EVERY"
COMMON="$COMMON,ML_ROWS=$ML_ROWS,ML_COLS=$ML_COLS,ML_CHECKPOINTS=$ML_CHECKPOINTS"
COMMON="$COMMON,DARSHAN_MOFKA_MAX_BATCHES=${MAX_BATCHES:-512},DARSHAN_MOFKA_FLUSH_MS=30000"
# Phase-2 batch sweep: forward DARSHAN_MOFKA_BATCH ONLY when set, so an unset run is
# byte-for-byte the old behavior (connector default 0 = adaptive batching). N>0 = fixed
# batch size (a batch transmits when N events accumulate or on flush); note a batch size
# larger than the workload's event count never fills and collapses to the final flush.
[ -n "${DARSHAN_MOFKA_BATCH:-}" ] && COMMON="$COMMON,DARSHAN_MOFKA_BATCH=$DARSHAN_MOFKA_BATCH"
COMMON="$COMMON,DARSHAN_MOFKA_TIMING=1,DARSHAN_MOFKA_DROP_POLICY=${DROP_POLICY:-block},RPC_THREAD_COUNT=4,SKIP_BUILD=1"
[ -n "${DARSHAN_MOFKA_RAW_JSON:-}" ] && COMMON="$COMMON,DARSHAN_MOFKA_RAW_JSON=$DARSHAN_MOFKA_RAW_JSON"

echo "=== $STUDY: $WORKLOAD $PROTO wlnodes=$WLNODES total=$NODES tasks/node=$TASKS q=$QUEUE part=$PARTITIONS cons=$CONSUMERS ==="
echo "    arms: baseline x$BASE_REPS, darshan-only x$RUNTIME_REPS, streaming x$STREAM_REPS  -> results/$STUDY/"

if [ "${DRYRUN:-0}" = 1 ]; then
  echo "DRYRUN qsub -A $account -q $QUEUE -l select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} -l walltime=$WALLTIME ${PBS_EXTRA[*]} -N ovh_${WORKLOAD}_${WLNODES}wl"
  exit 0
fi

qsub -A "$account" -q "$QUEUE" \
     -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
     "${PBS_EXTRA[@]}" -N "ovh_${WORKLOAD}_${WLNODES}wl" -j oe -o "$ROOT/results/" \
     -v "ROOT=$ROOT,COMMON=$COMMON,STUDY=$STUDY,BASE_REPS=$BASE_REPS,RUNTIME_REPS=$RUNTIME_REPS,STREAM_REPS=$STREAM_REPS,APPLY_MARGO_FIX=$APPLY_MARGO_FIX" <<'PBS'
cd "$ROOT" || { echo "FATAL: cannot cd to ROOT=$ROOT"; exit 1; }
# THE FIX (verified: +100% -> +2.6%): the streaming arm must run the connector's margo
# engine on a BLOCKING (basic_wait) scheduler + a dedicated sender ES, else margo's DEFAULT
# spinning scheduler pegs a whole core and doubles the wall. Exported here (commas break -v).
MARGO_FIX='{"use_progress_thread":false,"rpc_thread_count":0,"argobots":{"pools":[{"name":"__primary__","kind":"fifo_wait","access":"mpmc"},{"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],"xstreams":[{"name":"__primary__","scheduler":{"type":"basic_wait","pools":["__primary__"]}},{"name":"__progress__","scheduler":{"type":"basic_wait","pools":["__progress__"]}}]},"progress_pool":"__progress__"}'
run_arm(){  # $1=arm $2=reps $3=enable $4=no_darshan $5=apply_fix(1/0)
  echo "########## ARM $1 (reps=$2) $(date '+%H:%M:%S') ##########"
  local FIXENV=()
  [ "$5" = 1 ] && FIXENV=(DIASPORA_C_SENDER_THREADS=1 DARSHAN_MOFKA_MARGO_JSON="$MARGO_FIX")
  env $(echo "$COMMON" | tr ',' ' ') \
      REPS="$2" DARSHAN_MOFKA_ENABLE="$3" NO_DARSHAN="$4" "${FIXENV[@]}" \
      RESULTS_TAG="$STUDY/$1" \
      bash workloads/job.sh || echo "ARM $1 returned nonzero"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 3
}
run_arm baseline     "$BASE_REPS"    1 1 0
run_arm runtimeonly  "$RUNTIME_REPS" 0 0 0
run_arm streaming    "$STREAM_REPS"  1 0 "$APPLY_MARGO_FIX"
echo "########## OVERHEAD DONE ($STUDY) $(date '+%H:%M:%S') ##########"
PBS
