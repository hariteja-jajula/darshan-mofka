#!/bin/bash

set -euo pipefail



# ===================== KNOBS (edit these) =====================
NODES=4            # total nodes: 1 broker/consumer (N0) + 3 run the realistic ML workload (1 rank/node)
TASKS=1            # workload processes PER workload node (cxi/mpmd = 1 rank/node)
WORKLOAD=python-ml   # c | io_bench | io_bench_py | python-ml   (NOT mpi over cxi)
REPS=2             # repeat the whole run N times
EVENTS=600         # -> ML_EPOCHS. Realistic trainer: login-node calib ~0.83s/epoch non-streaming,
                   # so 600 epochs ~= 10min WORK/rep non-streaming; streaming adds overhead on top,
                   # so >=10min/rep with ENABLE=1. REPS=2 -> ~20-24min work, safely inside 1h wall.
PARTITIONS=16 # broker partitions (>= CONSUMERS to scale the drain)
CONSUMERS=1   # parallel sharded FlowCept drainers on N0
QUEUE=debug-scaling  # 4 nodes -> debug-scaling (debug is <=2 nodes)
WALLTIME=01:00:00
NCPUS=32          # Polaris compute node = 32 physical cores
# python-ml dataset size (big -> meaningful ~10min run; matches PAPER_pythonml calibration):
ML_FILES=64
ML_ROWS=4096
ML_COLS=64
CHECKPOINTS=2
# non-invasive per-core CPU sampling on the workload rank (mpstat -P ALL every N s -> mpstat.0.txt):
DM_MPSTAT=1
DM_MPSTAT_INT=5
# io_bench profile (only used when WORKLOAD=io_bench; defaults = moderate/sustained):


IO_SIZE_MB=16
IO_ITERS=16
IO_SLEEP_MS=50
IO_BLOCK_KB=1024
# compute knobs (io_bench): COMPUTE dense NxN matmuls PER I/O iteration (0=off),
# MATRIX_SIZE = N. I/O is UNCHANGED (same 600 events) -- this only adds per-rank CPU.
# Default tuned for ~10 min/rank: 16 iters * 76 matmuls * ~0.5s (N=512) ~= 600s.
# (login-node estimate; read WORK_START_NS/WORK_END_NS in the log to recalibrate.)
COMPUTE=76
MATRIX_SIZE=512


BATCH=512          # DARSHAN_MOFKA_BATCH: producer BatchSize. 0=Adaptive (send-on-notify=~1 RPC/event,
                   # the +351s pathology); N>0 = fixed N events/RPC (~384938/N RPCs). 512 => ~750 RPCs.
MAX_BATCHES=512    # DARSHAN_MOFKA_MAX_BATCHES: backpressure/drop point (run.sh default 64).
                   # INERT under Adaptive; becomes a live "block when N batches pending" valve once BATCH>0.
FLUSH_MS=30000        # DARSHAN_MOFKA_FLUSH_MS: final drain-wait ceiling (run.sh default 5000)
ENABLE=1                # DARSHAN_MOFKA_ENABLE: 1=stream (arm C), 0=darshan-native-only (arm B)
TIMING=1                # DARSHAN_MOFKA_TIMING: 1=emit per-call us to stderr (micro metrics), 0=clean macro run (run.sh default 1)

account=radix-io
SKIP_BUILD=1
# Route this BATCH=512 validation into its own results subdir so it doesn't mix with the
# Adaptive baseline (PYTHONML_2NODE_1PROC_1Broker-separate/RUN5,RUN6). One-variable A/B.
RESULTS_TAG=${RESULTS_TAG:-REALISTIC_pythonml_N4}
# ==============================================================





ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
account="${PBS_ACCOUNT:-radix-io}"
[ -n "$account" ] || { echo "set PBS_ACCOUNT=<project>"; exit 1; }

