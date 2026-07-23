#!/bin/bash
# submit.sh -- send job.sh to a compute node through PBS.
#
# The broker needs a compute node (its network transport does not come up on login
# nodes), so this is how you run the demo in batch.
#
# Usage:
#   PBS_ACCOUNT=<project> bash submit.sh [workload] [walltime] [queue]
#   # examples:
#   PBS_ACCOUNT=radix-io bash submit.sh                 # C smoke, 30 min, debug
#   PBS_ACCOUNT=radix-io bash submit.sh python-ml 00:45:00 debug
#   SKIP_BUILD=1 PBS_ACCOUNT=radix-io bash submit.sh    # reuse an existing build
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT="${PBS_ACCOUNT:-${ACCOUNT:-}}"
[ -n "$ACCOUNT" ] || { echo "set your allocation:  PBS_ACCOUNT=<project> bash submit.sh"; exit 1; }
WORKLOAD="${1:-c}"; WALLTIME="${2:-00:30:00}"; QUEUE="${3:-debug}"

# forward the knobs job.sh understands into the batch environment
FWD="WORKLOAD=$WORKLOAD"
[ -n "${SKIP_BUILD:-}" ]            && FWD="$FWD,SKIP_BUILD=$SKIP_BUILD"
[ -n "${MONGOD:-}" ]               && FWD="$FWD,MONGOD=$MONGOD"
[ -n "${DARSHAN_MOFKA_PROFILE:-}" ] && FWD="$FWD,DARSHAN_MOFKA_PROFILE=$DARSHAN_MOFKA_PROFILE"

# submit an inline wrapper so PBS_O_WORKDIR is the repo; the wrapper cds there and
# runs job.sh from the real tree (qsub otherwise copies the script to a spool dir).
qsub -A "$ACCOUNT" -q "$QUEUE" -l select=1:ncpus=32 -l walltime="$WALLTIME" \
     -N "dm_${WORKLOAD}" -j oe -o "$ROOT/results/" -v "$FWD" <<PBS
cd "$ROOT"
bash job.sh
PBS
