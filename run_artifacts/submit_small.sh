#!/bin/bash
# submit_small.sh -- request 10 nodes on `small` (3h) and run the whole study serially
# inside one allocation via study_alloc.sh. Charges the allocation (schedules reliably,
# unlike 2-node debug/preemptable). Edit NODES/WALLTIME if needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
account="${PBS_ACCOUNT:-radix-io}"
NODES="${NODES:-10}"; NCPUS="${NCPUS:-32}"; WALLTIME="${WALLTIME:-03:00:00}"; QUEUE="${QUEUE:-small}"
source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=(); [[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")

echo "submit: q=$QUEUE nodes=$NODES wall=$WALLTIME -> study_alloc.sh (serial full study)"
qsub -A "$account" -q "$QUEUE" \
     -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
     "${PBS_EXTRA[@]}" -N dm_study -j oe -o "$ROOT/results/" <<PBS
cd "$ROOT"
bash run_artifacts/study_alloc.sh
PBS