# Polaris needs -l filesystems (home + eagle are distinct Lustre mounts).
source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=()
[[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")

# ofi+cxi -> job.sh RUN_MODE=mpmd; forward the knobs as config overrides.
FWD="MOFKA_PROTOCOL=ofi+cxi,WORKLOAD=$WORKLOAD,NODES=$NODES,TASKS=$TASKS,REPS=$REPS"
FWD="$FWD,EVENTS=$EVENTS,CHECKPOINTS=$CHECKPOINTS,PARTITIONS=$PARTITIONS,CONSUMERS=$CONSUMERS,PLACEMENT=separate"
# python-ml dataset-size knobs (workload_env forwards ML_FILES/ML_ROWS/ML_COLS when set) + CPU sampler
FWD="$FWD,ML_FILES=$ML_FILES,ML_ROWS=$ML_ROWS,ML_COLS=$ML_COLS,DM_MPSTAT=$DM_MPSTAT,DM_MPSTAT_INT=$DM_MPSTAT_INT"
FWD="$FWD,IO_SIZE_MB=$IO_SIZE_MB,IO_ITERS=$IO_ITERS,IO_SLEEP_MS=$IO_SLEEP_MS,IO_BLOCK_KB=$IO_BLOCK_KB"
FWD="$FWD,COMPUTE=$COMPUTE,MATRIX_SIZE=$MATRIX_SIZE"
# connector knobs (env-var-wins over workload.config, so this file is the single source):
FWD="$FWD,DARSHAN_MOFKA_BATCH=$BATCH,DARSHAN_MOFKA_MAX_BATCHES=$MAX_BATCHES,DARSHAN_MOFKA_FLUSH_MS=$FLUSH_MS,DARSHAN_MOFKA_ENABLE=$ENABLE"
# TIMING is now a first-class knob in the block above (value-based gate: 0=off, 1=on),
# so it is always forwarded -- this file is the single source, workload.config is gone.
FWD="$FWD,DARSHAN_MOFKA_TIMING=$TIMING"
[ -n "${SKIP_BUILD:-}" ] && FWD="$FWD,SKIP_BUILD=$SKIP_BUILD"
[ -n "${MONGOD:-}" ]     && FWD="$FWD,MONGOD=$MONGOD"
# A/B: forward DARSHAN_MOFKA_ASYNC when set in the environment (0=sync inline push, 1=async default).
[ -n "${DARSHAN_MOFKA_ASYNC:-}" ] && FWD="$FWD,DARSHAN_MOFKA_ASYNC=$DARSHAN_MOFKA_ASYNC"
# Fix: run the producer sender on a dedicated Argobots ES (ABT-safe push, no raw-pthread
# thallium::mutex). Default ON (1) for this study; override with DIASPORA_C_SENDER_THREADS.
FWD="$FWD,DIASPORA_C_SENDER_THREADS=${DIASPORA_C_SENDER_THREADS:-1}"
# Study driver: route this job's runs into a labeled results subdir + set rpc threads.
[ -n "${RESULTS_TAG:-}" ]        && FWD="$FWD,RESULTS_TAG=$RESULTS_TAG"
[ -n "${RPC_THREADS:-}" ]        && FWD="$FWD,RPC_THREADS=$RPC_THREADS"
# Baseline arm: run workload without libdarshan (raw wall time, no streaming).
[ -n "${NO_DARSHAN:-}" ]         && FWD="$FWD,NO_DARSHAN=$NO_DARSHAN"

echo "submit: select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} q=$QUEUE wall=$WALLTIME cxi mpmd | $WORKLOAD ${TASKS}task/node reps=$REPS part=$PARTITIONS cons=$CONSUMERS"
qsub -A "$account" -q "$QUEUE" \
     -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
     "${PBS_EXTRA[@]}" -N dm_cxi -j oe -o "$ROOT/results/" -v "$FWD" <<PBS
cd "$ROOT"
# Fix A' (work.py model): yielding dedicated progress thread, NO cpubind/pinning.
# Exported here (not via -v) so the JSON's commas don't corrupt the qsub -v list.
# run.sh forwards DARSHAN_MOFKA_MARGO_JSON into CONNECTOR_ENV -> reaches the workload rank.
export DARSHAN_MOFKA_MARGO_JSON='{"use_progress_thread":false,"rpc_thread_count":0,"argobots":{"pools":[{"name":"__primary__","kind":"fifo_wait","access":"mpmc"},{"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],"xstreams":[{"name":"__primary__","scheduler":{"type":"basic_wait","pools":["__primary__"]}},{"name":"__progress__","scheduler":{"type":"basic_wait","pools":["__progress__"]}}]},"progress_pool":"__progress__"}'
bash workloads/job.sh
PBS
