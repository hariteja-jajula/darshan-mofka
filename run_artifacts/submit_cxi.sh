#!/bin/bash
# submit_cxi.sh -- THE one file to edit + submit for a cross-node ofi+cxi run.
# Edit the knobs below, then:  PBS_ACCOUNT=radix-io bash run_artifacts/submit_cxi.sh
#
# Forces ofi+cxi, which selects the single-MPMD path in job.sh (broker + FlowCept
# consumer + Darshan workload in ONE mpiexec sharing one Slingshot job VNI). Non-MPI
# workloads only (c | io_bench | python-ml); MPI-IO stays on the legacy/TCP baseline
# (Gate-0: MPI_Init hangs beside a stripped MPMD section -- run_artifacts/DECISION.md).
set -euo pipefail

# ===================== KNOBS (edit these) =====================
NODES="${NODES:-2}"            # total nodes: 1 broker/consumer (N0) + rest run the workload
TASKS="${TASKS:-1}"            # workload processes PER workload node
WORKLOAD="${WORKLOAD:-io_bench}"   # c | io_bench | python-ml   (NOT mpi over cxi)
REPS="${REPS:-1}"             # repeat the whole run N times
EVENTS="${EVENTS:-8}"         # workload scale knob (write-events / steps)
PARTITIONS="${PARTITIONS:-1}" # broker partitions (>= CONSUMERS to scale the drain)
CONSUMERS="${CONSUMERS:-1}"   # parallel sharded FlowCept drainers on N0
QUEUE="${QUEUE:-debug}"       # debug (<=2 nodes) | debug-scaling (up to ~10) | prod
WALLTIME="${WALLTIME:-00:30:00}"
NCPUS="${NCPUS:-32}"          # Polaris compute node = 32 physical cores
# io_bench profile (only used when WORKLOAD=io_bench; defaults = moderate/sustained):
IO_SIZE_MB="${IO_SIZE_MB:-16}"; IO_ITERS="${IO_ITERS:-16}"
IO_SLEEP_MS="${IO_SLEEP_MS:-50}"; IO_BLOCK_KB="${IO_BLOCK_KB:-1024}"
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
FWD="$FWD,EVENTS=$EVENTS,PARTITIONS=$PARTITIONS,CONSUMERS=$CONSUMERS,PLACEMENT=separate"
FWD="$FWD,IO_SIZE_MB=$IO_SIZE_MB,IO_ITERS=$IO_ITERS,IO_SLEEP_MS=$IO_SLEEP_MS,IO_BLOCK_KB=$IO_BLOCK_KB"
[ -n "${SKIP_BUILD:-}" ] && FWD="$FWD,SKIP_BUILD=$SKIP_BUILD"
[ -n "${MONGOD:-}" ]     && FWD="$FWD,MONGOD=$MONGOD"

echo "submit: select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} q=$QUEUE wall=$WALLTIME cxi mpmd | $WORKLOAD ${TASKS}task/node reps=$REPS part=$PARTITIONS cons=$CONSUMERS"
qsub -A "$account" -q "$QUEUE" \
     -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
     "${PBS_EXTRA[@]}" -N dm_cxi -j oe -o "$ROOT/results/" -v "$FWD" <<PBS
cd "$ROOT"
bash workloads/job.sh
PBS
