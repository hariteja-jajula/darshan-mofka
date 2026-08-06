#!/bin/bash
# diag_writemode.sh -- is the streaming overhead driven by OUR workload's unrealistic
# write pattern, or is it intrinsic? Two STREAMING arms, EXACT 881s config, differing
# ONLY in how train.py writes its shards:
#
#   Arm 1  row       ML_WRITE_MODE=row      -- legacy: one write() PER ROW.
#          64 files x 4096 rows => 262,144 write ops => ~385k total events. This is the
#          original 881s workload. NO real ML code writes row-at-a-time; it's an artifact.
#   Arm 2  buffered  ML_WRITE_MODE=buffered -- realistic: one write() per SHARD (like
#          np.tofile/np.save/torch.save). 64 writes instead of 262k => ~128k total events
#          (now dominated by 1000 epochs x 64 file reads, which IS legit ML iteration).
#
# Same everything else: EVENTS=1000 ML_FILES=64 ML_ROWS=4096 ML_COLS=64 CHECKPOINTS=2,
# ofi+cxi, Adaptive batch, DEFAULT progress thread (no custom MARGO_JSON). Both arms
# stream through the identical connector+Mofka path, so the ONLY variable is event volume
# coming from the write pattern.
#
# Read across (row baseline = 881s from prior runs; Arm1 here reconfirms in-allocation):
#   If Arm2 (buffered) wall drops toward native (~525s) roughly with the 3x event cut ->
#     the overhead is driven by OUR workload emitting 262k artifact write-events. "Our side."
#     Real workloads would not pay this; the connector/Mofka are fine at realistic volume.
#   If Arm2 stays ~881s despite 3x fewer events -> volume is NOT the lever; intrinsic cost.
#
# Usage (submit):  qsub -A radix-io -q debug -l select=2:ncpus=32:mpiprocs=32 \
#                       -l walltime=01:00:00 -l filesystems=home:eagle -j oe \
#                       -o overhead_study/diag_writemode.OU overhead_study/diag_writemode.sh
set -uo pipefail
ROOT="${PBS_O_WORKDIR:-/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight}"
while [ "$ROOT" != / ] && [ ! -d "$ROOT/workloads" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/workloads" ] || { echo "FATAL: cannot locate project root (no workloads/ dir)"; exit 1; }
cd "$ROOT"
LOG="$ROOT/results/diag_writemode.log"; mkdir -p "$ROOT/results"
say(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

FULL_NODEFILE="${PBS_NODEFILE:?must run inside a PBS job}"
mapfile -t ALLNODES < <(sort -u "$FULL_NODEFILE")
say "allocation: ${#ALLNODES[@]} nodes: ${ALLNODES[*]}"
[ "${#ALLNODES[@]}" -ge 2 ] || { say "need >=2 nodes"; exit 1; }
say "broker node = ${ALLNODES[0]} | workload node = ${ALLNODES[1]}"

# EXACT submit_cxi.sh 881s-baseline config.
EVENTS=${EVENTS:-1000}
CHECKPOINTS=${CHECKPOINTS:-2}
ML_FILES=${ML_FILES:-64}
ML_ROWS=${ML_ROWS:-4096}
ML_COLS=${ML_COLS:-64}
PARTITIONS=${PARTITIONS:-16}
CONSUMERS=${CONSUMERS:-1}

# run_arm <tag> <write_mode>
run_arm() {
  local tag="$1" wmode="$2"
  say "RUN python-ml/$tag (ML_WRITE_MODE=$wmode, streaming ON, default progress thread)"
  # NO custom DARSHAN_MOFKA_MARGO_JSON exported -> connector default use_progress_thread=1.
  PBS_NODEFILE="$FULL_NODEFILE" \
  env ML_WRITE_MODE="$wmode" \
    MOFKA_PROTOCOL=ofi+cxi WORKLOAD=python-ml TASKS=1 REPS=1 PLACEMENT=separate \
    EVENTS="$EVENTS" CHECKPOINTS="$CHECKPOINTS" \
    ML_FILES="$ML_FILES" ML_ROWS="$ML_ROWS" ML_COLS="$ML_COLS" \
    PARTITIONS="$PARTITIONS" CONSUMERS="$CONSUMERS" \
    DM_MPSTAT=1 DM_MPSTAT_INT=5 \
    DARSHAN_MOFKA_ENABLE=1 NO_DARSHAN=0 DARSHAN_MOFKA_BATCH=0 \
    DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 DIASPORA_C_SENDER_THREADS=1 \
    RESULTS_TAG="DIAGWRITE_python-ml/${tag}" \
    bash workloads/job.sh python-ml >> "$LOG" 2>&1 \
    && say "  done python-ml/$tag" || say "  FAILED python-ml/$tag (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 4
}

say "===== python-ml write-pattern A/B: row (385k events) vs buffered (128k events), both streaming ====="
run_arm row_385k      row
run_arm buffered_128k buffered

say "===== DIAGWRITE DONE ====="
