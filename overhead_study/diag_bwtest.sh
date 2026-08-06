#!/bin/bash
# diag_bwtest.sh -- CONFIRM the regime theory from diag_profile (job 7365261).
#
# diag_profile showed the realistic trainer streams at +1.7% because its small GEMMs
# are cache-resident: the drain thread co-runs on a free core and the connector-free
# compute region's CPU is UNCHANGED (137.90 -> 137.54). The reconciliation with the
# io_bench_py "+45% app-thread CPU" result is: contention only bites MEMORY-BANDWIDTH-
# bound compute (cache-spilling GEMMs share LLC/mem-BW with the drain). This job tests
# that directly on the SAME instrument by making train.py's GEMMs large enough to spill
# LLC (big ML_HIDDEN + big ML_BATCH), holding everything else fixed.
#
# ARMS (2): baseline (NO_DARSHAN=1) vs streaming (ENABLE=1). Same big-GEMM config.
#   READ: MLPROF region=compute cpu_s, baseline vs streaming.
#     * cpu_s RISES under streaming  -> regime (b) CONFIRMED: drain contends for
#       LLC/mem-BW, slowing cache-spilling compute (matches io_bench_py +45%). Fix =
#       pin sender ES to a far core/other NUMA away from the app.
#     * cpu_s stays FLAT (like small-GEMM +0%) -> the distinguisher is NOT cache
#       residency; look elsewhere (revisit io_bench_py's specific access pattern).
#
# Big-GEMM sizing: ML_HIDDEN=4096, ML_BATCH=4096 -> per-batch GEMMs are
#   xb(4096x64) @ W1(64x4096) = 4096x4096 (64 MB fp32 out) and a1(4096x4096) @ W2 --
# far larger than the ~2 MB Polaris L2 / ~32 MB shared L3, so they stream from DRAM.
#
# CRITICAL for the contention test: I/O emits must be INTERLEAVED with the heavy GEMMs
# so the drain co-runs DURING compute (that is what makes io_bench_py +45%). With
# ML_ROWS == ML_BATCH there is exactly 1 big GEMM per shard, so the loop alternates
# read(emit) -> big-GEMM -> read(emit) -> ... across ML_FILES shards, keeping the drain
# continuously fed while the cache-spilling GEMMs run. Many shards, few epochs.
#
# Usage:
#   qsub -A radix-io -q debug -l select=2:ncpus=32:mpiprocs=32 \
#        -l walltime=01:00:00 -l filesystems=home:eagle -j oe \
#        -o overhead_study/diag_bwtest.OU overhead_study/diag_bwtest.sh
set -uo pipefail
ROOT="${PBS_O_WORKDIR:-/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight}"
while [ "$ROOT" != / ] && [ ! -d "$ROOT/workloads" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/workloads" ] || { echo "FATAL: no workloads/ dir"; exit 1; }
cd "$ROOT"
LOG="$ROOT/results/diag_bwtest.log"; mkdir -p "$ROOT/results"
say(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

FULL_NODEFILE="${PBS_NODEFILE:?must run inside a PBS job}"
mapfile -t ALLNODES < <(sort -u "$FULL_NODEFILE")
say "allocation: ${#ALLNODES[@]} nodes: ${ALLNODES[*]}"
[ "${#ALLNODES[@]}" -ge 2 ] || { say "need >=2 nodes"; exit 1; }

# Big-GEMM, cache-spilling config. Many shards (=> many interleaved read emits), 1 big
# GEMM per shard (ML_ROWS==ML_BATCH), few epochs since each GEMM is ~1000x heavier.
EVENTS=${EVENTS:-10}          # ML_EPOCHS: 10 epochs x 64 shards x 1 GEMM => 640 heavy GEMMs
                             # (~0.9s wall/GEMM calib => ~10 min/arm, 2 arms fit 1h debug)
CHECKPOINTS=${CHECKPOINTS:-2}
ML_FILES=${ML_FILES:-64}     # 64 shards/epoch => 64 read-emits interleaved with the GEMMs
ML_ROWS=${ML_ROWS:-4096}     # == ML_BATCH => exactly 1 cache-spilling GEMM per shard read
ML_COLS=${ML_COLS:-64}
PARTITIONS=${PARTITIONS:-16}
CONSUMERS=${CONSUMERS:-1}

run_arm() {
  local enable="$1" nod="$2" tag="$3"
  say "RUN python-ml/$tag (enable=$enable no_darshan=$nod BIG-GEMM hidden=4096 batch=4096)"
  PBS_NODEFILE="$FULL_NODEFILE" \
  env \
    MOFKA_PROTOCOL=ofi+cxi WORKLOAD=python-ml TASKS=1 REPS=1 PLACEMENT=separate \
    EVENTS="$EVENTS" CHECKPOINTS="$CHECKPOINTS" \
    ML_FILES="$ML_FILES" ML_ROWS="$ML_ROWS" ML_COLS="$ML_COLS" \
    ML_HIDDEN=4096 ML_BATCH=4096 \
    ML_PROFILE=1 ML_BLAS_THREADS=1 \
    PARTITIONS="$PARTITIONS" CONSUMERS="$CONSUMERS" \
    DM_MPSTAT=1 DM_MPSTAT_INT=5 DM_WRAP_PERF=0 \
    DARSHAN_MOFKA_ENABLE="$enable" NO_DARSHAN="$nod" DARSHAN_MOFKA_BATCH=0 \
    DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 DIASPORA_C_SENDER_THREADS=1 \
    RESULTS_TAG="DIAGBW_python-ml/${tag}" \
    bash workloads/job.sh python-ml >> "$LOG" 2>&1 \
    && say "  done python-ml/$tag" || say "  FAILED python-ml/$tag (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 4
}

say "===== BW-contention test: big cache-spilling GEMMs, baseline vs streaming ====="
run_arm 0 1 baseline
run_arm 1 0 streaming
say "===== DIAGBW DONE (compare MLPROF region=compute cpu_s across the two arms) ====="
