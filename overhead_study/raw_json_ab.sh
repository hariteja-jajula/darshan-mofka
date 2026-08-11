#!/bin/bash
# raw_json_ab.sh -- ONE PBS allocation, controlled A/B for the raw-json handoff
# (DARSHAN_MOFKA_RAW_JSON). Runs three arms sequentially in the SAME allocation so the
# comparison controls for node/network placement:
#   baseline      NO_DARSHAN=1                      (BASE_REPS reps)  -> WORK-wall reference
#   stream_def    ENABLE=1, RAW unset (default ser) (STREAM_REPS reps)
#   stream_raw    ENABLE=1, RAW=1     (raw ser)     (STREAM_REPS reps)
# overhead(def) = stream_def WORK - baseline WORK ; overhead(raw) = stream_raw WORK - baseline WORK
# The delta (def - raw) is the payoff of killing the producer-side parse+dump.
#
#   bash overhead_study/raw_json_ab.sh                 # submit
#   DRYRUN=1 bash overhead_study/raw_json_ab.sh        # print qsub, don't submit
#
# ============================== KNOBS ==============================
WORKLOAD="${WORKLOAD:-io_bench}"     # io_bench (+45% mem-BW regime, C twin) | python-ml | mpi
WLNODES="${WLNODES:-1}"
TASKS="${TASKS:-1}"                  # cxi = 1 rank/node
PROTO="${PROTO:-ofi+cxi}"
PARTITIONS="${PARTITIONS:-4}"
CONSUMERS="${CONSUMERS:-1}"
BASE_REPS="${BASE_REPS:-1}"
STREAM_REPS="${STREAM_REPS:-3}"
# io_bench scale (matches overhead_study/1wlnode_..._iobench_..._cxi.sh calibration ~250s/rep):
IO_ITERS="${IO_ITERS:-8}" ML_FILES="${ML_FILES:-8}" IO_SIZE_MB="${IO_SIZE_MB:-16}"
COMPUTE="${COMPUTE:-72}" MATRIX_SIZE="${MATRIX_SIZE:-512}" CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-4}"
EVENTS="${EVENTS:-1000}"
ML_ROWS="${ML_ROWS:-4096}" ML_COLS="${ML_COLS:-64}" ML_CHECKPOINTS="${ML_CHECKPOINTS:-2}"
STUDY="${STUDY:-RAWAB_${WORKLOAD}_${WLNODES}wl}"
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

# shared knobs forwarded to every arm (env-wins over config files). Mirrors run_overhead.sh.
COMMON="MOFKA_PROTOCOL=$PROTO,WORKLOAD=$WORKLOAD,NODES=$NODES,TASKS=$TASKS,PLACEMENT=separate"
COMMON="$COMMON,EVENTS=$EVENTS,PARTITIONS=$PARTITIONS,CONSUMERS=$CONSUMERS"
COMMON="$COMMON,IO_ITERS=$IO_ITERS,ML_FILES=$ML_FILES,IO_SIZE_MB=$IO_SIZE_MB"
COMMON="$COMMON,COMPUTE=$COMPUTE,MATRIX_SIZE=$MATRIX_SIZE,CHECKPOINT_EVERY=$CHECKPOINT_EVERY"
COMMON="$COMMON,ML_ROWS=$ML_ROWS,ML_COLS=$ML_COLS,ML_CHECKPOINTS=$ML_CHECKPOINTS"
COMMON="$COMMON,DARSHAN_MOFKA_MAX_BATCHES=512,DARSHAN_MOFKA_FLUSH_MS=30000"
COMMON="$COMMON,DARSHAN_MOFKA_TIMING=1,DARSHAN_MOFKA_DROP_POLICY=block,RPC_THREAD_COUNT=4,SKIP_BUILD=1"

echo "=== $STUDY: $WORKLOAD $PROTO wlnodes=$WLNODES total=$NODES q=$QUEUE part=$PARTITIONS cons=$CONSUMERS ==="
echo "    arms: baseline x$BASE_REPS, stream_def(RAW off) x$STREAM_REPS, stream_raw(RAW on) x$STREAM_REPS -> results/$STUDY/"

if [ "${DRYRUN:-0}" = 1 ]; then
  echo "DRYRUN qsub -A $account -q $QUEUE -l select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} -l walltime=$WALLTIME ${PBS_EXTRA[*]} -N rawab_${WORKLOAD}_${WLNODES}wl"
  echo "--- COMMON ---"; echo "$COMMON" | tr ',' '\n' | sed 's/^/    /'
  exit 0
fi

qsub -A "$account" -q "$QUEUE" \
     -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
     "${PBS_EXTRA[@]}" -N "rawab_${WORKLOAD}_${WLNODES}wl" -j oe -o "$ROOT/results/" \
     -v "ROOT=$ROOT,COMMON=$COMMON,STUDY=$STUDY,BASE_REPS=$BASE_REPS,STREAM_REPS=$STREAM_REPS" <<'PBS'
cd "$ROOT" || { echo "FATAL: cannot cd to ROOT=$ROOT"; exit 1; }
run_arm(){  # $1=arm $2=reps $3=enable $4=no_darshan $5=raw_json
  echo "########## ARM $1 (reps=$2 raw_json=$5) $(date '+%H:%M:%S') ##########"
  env $(echo "$COMMON" | tr ',' ' ') \
      REPS="$2" DARSHAN_MOFKA_ENABLE="$3" NO_DARSHAN="$4" DARSHAN_MOFKA_RAW_JSON="$5" \
      RESULTS_TAG="$STUDY/$1" \
      bash workloads/job.sh || echo "ARM $1 returned nonzero"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 3
}
run_arm baseline    "$BASE_REPS"   1 1 0
run_arm stream_def  "$STREAM_REPS" 1 0 0
run_arm stream_raw  "$STREAM_REPS" 1 0 1
echo "########## RAW-JSON A/B DONE ($STUDY) $(date '+%H:%M:%S') ##########"
PBS
