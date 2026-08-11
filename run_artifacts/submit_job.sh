#!/bin/bash
set -euo pipefail

# ===================== KNOBS (edit these) =====================
ACCOUNT=radix-io
QUEUE=debug          # debug (<=2 nodes) | debug-scaling (~10) | prod
WALLTIME=01:00:00
NODES=2             # 1 broker/consumer (N0) + rest run the workload
NCPUS=32             # Polaris compute node = 32 physical cores

WORKLOAD=python-ml   # c | io_bench | io_bench_py | python-ml  (NOT mpi over cxi)
TASKS=1              # workload processes PER workload node
REPS=2               # repeat the whole run N times
EVENTS=100           # workload scale knob (write-events / steps)
PARTITIONS=16        # broker partitions (>= CONSUMERS to scale the drain)
CONSUMERS=1          # parallel sharded FlowCept drainers on N0

# io_bench only (moderate/sustained defaults)
IO_SIZE_MB=16
IO_ITERS=16
IO_SLEEP_MS=50
IO_BLOCK_KB=1024
COMPUTE=76           # dense NxN matmuls per I/O iteration (0=off); I/O unchanged
MATRIX_SIZE=512      # ~10 min/rank: 16 iters * 76 matmuls * ~0.5s @ N=512

# connector (env-var-wins over workload.config; this file is the single source)
MAX_BATCHES=512      # backpressure/drop point
FLUSH_MS=30000       # final drain-wait ceiling
ENABLE=1             # 1=stream (arm C), 0=darshan-native only (arm B)
TIMING=1             # 1=per-call us to stderr, 0=clean macro run

SKIP_BUILD=1
# ==============================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCOUNT="${PBS_ACCOUNT:-$ACCOUNT}"
[ -n "$ACCOUNT" ] || { echo "set PBS_ACCOUNT=<project>"; exit 1; }

# Polaris needs -l filesystems (home + eagle are distinct Lustre mounts).
source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=()
[[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")

# ofi+cxi -> job.sh RUN_MODE=mpmd; forward knobs as config overrides.
VARS=(
  MOFKA_PROTOCOL=ofi+cxi PLACEMENT=separate
  WORKLOAD="$WORKLOAD" NODES="$NODES" TASKS="$TASKS" REPS="$REPS" EVENTS="$EVENTS"
  PARTITIONS="$PARTITIONS" CONSUMERS="$CONSUMERS"
  IO_SIZE_MB="$IO_SIZE_MB" IO_ITERS="$IO_ITERS" IO_SLEEP_MS="$IO_SLEEP_MS" IO_BLOCK_KB="$IO_BLOCK_KB"
  COMPUTE="$COMPUTE" MATRIX_SIZE="$MATRIX_SIZE"
  DARSHAN_MOFKA_MAX_BATCHES="$MAX_BATCHES"
  DARSHAN_MOFKA_FLUSH_MS="$FLUSH_MS"
  DARSHAN_MOFKA_ENABLE="$ENABLE"
  DARSHAN_MOFKA_TIMING="$TIMING"
  SKIP_BUILD="$SKIP_BUILD"
  DIASPORA_C_SENDER_THREADS="${DIASPORA_C_SENDER_THREADS:-1}"
)

# optional passthroughs: forwarded only if set in the shell
for v in MONGOD DARSHAN_MOFKA_ASYNC RESULTS_TAG RPC_THREADS NO_DARSHAN; do
  if [ -n "${!v:-}" ]; then VARS+=("$v=${!v}"); fi
done

FWD=$(IFS=,; echo "${VARS[*]}")

echo "submit: select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} q=$QUEUE wall=$WALLTIME cxi mpmd | $WORKLOAD ${TASKS}task/node reps=$REPS part=$PARTITIONS cons=$CONSUMERS"

qsub -A "$ACCOUNT" -q "$QUEUE" \
     -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
     "${PBS_EXTRA[@]}" -N dm_cxi -j oe -o "$ROOT/results/" -v "$FWD" <<PBS
cd "$ROOT"

PBS