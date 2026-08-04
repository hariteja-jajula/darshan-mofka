#!/bin/bash
# paper_repro.sh -- reproduce the Mofka paper's overhead methodology for ONE workload:
#   overlap-friendly regime (COMPUTE=0, I/O + sleep -> slack for background streaming),
#   message service on its OWN node, self-timed overhead metric, batch-size SWEEP.
# One PBS job = baseline (1 rep) + streaming at each batch size in BSWEEP (1 rep each).
# Streaming carries the ABT-safe fix (DIASPORA_C_SENDER_THREADS=1) + A' yielding progress.
#
# Usage:
#   PBS_ACCOUNT=radix-io WL=io_bench PROTO=ofi+cxi TASKS=1 QUEUE=debug NODES=2 \
#     EV=... PART=4 CONS=1 BSWEEP="0 100 1000" \
#     bash run_artifacts/jobs/paper_repro.sh
set -euo pipefail
ROOT="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
account="${PBS_ACCOUNT:-radix-io}"
WL="${WL:?set WL}"; PROTO="${PROTO:?set PROTO}"; TASKS="${TASKS:?set TASKS}"
NODES="${NODES:-2}"; QUEUE="${QUEUE:-debug}"; WALL="${WALL:-01:00:00}"
EV="${EV:-100}"; PART="${PART:-4}"; CONS="${CONS:-1}"; RPC="${RPC:-0}"
IO_ITERS="${IO_ITERS:-16}"; IO_SLEEP_MS="${IO_SLEEP_MS:-50}"; IO_SIZE_MB="${IO_SIZE_MB:-16}"; IO_BLOCK_KB="${IO_BLOCK_KB:-1024}"
BSWEEP="${BSWEEP:-0 100 1000}"     # 0=Adaptive; paper sweeps 10/100/1k/10k
STUDY="${STUDY:-PAPER_${WL}}"
source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=(); [[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")
mkdir -p "$ROOT/results/$STUDY"
echo "submit: $WL $PROTO ${TASKS}t/node nodes=$NODES q=$QUEUE bsweep=[$BSWEEP] EV=$EV -> results/$STUDY"

qsub -A "$account" -q "$QUEUE" -l select="${NODES}:ncpus=32:mpiprocs=32" -l walltime="$WALL" \
     "${PBS_EXTRA[@]}" -N "paper_$WL" -j oe -o "$ROOT/results/$STUDY/" \
     -v "WL=$WL,PROTO=$PROTO,NODES=$NODES,TASKS=$TASKS,EV=$EV,PART=$PART,CONS=$CONS,RPC=$RPC,IO_ITERS=$IO_ITERS,IO_SLEEP_MS=$IO_SLEEP_MS,IO_SIZE_MB=$IO_SIZE_MB,IO_BLOCK_KB=$IO_BLOCK_KB,STUDY=$STUDY,SREPS=${SREPS:-3},ML_FILES=${ML_FILES:-},ML_ROWS=${ML_ROWS:-},ML_COLS=${ML_COLS:-}" <<'PBS'
ROOT="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
cd "$ROOT"; set -uo pipefail
export DARSHAN_MOFKA_MARGO_JSON='{"use_progress_thread":false,"rpc_thread_count":0,"argobots":{"pools":[{"name":"__primary__","kind":"fifo_wait","access":"mpmc"},{"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],"xstreams":[{"name":"__primary__","scheduler":{"type":"basic_wait","pools":["__primary__"]}},{"name":"__progress__","scheduler":{"type":"basic_wait","pools":["__progress__"]}}]},"progress_pool":"__progress__"}'

# COMPUTE=0 => overlap-friendly (I/O + sleep, no compute saturation) = the paper's regime.
run(){  # $1=arm-tag $2=enable $3=nodarshan $4=batch $5=sender
  echo "===== ARM $1 (batch=$4) $(date '+%H:%M:%S') ====="
  MOFKA_PROTOCOL="$PROTO" WORKLOAD="$WL" NODES="$NODES" TASKS="$TASKS" REPS=1 PLACEMENT=separate \
    EVENTS="$EV" PARTITIONS="$PART" CONSUMERS="$CONS" \
    IO_SIZE_MB="$IO_SIZE_MB" IO_ITERS="$IO_ITERS" IO_SLEEP_MS="$IO_SLEEP_MS" IO_BLOCK_KB="$IO_BLOCK_KB" \
    COMPUTE=0 MATRIX_SIZE=256 \
    DARSHAN_MOFKA_ENABLE="$2" NO_DARSHAN="$3" DARSHAN_MOFKA_BATCH="$4" DARSHAN_MOFKA_MAX_BATCHES=512 \
    DARSHAN_MOFKA_FLUSH_MS=30000 DARSHAN_MOFKA_TIMING=1 DARSHAN_MOFKA_DROP_POLICY=block \
    RPC_THREADS="$RPC" SKIP_BUILD=1 DIASPORA_C_SENDER_THREADS="$5" \
    ML_FILES="${ML_FILES:-}" ML_ROWS="${ML_ROWS:-}" ML_COLS="${ML_COLS:-}" \
    RESULTS_TAG="$STUDY/$1" \
    bash workloads/job.sh "$WL" || echo "ARM $1 nonzero"
  pkill -f 'bedrock ' 2>/dev/null||true; pkill -f mongod 2>/dev/null||true; sleep 3
}

# baseline once, then streaming Adaptive (batch=0) for SREPS reps (paper default = Adaptive).
run baseline 1 1 0 0
SREPS="${SREPS:-3}"
for r in $(seq 1 "$SREPS"); do run "streaming_rep$r" 1 0 0 1; done
echo "===== PAPER_REPRO DONE ($WL) $(date '+%H:%M:%S') ====="
PBS
