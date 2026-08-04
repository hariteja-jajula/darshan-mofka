#!/bin/bash
# job_iobenchpy_N1.sh -- overhead study: dlio (TCP), 1 workload node (32 ranks).
# ONE PBS job, all 3 arms on the SAME nodes, per-arm reps:
#   baseline(NO_DARSHAN=1) x1, runtimeonly(ENABLE=0) x1, streaming(ENABLE=1 +fix) x3.
# streaming carries the fix: DIASPORA_C_SENDER_THREADS=1 + A' yielding-progress margo JSON.
# Results -> results/OVH_dlio_N4/<arm>/RUN*.  ~7 min/rep (fits 1h debug).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
account="${PBS_ACCOUNT:-radix-io}"
source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=(); [[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")
STUDY=OVH_dlio_N4; mkdir -p "$ROOT/results/$STUDY"

qsub -A "$account" -q debug-scaling \
     -l select=5:ncpus=32:mpiprocs=32 -l walltime=01:00:00 \
     "${PBS_EXTRA[@]}" -N 3arm_dlio_N4 -j oe -o "$ROOT/results/$STUDY/" <<'PBS'
ROOT="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
cd "$ROOT"
set -uo pipefail
export DARSHAN_MOFKA_MARGO_JSON='{"use_progress_thread":false,"rpc_thread_count":0,"argobots":{"pools":[{"name":"__primary__","kind":"fifo_wait","access":"mpmc"},{"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],"xstreams":[{"name":"__primary__","scheduler":{"type":"basic_wait","pools":["__primary__"]}},{"name":"__progress__","scheduler":{"type":"basic_wait","pools":["__progress__"]}}]},"progress_pool":"__progress__"}'

WL=dlio; PROTO=ofi+tcp; NODES=5; TASKS=32
CMP=0; MAT=256; EV=210; PART=16; CONS=16; RPC=4

run_arm() {  # $1=arm $2=reps $3=enable $4=nodarshan $5=sender
  echo "===== ARM $1 reps=$2 enable=$3 no_darshan=$4 sender=$5 $(date '+%H:%M:%S') ====="
  MOFKA_PROTOCOL="$PROTO" WORKLOAD="$WL" NODES="$NODES" TASKS="$TASKS" REPS="$2" PLACEMENT=separate \
    EVENTS="$EV" PARTITIONS="$PART" CONSUMERS="$CONS" \
    IO_SIZE_MB=16 IO_ITERS=16 IO_SLEEP_MS=50 IO_BLOCK_KB=1024 COMPUTE="$CMP" MATRIX_SIZE="$MAT" \
    DARSHAN_MOFKA_ENABLE="$3" NO_DARSHAN="$4" DARSHAN_MOFKA_BATCH=0 DARSHAN_MOFKA_MAX_BATCHES=512 \
    DARSHAN_MOFKA_FLUSH_MS=30000 DARSHAN_MOFKA_TIMING=1 DARSHAN_MOFKA_DROP_POLICY=block \
    RPC_THREADS="$RPC" SKIP_BUILD=1 DIASPORA_C_SENDER_THREADS="$5" \
    RESULTS_TAG="OVH_dlio_N4/$1" \
    bash workloads/job.sh "$WL" || echo "ARM $1 FAILED (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 3
}

run_arm baseline    1 1 1 0
run_arm runtimeonly 1 0 0 0
run_arm streaming   3 1 0 1
echo "===== 3-ARM JOB DONE $(date '+%H:%M:%S') ====="
PBS
